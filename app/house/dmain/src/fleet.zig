//! Every device across the house's sources: its battery, link and when it was last
//! heard, and the recent events, folded from the house log.
//!
//! A `reader` handler, like `rooms`. The rest is pure: it takes the clock.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const houselog = @import("houselog");

pub const LOW_BATTERY_PCT: u8 = 20;
/// A sensor reports temperature or motion through the day, so this long without one
/// says something. A dimmer reports only when pressed, and a light when it changes,
/// so their silence says nothing, and only their link is judged.
pub const SENSOR_QUIET_MS: i64 = 24 * 60 * 60 * 1000;

const LOG_LINES = 300;
const LINE_BYTES = 120;
/// An IEEE address as text is 23; longer ids aren't kept.
const DEV_BYTES = 32;

pub const Device = struct {
    dev: []const u8,
    name: []const u8,
    room: ?[]const u8,
    src: []const u8,
    /// The model, as the source's inventory names it.
    product: ?[]const u8 = null,
    /// What it offers, from the same inventory.
    has: []const houselog.Service = &.{},
    /// Whether the source's latest inventory lists it.
    listed: bool = true,
    /// Why it's off on purpose, from `rooms.json`: nothing counts it as wrong.
    parked: ?[]const u8 = null,
    has_battery: bool = false,
    reports_steadily: bool = false,
    battery: ?u8 = null,
    link: ?houselog.Link = null,
    last_heard_ms: ?i64 = null,

    pub fn batteryLow(self: Device) bool {
        if (self.parked != null) return false;
        return if (self.battery) |pct| pct <= LOW_BATTERY_PCT else false;
    }

    /// A link the source says is bad, or a sensor that has stopped reporting.
    pub fn looksWrong(self: Device, now_ms: i64) bool {
        if (self.parked != null) return false;
        if (self.link) |link| if (link != .connected) return true;
        if (!self.reports_steadily) return false;
        const heard = self.last_heard_ms orelse return true;
        return now_ms - heard > SENSOR_QUIET_MS;
    }
};

pub const LogLine = struct {
    at: Io.Timestamp,
    len: u8,
    bytes: [LINE_BYTES]u8,
    /// Which log it came from.
    hub: bool = false,
    /// The device it's about, if any, so one device's lines can be picked out.
    dev_len: u8 = 0,
    dev_bytes: [DEV_BYTES]u8 = undefined,

    pub fn dev(self: *const LogLine) ?[]const u8 {
        return if (self.dev_len == 0) null else self.dev_bytes[0..self.dev_len];
    }

    pub fn text(self: *const LogLine) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// One source's recent lines. Per source, because a log's lines arrive a source at
/// a time when it's replayed, and a busy source mustn't push a quiet one out.
const Ring = struct {
    lines: []LogLine,
    /// Where the next line goes.
    next: usize = 0,
    count: usize = 0,

    fn claim(self: *Ring) *LogLine {
        return &self.lines[self.next];
    }

    fn commit(self: *Ring) void {
        self.next = (self.next + 1) % self.lines.len;
        self.count = @min(self.count + 1, self.lines.len);
    }

    /// Oldest to newest, `index` from 0.
    fn at(self: *const Ring, index: usize) *const LogLine {
        return &self.lines[(self.next + self.lines.len - self.count + index) % self.lines.len];
    }
};

pub const Fleet = struct {
    gpa: Allocator,
    /// Names and rooms. Only grows when an inventory brings a new one, which is
    /// rare enough to leave for as long as a screen stays open.
    arena: std.heap.ArenaAllocator,
    devices: std.ArrayList(Device) = .empty,
    hue_log: Ring,
    hub_log: Ring,
    bad_lines: usize = 0,
    /// The latest time on any record, which is how a quiet link is judged: by the
    /// house's own records, not by pings.
    newest_ms: ?i64 = null,

    pub fn init(gpa: Allocator) !Fleet {
        const hue_lines = try gpa.alloc(LogLine, LOG_LINES);
        errdefer gpa.free(hue_lines);
        const hub_lines = try gpa.alloc(LogLine, LOG_LINES);
        return .{ .gpa = gpa, .arena = .init(gpa), .hue_log = .{ .lines = hue_lines }, .hub_log = .{ .lines = hub_lines } };
    }

    pub fn deinit(self: *Fleet) void {
        self.gpa.free(self.hue_log.lines);
        self.gpa.free(self.hub_log.lines);
        self.devices.deinit(self.gpa);
        self.arena.deinit();
    }

    pub fn find(self: *Fleet, dev: []const u8) ?*Device {
        for (self.devices.items) |*d| {
            if (std.mem.eql(u8, d.dev, dev)) return d;
        }
        return null;
    }

    fn inventory(self: *Fleet, src: []const u8, listed: []const houselog.Device) !void {
        const a = self.arena.allocator();
        for (self.devices.items) |*d| {
            if (std.mem.eql(u8, d.src, src)) d.listed = false;
        }
        for (listed) |item| {
            const has = struct {
                fn check(services: []const houselog.Service, wanted: houselog.Service) bool {
                    return std.mem.indexOfScalar(houselog.Service, services, wanted) != null;
                }
            }.check;
            const d = self.find(item.dev) orelse blk: {
                try self.devices.append(self.gpa, .{
                    .dev = try a.dupe(u8, item.dev),
                    .name = try a.dupe(u8, item.name),
                    .room = if (item.room) |r| try a.dupe(u8, r) else null,
                    .src = try a.dupe(u8, src),
                });
                break :blk &self.devices.items[self.devices.items.len - 1];
            };
            if (!std.mem.eql(u8, d.name, item.name)) d.name = try a.dupe(u8, item.name);
            if (item.room) |r| {
                if (d.room == null or !std.mem.eql(u8, d.room.?, r)) d.room = try a.dupe(u8, r);
            } else {
                d.room = null;
            }
            if (!std.mem.eql(u8, d.src, src)) d.src = try a.dupe(u8, src);
            d.listed = true;
            if (item.product) |p| {
                if (d.product == null or !std.mem.eql(u8, d.product.?, p)) d.product = try a.dupe(u8, p);
            }
            if (!std.mem.eql(houselog.Service, d.has, item.has)) d.has = try a.dupe(houselog.Service, item.has);
            d.has_battery = has(item.has, .battery);
            d.reports_steadily = has(item.has, .temperature) or has(item.has, .humidity) or has(item.has, .motion);
        }
    }

    fn heard(d: *Device, ms: i64) void {
        if (d.last_heard_ms == null or d.last_heard_ms.? < ms) d.last_heard_ms = ms;
    }

    /// Each device's reason from `reasons`, which gives null for one not parked.
    /// The reasons must outlive the next call.
    pub fn park(self: *Fleet, ctx: anytype, comptime reasons: fn (@TypeOf(ctx), []const u8) ?[]const u8) void {
        for (self.devices.items) |*d| d.parked = reasons(ctx, d.dev);
    }

    pub fn record(self: *Fleet, r: houselog.Record) void {
        const at_ms = r.at.toMilliseconds();
        if (self.newest_ms == null or self.newest_ms.? < at_ms) self.newest_ms = at_ms;
        if (r.body == .inventory) {
            self.inventory(r.src, r.body.inventory) catch {};
            return;
        }
        self.addLogLine(r);
        const dev = r.dev() orelse return;
        const d = self.find(dev) orelse return;
        switch (r.body) {
            .battery => |b| d.battery = b.pct,
            .link => |l| d.link = l.status,
            // A snapshot's own time isn't hearing from the device, but this says
            // when the room last changed.
            .motion => |m| if (m.since) |since| heard(d, since.toMilliseconds()),
            else => {},
        }
        // A source saying it has lost a device is the source talking, not the device:
        // counting it kept a plug that hub hadn't heard for days at "30 min ago".
        const lost = r.body == .link and r.body.link.status != .connected;
        if (!r.init and !lost) heard(d, r.at.toMilliseconds());
    }

    pub fn bad(self: *Fleet, _: []const u8, _: houselog.ParseError) void {
        self.bad_lines += 1;
    }

    /// What a person reads for. Temperature and light level arrive all day and
    /// would bury everything else, and heartbeats and snapshots say nothing happened.
    fn addLogLine(self: *Fleet, r: houselog.Record) void {
        if (r.init) return;
        const ring = if (std.mem.eql(u8, r.src, "hub")) &self.hub_log else &self.hue_log;
        const slot = ring.claim();
        var w: Io.Writer = .fixed(&slot.bytes);
        self.describe(&w, r) catch |err| switch (err) {
            error.NotLogged => return,
            error.WriteFailed => {}, // keep what fits
        };
        slot.at = r.at;
        slot.len = @intCast(w.buffered().len);
        slot.hub = ring == &self.hub_log;
        slot.dev_len = 0;
        if (r.dev()) |d| if (d.len <= DEV_BYTES) {
            @memcpy(slot.dev_bytes[0..d.len], d);
            slot.dev_len = @intCast(d.len);
        };
        ring.commit();
    }

    fn describe(self: *Fleet, w: *Io.Writer, r: houselog.Record) error{ NotLogged, WriteFailed }!void {
        const short_src: []const u8 = if (std.mem.eql(u8, r.src, "hub")) "hub" else "hue";
        const name: []const u8 = if (r.dev()) |dev| (if (self.find(dev)) |d| d.name else dev) else "";
        switch (r.body) {
            .start => try w.print("{s}  logger started", .{short_src}),
            .up => try w.print("{s}  source up", .{short_src}),
            .down => |why| try w.print("{s}  SOURCE DOWN: {s}", .{ short_src, why }),
            .motion => |m| try w.print("{s}  {s}: {s}", .{ short_src, name, if (m.on) "motion" else "clear" }),
            .battery => |b| try w.print("{s}  {s}: battery {d}%", .{ short_src, name, b.pct }),
            .link => |l| try w.print("{s}  {s}: link {t}", .{ short_src, name, l.status }),
            .light => |l| {
                try w.print("{s}  {s}:", .{ short_src, name });
                if (l.on) |on| try w.print(" {s}", .{if (on) "on" else "off"});
                if (l.bri) |bri| try w.print(" {d:.0}%", .{bri});
                if (l.ct_k) |k| try w.print(" {d} K", .{k});
            },
            .button => |b| try w.print("{s}  {s}: button {d} {t}", .{ short_src, name, b.n, b.event }),
            .rotary => |t| try w.print("{s}  {s}: dial {t} {d}", .{ short_src, name, t.dir, t.steps }),
            .alarm => |a| try w.print("{s}  {s}: {s}", .{ short_src, name, if (a.on) "ALARM" else "alarm clear" }),
            .temperature, .humidity, .light_level, .heartbeat, .inventory => return error.NotLogged,
        }
    }

    /// Every source's recent lines by time, newest first. A line whose source has
    /// more than a ring's worth since is gone, so this reaches back further for a
    /// quiet source than a busy one.
    pub fn recentLog(self: *const Fleet, arena: Allocator) ![]const *const LogLine {
        const out = try arena.alloc(*const LogLine, self.hue_log.count + self.hub_log.count);
        var n: usize = 0;
        for ([_]*const Ring{ &self.hue_log, &self.hub_log }) |ring| {
            for (0..ring.count) |i| {
                out[n] = ring.at(i);
                n += 1;
            }
        }
        std.mem.sort(*const LogLine, out, {}, struct {
            fn newer(_: void, x: *const LogLine, y: *const LogLine) bool {
                return x.at.toNanoseconds() > y.at.toNanoseconds();
            }
        }.newer);
        return out;
    }
};

/// "just now", "12 min ago", "3 h ago", "2 d ago", or how far the log reaches.
pub fn ageText(arena: Allocator, heard_ms: ?i64, now_ms: i64) ![]const u8 {
    const ms = heard_ms orelse return "not in the log";
    const minutes = @divTrunc(now_ms - ms, 60_000);
    if (minutes < 1) return "just now";
    if (minutes < 60) return std.fmt.allocPrint(arena, "{d} min ago", .{minutes});
    if (minutes < 48 * 60) return std.fmt.allocPrint(arena, "{d} h ago", .{@divTrunc(minutes, 60)});
    return std.fmt.allocPrint(arena, "{d} d ago", .{@divTrunc(minutes, 24 * 60)});
}

const testing = std.testing;

fn at(ms: i64) Io.Timestamp {
    return .fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms);
}

const sensor: houselog.Device = .{ .dev = "s", .name = "Sensor", .room = "Hall", .has = &.{ .temperature, .battery, .link } };
const dimmer: houselog.Device = .{ .dev = "d", .name = "Dimmer", .has = &.{ .button, .battery, .link } };

test "a fold keeps each device's battery, link and when it was last heard" {
    var f = try Fleet.init(testing.allocator);
    defer f.deinit();
    f.record(.{ .at = at(0), .src = "hue-bridge", .body = .{ .inventory = &.{ sensor, dimmer } } });
    f.record(.{ .at = at(1000), .src = "hue-bridge", .init = true, .body = .{ .battery = .{ .dev = "s", .pct = 47 } } });
    f.record(.{ .at = at(1000), .src = "hue-bridge", .init = true, .body = .{ .link = .{ .dev = "s", .status = .connected } } });

    const s = f.find("s").?;
    try testing.expectEqual(@as(?u8, 47), s.battery);
    try testing.expectEqual(houselog.Link.connected, s.link.?);
    try testing.expect(s.has_battery and s.reports_steadily);
    try testing.expect(s.last_heard_ms == null); // a snapshot isn't hearing from it

    f.record(.{ .at = at(5000), .src = "hue-bridge", .body = .{ .temperature = .{ .dev = "s", .c = 18 } } });
    try testing.expectEqual(@as(?i64, 5000), s.last_heard_ms);
}

test "a motion snapshot says when it was last heard, even from before the log" {
    var f = try Fleet.init(testing.allocator);
    defer f.deinit();
    f.record(.{ .at = at(0), .src = "hue-bridge", .body = .{ .inventory = &.{sensor} } });
    f.record(.{ .at = at(9000), .src = "hue-bridge", .init = true, .body = .{ .motion = .{ .dev = "s", .on = false, .since = at(2000) } } });
    try testing.expectEqual(@as(?i64, 2000), f.find("s").?.last_heard_ms);
}

test "a source saying it lost a device isn't hearing from it" {
    var f = try Fleet.init(testing.allocator);
    defer f.deinit();
    f.record(.{ .at = at(0), .src = "hub", .body = .{ .inventory = &.{dimmer} } });
    const d = f.find("d").?;
    f.record(.{ .at = at(1000), .src = "hub", .body = .{ .link = .{ .dev = "d", .status = .disconnected } } });
    try testing.expect(d.last_heard_ms == null);
    // Coming back is the source hearing it again.
    f.record(.{ .at = at(2000), .src = "hub", .body = .{ .link = .{ .dev = "d", .status = .connected } } });
    try testing.expectEqual(@as(?i64, 2000), d.last_heard_ms);
}

test "a parked device is never wrong, whatever its link or battery" {
    var d: Device = .{ .dev = "x", .name = "x", .room = null, .src = "hub", .link = .disconnected, .has_battery = true, .battery = 1, .reports_steadily = true };
    try testing.expect(d.looksWrong(0) and d.batteryLow());
    d.parked = "unplugged on purpose";
    try testing.expect(!d.looksWrong(0) and !d.batteryLow());
}

test "looksWrong judges a sensor by silence, and anything by its link" {
    var f = try Fleet.init(testing.allocator);
    defer f.deinit();
    f.record(.{ .at = at(0), .src = "hue-bridge", .body = .{ .inventory = &.{ sensor, dimmer } } });
    const s = f.find("s").?;
    const d = f.find("d").?;
    const day = SENSOR_QUIET_MS;

    try testing.expect(s.looksWrong(day)); // never heard
    try testing.expect(!d.looksWrong(day * 30)); // a dimmer is allowed to be quiet

    f.record(.{ .at = at(1000), .src = "hue-bridge", .body = .{ .temperature = .{ .dev = "s", .c = 18 } } });
    try testing.expect(!s.looksWrong(1000 + day));
    try testing.expect(s.looksWrong(1000 + day + 1));

    f.record(.{ .at = at(2000), .src = "hue-bridge", .body = .{ .link = .{ .dev = "d", .status = .disconnected } } });
    try testing.expect(d.looksWrong(3000));
}

test "batteryLow needs a reading" {
    var d: Device = .{ .dev = "x", .name = "x", .room = null, .src = "hub" };
    try testing.expect(!d.batteryLow());
    d.battery = LOW_BATTERY_PCT + 1;
    try testing.expect(!d.batteryLow());
    d.battery = LOW_BATTERY_PCT;
    try testing.expect(d.batteryLow());
}

test "a device dropped from its source's inventory is no longer listed, and other sources' stay" {
    var f = try Fleet.init(testing.allocator);
    defer f.deinit();
    f.record(.{ .at = at(0), .src = "hue-bridge", .body = .{ .inventory = &.{ sensor, dimmer } } });
    f.record(.{ .at = at(0), .src = "hub", .body = .{ .inventory = &.{.{ .dev = "h", .name = "Hub one" }} } });
    f.record(.{ .at = at(1), .src = "hue-bridge", .body = .{ .inventory = &.{sensor} } });
    try testing.expect(f.find("s").?.listed);
    try testing.expect(!f.find("d").?.listed);
    try testing.expect(f.find("h").?.listed);
}

test "the log keeps events, newest first, and leaves out the noise" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f = try Fleet.init(testing.allocator);
    defer f.deinit();
    f.record(.{ .at = at(0), .src = "hue-bridge", .body = .{ .inventory = &.{sensor} } });
    f.record(.{ .at = at(1), .src = "hue-bridge", .body = .{ .temperature = .{ .dev = "s", .c = 18 } } });
    f.record(.{ .at = at(2), .src = "hue-bridge", .init = true, .body = .{ .battery = .{ .dev = "s", .pct = 47 } } });
    f.record(.{ .at = at(3), .src = "hue-bridge", .body = .heartbeat });
    f.record(.{ .at = at(4), .src = "hue-bridge", .body = .{ .battery = .{ .dev = "s", .pct = 46 } } });
    f.record(.{ .at = at(5), .src = "hub", .body = .{ .alarm = .{ .dev = "s", .on = true } } });
    const lines = try f.recentLog(arena.allocator());
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqualStrings("hub  Sensor: ALARM", lines[0].text());
    try testing.expectEqualStrings("hue  Sensor: battery 46%", lines[1].text());
}

test "the log merges sources by time, whichever was read first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f = try Fleet.init(testing.allocator);
    defer f.deinit();
    f.record(.{ .at = at(0), .src = "hue-bridge", .body = .{ .inventory = &.{sensor} } });
    // As at startup: all of one source's log, then all of the other's.
    f.record(.{ .at = at(10), .src = "hue-bridge", .body = .{ .battery = .{ .dev = "s", .pct = 1 } } });
    f.record(.{ .at = at(30), .src = "hue-bridge", .body = .{ .battery = .{ .dev = "s", .pct = 3 } } });
    f.record(.{ .at = at(20), .src = "hub", .body = .{ .battery = .{ .dev = "s", .pct = 2 } } });
    const lines = try f.recentLog(arena.allocator());
    try testing.expectEqual(@as(i64, 30), lines[0].at.toMilliseconds());
    try testing.expectEqual(@as(i64, 20), lines[1].at.toMilliseconds());
    try testing.expectEqual(@as(i64, 10), lines[2].at.toMilliseconds());
}

test "a busy source can't push a quiet one out of the log" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f = try Fleet.init(testing.allocator);
    defer f.deinit();
    f.record(.{ .at = at(0), .src = "hub", .body = .{ .down = "early" } });
    var i: i64 = 1;
    while (i < LOG_LINES * 2) : (i += 1) {
        f.record(.{ .at = at(i), .src = "hue-bridge", .body = .{ .down = "busy" } });
    }
    const lines = try f.recentLog(arena.allocator());
    try testing.expectEqual(@as(usize, LOG_LINES + 1), lines.len);
    try testing.expectEqualStrings("hub  SOURCE DOWN: early", lines[lines.len - 1].text());
}

test "the log wraps, and a line too long to fit is cut rather than lost" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f = try Fleet.init(testing.allocator);
    defer f.deinit();
    const long: [200]u8 = @splat('x');
    var i: i64 = 0;
    while (i < LOG_LINES + 5) : (i += 1) {
        f.record(.{ .at = at(i), .src = "hub", .body = .{ .down = &long } });
    }
    const lines = try f.recentLog(arena.allocator());
    try testing.expectEqual(@as(usize, LOG_LINES), lines.len);
    try testing.expectEqual(@as(i64, LOG_LINES + 4), lines[0].at.toMilliseconds());
    try testing.expectEqual(@as(i64, 5), lines[LOG_LINES - 1].at.toMilliseconds());
    try testing.expectEqual(LINE_BYTES, lines[0].text().len);
}

test "a log line keeps which device it's about, and the newest record's time" {
    var f = try Fleet.init(testing.allocator);
    defer f.deinit();
    f.record(.{ .at = at(0), .src = "hue-bridge", .body = .{ .inventory = &.{sensor} } });
    f.record(.{ .at = at(3000), .src = "hue-bridge", .body = .{ .motion = .{ .dev = "s", .on = true } } });
    f.record(.{ .at = at(4000), .src = "hue-bridge", .body = .up });
    const lines = try f.recentLog(testing.allocator);
    defer testing.allocator.free(lines);
    try testing.expect(lines[0].dev() == null);
    try testing.expectEqualStrings("s", lines[1].dev().?);
    try testing.expectEqual(@as(?i64, 4000), f.newest_ms);
}

test "ageText" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("not in the log", try ageText(a, null, 0));
    try testing.expectEqualStrings("just now", try ageText(a, 0, 59_000));
    try testing.expectEqualStrings("12 min ago", try ageText(a, 0, 12 * 60_000));
    try testing.expectEqualStrings("3 h ago", try ageText(a, 0, 3 * 3_600_000));
    try testing.expectEqualStrings("2 d ago", try ageText(a, 0, 48 * 3_600_000));
}
