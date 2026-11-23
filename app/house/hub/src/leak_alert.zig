//! Flashes a Hue Bridge light while a leak sensor reads wet.
//!
//! `Policy` decides when, and is pure so its timing can be tested. The Bridge
//! write is `bridge_sender`'s. The flash has its duration set on the Bridge, so
//! it ends by itself if hub dies mid-alert.

const std = @import("std");
const Io = std.Io;

pub const SETUP_FILE = "leak-alert.json";

/// Soon enough to matter in a leak, and well under the Bridge's rate limits.
const RETRY_MS: i64 = 30_000;
/// How long a sensor must read dry before it counts as dry. A probe being touched
/// or wiped flipped between wet and dry several times a second, 20 flips in 26 s,
/// and each flip would otherwise be a request to the Bridge.
const DRY_HOLD_MS: i64 = 30_000;
const MAX_FILE: usize = 4096;
const LIGHT_ID_LEN = 36;

pub const Command = enum { none, flash, stop };

pub const Policy = struct {
    repeat_ms: i64,
    flashing: bool = false,
    last_flash_ms: i64 = 0,
    was_latched: bool = false,
    /// Since when it has read dry without a break, if it has.
    dry_since_ms: ?i64 = null,
    /// Acknowledged before it settled dry. Only settling dry ends it, because a
    /// sensor that reports wet again re-latches, and an `ack` must stay heard.
    muted: bool = false,

    pub fn step(self: *Policy, alert: ?bool, latched: bool, now_ms: i64) Command {
        const wet = alert == true;
        if (wet) {
            self.dry_since_ms = null;
        } else if (self.dry_since_ms == null) {
            self.dry_since_ms = now_ms;
        }
        const settled_dry = if (self.dry_since_ms) |since| now_ms - since >= DRY_HOLD_MS else false;

        if (settled_dry) self.muted = false;
        if (self.was_latched and !latched and !settled_dry) self.muted = true;
        self.was_latched = latched;

        const carry_on = self.flashing and !settled_dry;
        if ((wet or carry_on) and latched and !self.muted) {
            if (self.flashing and now_ms - self.last_flash_ms < self.repeat_ms) return .none;
            self.flashing = true;
            self.last_flash_ms = now_ms;
            return .flash;
        }
        if (!self.flashing) return .none;
        self.flashing = false;
        return .stop;
    }

    /// The Bridge didn't take the flash, so try again sooner than the next repeat.
    pub fn flashFailed(self: *Policy, now_ms: i64) void {
        if (self.flashing) self.last_flash_ms = now_ms - self.repeat_ms + RETRY_MS;
    }
};

pub const Setup = struct {
    sensor: []const u8,
    light: []const u8,
    flash_s: u32,
    repeat_s: u32,

    fn check(self: Setup) !void {
        if (self.light.len != LIGHT_ID_LEN) return error.BadLightId;
        if (self.flash_s == 0 or self.repeat_s < self.flash_s) return error.BadTiming;
    }
};

pub fn parseSetup(arena: std.mem.Allocator, text: []const u8) !Setup {
    const setup = try std.json.parseFromSliceLeaky(Setup, arena, text, .{ .allocate = .alloc_always });
    try setup.check();
    return setup;
}

/// Null when the file is absent, which only means this hub has no alert.
pub fn load(arena: std.mem.Allocator, io: Io, dir: Io.Dir) !?Setup {
    var buf: [MAX_FILE]u8 = undefined;
    const text = dir.readFile(io, SETUP_FILE, &buf) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return try parseSetup(arena, text);
}

const testing = std.testing;

fn testPolicy() Policy {
    return .{ .repeat_ms = 300_000 };
}

test "a wet sensor flashes at once, then only at each repeat" {
    var p = testPolicy();
    try testing.expectEqual(Command.none, p.step(null, false, 0));
    try testing.expectEqual(Command.none, p.step(false, false, 1));
    try testing.expectEqual(Command.flash, p.step(true, true, 1000));
    try testing.expectEqual(Command.none, p.step(true, true, 1001));
    try testing.expectEqual(Command.none, p.step(true, true, 1000 + 299_999));
    try testing.expectEqual(Command.flash, p.step(true, true, 1000 + 300_000));
}

test "settling dry stops the flash once, and a new leak flashes again" {
    var p = testPolicy();
    try testing.expectEqual(Command.flash, p.step(true, true, 0));
    try testing.expectEqual(Command.none, p.step(false, true, 10));
    try testing.expectEqual(Command.none, p.step(false, true, 10 + DRY_HOLD_MS - 1));
    try testing.expectEqual(Command.stop, p.step(false, true, 10 + DRY_HOLD_MS));
    try testing.expectEqual(Command.none, p.step(false, true, 10 + DRY_HOLD_MS + 1));
    try testing.expectEqual(Command.flash, p.step(true, true, 10 + DRY_HOLD_MS + 2));
}

test "a flickering probe is one flash, however often it flips" {
    var p = testPolicy();
    try testing.expectEqual(Command.flash, p.step(true, true, 0));
    var now: i64 = 300;
    var wet = false;
    while (now < 26_000) : (now += 300) {
        try testing.expectEqual(Command.none, p.step(wet, true, now));
        wet = !wet;
    }
}

test "a flash carries on through a dry spell only up to the repeat" {
    var p = testPolicy();
    try testing.expectEqual(Command.flash, p.step(true, true, 0));
    try testing.expectEqual(Command.none, p.step(false, true, 299_990));
    try testing.expectEqual(Command.flash, p.step(false, true, 300_000));
    try testing.expectEqual(Command.stop, p.step(false, true, 299_990 + DRY_HOLD_MS));
}

test "an ack holds through a flicker, even one caught on a dry reading" {
    var p = testPolicy();
    try testing.expectEqual(Command.flash, p.step(true, true, 0));
    try testing.expectEqual(Command.none, p.step(false, true, 10));
    try testing.expectEqual(Command.stop, p.step(false, false, 20));
    try testing.expectEqual(Command.none, p.step(true, true, 30));
    try testing.expectEqual(Command.none, p.step(false, true, 40));
    try testing.expectEqual(Command.none, p.step(true, true, 50));
}

test "an ack stops the flash, and stays heard while it is still wet" {
    var p = testPolicy();
    try testing.expectEqual(Command.flash, p.step(true, true, 0));
    try testing.expectEqual(Command.stop, p.step(true, false, 10));
    try testing.expectEqual(Command.none, p.step(true, false, 300_020));
    // The sensor says wet again, which re-latches: still acknowledged.
    try testing.expectEqual(Command.none, p.step(true, true, 300_030));
    try testing.expectEqual(Command.none, p.step(true, true, 900_000));
    // Settled dry, then a new leak: a new alert.
    try testing.expectEqual(Command.none, p.step(false, true, 900_010));
    try testing.expectEqual(Command.none, p.step(false, true, 900_010 + DRY_HOLD_MS));
    try testing.expectEqual(Command.flash, p.step(true, true, 900_020 + DRY_HOLD_MS));
}

test "an ack after it has settled dry doesn't silence the next leak" {
    var p = testPolicy();
    try testing.expectEqual(Command.flash, p.step(true, true, 0));
    try testing.expectEqual(Command.none, p.step(false, true, 10));
    try testing.expectEqual(Command.stop, p.step(false, true, 10 + DRY_HOLD_MS));
    try testing.expectEqual(Command.none, p.step(false, false, 20 + DRY_HOLD_MS));
    try testing.expectEqual(Command.flash, p.step(true, true, 30 + DRY_HOLD_MS));
}

test "a flash the Bridge refused is tried again in 30 s, not 5 min" {
    var p = testPolicy();
    try testing.expectEqual(Command.flash, p.step(true, true, 0));
    p.flashFailed(100);
    try testing.expectEqual(Command.none, p.step(true, true, 100 + RETRY_MS - 1));
    try testing.expectEqual(Command.flash, p.step(true, true, 100 + RETRY_MS));
}

test "parseSetup refuses what would never work" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const id = "fbe5b4b7-bb8f-4978-851d-b122693511ed";
    const good = try parseSetup(a, "{\"sensor\":\"moisture\",\"light\":\"" ++ id ++ "\",\"flash_s\":60,\"repeat_s\":300}");
    try testing.expectEqualStrings("moisture", good.sensor);
    try testing.expectEqual(@as(u32, 60), good.flash_s);
    try testing.expectError(error.BadLightId, parseSetup(a, "{\"sensor\":\"m\",\"light\":\"x\",\"flash_s\":60,\"repeat_s\":300}"));
    try testing.expectError(error.BadTiming, parseSetup(a, "{\"sensor\":\"m\",\"light\":\"" ++ id ++ "\",\"flash_s\":0,\"repeat_s\":300}"));
    try testing.expectError(error.BadTiming, parseSetup(a, "{\"sensor\":\"m\",\"light\":\"" ++ id ++ "\",\"flash_s\":60,\"repeat_s\":30}"));
    try testing.expectError(error.UnknownField, parseSetup(a, "{\"sensor\":\"m\",\"light\":\"" ++ id ++ "\",\"flash_s\":60,\"repeat_s\":300,\"extra\":1}"));
}
