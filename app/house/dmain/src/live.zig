//! What the pages know right now: the sensor table, kept current by
//! following today's house log, and whether the logger behind it is alive.
//!
//! A `reader` handler, like the export, so the page and the CSV read the log
//! the same way. `json` is pure: it takes the clock as a parameter.

const std = @import("std");
const Io = std.Io;
const houselog = @import("houselog");
const table = @import("table.zig");
const display_cfg = @import("display.zig");
const motion = @import("motion.zig");

/// Longer than this since the last record and the logger is not running: two
/// missed heartbeats and a minute's slack, at the default 5-minute beat.
pub const alive_gap_ms: i64 = 11 * 60 * 1000;

pub const Live = struct {
    table: table.Table,
    /// The last record of any kind, in Unix milliseconds.
    last_ms: ?i64 = null,
    /// The source (the bridge) as the logger last reported it.
    up: bool = false,
    /// The last record that came from the source.
    last_source_ms: ?i64 = null,
    /// What the motion page shows.
    board: motion.Board,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator, motion_rows: []const display_cfg.MotionRow) !Live {
        return .{ .table = .init(gpa), .board = try .init(gpa, motion_rows), .gpa = gpa };
    }

    pub fn deinit(self: *Live) void {
        self.table.deinit();
        self.board.deinit(self.gpa);
    }

    /// `stopped`: no record for longer than two missed heartbeats. `bridge`:
    /// the logger is running but cannot reach the bridge. `silent`: the logger
    /// thinks it can, and nothing has come from the bridge for too long. Its
    /// heartbeats say nothing about that: they come from its own clock.
    pub fn logger(self: *const Live, now_ms: i64) motion.Logger {
        if (self.last_ms == null or now_ms - self.last_ms.? > alive_gap_ms) return .stopped;
        if (!self.up) return .bridge;
        if (self.last_source_ms) |t| if (now_ms - t > table.source_silence_ms) return .silent;
        return .ok;
    }

    /// The motion page's whole state, as `motion.Board.json` describes.
    pub fn motionJson(self: *const Live, w: *Io.Writer, now_ms: i64) !void {
        try self.board.json(w, self.logger(now_ms), now_ms);
    }

    pub fn record(self: *Live, r: houselog.Record) void {
        _ = self.table.apply(r) catch {};
        self.board.apply(r);
        switch (r.body) {
            .up => self.up = true,
            .down => self.up = false,
            else => {},
        }
        self.last_ms = r.at.toMilliseconds();
        if (r.fromSource()) self.last_source_ms = self.last_ms;
    }

    pub fn bad(_: *Live, _: []const u8, _: houselog.ParseError) void {}

    /// The page's whole state:
    ///
    ///   {"logger":"ok","rows":[{"label":"Kitchen","c":18.22,"age_s":312,"rh":62,"stale":false}, …]}
    ///
    /// `logger` is as `logger` describes. `c` is the calibrated reading. A row is stale when its reading is older than `stale_min`, its
    /// sensor's link is not `connected`, or there is no reading at all;
    /// `c` and `age_s` are null when unknown.
    pub fn json(self: *const Live, w: *Io.Writer, display: []const display_cfg.Row, stale_min: u32, now_ms: i64) !void {
        try w.print("{{\"logger\":\"{t}\",\"rows\":[", .{self.logger(now_ms)});
        for (display, 0..) |row, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"label\":");
            try std.json.Stringify.value(row.label, .{}, w);
            const s: ?table.Sensor = if (self.table.find(row.dev)) |idx| self.table.sensors[idx] else null;
            const c = if (s) |x| x.celsius else null;
            const age_s: ?i64 = if (s) |x| (if (x.seen_ms) |seen| @divTrunc(@max(0, now_ms - seen), 1000) else null) else null;
            const linked = if (s) |x| (x.link orelse .connected) == .connected else false;
            const stale = c == null or age_s == null or age_s.? > @as(i64, stale_min) * 60 or !linked;
            if (c) |v| try w.print(",\"c\":{d}", .{table.corrected(v, row.correction)}) else try w.writeAll(",\"c\":null");
            if (age_s) |v| try w.print(",\"age_s\":{d}", .{v}) else try w.writeAll(",\"age_s\":null");
            if (s) |x| if (x.humidity) |rh| try w.print(",\"rh\":{d:.0}", .{rh});
            try w.print(",\"stale\":{}", .{stale});
            if (row.outside) try w.writeAll(",\"outside\":true");
            try w.writeByte('}');
        }
        try w.writeAll("]}");
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "json: a row shows the calibrated reading" {
    var l = try Live.init(testing.allocator, &.{});
    defer l.deinit();
    feed(&l, 0, false, .{ .inventory = &.{.{ .dev = k, .name = "Kitchen", .has = &.{.temperature} }} });
    feed(&l, 0, false, .up);
    feed(&l, 0, false, .{ .temperature = .{ .dev = k, .c = 18.22 } });
    const corrected_rows = [_]display_cfg.Row{.{ .dev = k, .label = "Kitchen", .correction = 1.72 }};

    var buf: [128]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    try l.json(&w, &corrected_rows, 120, 0);
    try testing.expectEqualStrings("{\"logger\":\"ok\",\"rows\":[{\"label\":\"Kitchen\",\"c\":19.94,\"age_s\":0,\"stale\":false}]}", w.buffered());
}

test "heartbeats alone do not keep the logger ok: the failure of 2026-11-06" {
    const mrows = [_]display_cfg.MotionRow{.{ .dev = k, .label = "Kitchen" }};
    var l = try Live.init(testing.allocator, &mrows);
    defer l.deinit();
    feed(&l, 0, false, .up);
    feed(&l, 0, false, .{ .motion = .{ .dev = k, .on = true } });
    const minute: i64 = 60_000;

    try testing.expectEqual(motion.Logger.ok, l.logger(9 * minute));

    // The stream dies; the logger beats on, so it is not `stopped`.
    var t: i64 = 5;
    while (t <= 60) : (t += 5) feed(&l, t * minute, false, .heartbeat);
    try testing.expectEqual(motion.Logger.silent, l.logger(60 * minute));

    // A motion left on is not reported as motion now, because its off could have been lost.
    var buf: [128]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    try l.motionJson(&w, 60 * minute);
    try testing.expect(std.mem.startsWith(u8, w.buffered(), "{\"logger\":\"silent\",\"rows\":[{\"label\":\"Kitchen\",\"on\":false"));

    // Anything from the source clears it.
    feed(&l, 61 * minute, false, .{ .temperature = .{ .dev = k, .c = 18 } });
    try testing.expectEqual(motion.Logger.ok, l.logger(61 * minute));

    // And once the logger reports the loss, that is the more useful thing to say.
    feed(&l, 72 * minute, false, .{ .down = "StreamStalled" });
    try testing.expectEqual(motion.Logger.bridge, l.logger(72 * minute));
}

test "a record reaches the motion page too, and both pages agree on the logger" {
    const mrows = [_]display_cfg.MotionRow{.{ .dev = k, .label = "Kitchen" }};
    var l = try Live.init(testing.allocator, &mrows);
    defer l.deinit();
    feed(&l, 0, false, .up);
    feed(&l, 1000, false, .{ .motion = .{ .dev = k, .on = false } });

    var buf: [128]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    try l.motionJson(&w, 2000);
    try testing.expectEqualStrings("{\"logger\":\"ok\",\"rows\":[{\"label\":\"Kitchen\",\"on\":false,\"last_ms\":1000,\"age_s\":1,\"lost\":false}]}", w.buffered());

    w = Io.Writer.fixed(&buf);
    try l.motionJson(&w, 1000 + alive_gap_ms + 1);
    try testing.expect(std.mem.startsWith(u8, w.buffered(), "{\"logger\":\"stopped\""));
}

const k = "00:17:88:01:0b:09:ec:13";
const n = "00:17:88:01:06:44:35:a4";
const rows = [_]display_cfg.Row{
    .{ .dev = k, .label = "Kitchen" },
    .{ .dev = n, .label = "Outside", .outside = true },
    .{ .dev = "00:00:00:00:00:00:00:00", .label = "Gone" },
};

fn at(ms: i64) Io.Timestamp {
    return .{ .nanoseconds = @as(i96, ms) * std.time.ns_per_ms };
}

fn feed(l: *Live, ms: i64, init_: bool, body: houselog.Body) void {
    l.record(.{ .at = at(ms), .src = "test", .init = init_, .body = body });
}

test "json: fresh, stale by age, stale by link, and a sensor the log never named" {
    var l = try Live.init(testing.allocator, &.{});
    defer l.deinit();
    feed(&l, 0, false, .{ .inventory = &.{
        .{ .dev = k, .name = "Kitchen", .has = &.{ .temperature, .link } },
        .{ .dev = n, .name = "North Wall", .has = &.{ .temperature, .link } },
    } });
    feed(&l, 0, true, .{ .temperature = .{ .dev = n, .c = 6.5 } });
    feed(&l, 1000, false, .up);
    feed(&l, 60_000, false, .{ .temperature = .{ .dev = k, .c = 18.22 } });

    var buf: [512]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    // 31 minutes after the outside reading, 30 after the kitchen's.
    try l.json(&w, &rows, 30, 31 * 60_000);
    try testing.expectEqualStrings(
        "{\"logger\":\"stopped\",\"rows\":[" ++
            "{\"label\":\"Kitchen\",\"c\":18.22,\"age_s\":1800,\"stale\":false}," ++
            "{\"label\":\"Outside\",\"c\":6.5,\"age_s\":1860,\"stale\":true,\"outside\":true}," ++
            "{\"label\":\"Gone\",\"c\":null,\"age_s\":null,\"stale\":true}]}",
        w.buffered(),
    );

    feed(&l, 31 * 60_000, false, .heartbeat);
    feed(&l, 31 * 60_000, false, .{ .link = .{ .dev = k, .status = .disconnected } });
    w = Io.Writer.fixed(&buf);
    try l.json(&w, rows[0..1], 30, 31 * 60_000);
    try testing.expectEqualStrings("{\"logger\":\"ok\",\"rows\":[{\"label\":\"Kitchen\",\"c\":18.22,\"age_s\":1800,\"stale\":true}]}", w.buffered());

    feed(&l, 32 * 60_000, false, .{ .down = "StreamClosed" });
    w = Io.Writer.fixed(&buf);
    try l.json(&w, rows[0..0], 30, 32 * 60_000);
    try testing.expectEqualStrings("{\"logger\":\"bridge\",\"rows\":[]}", w.buffered());
}
