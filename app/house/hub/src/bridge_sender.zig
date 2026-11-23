//! hub's writes to the Hue Bridge, on a task of their own: a TLS connection to the
//! Bridge takes seconds, and only the engine loop may hold up the radio.
//!
//! **One slot per Bridge light, the latest wish winning.** The Bridge only needs
//! what a light should be now, so a request made while another waits replaces it.
//! Slots are claimed by the engine loop alone and never released, so the task can
//! read a claimed slot's id without a lock. A failed write is tried once more
//! after `RETRY_MS`, then reported.

const std = @import("std");
const Io = std.Io;
const bridge_write = @import("bridge_write");

/// Holds the Bridge's application key: gitignored, and never printed.
pub const BRIDGE_FILE = "bridge.json";
pub const ID_LEN = 36;
/// Rules and the leak alert together name a handful of lights.
pub const SLOTS = 16;
const RETRY_MS: i64 = 5_000;
const POLL = Io.Duration.fromMilliseconds(200);
const MAX_FILE: usize = 4096;

/// What a light should do. Any other value is a flash of that many ms.
pub const NONE: u32 = 0;
pub const ON: u32 = std.math.maxInt(u32);
pub const OFF: u32 = std.math.maxInt(u32) - 1;
pub const STOP_FLASH: u32 = std.math.maxInt(u32) - 2;
pub const MAX_FLASH_MS: u32 = 10 * 60_000;

pub const Outcome = enum(u8) { none, accepted, failed };

pub const Result = struct { request: u32, outcome: Outcome };

pub const Slot = struct {
    id: [ID_LEN]u8 = undefined,
    claimed: std.atomic.Value(bool) = .init(false),
    pending: std.atomic.Value(u32) = .init(NONE),
    /// What the last write was, then how it went. Two words, not one packed
    /// 64-bit one, which the 32-bit Pi can't do atomically.
    result_request: std.atomic.Value(u32) = .init(NONE),
    result: std.atomic.Value(Outcome) = .init(.none),
    /// How the engine loop's log lines name it; the engine loop's alone.
    label: [24]u8 = undefined,
    label_len: usize = 0,
    // The task's own.
    retry: u32 = NONE,
    retry_at_ms: i64 = 0,

    pub fn request(self: *Slot, what: u32) void {
        self.pending.store(what, .release);
    }

    pub fn setLabel(self: *Slot, text: []const u8) void {
        self.label_len = @min(text.len, self.label.len);
        @memcpy(self.label[0..self.label_len], text[0..self.label_len]);
    }

    pub fn name(self: *const Slot) []const u8 {
        return if (self.label_len > 0) self.label[0..self.label_len] else &self.id;
    }

    pub fn takeResult(self: *Slot) ?Result {
        const outcome = self.result.swap(.none, .acq_rel);
        if (outcome == .none) return null;
        return .{ .request = self.result_request.load(.acquire), .outcome = outcome };
    }

    fn finish(self: *Slot, what: u32, outcome: Outcome) void {
        self.result_request.store(what, .release);
        self.result.store(outcome, .release);
    }
};

pub const Sender = struct {
    gpa: std.mem.Allocator,
    bridge: bridge_write.Credentials,
    slots: [SLOTS]Slot = @splat(.{}),

    /// The slot for a light, claimed if new. Engine loop only. Null when the id
    /// isn't a Bridge id or every slot is taken.
    pub fn slotFor(self: *Sender, light_id: []const u8) ?*Slot {
        if (light_id.len != ID_LEN) return null;
        for (&self.slots) |*slot| {
            if (!slot.claimed.load(.acquire)) {
                @memcpy(&slot.id, light_id);
                slot.claimed.store(true, .release);
                return slot;
            }
            if (std.mem.eql(u8, &slot.id, light_id)) return slot;
        }
        return null;
    }

    pub fn task(self: *Sender, io: Io) void {
        while (true) {
            io.sleep(POLL, .awake) catch return;
            for (&self.slots) |*slot| {
                if (!slot.claimed.load(.acquire)) break;
                self.serve(io, slot) catch return;
            }
        }
    }

    fn serve(self: *Sender, io: Io, slot: *Slot) error{Canceled}!void {
        const now_ms = Io.Timestamp.now(io, .awake).toMilliseconds();
        var what = slot.pending.swap(NONE, .acq_rel);
        var retrying = false;
        if (what != NONE) {
            slot.retry = NONE;
        } else if (slot.retry != NONE and now_ms >= slot.retry_at_ms) {
            what = slot.retry;
            slot.retry = NONE;
            retrying = true;
        } else return;

        self.send(io, &slot.id, what) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            std.log.warn("bridge: a write failed: {t}", .{err});
            if (retrying) {
                slot.finish(what, .failed);
            } else {
                slot.retry = what;
                slot.retry_at_ms = now_ms + RETRY_MS;
            }
            return;
        };
        slot.finish(what, .accepted);
    }

    fn send(self: *Sender, io: Io, light_id: []const u8, what: u32) !void {
        var body_buf: [96]u8 = undefined;
        const text = body(&body_buf, what) catch return error.BadRequest;
        try bridge_write.setLight(self.gpa, io, self.bridge, light_id, text, null);
    }
};

/// The light's PUT body for a request.
pub fn body(buf: []u8, what: u32) ![]const u8 {
    return switch (what) {
        NONE => error.NothingToSend,
        ON => "{\"on\":{\"on\":true}}",
        OFF => "{\"on\":{\"on\":false}}",
        STOP_FLASH => bridge_write.STOP_FLASH_BODY,
        else => if (what > MAX_FLASH_MS) error.BadRequest else bridge_write.flashBody(buf, what),
    };
}

/// Null when hub has no `bridge.json`, which only means it doesn't write to the
/// Bridge. Errors are named by the caller, never the file's contents.
pub fn loadCredentials(arena: std.mem.Allocator, io: Io, dir: Io.Dir) !?bridge_write.Credentials {
    var buf: [MAX_FILE]u8 = undefined;
    const text = dir.readFile(io, BRIDGE_FILE, &buf) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return try bridge_write.parseCredentials(arena, text);
}

/// A request as a log line reads it.
pub fn describe(buf: []u8, what: u32) []const u8 {
    return switch (what) {
        ON => "on",
        OFF => "off",
        STOP_FLASH => "stop flashing",
        else => std.fmt.bufPrint(buf, "flash for {d} s", .{what / 1000}) catch "flash",
    };
}

const testing = std.testing;

const LAMP = "0123456789abcdef0123456789abcdef0123";
const FAN = "fedcba9876543210fedcba9876543210fedc";

test "a light keeps one slot, and a new light claims the next" {
    var s: Sender = .{ .gpa = testing.allocator, .bridge = undefined };
    const a = s.slotFor(LAMP).?;
    try testing.expect(s.slotFor(LAMP).? == a);
    const b = s.slotFor(FAN).?;
    try testing.expect(a != b);
    try testing.expect(s.slotFor("short") == null);
}

test "slots run out rather than overwrite" {
    var s: Sender = .{ .gpa = testing.allocator, .bridge = undefined };
    var id: [ID_LEN]u8 = @splat('a');
    for (0..SLOTS) |i| {
        id[0] = @intCast('a' + i);
        try testing.expect(s.slotFor(&id) != null);
    }
    id[0] = 'Z';
    try testing.expect(s.slotFor(&id) == null);
}

test "the latest request wins, and a result is read once" {
    var slot: Slot = .{};
    slot.request(ON);
    slot.request(OFF);
    try testing.expectEqual(OFF, slot.pending.load(.acquire));
    slot.finish(OFF, .accepted);
    try testing.expectEqual(Result{ .request = OFF, .outcome = .accepted }, slot.takeResult().?);
    try testing.expect(slot.takeResult() == null);
    slot.finish(5000, .failed);
    try testing.expectEqual(Result{ .request = 5000, .outcome = .failed }, slot.takeResult().?);
}

test "each request's body" {
    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings("{\"on\":{\"on\":true}}", try body(&buf, ON));
    try testing.expectEqualStrings("{\"on\":{\"on\":false}}", try body(&buf, OFF));
    try testing.expectEqualStrings(bridge_write.STOP_FLASH_BODY, try body(&buf, STOP_FLASH));
    try testing.expect(std.mem.indexOf(u8, try body(&buf, 60_000), "60000") != null);
    try testing.expectError(error.NothingToSend, body(&buf, NONE));
    try testing.expectError(error.BadRequest, body(&buf, MAX_FLASH_MS + 1));
    try testing.expectEqualStrings("flash for 60 s", describe(&buf, 60_000));
}
