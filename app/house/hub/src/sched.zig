//! Simple schedules: fires a `config.zig` `ScheduleEntry`
//! once per day at its configured local wall-clock time. Split in two
//! deliberately:
//!   - `currentCalendarDay` — the only IMPURE part: it reads the clock.
//!     A `schedule.json` "18:00" means the user's *local* evening, and an
//!     instant-to-local conversion needs the OS timezone database (the
//!     offset isn't even constant — it shifts at DST transitions). That
//!     conversion lives in `time.zig` as `localNow` (libc's `localtime_r`,
//!     which has no `std.Io` equivalent in this Zig version); this module
//!     had it first, and the persistent log moved it there so `hub.log`'s
//!     timestamps could share one copy of the `struct tm` layout rather
//!     than duplicate it.
//!   - `Scheduler.tick` — pure decision logic (given a time + calendar day
//!     + the schedule list, which entries fire *now*), fully unit-testable
//!     without touching the real clock.
//! The caller (`main.zig`) turns a fired entry into a `PendingAction` via
//! `engine.zig`'s `Coordinator.enqueueAction` and drains it through the
//! exact same fire-and-forget path a rule-matched action already uses —
//! a schedule is just a rule whose "event" is wall-clock time instead of
//! a physical button/sensor, with `Phase.tick` (a schedule is a one-shot
//! trigger, not a press/hold/release gesture).
const std = @import("std");
const Local = @import("local_time");

pub const LocalTime = struct { hour: u8, minute: u8 };

/// Local wall-clock hour/minute, right now.
pub fn currentLocalTime(io: std.Io) LocalTime {
    const day = currentCalendarDay(io);
    return .{ .hour = day.hour, .minute = day.minute };
}

/// Enough of `struct tm` to both check a time-of-day match (`hour`/
/// `minute`) and tell today apart from any other day (`year`/`yday`) —
/// the latter is what makes `Scheduler` fire an entry once per day
/// instead of once per matching minute (a HH:MM match is true for a full
/// 60 seconds of poll-loop ticks).
pub const CalendarDay = struct { year: i16, yday: i16, hour: u8, minute: u8 };

pub fn currentCalendarDay(io: std.Io) CalendarDay {
    // The libc `localtime_r` conversion this module used to own now lives in
    // `time.zig`, shared with `hub.log`'s timestamps — one
    // copy of the `struct tm` layout, not two. The split this module cares
    // about is unchanged: everything below `tick` stays pure and testable,
    // and only this function reads the clock.
    const t = Local.localNow(io);
    return .{ .year = t.year, .yday = t.yday, .hour = t.hour, .minute = t.minute };
}

pub const MAX_SCHEDULES = ConfigMod.MAX_SCHEDULES;

/// Indices into `config.schedules` that matched on one `Scheduler.tick`
/// call. Bounded/fixed-size — same convention as `engine.zig`'s
/// `PendingAction` queue — since a real fleet has few schedules and a
/// single wall-clock minute can plausibly match more than one of them.
pub const FiredList = struct {
    indices: [MAX_SCHEDULES]usize = undefined,
    count: usize = 0,

    fn append(self: *FiredList, i: usize) void {
        if (self.count < self.indices.len) {
            self.indices[self.count] = i;
            self.count += 1;
        }
    }

    pub fn slice(self: *const FiredList) []const usize {
        return self.indices[0..self.count];
    }
};

/// Per-entry "already fired today" state, indexed by position in
/// `config.schedules`. `-1` sentinels mean "never fired" (a valid
/// `tm_year`/`tm_yday` is always >= 0).
pub const Scheduler = struct {
    last_fired_year: [MAX_SCHEDULES]i16 = @splat(-1),
    last_fired_yday: [MAX_SCHEDULES]i16 = @splat(-1),

    /// Checks every entry in `schedules` against `cal`; an entry fires if
    /// its `time` matches `cal.hour`/`cal.minute` AND it hasn't already
    /// fired on `cal.year`/`cal.yday`. Entries past `MAX_SCHEDULES` are
    /// silently unreachable (a real fleet has far fewer; validated
    /// schedule count isn't enforced at load, so this is a safety bound,
    /// not an expected case).
    pub fn tick(self: *Scheduler, schedules: anytype, cal: CalendarDay) FiredList {
        var fired: FiredList = .{};
        for (schedules, 0..) |entry, i| {
            if (i >= MAX_SCHEDULES) break;
            const t = ParseHHMM(entry.time) orelse continue; // validated at load
            if (t.hour != cal.hour or t.minute != cal.minute) continue;
            if (self.last_fired_year[i] == cal.year and self.last_fired_yday[i] == cal.yday) continue;
            self.last_fired_year[i] = cal.year;
            self.last_fired_yday[i] = cal.yday;
            fired.append(i);
        }
        return fired;
    }
};

// `config.zig`'s parseHHMM, re-exported under a test-local name so this
// module's tests don't need a real `config.Config` — see the test below
// for why a plain struct literal stands in for `ScheduleEntry`.
const ConfigMod = @import("config");
const ParseHHMM = ConfigMod.parseHHMM;

test "Scheduler.tick fires once per day, not once per matching minute" {
    const TestEntry = struct { name: []const u8, time: []const u8, action: []const u8, target: []const u8 };
    const schedules = [_]TestEntry{
        .{ .name = "porch-on", .time = "18:00", .action = "on", .target = "bulb1" },
        .{ .name = "porch-off", .time = "23:30", .action = "off", .target = "bulb1" },
    };

    var sched: Scheduler = .{};
    const cal: CalendarDay = .{ .year = 126, .yday = 200, .hour = 18, .minute = 0 };

    const first = sched.tick(&schedules, cal);
    try std.testing.expectEqual(@as(usize, 1), first.count);
    try std.testing.expectEqual(@as(usize, 0), first.slice()[0]); // porch-on

    // Same minute polled again (the ~1s poll cadence ticks many times
    // within one wall-clock minute) — must NOT re-fire.
    const second = sched.tick(&schedules, cal);
    try std.testing.expectEqual(@as(usize, 0), second.count);

    // A later time that matches the second entry fires it independently.
    const evening: CalendarDay = .{ .year = 126, .yday = 200, .hour = 23, .minute = 30 };
    const third = sched.tick(&schedules, evening);
    try std.testing.expectEqual(@as(usize, 1), third.count);
    try std.testing.expectEqual(@as(usize, 1), third.slice()[0]); // porch-off

    // The next day, the same HH:MM match fires again.
    const next_day: CalendarDay = .{ .year = 126, .yday = 201, .hour = 18, .minute = 0 };
    const fourth = sched.tick(&schedules, next_day);
    try std.testing.expectEqual(@as(usize, 1), fourth.count);
}

test "Scheduler.tick skips entries with an unparseable time" {
    const TestEntry = struct { name: []const u8, time: []const u8, action: []const u8, target: []const u8 };
    const schedules = [_]TestEntry{
        .{ .name = "bad", .time = "not-a-time", .action = "on", .target = "bulb1" },
    };
    var sched: Scheduler = .{};
    const cal: CalendarDay = .{ .year = 126, .yday = 1, .hour = 12, .minute = 0 };
    const fired = sched.tick(&schedules, cal);
    try std.testing.expectEqual(@as(usize, 0), fired.count);
}

test "Semantic Check" {
    std.testing.refAllDecls(@This());
}
