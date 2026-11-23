//! Each room's on/off and every safety alarm, across all of the house's sources.
//!
//! A `reader` handler, like `live`. `json` is pure: it takes the clock.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const houselog = @import("houselog");

/// Longer than this since a source's last record, and its logger isn't running:
/// two missed heartbeats and a minute's slack, at the 5-minute beat.
const alive_gap_ms: i64 = 11 * 60 * 1000;
const source_silence_ms: i64 = 10 * 60 * 1000;

pub const SourceConfig = struct {
    name: []const u8,
    /// Whether long silence from this source is itself suspicious. Hue reports
    /// constantly, so it is. A quiet house leaves hub silent, and hub's radio loop
    /// tests its own link, so its `up` and `down` can be believed instead.
    checks_silence: bool,
};

pub const SourceState = enum { ok, stopped, down, silent };

const Source = struct {
    config: SourceConfig,
    up: bool = false,
    last_ms: ?i64 = null,
    last_source_ms: ?i64 = null,

    fn state(self: *const Source, now_ms: i64) SourceState {
        if (self.last_ms == null or now_ms - self.last_ms.? > alive_gap_ms) return .stopped;
        if (!self.up) return .down;
        if (self.config.checks_silence) {
            if (self.last_source_ms) |t| if (now_ms - t > source_silence_ms) return .silent;
        }
        return .ok;
    }
};

const Device = struct {
    dev: []u8,
    name: []u8,
    room: ?[]u8,
    /// Index into `sources`: the source whose inventory last listed it.
    source: usize,
    is_light: bool = false,
    is_alarm: bool = false,
    /// One bit per light channel, as `ch` in the house log. Known bits say a
    /// channel has reported, because not known isn't off.
    on_mask: u32 = 0,
    known_mask: u32 = 0,
    link: ?houselog.Link = null,
    last_ms: ?i64 = null,
    alarm_on: ?bool = null,
    alarm_tripped_ms: ?i64 = null,
};

pub const Rooms = struct {
    gpa: Allocator,
    sources: []Source,
    /// The order to show rooms in. One not listed comes after, alphabetically.
    order: []const []const u8,
    devices: std.ArrayList(Device) = .empty,

    pub fn init(gpa: Allocator, configs: []const SourceConfig, order: []const []const u8) !Rooms {
        const owned = try gpa.alloc(Source, configs.len);
        for (configs, owned) |config, *s| s.* = .{ .config = config };
        return .{ .gpa = gpa, .sources = owned, .order = order };
    }

    pub fn deinit(self: *Rooms) void {
        for (self.devices.items) |*d| self.freeDevice(d);
        self.devices.deinit(self.gpa);
        self.gpa.free(self.sources);
    }

    fn freeDevice(self: *Rooms, d: *Device) void {
        self.gpa.free(d.dev);
        self.gpa.free(d.name);
        if (d.room) |r| self.gpa.free(r);
    }

    fn find(self: *Rooms, dev: []const u8) ?*Device {
        for (self.devices.items) |*d| {
            if (std.mem.eql(u8, d.dev, dev)) return d;
        }
        return null;
    }

    fn sourceIndex(self: *const Rooms, name: []const u8) ?usize {
        for (self.sources, 0..) |*s, i| {
            if (std.mem.eql(u8, s.config.name, name)) return i;
        }
        return null;
    }

    pub fn record(self: *Rooms, r: houselog.Record) void {
        const source_index = self.sourceIndex(r.src) orelse return;
        const source = &self.sources[source_index];
        source.last_ms = @intCast(r.at.toMilliseconds());
        if (r.fromSource()) source.last_source_ms = source.last_ms;

        switch (r.body) {
            .up => source.up = true,
            .down => source.up = false,
            .inventory => |list| self.applyInventory(source_index, list) catch {},
            .light => |b| if (self.find(b.dev)) |d| {
                d.last_ms = source.last_ms;
                if (b.on) |on| {
                    const bit = @as(u32, 1) << @intCast(b.ch & 31);
                    d.known_mask |= bit;
                    if (on) d.on_mask |= bit else d.on_mask &= ~bit;
                }
            },
            .link => |b| if (self.find(b.dev)) |d| {
                d.link = b.status;
                d.last_ms = source.last_ms;
            },
            .alarm => |b| if (self.find(b.dev)) |d| {
                d.last_ms = source.last_ms;
                d.alarm_on = b.on;
                if (b.on and !r.init) d.alarm_tripped_ms = source.last_ms;
            },
            else => if (r.dev()) |dev| {
                if (self.find(dev)) |d| d.last_ms = source.last_ms;
            },
        }
    }

    pub fn bad(_: *Rooms, _: []const u8, _: houselog.ParseError) void {}

    /// Replaces this source's devices, keeping what's known about any still
    /// listed. A device that another source lists goes with that source.
    fn applyInventory(self: *Rooms, source_index: usize, list: []const houselog.Device) !void {
        var i: usize = 0;
        while (i < self.devices.items.len) {
            const d = &self.devices.items[i];
            const listed = for (list) |l| {
                if (std.mem.eql(u8, l.dev, d.dev)) break true;
            } else false;
            if (d.source == source_index and !listed) {
                self.freeDevice(d);
                _ = self.devices.swapRemove(i);
            } else {
                i += 1;
            }
        }
        for (list) |l| {
            const d = self.find(l.dev) orelse blk: {
                try self.devices.append(self.gpa, .{
                    .dev = try self.gpa.dupe(u8, l.dev),
                    .name = &.{},
                    .room = null,
                    .source = source_index,
                });
                break :blk &self.devices.items[self.devices.items.len - 1];
            };
            const name = try self.gpa.dupe(u8, l.name);
            errdefer self.gpa.free(name);
            const room = if (l.room) |x| try self.gpa.dupe(u8, x) else null;
            self.gpa.free(d.name);
            if (d.room) |x| self.gpa.free(x);
            d.name = name;
            d.room = room;
            d.source = source_index;
            d.is_light = std.mem.indexOfScalar(houselog.Service, l.has, .light) != null;
            d.is_alarm = std.mem.indexOfScalar(houselog.Service, l.has, .alarm) != null;
        }
    }

    /// Whether what's known about a device can be believed now.
    fn responding(self: *const Rooms, d: *const Device, now_ms: i64) bool {
        if (self.sources[d.source].state(now_ms) != .ok) return false;
        return (d.link orelse .connected) == .connected;
    }

    const RoomRow = struct { name: []const u8, on: u32 = 0, known: u32 = 0, lost: u32 = 0, rank: usize };

    fn lessThan(_: void, a: RoomRow, b: RoomRow) bool {
        if (a.rank != b.rank) return a.rank < b.rank;
        return std.mem.lessThan(u8, a.name, b.name);
    }

    /// The whole page's state:
    ///
    ///   {"sources":[{"src":"hub","state":"ok"}],
    ///    "rooms":[{"room":"Kitchen","state":"on","on":2,"known":5,"lost":0}],
    ///    "alarms":[{"name":"moisture","room":"Garage","on":false,"lost":false,"age_s":60,"tripped_age_s":null}]}
    ///
    /// A room's `state` is `on` if any responding light is on, `off` if at least
    /// one responded and none is on, and `unknown` if none has. `lost` counts the
    /// lights not responding. A device with no room is under "No room".
    pub fn json(self: *const Rooms, arena: Allocator, w: *Io.Writer, now_ms: i64) !void {
        try w.writeAll("{\"sources\":[");
        for (self.sources, 0..) |*s, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"src\":");
            try std.json.Stringify.value(s.config.name, .{}, w);
            try w.print(",\"state\":\"{t}\"}}", .{s.state(now_ms)});
        }

        var rows: std.ArrayList(RoomRow) = .empty;
        for (self.devices.items) |*d| {
            if (!d.is_light) continue;
            const name = d.room orelse "No room";
            const row = for (rows.items) |*r| {
                if (std.mem.eql(u8, r.name, name)) break r;
            } else blk: {
                var rank = self.order.len;
                for (self.order, 0..) |o, i| {
                    if (std.mem.eql(u8, o, name)) rank = i;
                }
                try rows.append(arena, .{ .name = name, .rank = rank });
                break :blk &rows.items[rows.items.len - 1];
            };
            if (!self.responding(d, now_ms) or d.known_mask == 0) {
                row.lost += 1;
            } else {
                row.known += 1;
                if (d.on_mask != 0) row.on += 1;
            }
        }
        std.mem.sort(RoomRow, rows.items, {}, lessThan);

        try w.writeAll("],\"rooms\":[");
        for (rows.items, 0..) |r, i| {
            if (i > 0) try w.writeByte(',');
            const state: []const u8 = if (r.on > 0) "on" else if (r.known > 0) "off" else "unknown";
            try w.writeAll("{\"room\":");
            try std.json.Stringify.value(r.name, .{}, w);
            try w.print(",\"state\":\"{s}\",\"on\":{d},\"known\":{d},\"lost\":{d}}}", .{ state, r.on, r.known, r.lost });
        }

        try w.writeAll("],\"alarms\":[");
        var first = true;
        for (self.devices.items) |*d| {
            if (!d.is_alarm) continue;
            if (!first) try w.writeByte(',');
            first = false;
            try w.writeAll("{\"name\":");
            try std.json.Stringify.value(d.name, .{}, w);
            try w.writeAll(",\"room\":");
            try std.json.Stringify.value(d.room, .{}, w);
            try w.print(",\"on\":{},\"lost\":{}", .{ d.alarm_on orelse false, !self.responding(d, now_ms) });
            try writeAge(w, "age_s", d.last_ms, now_ms);
            try writeAge(w, "tripped_age_s", d.alarm_tripped_ms, now_ms);
            try w.writeByte('}');
        }
        try w.writeAll("]}");
    }
};

fn writeAge(w: *Io.Writer, key: []const u8, then_ms: ?i64, now_ms: i64) !void {
    try w.print(",\"{s}\":", .{key});
    if (then_ms) |t| try w.print("{d}", .{@divTrunc(@max(0, now_ms - t), 1000)}) else try w.writeAll("null");
}

const testing = std.testing;

const sources = [_]SourceConfig{
    .{ .name = "hue-bridge", .checks_silence = true },
    .{ .name = "hub", .checks_silence = false },
};
const minute: i64 = 60_000;

fn at(ms: i64) Io.Timestamp {
    return .{ .nanoseconds = @as(i96, ms) * std.time.ns_per_ms };
}

fn feed(r: *Rooms, ms: i64, src: []const u8, body: houselog.Body) void {
    r.record(.{ .at = at(ms), .src = src, .body = body });
}

fn output(r: *const Rooms, buf: []u8, now_ms: i64) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var w = Io.Writer.fixed(buf);
    try r.json(arena.allocator(), &w, now_ms);
    return w.buffered();
}

fn expectContains(text: []const u8, part: []const u8) !void {
    if (std.mem.indexOf(u8, text, part) == null) {
        std.debug.print("\nmissing: {s}\nin: {s}\n", .{ part, text });
        return error.TestExpectedContains;
    }
}

fn twoLights(r: *Rooms) void {
    feed(r, 0, "hue-bridge", .up);
    feed(r, 0, "hue-bridge", .{ .inventory = &.{
        .{ .dev = "a", .name = "Spot A", .room = "Kitchen", .has = &.{ .light, .link } },
        .{ .dev = "b", .name = "Spot B", .room = "Kitchen", .has = &.{ .light, .link } },
        .{ .dev = "s", .name = "Sensor", .room = "Hall", .has = &.{ .motion, .link } },
    } });
    feed(r, 0, "hue-bridge", .{ .light = .{ .dev = "a", .on = false } });
    feed(r, 0, "hue-bridge", .{ .light = .{ .dev = "b", .on = false } });
}

test "a room is on if any light in it is on, including several channels" {
    var r = try Rooms.init(testing.allocator, &sources, &.{});
    defer r.deinit();
    twoLights(&r);
    var buf: [1024]u8 = undefined;
    try expectContains(try output(&r, &buf, minute), "{\"room\":\"Kitchen\",\"state\":\"off\",\"on\":0,\"known\":2,\"lost\":0}");

    feed(&r, minute, "hue-bridge", .{ .light = .{ .dev = "b", .on = true } });
    try expectContains(try output(&r, &buf, minute), "\"state\":\"on\",\"on\":1,\"known\":2");

    feed(&r, minute, "hue-bridge", .{ .light = .{ .dev = "a", .ch = 1, .on = true } });
    feed(&r, minute, "hue-bridge", .{ .light = .{ .dev = "a", .ch = 0, .on = false } });
    feed(&r, minute, "hue-bridge", .{ .light = .{ .dev = "b", .on = false } });
    try expectContains(try output(&r, &buf, minute), "\"state\":\"on\",\"on\":1,\"known\":2");

    // A sensor isn't a light, so its room isn't listed at all.
    try testing.expect(std.mem.indexOf(u8, try output(&r, &buf, minute), "Hall") == null);
}

test "not known isn't off: a light that never reported, and a lost link" {
    var r = try Rooms.init(testing.allocator, &sources, &.{});
    defer r.deinit();
    feed(&r, 0, "hue-bridge", .up);
    feed(&r, 0, "hue-bridge", .{ .inventory = &.{.{ .dev = "a", .name = "A", .room = "Kitchen", .has = &.{.light} }} });
    var buf: [1024]u8 = undefined;
    try expectContains(try output(&r, &buf, minute), "\"state\":\"unknown\",\"on\":0,\"known\":0,\"lost\":1");

    twoLights(&r);
    feed(&r, minute, "hue-bridge", .{ .link = .{ .dev = "a", .status = .disconnected } });
    try expectContains(try output(&r, &buf, minute), "\"state\":\"off\",\"on\":0,\"known\":1,\"lost\":1");
    feed(&r, minute, "hue-bridge", .{ .link = .{ .dev = "b", .status = .issue } });
    try expectContains(try output(&r, &buf, minute), "\"state\":\"unknown\"");
    feed(&r, minute, "hue-bridge", .{ .link = .{ .dev = "a", .status = .connected } });
    feed(&r, minute, "hue-bridge", .{ .link = .{ .dev = "b", .status = .connected } });
    try expectContains(try output(&r, &buf, minute), "\"state\":\"off\",\"on\":0,\"known\":2,\"lost\":0");
}

test "a dead source means not known, and each source is judged in its own way" {
    var r = try Rooms.init(testing.allocator, &sources, &.{});
    defer r.deinit();
    twoLights(&r);
    feed(&r, 0, "hub", .up);
    feed(&r, 0, "hub", .{ .inventory = &.{.{ .dev = "p", .name = "panel", .room = "Utility", .has = &.{.light} }} });
    feed(&r, 0, "hub", .{ .light = .{ .dev = "p", .on = true } });
    var buf: [1024]u8 = undefined;

    // Ten quiet minutes with heartbeats: suspicious for Hue, normal for hub.
    var t: i64 = 5;
    while (t <= 15) : (t += 5) {
        feed(&r, t * minute, "hue-bridge", .heartbeat);
        feed(&r, t * minute, "hub", .heartbeat);
    }
    const quiet = try output(&r, &buf, 15 * minute);
    try expectContains(quiet, "{\"src\":\"hue-bridge\",\"state\":\"silent\"}");
    try expectContains(quiet, "{\"src\":\"hub\",\"state\":\"ok\"}");
    try expectContains(quiet, "{\"room\":\"Kitchen\",\"state\":\"unknown\"");
    try expectContains(quiet, "{\"room\":\"Utility\",\"state\":\"on\"");

    feed(&r, 16 * minute, "hub", .{ .down = "FileNotFound" });
    try expectContains(try output(&r, &buf, 16 * minute), "{\"src\":\"hub\",\"state\":\"down\"}");
    try expectContains(try output(&r, &buf, 40 * minute), "{\"src\":\"hub\",\"state\":\"stopped\"}");
}

test "rooms span networks, and a device follows its last inventory" {
    var r = try Rooms.init(testing.allocator, &sources, &.{});
    defer r.deinit();
    twoLights(&r);
    feed(&r, 0, "hub", .up);
    feed(&r, 0, "hub", .{ .inventory = &.{.{ .dev = "p", .name = "panel", .room = "Kitchen", .has = &.{.light} }} });
    feed(&r, 0, "hub", .{ .light = .{ .dev = "p", .on = true } });
    var buf: [1024]u8 = undefined;
    try expectContains(try output(&r, &buf, minute), "{\"room\":\"Kitchen\",\"state\":\"on\",\"on\":1,\"known\":3,\"lost\":0}");

    // Spot A moves to hub, keeping its identity and what's known about it.
    feed(&r, minute, "hub", .{ .inventory = &.{
        .{ .dev = "p", .name = "panel", .room = "Kitchen", .has = &.{.light} },
        .{ .dev = "a", .name = "Spot A", .room = "Kitchen", .has = &.{.light} },
    } });
    feed(&r, minute, "hue-bridge", .{ .inventory = &.{.{ .dev = "b", .name = "Spot B", .room = "Kitchen", .has = &.{.light} }} });
    try testing.expectEqual(@as(usize, 3), r.devices.items.len);
    try expectContains(try output(&r, &buf, minute), "\"known\":3");

    // A device dropped by its source goes.
    feed(&r, minute, "hub", .{ .inventory = &.{.{ .dev = "p", .name = "panel", .room = "Kitchen", .has = &.{.light} }} });
    try testing.expectEqual(@as(usize, 2), r.devices.items.len);
}

test "rooms come in the order given, then the rest alphabetically" {
    const order = [_][]const u8{ "Lounge", "Kitchen" };
    var r = try Rooms.init(testing.allocator, &sources, &order);
    defer r.deinit();
    feed(&r, 0, "hue-bridge", .up);
    feed(&r, 0, "hue-bridge", .{ .inventory = &.{
        .{ .dev = "1", .name = "1", .room = "Attic", .has = &.{.light} },
        .{ .dev = "2", .name = "2", .room = "Kitchen", .has = &.{.light} },
        .{ .dev = "3", .name = "3", .room = "Lounge", .has = &.{.light} },
        .{ .dev = "4", .name = "4", .has = &.{.light} },
    } });
    var buf: [1024]u8 = undefined;
    const text = try output(&r, &buf, minute);
    const lounge = std.mem.indexOf(u8, text, "Lounge").?;
    const kitchen = std.mem.indexOf(u8, text, "Kitchen").?;
    const attic = std.mem.indexOf(u8, text, "Attic").?;
    const none = std.mem.indexOf(u8, text, "No room").?;
    try testing.expect(lounge < kitchen and kitchen < attic and attic < none);
}

test "an alarm says wet or dry, when it last tripped, and when it can't be trusted" {
    var r = try Rooms.init(testing.allocator, &sources, &.{});
    defer r.deinit();
    feed(&r, 0, "hub", .up);
    feed(&r, 0, "hub", .{ .inventory = &.{.{ .dev = "m", .name = "moisture", .room = "Garage", .has = &.{ .alarm, .link } }} });
    var buf: [1024]u8 = undefined;
    try expectContains(try output(&r, &buf, minute), "{\"name\":\"moisture\",\"room\":\"Garage\",\"on\":false,\"lost\":false,\"age_s\":null,\"tripped_age_s\":null}");

    feed(&r, minute, "hub", .{ .alarm = .{ .dev = "m", .on = true } });
    try expectContains(try output(&r, &buf, 2 * minute), "\"on\":true,\"lost\":false,\"age_s\":60,\"tripped_age_s\":60");
    feed(&r, 2 * minute, "hub", .{ .alarm = .{ .dev = "m", .on = false } });
    try expectContains(try output(&r, &buf, 3 * minute), "\"on\":false,\"lost\":false,\"age_s\":60,\"tripped_age_s\":120");

    // hub stopping means this says nothing about whether it's dry.
    try expectContains(try output(&r, &buf, 20 * minute), "\"lost\":true");

    // A state re-read at the start of a day isn't a new trip.
    r.record(.{ .at = at(30 * minute), .src = "hub", .init = true, .body = .{ .alarm = .{ .dev = "m", .on = false } } });
    feed(&r, 30 * minute, "hub", .heartbeat);
    try expectContains(try output(&r, &buf, 30 * minute), "\"tripped_age_s\":1740");
}

test "a record from an unknown source or about an unknown device is ignored" {
    var r = try Rooms.init(testing.allocator, &sources, &.{});
    defer r.deinit();
    feed(&r, 0, "toaster", .up);
    feed(&r, 0, "hub", .{ .light = .{ .dev = "ghost", .on = true } });
    feed(&r, 0, "hub", .{ .alarm = .{ .dev = "ghost", .on = true } });
    try testing.expectEqual(@as(usize, 0), r.devices.items.len);
}
