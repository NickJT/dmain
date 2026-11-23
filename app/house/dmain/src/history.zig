//! A range of the house logs as the admin app's charts draw it: each sensor's
//! temperature and humidity as segments of readings, the gaps between them and
//! why, and each motion sensor's spans of motion.
//!
//! **A reading holds until the next, for `stale_ms` at most.** These sensors
//! report only on a change, so a steady room is quiet for an hour and its line
//! carries on flat; past `stale_ms` the line stops and a gap says the sensor
//! went silent. A link the source calls lost stops it at once. Nothing is ever
//! joined across a gap, because that would invent readings.
//!
//! **The range starts with what was true at its start**: the last reading before
//! it, if recent enough, is carried to the range's first instant. So a caller
//! replays the day before the range too.
//!
//! Pure: records in, series out. Times are Unix milliseconds.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const houselog = @import("houselog");
const display_cfg = @import("display.zig");

pub const Point = struct {
    t: i64,
    v: f64,

    /// `[t, v]`: a month of readings is most of what the app is sent.
    pub fn jsonStringify(self: Point, jw: anytype) !void {
        try jw.write(.{ self.t, self.v });
    }
};

pub const Why = enum { link_lost, silent };

pub const Gap = struct {
    from: i64,
    /// null while it lasts to the end of the range.
    to: ?i64,
    why: Why,
};

pub const Series = struct {
    dev: []const u8,
    label: []const u8,
    outside: bool,
    segments: []const []const Point,
    gaps: []const Gap,
};

pub const Span = struct { from: i64, to: i64 };

pub const MotionSeries = struct {
    dev: []const u8,
    label: []const u8,
    outdoor: bool,
    spans: []const Span,
};

pub const History = struct {
    from: i64,
    to: i64,
    /// The newest record read, from either log: where today's lines stop.
    newest: ?i64,
    /// Whether temperatures are as the sensors gave them, or with `display.json`'s corrections.
    raw: bool,
    temperature: []const Series,
    humidity: []const Series,
    motion: []const MotionSeries,
};

pub const Options = struct {
    from: i64,
    to: i64,
    stale_ms: i64,
    raw: bool = false,
    /// Readings closer together than the range over this are kept as one, the
    /// last, so a month draws as fast as a day. A step line loses only the
    /// brief excursions between.
    max_points: i64 = 1500,
};

const Track = struct {
    dev: []const u8,
    label: []const u8,
    outside: bool,
    correction: f64,
    current: std.ArrayList(Point) = .empty,
    segments: std.ArrayList([]const Point) = .empty,
    gaps: std.ArrayList(Gap) = .empty,
    last_t: ?i64 = null,
    last_v: f64 = 0,
    lost: bool = false,
    /// Whether the range's start has been settled from what came before it.
    started: bool = false,

    fn close(self: *Track, a: Allocator) !void {
        if (self.current.items.len == 0) return;
        try self.segments.append(a, try self.current.toOwnedSlice(a));
    }

    /// Carries the last reading before the range to its start, if it was recent.
    fn start(self: *Track, a: Allocator, o: Options) !void {
        if (self.started) return;
        self.started = true;
        const t = self.last_t orelse return;
        if (self.lost or o.from - t > o.stale_ms) return;
        try self.current.append(a, .{ .t = o.from, .v = self.last_v });
    }

    fn reading(self: *Track, a: Allocator, o: Options, t: i64, raw_v: f64) !void {
        if (t > o.to) return;
        // Hundredths: finer than any of these sensors, and free of float noise.
        const v = @round((if (o.raw) raw_v else raw_v + self.correction) * 100) / 100;
        if (t < o.from) {
            self.last_t = t;
            self.last_v = v;
            self.lost = false;
            return;
        }
        try self.start(a, o);
        if (self.lost) {
            // A reading means the link is back.
            self.lost = false;
            if (self.gaps.items.len > 0 and self.gaps.items[self.gaps.items.len - 1].to == null)
                self.gaps.items[self.gaps.items.len - 1].to = t;
        } else if (self.last_t) |last| {
            if (t - last > o.stale_ms and self.current.items.len > 0) {
                const until = last + o.stale_ms;
                try self.current.append(a, .{ .t = until, .v = self.last_v });
                try self.close(a);
                try self.gaps.append(a, .{ .from = until, .to = t, .why = .silent });
            }
        }
        const bucket = @max(1, @divTrunc(o.to - o.from, o.max_points));
        const items = self.current.items;
        if (items.len > 1 and t - items[items.len - 1].t < bucket) {
            items[items.len - 1].v = v;
        } else {
            try self.current.append(a, .{ .t = t, .v = v });
        }
        self.last_t = t;
        self.last_v = v;
    }

    fn link(self: *Track, a: Allocator, o: Options, t: i64, connected: bool) !void {
        if (t > o.to) return;
        if (connected or self.lost) return;
        self.lost = true;
        if (t < o.from) return;
        try self.start(a, o);
        if (self.current.items.len > 0) {
            try self.current.append(a, .{ .t = t, .v = self.last_v });
            try self.close(a);
        }
        try self.gaps.append(a, .{ .from = t, .to = null, .why = .link_lost });
    }

    fn finish(self: *Track, a: Allocator, o: Options, end: i64) !?Series {
        try self.start(a, o);
        if (!self.lost) if (self.last_t) |last| {
            const until = @min(end, last + o.stale_ms);
            const items = self.current.items;
            if (items.len > 0 and until > items[items.len - 1].t) try self.current.append(a, .{ .t = until, .v = self.last_v });
            if (items.len > 0 and last + o.stale_ms < end) try self.gaps.append(a, .{ .from = until, .to = null, .why = .silent });
        };
        try self.close(a);
        if (self.segments.items.len == 0 and self.gaps.items.len == 0) return null;
        return .{ .dev = self.dev, .label = self.label, .outside = self.outside, .segments = self.segments.items, .gaps = self.gaps.items };
    }
};

const MotionTrack = struct {
    row: display_cfg.MotionRow,
    on_since: ?i64 = null,
    spans: std.ArrayList(Span) = .empty,

    fn set(self: *MotionTrack, a: Allocator, o: Options, t: i64, on: bool) !void {
        if (on) {
            if (self.on_since == null) self.on_since = t;
        } else if (self.on_since) |since| {
            try self.add(a, o, since, t);
            self.on_since = null;
        }
    }

    fn add(self: *MotionTrack, a: Allocator, o: Options, from: i64, to: i64) !void {
        const f = @max(from, o.from);
        const t = @min(to, o.to);
        if (t > f) try self.spans.append(a, .{ .from = f, .to = t });
    }
};

/// A `reader.replay` handler: give it every record from the day before the range
/// to its end, from both logs, then `finish`.
pub const Fold = struct {
    arena: Allocator,
    options: Options,
    temperature: []Track,
    humidity: []Track,
    motion: []MotionTrack,
    newest: ?i64 = null,
    failed: bool = false,
    bad_lines: usize = 0,

    pub fn init(arena: Allocator, display: display_cfg.Config, options: Options) !Fold {
        const temperature = try arena.alloc(Track, display.display.len);
        const humidity = try arena.alloc(Track, display.display.len);
        for (display.display, temperature, humidity) |row, *t, *h| {
            t.* = .{ .dev = row.dev, .label = row.label, .outside = row.outside, .correction = row.correction };
            // Humidity has no calibration.
            h.* = .{ .dev = row.dev, .label = row.label, .outside = row.outside, .correction = 0 };
        }
        const motion = try arena.alloc(MotionTrack, display.motion.len);
        for (display.motion, motion) |row, *m| m.* = .{ .row = row };
        return .{ .arena = arena, .options = options, .temperature = temperature, .humidity = humidity, .motion = motion };
    }

    fn find(tracks: []Track, dev: []const u8) ?*Track {
        for (tracks) |*t| if (std.mem.eql(u8, t.dev, dev)) return t;
        return null;
    }

    fn findMotion(self: *Fold, dev: []const u8) ?*MotionTrack {
        for (self.motion) |*m| if (std.mem.eql(u8, m.row.dev, dev)) return m;
        return null;
    }

    pub fn record(self: *Fold, r: houselog.Record) void {
        self.take(r) catch {
            self.failed = true;
        };
    }

    pub fn bad(self: *Fold, _: []const u8, _: houselog.ParseError) void {
        self.bad_lines += 1;
    }

    fn take(self: *Fold, r: houselog.Record) !void {
        const t = r.at.toMilliseconds();
        if (self.newest == null or self.newest.? < t) self.newest = t;
        const a = self.arena;
        const o = self.options;
        switch (r.body) {
            .temperature => |b| if (find(self.temperature, b.dev)) |track| try track.reading(a, o, t, b.c),
            .humidity => |b| if (find(self.humidity, b.dev)) |track| try track.reading(a, o, t, b.rh),
            .motion => |b| if (self.findMotion(b.dev)) |m| {
                // A snapshot says when its state began, which may be before the log.
                const at = if (b.since) |s| s.toMilliseconds() else t;
                try m.set(a, o, at, b.on);
            },
            .link => |b| {
                const connected = b.status == .connected;
                if (find(self.temperature, b.dev)) |track| try track.link(a, o, t, connected);
                if (find(self.humidity, b.dev)) |track| try track.link(a, o, t, connected);
                if (!connected) if (self.findMotion(b.dev)) |m| try m.set(a, o, t, false);
            },
            else => {},
        }
    }

    pub fn finish(self: *Fold) !History {
        if (self.failed) return error.OutOfMemory;
        const a = self.arena;
        const o = self.options;
        const end = @min(o.to, self.newest orelse o.to);
        var temperature: std.ArrayList(Series) = .empty;
        for (self.temperature) |*t| if (try t.finish(a, o, end)) |s| try temperature.append(a, s);
        var humidity: std.ArrayList(Series) = .empty;
        for (self.humidity) |*t| if (try t.finish(a, o, end)) |s| try humidity.append(a, s);
        const motion = try a.alloc(MotionSeries, self.motion.len);
        for (self.motion, motion) |*m, *out| {
            if (m.on_since) |since| try m.add(a, o, since, end);
            out.* = .{ .dev = m.row.dev, .label = m.row.label, .outdoor = m.row.outdoor, .spans = m.spans.items };
        }
        return .{
            .from = o.from,
            .to = o.to,
            .newest = self.newest,
            .raw = o.raw,
            .temperature = temperature.items,
            .humidity = humidity.items,
            .motion = motion,
        };
    }
};

const testing = std.testing;

const MIN: i64 = 60_000;

fn rec(t_min: i64, body: houselog.Body) houselog.Record {
    return .{ .at = .fromNanoseconds(@as(i96, t_min * MIN) * std.time.ns_per_ms), .src = "hue-bridge", .body = body };
}

const test_display: display_cfg.Config = .{
    .arena = undefined,
    .stale_min = 120,
    .display = &.{
        .{ .dev = "k", .label = "Kitchen", .correction = 1.5 },
        .{ .dev = "o", .label = "Outside", .outside = true },
    },
    .motion = &.{.{ .dev = "k", .label = "Kitchen" }},
};

/// A range of 1000 minutes from minute 1000, held for two hours.
const opts: Options = .{ .from = 1000 * MIN, .to = 2000 * MIN, .stale_ms = 120 * MIN };

test "a reading before the range carries to its start, and the line holds to the newest record" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var fold = try Fold.init(arena.allocator(), test_display, opts);
    fold.record(rec(950, .{ .temperature = .{ .dev = "k", .c = 18 } }));
    fold.record(rec(1030, .{ .temperature = .{ .dev = "k", .c = 19 } }));
    fold.record(rec(1060, .heartbeat));
    const h = try fold.finish();
    const k = h.temperature[0];
    try testing.expectEqualStrings("Kitchen", k.label);
    try testing.expectEqual(@as(usize, 1), k.segments.len);
    const pts = k.segments[0];
    // Corrected by 1.5; the start carried from minute 950; the end at the newest record.
    try testing.expectEqual(Point{ .t = 1000 * MIN, .v = 19.5 }, pts[0]);
    try testing.expectEqual(Point{ .t = 1030 * MIN, .v = 20.5 }, pts[1]);
    try testing.expectEqual(Point{ .t = 1060 * MIN, .v = 20.5 }, pts[2]);
    try testing.expectEqual(@as(usize, 0), k.gaps.len);
    // Outside never reported, so it isn't drawn at all.
    try testing.expectEqual(@as(usize, 1), h.temperature.len);
}

test "silence past stale_ms ends the line and says so, and the raw option leaves values alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var o = opts;
    o.raw = true;
    var fold = try Fold.init(arena.allocator(), test_display, o);
    fold.record(rec(1010, .{ .temperature = .{ .dev = "k", .c = 18 } }));
    fold.record(rec(1500, .{ .temperature = .{ .dev = "k", .c = 17 } }));
    fold.record(rec(1520, .heartbeat));
    const k = (try fold.finish()).temperature[0];
    try testing.expectEqual(@as(usize, 2), k.segments.len);
    try testing.expectEqual(Point{ .t = 1130 * MIN, .v = 18 }, k.segments[0][1]);
    try testing.expectEqual(Gap{ .from = 1130 * MIN, .to = 1500 * MIN, .why = .silent }, k.gaps[0]);
    try testing.expectEqual(Point{ .t = 1500 * MIN, .v = 17 }, k.segments[1][0]);
}

test "a lost link ends the line at once, and the next reading starts a new one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var fold = try Fold.init(arena.allocator(), test_display, opts);
    fold.record(rec(1010, .{ .temperature = .{ .dev = "k", .c = 18 } }));
    fold.record(rec(1020, .{ .link = .{ .dev = "k", .status = .disconnected } }));
    fold.record(rec(1080, .{ .link = .{ .dev = "k", .status = .connected } }));
    fold.record(rec(1090, .{ .temperature = .{ .dev = "k", .c = 18 } }));
    fold.record(rec(1100, .heartbeat));
    const k = (try fold.finish()).temperature[0];
    try testing.expectEqual(@as(usize, 2), k.segments.len);
    try testing.expectEqual(@as(i64, 1020 * MIN), k.segments[0][k.segments[0].len - 1].t);
    try testing.expectEqual(Gap{ .from = 1020 * MIN, .to = 1090 * MIN, .why = .link_lost }, k.gaps[0]);
    try testing.expectEqual(@as(i64, 1090 * MIN), k.segments[1][0].t);
}

test "motion spans run from motion to clear, from a snapshot's since, and to the end while still on" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var fold = try Fold.init(arena.allocator(), test_display, opts);
    // On since before the range: clipped to its start.
    var snap = rec(1005, .{ .motion = .{ .dev = "k", .on = true, .since = .fromNanoseconds(@as(i96, 990 * MIN) * std.time.ns_per_ms) } });
    snap.init = true;
    fold.record(snap);
    fold.record(rec(1010, .{ .motion = .{ .dev = "k", .on = false } }));
    fold.record(rec(1500, .{ .motion = .{ .dev = "k", .on = true } }));
    fold.record(rec(1600, .heartbeat));
    const m = (try fold.finish()).motion[0];
    try testing.expectEqual(@as(usize, 2), m.spans.len);
    try testing.expectEqual(Span{ .from = 1000 * MIN, .to = 1010 * MIN }, m.spans[0]);
    try testing.expectEqual(Span{ .from = 1500 * MIN, .to = 1600 * MIN }, m.spans[1]);
}

test "readings closer than the range allows are kept as the last of them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var o = opts;
    o.max_points = 10; // one point per 100 minutes
    var fold = try Fold.init(arena.allocator(), test_display, o);
    fold.record(rec(1000, .{ .temperature = .{ .dev = "o", .c = 5 } }));
    fold.record(rec(1010, .{ .temperature = .{ .dev = "o", .c = 6 } }));
    fold.record(rec(1020, .{ .temperature = .{ .dev = "o", .c = 7 } }));
    fold.record(rec(1050, .{ .temperature = .{ .dev = "o", .c = 8 } }));
    fold.record(rec(1060, .heartbeat));
    const pts = (try fold.finish()).temperature[0].segments[0];
    try testing.expectEqual(@as(usize, 3), pts.len);
    try testing.expectEqual(Point{ .t = 1010 * MIN, .v = 8 }, pts[1]);
}
