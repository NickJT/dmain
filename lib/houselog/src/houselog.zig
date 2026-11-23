//! The house log: what the house's devices did, in a vocabulary of its own.
//!
//!   {"v":4,"src":"hue-bridge","t":"2026-11-04T09:20:04.067Z","kind":"temperature","dev":"00:17:88:01:0b:2c:4d:1e","c":18.22}
//!
//! One JSON object a line, one file per local day. **No source's protocol
//! reaches this file.** A translator per source — today the Hue bridge's CLIP
//! v2, later the house's own hub — maps its messages into these records, and
//! every consumer reads only these. Replacing a source means writing a new
//! translator; nothing downstream changes.
//!
//! **A device is its Zigbee IEEE address** (`00:17:88:01:0b:2c:4d:1e`, lower
//! case), because that survives a device moving from one coordinator to
//! another, and a room's history must survive the bridge being replaced. A
//! device with no IEEE address keeps its source's id, prefixed with the source:
//! `hue:<uuid>`.
//!
//! **Every state record is that service's whole current state**, so a consumer
//! can take any record alone. `init` marks one read from an inventory snapshot
//! rather than reported, which is how each day's file opens. Buttons and rotary
//! dials are events, not state, and are never `init`.
//!
//! **Units are the world's, not a source's**: degrees Celsius, real lux, battery
//! percent, brightness percent, colour temperature in kelvin.
//!
//! Any change to this vocabulary is a new `version`. A reader refuses a line it
//! does not know rather than guessing at it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const time = @import("time");

pub const version = 4;
/// Lines from before `humidity` arrived say 3 and mean the same, and a source with
/// no raw capture of its own, such as hub, can't rewrite them.
pub const oldest_readable = 3;

/// What a device's settings are now, which isn't an event and so isn't logged.
pub const settings = @import("settings.zig");
/// What runs by the clock, which also isn't an event.
pub const schedules = @import("schedules.zig");
/// A Zigbee network as its coordinator sees it now, which isn't an event either.
pub const network = @import("network.zig");

pub const Link = enum { connected, disconnected, issue, unidirectional, pending, unknown };

pub const ButtonEvent = enum { press, hold, repeat, release, long_release, double_release };

pub const Direction = enum { cw, ccw };

pub const RotaryAction = enum { start, repeat };

/// The state kinds a device can report; an inventory lists which each has.
pub const Service = enum { temperature, humidity, motion, light_level, battery, link, light, button, rotary, alarm };

pub const Device = struct {
    dev: []const u8,
    name: []const u8,
    room: ?[]const u8 = null,
    product: ?[]const u8 = null,
    has: []const Service = &.{},
};

pub const Body = union(enum) {
    /// The logging process started.
    start,
    /// The source answered; records follow.
    up,
    /// The source was lost, and why.
    down: []const u8,
    /// The logging process is alive. A gap between heartbeats is a gap in the
    /// record; a gap between other records may just be a quiet house.
    heartbeat,
    /// Every device the source knows, replacing any earlier list.
    inventory: []const Device,
    temperature: struct { dev: []const u8, c: f64 },
    /// Relative humidity, percent.
    humidity: struct { dev: []const u8, rh: f64 },
    /// `since` says when this state began, and only an `init` record carries
    /// it: a snapshot's own time says nothing about when a room last moved, and
    /// a reported change happened at the record's `t`.
    motion: struct { dev: []const u8, on: bool, since: ?Io.Timestamp = null },
    light_level: struct { dev: []const u8, lux: f64 },
    battery: struct { dev: []const u8, pct: u8 },
    link: struct { dev: []const u8, status: Link },
    /// `ch` tells apart several lights in one device; it is 0 for nearly all.
    light: struct { dev: []const u8, ch: u8 = 0, on: ?bool = null, bri: ?f64 = null, ct_k: ?u32 = null },
    /// `n` is the button's number on the device, from 1.
    button: struct { dev: []const u8, n: u8, event: ButtonEvent },
    rotary: struct { dev: []const u8, dir: Direction, steps: u32, action: RotaryAction },
    /// A safety sensor tripped or cleared, such as a leak detector.
    alarm: struct { dev: []const u8, on: bool },
};

pub const Kind = std.meta.Tag(Body);

pub const Record = struct {
    at: Io.Timestamp,
    src: []const u8,
    init: bool = false,
    body: Body,

    /// Whether this record shows the source is still talking. A heartbeat or a
    /// `start` is the logger's own, and proves only that the logger is running;
    /// a connection can die with the logger none the wiser, beating on. `down`
    /// is the logger reporting the source's absence.
    pub fn fromSource(self: Record) bool {
        return switch (self.body) {
            .start, .heartbeat, .down => false,
            else => true,
        };
    }

    /// The device this record is about, if any.
    pub fn dev(self: Record) ?[]const u8 {
        return switch (self.body) {
            inline .temperature, .humidity, .motion, .light_level, .battery, .link, .light, .button, .rotary, .alarm => |b| b.dev,
            else => null,
        };
    }
};

/// Hue reports lux as `10000·log10(lux) + 1`; three significant figures is
/// finer than the sensor and free of float noise.
pub fn sig3(x: f64) f64 {
    if (x == 0 or !std.math.isFinite(x)) return x;
    const mag = @floor(std.math.log10(@abs(x)));
    const scale = std.math.pow(f64, 10, 2 - mag);
    return @round(x * scale) / scale;
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

/// One record as one line, newline included.
pub fn format(w: *Io.Writer, r: Record) !void {
    try w.print("{{\"v\":{d},\"src\":", .{version});
    try str(w, r.src);
    try w.writeAll(",\"t\":\"");
    try time.formatIsoUtcMillis(r.at, w);
    try w.print("\",\"kind\":\"{t}\"", .{std.meta.activeTag(r.body)});
    if (r.init) try w.writeAll(",\"init\":true");
    switch (r.body) {
        .start, .up, .heartbeat => {},
        .down => |why| {
            try w.writeAll(",\"reason\":");
            try str(w, why);
        },
        .inventory => |devices| {
            try w.writeAll(",\"devices\":[");
            for (devices, 0..) |d, i| {
                if (i > 0) try w.writeByte(',');
                try w.writeAll("{\"dev\":");
                try str(w, d.dev);
                try w.writeAll(",\"name\":");
                try str(w, d.name);
                if (d.room) |room| {
                    try w.writeAll(",\"room\":");
                    try str(w, room);
                }
                if (d.product) |p| {
                    try w.writeAll(",\"product\":");
                    try str(w, p);
                }
                try w.writeAll(",\"has\":[");
                for (d.has, 0..) |s, k| {
                    if (k > 0) try w.writeByte(',');
                    try w.print("\"{t}\"", .{s});
                }
                try w.writeAll("]}");
            }
            try w.writeByte(']');
        },
        .temperature => |b| try w.print(",\"dev\":\"{s}\",\"c\":{d}", .{ b.dev, b.c }),
        .humidity => |b| try w.print(",\"dev\":\"{s}\",\"rh\":{d}", .{ b.dev, b.rh }),
        .motion => |b| {
            try w.print(",\"dev\":\"{s}\",\"on\":{}", .{ b.dev, b.on });
            if (b.since) |s| {
                try w.writeAll(",\"since\":\"");
                try time.formatIsoUtcMillis(s, w);
                try w.writeByte('"');
            }
        },
        .light_level => |b| try w.print(",\"dev\":\"{s}\",\"lux\":{d}", .{ b.dev, b.lux }),
        .battery => |b| try w.print(",\"dev\":\"{s}\",\"pct\":{d}", .{ b.dev, b.pct }),
        .link => |b| try w.print(",\"dev\":\"{s}\",\"status\":\"{t}\"", .{ b.dev, b.status }),
        .light => |b| {
            try w.print(",\"dev\":\"{s}\"", .{b.dev});
            if (b.ch != 0) try w.print(",\"ch\":{d}", .{b.ch});
            if (b.on) |on| try w.print(",\"on\":{}", .{on});
            if (b.bri) |bri| try w.print(",\"bri\":{d}", .{bri});
            if (b.ct_k) |k| try w.print(",\"ct_k\":{d}", .{k});
        },
        .button => |b| try w.print(",\"dev\":\"{s}\",\"n\":{d},\"event\":\"{t}\"", .{ b.dev, b.n, b.event }),
        .rotary => |b| try w.print(",\"dev\":\"{s}\",\"dir\":\"{t}\",\"steps\":{d},\"action\":\"{t}\"", .{ b.dev, b.dir, b.steps, b.action }),
        .alarm => |b| try w.print(",\"dev\":\"{s}\",\"on\":{}", .{ b.dev, b.on }),
    }
    try w.writeAll("}\n");
}

/// A device name is typed by a person, so it is escaped. Ids and enum tags are
/// ours and never need it.
fn str(w: *Io.Writer, s: []const u8) !void {
    try std.json.Stringify.value(s, .{}, w);
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

const DeviceLine = struct {
    dev: []const u8,
    name: []const u8,
    room: ?[]const u8 = null,
    product: ?[]const u8 = null,
    has: []const []const u8 = &.{},
};

/// Every field any kind carries. Parsed strictly: a field this version does
/// not know means a newer writer, and the line is refused.
const Line = struct {
    v: u32,
    src: []const u8,
    t: []const u8,
    kind: []const u8,
    init: bool = false,
    reason: ?[]const u8 = null,
    devices: ?[]const DeviceLine = null,
    dev: ?[]const u8 = null,
    c: ?f64 = null,
    rh: ?f64 = null,
    on: ?bool = null,
    since: ?[]const u8 = null,
    lux: ?f64 = null,
    pct: ?u8 = null,
    status: ?[]const u8 = null,
    ch: u8 = 0,
    bri: ?f64 = null,
    ct_k: ?u32 = null,
    n: ?u8 = null,
    event: ?[]const u8 = null,
    dir: ?[]const u8 = null,
    steps: ?u32 = null,
    action: ?[]const u8 = null,
};

pub const ParseError = error{ BadRecord, UnknownVersion, OutOfMemory };

/// Parse one line, without its newline. Strings in the result live in `arena`.
pub fn parse(arena: Allocator, line: []const u8) ParseError!Record {
    const l = std.json.parseFromSliceLeaky(Line, arena, line, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadRecord,
    };
    if (l.v < oldest_readable or l.v > version) return error.UnknownVersion;
    const kind = std.meta.stringToEnum(Kind, l.kind) orelse return error.BadRecord;
    const body: Body = switch (kind) {
        .start => .start,
        .up => .up,
        .heartbeat => .heartbeat,
        .down => .{ .down = l.reason orelse "" },
        .inventory => blk: {
            const src = l.devices orelse return error.BadRecord;
            const out = try arena.alloc(Device, src.len);
            for (src, out) |d, *o| {
                const has = try arena.alloc(Service, d.has.len);
                for (d.has, has) |s, *h| h.* = std.meta.stringToEnum(Service, s) orelse return error.BadRecord;
                o.* = .{ .dev = d.dev, .name = d.name, .room = d.room, .product = d.product, .has = has };
            }
            break :blk .{ .inventory = out };
        },
        .temperature => .{ .temperature = .{ .dev = try need(l.dev), .c = try need(l.c) } },
        .humidity => .{ .humidity = .{ .dev = try need(l.dev), .rh = try need(l.rh) } },
        .motion => .{ .motion = .{
            .dev = try need(l.dev),
            .on = try need(l.on),
            .since = if (l.since) |s| time.ISO2Timestamp(s) catch return error.BadRecord else null,
        } },
        .light_level => .{ .light_level = .{ .dev = try need(l.dev), .lux = try need(l.lux) } },
        .battery => .{ .battery = .{ .dev = try need(l.dev), .pct = try need(l.pct) } },
        .link => .{ .link = .{ .dev = try need(l.dev), .status = try tag(Link, l.status) } },
        .light => .{ .light = .{ .dev = try need(l.dev), .ch = l.ch, .on = l.on, .bri = l.bri, .ct_k = l.ct_k } },
        .button => .{ .button = .{ .dev = try need(l.dev), .n = try need(l.n), .event = try tag(ButtonEvent, l.event) } },
        .rotary => .{ .rotary = .{
            .dev = try need(l.dev),
            .dir = try tag(Direction, l.dir),
            .steps = try need(l.steps),
            .action = try tag(RotaryAction, l.action),
        } },
        .alarm => .{ .alarm = .{ .dev = try need(l.dev), .on = try need(l.on) } },
    };
    return .{
        .at = time.ISO2Timestamp(l.t) catch return error.BadRecord,
        .src = l.src,
        .init = l.init,
        .body = body,
    };
}

fn need(v: anytype) ParseError!@typeInfo(@TypeOf(v)).optional.child {
    return v orelse error.BadRecord;
}

fn tag(comptime E: type, s: ?[]const u8) ParseError!E {
    return std.meta.stringToEnum(E, s orelse return error.BadRecord) orelse error.BadRecord;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn roundTrip(r: Record) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [1024]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    try format(&w, r);
    const line = w.buffered();
    try testing.expect(line[line.len - 1] == '\n');
    const back = try parse(arena.allocator(), line[0 .. line.len - 1]);
    var buf2: [1024]u8 = undefined;
    var w2 = Io.Writer.fixed(&buf2);
    try format(&w2, back);
    try testing.expectEqualStrings(line, w2.buffered());
}

test {
    _ = settings;
    _ = network;
}

test "every kind survives a round trip" {
    const at = try time.ISO2Timestamp("2026-11-04T09:20:04.067Z");
    const dev = "00:17:88:01:0b:2c:4d:1e";
    const cases = [_]Body{
        .start,
        .up,
        .heartbeat,
        .{ .down = "StreamClosed" },
        .{ .inventory = &.{
            .{ .dev = dev, .name = "Bed 3 (Ensuite)", .room = "Ensuite", .product = "Hue motion sensor", .has = &.{ .motion, .temperature, .light_level, .battery, .link } },
            .{ .dev = "hue:7f1c", .name = "Hue Bridge", .has = &.{} },
        } },
        .{ .temperature = .{ .dev = dev, .c = 18.22 } },
        .{ .humidity = .{ .dev = dev, .rh = 61.8 } },
        .{ .motion = .{ .dev = dev, .on = true } },
        .{ .motion = .{ .dev = dev, .on = false, .since = try time.ISO2Timestamp("2026-11-03T15:58:44.400Z") } },
        .{ .light_level = .{ .dev = dev, .lux = 412 } },
        .{ .battery = .{ .dev = dev, .pct = 61 } },
        .{ .link = .{ .dev = dev, .status = .issue } },
        .{ .light = .{ .dev = dev, .on = false, .bri = 49.8, .ct_k = 2732 } },
        .{ .light = .{ .dev = dev, .ch = 1, .on = true } },
        .{ .button = .{ .dev = dev, .n = 4, .event = .release } },
        .{ .rotary = .{ .dev = dev, .dir = .ccw, .steps = 15, .action = .start } },
        .{ .alarm = .{ .dev = dev, .on = true } },
    };
    for (cases) |b| try roundTrip(.{ .at = at, .src = "hue-bridge", .body = b });
    try roundTrip(.{ .at = at, .src = "hue-bridge", .init = true, .body = .{ .temperature = .{ .dev = dev, .c = 6.25 } } });
}

test "only what the source sent shows the source is talking" {
    const at: Io.Timestamp = .{ .nanoseconds = 0 };
    for ([_]Body{ .start, .heartbeat, .{ .down = "x" } }) |b| {
        try testing.expect(!(Record{ .at = at, .src = "s", .body = b }).fromSource());
    }
    for ([_]Body{ .up, .{ .inventory = &.{} }, .{ .temperature = .{ .dev = "d", .c = 1 } } }) |b| {
        try testing.expect((Record{ .at = at, .src = "s", .body = b }).fromSource());
    }
}

test "the line is what the format promises" {
    var buf: [256]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    try format(&w, .{
        .at = try time.ISO2Timestamp("2026-11-04T09:20:04.067Z"),
        .src = "hue-bridge",
        .init = true,
        .body = .{ .temperature = .{ .dev = "00:17:88:01:0b:2c:4d:1e", .c = 18.22 } },
    });
    try testing.expectEqualStrings(
        "{\"v\":4,\"src\":\"hue-bridge\",\"t\":\"2026-11-04T09:20:04.067Z\",\"kind\":\"temperature\",\"init\":true,\"dev\":\"00:17:88:01:0b:2c:4d:1e\",\"c\":18.22}\n",
        w.buffered(),
    );
}

test "a line this version does not know is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const head = "{\"v\":3,\"src\":\"s\",\"t\":\"2026-11-04T00:00:00Z\",";
    try testing.expectError(error.UnknownVersion, parse(a, "{\"v\":5,\"src\":\"s\",\"t\":\"2026-11-04T00:00:00Z\",\"kind\":\"up\"}"));
    try testing.expectError(error.UnknownVersion, parse(a, "{\"v\":2,\"src\":\"s\",\"t\":\"2026-11-04T00:00:00Z\",\"kind\":\"up\"}"));
    try testing.expectError(error.BadRecord, parse(a, head ++ "\"kind\":\"motion\",\"dev\":\"d\",\"on\":false,\"since\":\"yesterday\"}"));
    try testing.expectError(error.BadRecord, parse(a, head ++ "\"kind\":\"smell\"}"));
    try testing.expectError(error.BadRecord, parse(a, head ++ "\"kind\":\"temperature\",\"dev\":\"d\"}"));
    try testing.expectError(error.BadRecord, parse(a, head ++ "\"kind\":\"up\",\"colour\":1}"));
}

test "a line from version 3 still reads, because hub's old days can't be rewritten" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "{\"v\":3,\"src\":\"hub\",\"t\":\"2026-11-04T00:00:00Z\",\"kind\":\"temperature\",\"dev\":\"d\",\"c\":18.5}");
    try testing.expectEqual(@as(f64, 18.5), r.body.temperature.c);
}

test "sig3" {
    try testing.expectEqual(@as(f64, 412), sig3(412.3));
    try testing.expectEqual(@as(f64, 1230), sig3(1234.5));
    try testing.expectEqual(@as(f64, 1.23), sig3(1.2345));
}
