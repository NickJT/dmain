//! The motion page's state: for each sensor on it, whether it sees motion now,
//! and when it last did. Fed house-log records; nothing here does I/O or reads
//! a clock.
//!
//! **When the sensor last saw motion is when it went off, not when it came
//! on.** A person who stays in a room holds the sensor on for minutes. While it
//! is on the answer is "now".
//!
//! **A snapshot's `init` record is not motion.** It says the room is quiet at
//! the moment of the snapshot, and every midnight would otherwise look like
//! someone walking through every room. Only its `since` counts, which is when
//! the bridge saw that state begin, and that can only move a time forward: a
//! reconnect's snapshot recovers motion missed during an outage, and never
//! undoes what the log already knows.

const std = @import("std");
const Io = std.Io;
const houselog = @import("houselog");
const display_cfg = @import("display.zig");

pub const State = struct {
    on: bool = false,
    /// When motion was last seen, in Unix milliseconds.
    last_ms: ?i64 = null,
    link: ?houselog.Link = null,
};

pub const Board = struct {
    rows: []const display_cfg.MotionRow,
    states: []State,

    pub fn init(gpa: std.mem.Allocator, rows: []const display_cfg.MotionRow) !Board {
        const states = try gpa.alloc(State, rows.len);
        @memset(states, .{});
        return .{ .rows = rows, .states = states };
    }

    pub fn deinit(self: *Board, gpa: std.mem.Allocator) void {
        gpa.free(self.states);
    }

    pub fn apply(self: *Board, r: houselog.Record) void {
        switch (r.body) {
            .motion => |b| {
                const s = self.find(b.dev) orelse return;
                s.on = b.on;
                if (!r.init) {
                    s.last_ms = r.at.toMilliseconds();
                } else if (b.since) |since| {
                    const t = since.toMilliseconds();
                    if (s.last_ms == null or t > s.last_ms.?) s.last_ms = @intCast(t);
                }
            },
            .link => |b| {
                const s = self.find(b.dev) orelse return;
                s.link = b.status;
            },
            else => {},
        }
    }

    fn find(self: *Board, dev: []const u8) ?*State {
        for (self.rows, self.states) |row, *s| if (std.mem.eql(u8, row.dev, dev)) return s;
        return null;
    }

    /// The page's whole state:
    ///
    ///   {"logger":"ok","rows":[{"label":"Hall","on":false,"last_ms":1793…,"age_s":180,"lost":false}, …]}
    ///
    /// `on` needs a running logger and a live link, because the off that would
    /// clear it may never have reached the log. `last_ms` and `age_s` are null
    /// when no motion is known. `lost` means the sensor's link is down, so a
    /// quiet row says nothing about the room.
    pub fn json(self: *const Board, w: *Io.Writer, logger: Logger, now_ms: i64) !void {
        try w.print("{{\"logger\":\"{t}\",\"rows\":[", .{logger});
        for (self.rows, self.states, 0..) |row, s, i| {
            if (i > 0) try w.writeByte(',');
            const lost = (s.link orelse .connected) != .connected;
            try w.writeAll("{\"label\":");
            try std.json.Stringify.value(row.label, .{}, w);
            try w.print(",\"on\":{}", .{s.on and logger == .ok and !lost});
            if (s.last_ms) |t| {
                try w.print(",\"last_ms\":{d},\"age_s\":{d}", .{ t, @divTrunc(@max(0, now_ms - t), 1000) });
            } else try w.writeAll(",\"last_ms\":null,\"age_s\":null");
            try w.print(",\"lost\":{}", .{lost});
            if (row.outdoor) try w.writeAll(",\"outdoor\":true");
            try w.writeByte('}');
        }
        try w.writeAll("]}");
    }
};

/// Whether the log behind a page can be believed right now.
pub const Logger = enum { ok, stopped, bridge, silent };

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const h = "00:17:88:01:0b:ce:21:95";
const n = "00:17:88:01:06:44:35:a4";
const test_rows = [_]display_cfg.MotionRow{
    .{ .dev = h, .label = "Hall" },
    .{ .dev = n, .label = "North Wall", .outdoor = true },
};

fn ts(ms: i64) Io.Timestamp {
    return .{ .nanoseconds = @as(i96, ms) * std.time.ns_per_ms };
}

fn feed(b: *Board, ms: i64, init_: bool, body: houselog.Body) void {
    b.apply(.{ .at = ts(ms), .src = "test", .init = init_, .body = body });
}

fn expectJson(b: *const Board, logger: Logger, now_ms: i64, want: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    try b.json(&w, logger, now_ms);
    try testing.expectEqualStrings(want, w.buffered());
}

test "the last motion is when it went off; while on it is now" {
    var b = try Board.init(testing.allocator, test_rows[0..1]);
    defer b.deinit(testing.allocator);
    feed(&b, 100_000, false, .{ .motion = .{ .dev = h, .on = true } });
    try expectJson(&b, .ok, 110_000, "{\"logger\":\"ok\",\"rows\":[{\"label\":\"Hall\",\"on\":true,\"last_ms\":100000,\"age_s\":10,\"lost\":false}]}");
    feed(&b, 160_000, false, .{ .motion = .{ .dev = h, .on = false } });
    try expectJson(&b, .ok, 220_000, "{\"logger\":\"ok\",\"rows\":[{\"label\":\"Hall\",\"on\":false,\"last_ms\":160000,\"age_s\":60,\"lost\":false}]}");
}

test "a snapshot is not motion: only its since counts, and only forward" {
    var b = try Board.init(testing.allocator, test_rows[0..1]);
    defer b.deinit(testing.allocator);

    // A snapshot with no `since` leaves the time unknown, however late it came.
    feed(&b, 500_000, true, .{ .motion = .{ .dev = h, .on = false } });
    try expectJson(&b, .ok, 500_000, "{\"logger\":\"ok\",\"rows\":[{\"label\":\"Hall\",\"on\":false,\"last_ms\":null,\"age_s\":null,\"lost\":false}]}");

    // With one, the room's last motion is known, and the snapshot's time is not it.
    feed(&b, 600_000, true, .{ .motion = .{ .dev = h, .on = false, .since = ts(40_000) } });
    try testing.expectEqual(@as(?i64, 40_000), b.states[0].last_ms);

    // An older `since` cannot undo a later report.
    feed(&b, 700_000, false, .{ .motion = .{ .dev = h, .on = false } });
    feed(&b, 800_000, true, .{ .motion = .{ .dev = h, .on = false, .since = ts(690_000) } });
    try testing.expectEqual(@as(?i64, 700_000), b.states[0].last_ms);

    // A newer one recovers motion missed during an outage.
    feed(&b, 900_000, true, .{ .motion = .{ .dev = h, .on = false, .since = ts(850_000) } });
    try testing.expectEqual(@as(?i64, 850_000), b.states[0].last_ms);
}

test "on is withheld when the off could have been missed" {
    var b = try Board.init(testing.allocator, &test_rows);
    defer b.deinit(testing.allocator);
    feed(&b, 1000, false, .{ .motion = .{ .dev = h, .on = true } });
    feed(&b, 1000, false, .{ .motion = .{ .dev = n, .on = true } });
    feed(&b, 2000, false, .{ .link = .{ .dev = n, .status = .disconnected } });

    try expectJson(&b, .ok, 2000, "{\"logger\":\"ok\",\"rows\":[" ++
        "{\"label\":\"Hall\",\"on\":true,\"last_ms\":1000,\"age_s\":1,\"lost\":false}," ++
        "{\"label\":\"North Wall\",\"on\":false,\"last_ms\":1000,\"age_s\":1,\"lost\":true,\"outdoor\":true}]}");
    try expectJson(&b, .stopped, 2000, "{\"logger\":\"stopped\",\"rows\":[" ++
        "{\"label\":\"Hall\",\"on\":false,\"last_ms\":1000,\"age_s\":1,\"lost\":false}," ++
        "{\"label\":\"North Wall\",\"on\":false,\"last_ms\":1000,\"age_s\":1,\"lost\":true,\"outdoor\":true}]}");
}

test "a sensor not on the page is ignored, and one never heard from shows nothing" {
    var b = try Board.init(testing.allocator, test_rows[0..1]);
    defer b.deinit(testing.allocator);
    feed(&b, 1000, false, .{ .motion = .{ .dev = n, .on = true } });
    try testing.expectEqual(@as(?i64, null), b.states[0].last_ms);
}
