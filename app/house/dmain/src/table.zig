//! The sensor table: every device in the house log that reports a
//! temperature, with the state worth showing beside each reading.
//!
//! Fed house-log records one at a time, from any source. An `inventory`
//! replaces that source's part of the list — a sensor added, removed or renamed
//! takes effect there — and keeps the state of every sensor that survives it. Nothing here does I/O or reads a
//! clock.

const std = @import("std");
const Allocator = std.mem.Allocator;
const houselog = @import("houselog");

pub const Sensor = struct {
    /// The house log's device id: an IEEE address.
    dev: []const u8,
    name: []const u8,
    /// The source whose inventory lists it, which is the only one that replaces it.
    src: []const u8 = "",
    celsius: ?f64 = null,
    /// Relative humidity, percent, from a sensor that has one.
    humidity: ?f64 = null,
    battery: ?u8 = null,
    link: ?houselog.Link = null,
    /// When the temperature was last reported, in Unix milliseconds. An
    /// `init` value only sets it when nothing earlier did: the inventory says
    /// what the reading is, not when the sensor took it, and a dead sensor
    /// must not look fresh after every midnight.
    seen_ms: ?i64 = null,
};

/// Longer than this with nothing from the source and it is treated as lost, even
/// with the logger's heartbeats still arriving. The longest normal silence seen
/// from this house is 4 minutes, overnight.
pub const source_silence_ms: i64 = 10 * 60 * 1000;

/// A reading on the calibrated scale. To the 0.01 °C the sensors report in, so a
/// sum's floating-point tail never reaches a file or the page.
pub fn corrected(raw: f64, correction: f64) f64 {
    return @round((raw + correction) * 100) / 100;
}

/// Why a row is being written. Every row carries the sensor's whole state, so
/// a reader can take any row as "this was true at this instant"; the kind only
/// says what prompted it.
pub const Kind = enum {
    /// The day's or the connection's opening state.
    start,
    /// The sensor reported a temperature.
    reading,
    /// The periodic snapshot, written only where the logger was alive — the
    /// proof that a flat line is a steady room and not a stopped logger.
    snapshot,
    /// Zigbee connectivity changed. A disconnected sensor's last reading
    /// stands still, and this is how a plot knows to stop the line.
    link,
    /// Battery level changed.
    battery,
};

pub const Table = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    sensors: []Sensor = &.{},

    pub fn init(gpa: Allocator) Table {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(self: *Table) void {
        self.arena.deinit();
    }

    pub const Change = struct { index: usize, kind: Kind };

    /// Apply one record. Returns the row it prompts, if any; an inventory or
    /// an `init` value prompts none, because the caller writes the opening
    /// rows once the whole opening state has arrived.
    pub fn apply(self: *Table, r: houselog.Record) !?Change {
        switch (r.body) {
            .inventory => |devices| {
                try self.replace(r.src, devices);
                return null;
            },
            // Shown beside the temperature, and prompting no row of its own: the
            // export's columns are the temperature's.
            .humidity => |b| {
                const i = self.find(b.dev) orelse return null;
                self.sensors[i].humidity = b.rh;
                return null;
            },
            .temperature => |b| {
                const i = self.find(b.dev) orelse return null;
                const s = &self.sensors[i];
                s.celsius = b.c;
                if (!r.init or s.seen_ms == null) s.seen_ms = r.at.toMilliseconds();
                return if (r.init) null else .{ .index = i, .kind = .reading };
            },
            .battery => |b| {
                const i = self.find(b.dev) orelse return null;
                if (self.sensors[i].battery == b.pct) return null;
                self.sensors[i].battery = b.pct;
                return if (r.init) null else .{ .index = i, .kind = .battery };
            },
            .link => |b| {
                const i = self.find(b.dev) orelse return null;
                if (self.sensors[i].link == b.status) return null;
                self.sensors[i].link = b.status;
                return if (r.init) null else .{ .index = i, .kind = .link };
            },
            else => return null,
        }
    }

    pub fn find(self: *const Table, dev: []const u8) ?usize {
        for (self.sensors, 0..) |s, i| if (std.mem.eql(u8, s.dev, dev)) return i;
        return null;
    }

    /// The new list, sorted by name: this source's sensors from `devices`, with
    /// the state of every one it still names, and every other source's as they
    /// were. Built in a fresh arena and swapped in, so a consumer that runs for
    /// months holds one inventory's worth of strings per source.
    fn replace(self: *Table, src: []const u8, devices: []const houselog.Device) !void {
        var fresh = std.heap.ArenaAllocator.init(self.gpa);
        errdefer fresh.deinit();
        const a = fresh.allocator();

        var list: std.ArrayList(Sensor) = .empty;
        for (self.sensors) |old| {
            if (std.mem.eql(u8, old.src, src)) continue;
            var kept = old;
            kept.dev = try a.dupe(u8, old.dev);
            kept.name = try a.dupe(u8, old.name);
            kept.src = try a.dupe(u8, old.src);
            try list.append(a, kept);
        }
        for (devices) |d| {
            if (std.mem.indexOfScalar(houselog.Service, d.has, .temperature) == null) continue;
            var s: Sensor = .{ .dev = try a.dupe(u8, d.dev), .name = try a.dupe(u8, d.name), .src = try a.dupe(u8, src) };
            if (self.find(d.dev)) |i| {
                const old = self.sensors[i];
                s.celsius = old.celsius;
                s.humidity = old.humidity;
                s.battery = old.battery;
                s.link = old.link;
                s.seen_ms = old.seen_ms;
            }
            try list.append(a, s);
        }
        const sensors = try list.toOwnedSlice(a);
        std.mem.sort(Sensor, sensors, {}, struct {
            fn lt(_: void, x: Sensor, y: Sensor) bool {
                return std.mem.lessThan(u8, x.name, y.name);
            }
        }.lt);

        self.arena.deinit();
        self.arena = fresh;
        self.sensors = sensors;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const kitchen = "00:17:88:01:0b:09:ec:13";
const north = "00:17:88:01:06:44:35:a4";

fn rec(init: bool, body: houselog.Body) houselog.Record {
    return .{ .at = .{ .nanoseconds = 0 }, .src = "test", .init = init, .body = body };
}

fn inventory(names: []const [2][]const u8) houselog.Body {
    const S = struct {
        var buf: [8]houselog.Device = undefined;
    };
    for (names, 0..) |n, i| S.buf[i] = .{ .dev = n[0], .name = n[1], .has = &.{ .temperature, .battery, .link } };
    return .{ .inventory = S.buf[0..names.len] };
}

test "corrected: no floating-point tail, and no correction changes nothing" {
    try testing.expectEqual(@as(f64, 20.31), corrected(18.22, 2.09));
    try testing.expectEqual(@as(f64, 18.22), corrected(18.22, 0));
    try testing.expectEqual(@as(f64, 16.53), corrected(16.96, -0.43));
}

test "an inventory lists the temperature sensors, sorted; init values prompt no row" {
    var t = Table.init(testing.allocator);
    defer t.deinit();

    _ = try t.apply(rec(false, inventory(&.{ .{ north, "North Wall" }, .{ kitchen, "Kitchen" } })));
    try testing.expectEqual(@as(usize, 2), t.sensors.len);
    try testing.expectEqualStrings("Kitchen", t.sensors[0].name);

    try testing.expectEqual(@as(?Table.Change, null), try t.apply(rec(true, .{ .temperature = .{ .dev = kitchen, .c = 18.2 } })));
    try testing.expectEqual(@as(?f64, 18.2), t.sensors[0].celsius);

    const c = (try t.apply(rec(false, .{ .temperature = .{ .dev = kitchen, .c = 18.5 } }))).?;
    try testing.expectEqual(Kind.reading, c.kind);
    try testing.expectEqual(@as(?Table.Change, null), try t.apply(rec(false, .{ .motion = .{ .dev = kitchen, .on = true } })));
}

test "a rename keeps the state; a removal drops the sensor" {
    var t = Table.init(testing.allocator);
    defer t.deinit();

    _ = try t.apply(rec(false, inventory(&.{ .{ north, "North Wall" }, .{ kitchen, "Kitchen" } })));
    _ = try t.apply(rec(false, .{ .temperature = .{ .dev = kitchen, .c = 18.5 } }));
    _ = try t.apply(rec(false, .{ .battery = .{ .dev = kitchen, .pct = 61 } }));

    _ = try t.apply(rec(false, inventory(&.{.{ kitchen, "Galley" }})));
    try testing.expectEqual(@as(usize, 1), t.sensors.len);
    try testing.expectEqualStrings("Galley", t.sensors[0].name);
    try testing.expectEqual(@as(?f64, 18.5), t.sensors[0].celsius);
    try testing.expectEqual(@as(?u8, 61), t.sensors[0].battery);
}

test "seen: a report sets it, an init only fills it, an inventory keeps it" {
    var t = Table.init(testing.allocator);
    defer t.deinit();
    _ = try t.apply(rec(false, inventory(&.{.{ kitchen, "Kitchen" }})));
    var r = rec(true, .{ .temperature = .{ .dev = kitchen, .c = 18 } });
    r.at = .{ .nanoseconds = 5 * std.time.ns_per_s };
    _ = try t.apply(r);
    try testing.expectEqual(@as(?i64, 5000), t.sensors[0].seen_ms);
    r.at = .{ .nanoseconds = 9 * std.time.ns_per_s };
    _ = try t.apply(r); // a later init does not freshen it
    try testing.expectEqual(@as(?i64, 5000), t.sensors[0].seen_ms);
    r.init = false;
    _ = try t.apply(r);
    try testing.expectEqual(@as(?i64, 9000), t.sensors[0].seen_ms);
    _ = try t.apply(rec(false, inventory(&.{.{ kitchen, "Kitchen" }})));
    try testing.expectEqual(@as(?i64, 9000), t.sensors[0].seen_ms);
}

test "a battery or link record that changes nothing prompts no row" {
    var t = Table.init(testing.allocator);
    defer t.deinit();
    _ = try t.apply(rec(false, inventory(&.{.{ kitchen, "Kitchen" }})));
    try testing.expectEqual(Kind.battery, (try t.apply(rec(false, .{ .battery = .{ .dev = kitchen, .pct = 61 } }))).?.kind);
    try testing.expectEqual(@as(?Table.Change, null), try t.apply(rec(false, .{ .battery = .{ .dev = kitchen, .pct = 61 } })));
    try testing.expectEqual(Kind.link, (try t.apply(rec(false, .{ .link = .{ .dev = kitchen, .status = .issue } }))).?.kind);
}

test "one source's inventory leaves another's sensors as they were" {
    var t = Table.init(testing.allocator);
    defer t.deinit();
    const hub_sensor = "cc:36:bb:ff:fe:02:e1:39";
    _ = try t.apply(.{ .at = .{ .nanoseconds = 0 }, .src = "hue-bridge", .body = inventory(&.{.{ kitchen, "Kitchen" }}) });
    _ = try t.apply(.{ .at = .{ .nanoseconds = 0 }, .src = "hub", .body = inventory(&.{.{ hub_sensor, "hum1" }}) });
    _ = try t.apply(rec(false, .{ .temperature = .{ .dev = kitchen, .c = 18.5 } }));
    _ = try t.apply(rec(false, .{ .humidity = .{ .dev = hub_sensor, .rh = 61.8 } }));
    try testing.expectEqual(@as(usize, 2), t.sensors.len);

    // Hue's list again, as at every reconnect: hub's sensor and its reading stay.
    _ = try t.apply(.{ .at = .{ .nanoseconds = 0 }, .src = "hue-bridge", .body = inventory(&.{.{ kitchen, "Kitchen" }}) });
    try testing.expectEqual(@as(usize, 2), t.sensors.len);
    try testing.expectEqual(@as(?f64, 61.8), t.sensors[t.find(hub_sensor).?].humidity);
    try testing.expectEqual(@as(?f64, 18.5), t.sensors[t.find(kitchen).?].celsius);

    // hub's list without it: gone, and Hue's untouched.
    _ = try t.apply(.{ .at = .{ .nanoseconds = 0 }, .src = "hub", .body = inventory(&.{}) });
    try testing.expect(t.find(hub_sensor) == null);
    try testing.expect(t.find(kitchen) != null);
}
