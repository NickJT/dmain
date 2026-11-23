//! Tells a shower from a humid room, from one sensor's humidity readings, for a
//! fan to run on.
//!
//! **A shower is a fast rise, not a high reading.** The Ensuite reads 68 to 93 %
//! all day and stays near 90 % for hours after a shower, so no threshold works.
//! A rise of `RISE_CENTI` within `WINDOW_MS` picked out both showers each day of
//! a week of `hum1`'s readings (2026-11-11 to 17) and nothing else.
//!
//! **A run ends only `RUN_AFTER_RISE_MS` after its last rise.** It also ended once
//! the reading fell back near where it rose from, until that stopped a run after
//! 28 minutes with the room at 83.5 % (2026-11-18): this room's air is near 80 %
//! anyway, so near the start isn't dry. Pure: readings and the clock in, `humid`
//! and `dry` out.

const std = @import("std");

/// 5 points of relative humidity, in the ZCL's hundredths.
pub const RISE_CENTI: u16 = 500;
pub const WINDOW_MS: i64 = 10 * 60_000;
/// A run is over this long after the last reading that was still rising.
pub const RUN_AFTER_RISE_MS: i64 = 45 * 60_000;

const Reading = struct { at_ms: i64, centi: u16 };

/// The sensor reports at most every 30 s, so a 10-minute window holds about 20;
/// past this, the oldest are dropped, which only makes a rise harder to see.
const KEEP = 32;

pub const Detector = struct {
    readings: [KEEP]Reading = undefined,
    len: usize = 0,
    /// While a run lasts, when it last rose.
    last_rise_ms: ?i64 = null,

    pub fn running(self: *const Detector) bool {
        return self.last_rise_ms != null;
    }

    /// The lowest reading in the window before `now_ms`, if any.
    pub fn windowLow(self: *const Detector, now_ms: i64) ?u16 {
        var low: ?u16 = null;
        for (self.readings[0..self.len]) |r| {
            if (now_ms - r.at_ms > WINDOW_MS) continue;
            low = if (low) |l| @min(l, r.centi) else r.centi;
        }
        return low;
    }

    /// True when this reading starts a run: `humid`. A rise during a run moves
    /// its end; only `tick` ends one.
    pub fn reading(self: *Detector, centi: u16, now_ms: i64) bool {
        const low = self.windowLow(now_ms);
        self.keep(.{ .at_ms = now_ms, .centi = centi });
        const rising = if (low) |l| centi >= l +| RISE_CENTI else false;
        if (!rising) return false;
        const started = self.last_rise_ms == null;
        self.last_rise_ms = now_ms;
        return started;
    }

    /// True when a run has gone `RUN_AFTER_RISE_MS` without a rise: `dry`.
    pub fn tick(self: *Detector, now_ms: i64) bool {
        const last = self.last_rise_ms orelse return false;
        if (now_ms - last < RUN_AFTER_RISE_MS) return false;
        self.last_rise_ms = null;
        return true;
    }

    fn keep(self: *Detector, r: Reading) void {
        // Drop what's out of the window, then the oldest if still full.
        var n: usize = 0;
        for (self.readings[0..self.len]) |old| {
            if (r.at_ms - old.at_ms <= WINDOW_MS) {
                self.readings[n] = old;
                n += 1;
            }
        }
        if (n == KEEP) {
            std.mem.copyForwards(Reading, self.readings[0 .. KEEP - 1], self.readings[1..KEEP]);
            n -= 1;
        }
        self.readings[n] = r;
        self.len = n + 1;
    }
};

const testing = std.testing;
const MIN: i64 = 60_000;

test "a shower's rise starts a run, and 45 minutes after the last rise ends it" {
    var d: Detector = .{};
    // A slow evening: no run.
    try testing.expect(!d.reading(7800, 0));
    try testing.expect(!d.reading(7820, 15 * MIN));
    // The shower: 1 point a minute.
    try testing.expect(!d.reading(7920, 16 * MIN));
    try testing.expect(!d.reading(8150, 19 * MIN));
    try testing.expect(d.reading(8330, 21 * MIN));
    // Still climbing: each rise moves the end, and starts nothing new.
    try testing.expect(!d.reading(9000, 26 * MIN));
    try testing.expect(!d.tick(26 * MIN + RUN_AFTER_RISE_MS - 1));
    // Then it stays high for hours, as the Ensuite does.
    try testing.expect(!d.reading(9050, 50 * MIN));
    try testing.expect(d.tick(26 * MIN + RUN_AFTER_RISE_MS));
    try testing.expect(!d.running());
    try testing.expect(!d.tick(200 * MIN));
}

test "falling back near the start doesn't end a run" {
    // 2026-11-18's first shower: up from 79 % to 88.6 %, then down to 83.5 %
    // 28 minutes on, which once ended the run with the room still damp.
    var d: Detector = .{};
    _ = d.reading(7900, 0);
    try testing.expect(d.reading(8450, 5 * MIN));
    try testing.expect(!d.reading(8860, 8 * MIN));
    try testing.expect(!d.reading(8350, 33 * MIN));
    try testing.expect(!d.reading(7940, 48 * MIN));
    try testing.expect(d.running());
    try testing.expect(d.tick(8 * MIN + RUN_AFTER_RISE_MS));
}

test "a second shower during a run extends it, then a later one starts another" {
    var d: Detector = .{};
    _ = d.reading(7900, 0);
    try testing.expect(d.reading(8450, 5 * MIN));
    _ = d.reading(7940, 48 * MIN);
    // Another rise at 50 minutes: the same run, now ending 45 minutes after it.
    try testing.expect(!d.reading(8460, 50 * MIN));
    try testing.expect(!d.tick(5 * MIN + RUN_AFTER_RISE_MS));
    try testing.expect(d.tick(50 * MIN + RUN_AFTER_RISE_MS));
    _ = d.reading(7900, 200 * MIN);
    try testing.expect(d.reading(8500, 205 * MIN));
}

test "a slow rise is not a shower, nor is a first reading" {
    var d: Detector = .{};
    try testing.expect(!d.reading(9000, 0));
    var t: i64 = MIN;
    var v: u16 = 7000;
    // 1 point every 4 minutes, for two hours: never 5 within 10 minutes.
    while (t < 120 * MIN) : (t += 4 * MIN) {
        try testing.expect(!d.reading(v, t));
        v += 100;
    }
    try testing.expect(!d.running());
}

test "a rise against a reading older than the window doesn't count" {
    var d: Detector = .{};
    _ = d.reading(7000, 0);
    try testing.expect(!d.reading(7600, 11 * MIN));
}

test "many readings keep the newest" {
    var d: Detector = .{};
    var t: i64 = 0;
    while (t < 40) : (t += 1) _ = d.reading(7000, t * 1000);
    try testing.expectEqual(@as(usize, KEEP), d.len);
    try testing.expectEqual(@as(i64, 39_000), d.readings[KEEP - 1].at_ms);
    try testing.expect(d.reading(7500, 41_000));
}
