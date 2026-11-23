//! Local wall-clock time — **host-only, and the only file in this package that
//! is**.
//!
//! Split out of `time.zig` on 2026-07-26 so that a libc dependency reaches only
//! the callers that genuinely need one. Everything here goes through libc's
//! `localtime_r`; everything that does not is next door and stays
//! freestanding-safe.
//!
//! **Take this module only for a clock a human reads against the wall.** For
//! durations, elapsed times, ISO parsing or printing a stored instant, use
//! `time.zig` — those need no timezone and therefore no libc.
//!
//! ## Why local, rather than just using the epoch helpers
//!
//! `std.time.epoch.EpochSeconds` has no timezone or DST awareness, so on a
//! machine in BST it reports an hour behind the clock on the wall. That is
//! wrong for every consumer either application has — a TUI clock a human reads,
//! a `hub.log` line correlated against "the lights died around 2am", and
//! `sched.zig`'s "18:00" meaning the user's evening. The offset is not even
//! constant: it shifts at DST transitions. An earlier clock here read an hour
//! off all summer for exactly this reason.

const std = @import("std");

const c = struct {
    extern fn localtime_r(timer: *const i64, result: *Tm) ?*Tm;
    // POSIX `struct tm` — `tm_gmtoff`/`tm_zone` are BSD extensions after
    // the 9 POSIX-standard `int` fields; unused here but must be present
    // for the struct's size/layout to match what `localtime_r` writes.
    // Layout verified against BOTH bundled libc headers and found
    // identical: Darwin's `_time.h`, and glibc's `bits/types/struct_tm.h`.
    // glibc renames the last two fields to `__tm_gmtoff`/`__tm_zone`
    // without `__USE_MISC`, but never omits them, so size and field offsets
    // match on both platforms. `time_t` is 64-bit on both targets these
    // applications build for (aarch64-macos, x86_64-linux), matching the
    // `i64` below.
    const Tm = extern struct {
        tm_sec: c_int,
        tm_min: c_int,
        tm_hour: c_int,
        tm_mday: c_int,
        tm_mon: c_int,
        tm_year: c_int,
        tm_wday: c_int,
        tm_yday: c_int,
        tm_isdst: c_int,
        tm_gmtoff: c_long,
        tm_zone: ?[*:0]const u8,
    };
};

/// Enough of `struct tm` for what the two applications need: telling one day
/// from another (`year`/`yday` — hub's `sched.zig` once-per-day dedup) and
/// showing a wall clock (`hour`/`minute`/`second`).
pub const LocalTime = struct {
    year: i16,
    yday: i16,
    hour: u8,
    minute: u8,
    second: u8,

    /// The calendar year, e.g. 2026.
    ///
    /// **`LocalTime.year` is libc's `tm_year`, which counts from 1900**, so the raw
    /// field is 126 for 2026. Nothing was wrong with that until something wanted to
    /// print a date; this exists so the +1900 is written once rather than at every
    /// call site that gets it wrong.
    pub fn civilYear(self: LocalTime) i32 {
        return 1900 + @as(i32, self.year);
    }

    /// Month (1-12) and day-of-month (1-31) from `year`/`yday`.
    ///
    /// `LocalTime` carries `yday` because its original callers only ever needed to
    /// tell one day from another. Printing a date needs the calendar, and this is
    /// the conversion — leap-year aware, because a log timestamped 2028-02-29 as
    /// "03-01" would be wrong exactly once every four years, which is the worst
    /// possible frequency for noticing.
    pub fn monthDay(self: LocalTime) struct { month: u8, day: u8 } {
        const y = self.civilYear();
        const leap = (@rem(y, 4) == 0 and @rem(y, 100) != 0) or @rem(y, 400) == 0;
        const lengths = [12]u16{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

        // `tm_yday` is 0-based; day-of-month is 1-based.
        var remaining: i32 = self.yday;
        for (lengths, 0..) |len, i| {
            if (remaining < len) return .{ .month = @intCast(i + 1), .day = @intCast(remaining + 1) };
            remaining -= len;
        }
        // Only reachable if yday is out of range for the year, which libc does not
        // produce. Clamp rather than trap: a log line is not worth a panic.
        return .{ .month = 12, .day = 31 };
    }
};

/// Local wall-clock time at an arbitrary instant.
///
/// The general form, and `localNow` is the special case. Added 2026-07-26,
/// because until then this module could only answer "what time is it now",
/// which left the interesting question unanswerable: **what the clock does
/// across a DST transition.** That is the behaviour this workspace actually
/// gets caught by, and it is untestable without being able to name an instant.
///
/// Takes no `std.Io` — an instant is already an instant, so there is no clock
/// to read.
pub fn localAt(timestamp: std.Io.Timestamp) LocalTime {
    const secs: i64 = @intCast(timestamp.toSeconds());
    var tm: c.Tm = undefined;
    _ = c.localtime_r(&secs, &tm);
    return .{
        .year = @intCast(tm.tm_year),
        .yday = @intCast(tm.tm_yday),
        .hour = @intCast(tm.tm_hour),
        .minute = @intCast(tm.tm_min),
        .second = @intCast(tm.tm_sec),
    };
}

/// Local wall-clock time right now. "Now" comes from `Io.Timestamp` like
/// everything else in this workspace; only the timezone conversion is libc's.
pub fn localNow(io: std.Io) LocalTime {
    return localAt(std.Io.Timestamp.now(io, .real));
}

/// "YYYY-MM-DD HH:MM:SS" in local time.
///
/// A log read tomorrow needs the time; a log read next month needs the date,
/// and a log that rotates or is copied off the machine has no other record of
/// which day a line belongs to.
pub fn formatLocalDateTime(io: std.Io, writer: *std.Io.Writer) !void {
    const t = localNow(io);
    const md = t.monthDay();
    // The year is cast to unsigned before printing. `{d:0>4}` on a *signed*
    // integer emits an explicit `+`, so the year came out as "+2026" and every
    // date field was one byte wider than it looks — which matters here, because
    // callers address these as fixed columns.
    const year: u32 = @intCast(@max(0, t.civilYear()));
    try writer.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year, md.month, md.day, t.hour, t.minute, t.second,
    });
}

/// "HH:MM:SS" in local time, for anything a human reads.
pub fn formatLocalTime(io: std.Io, writer: *std.Io.Writer) !void {
    const t = localNow(io);
    try writer.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ t.hour, t.minute, t.second });
}

/// "HH:MM:SS" for display — **local**, not UTC. Its callers are the two TUIs'
/// corner clocks, read against the clock on the wall.
pub fn timeNow(io: std.Io, buf: *[8]u8) ![]const u8 {
    const t = localNow(io);
    return try std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ t.hour, t.minute, t.second });
}

test "monthDay: boundaries, and the leap year that only bites once in four" {
    const t = std.testing;
    // 2026 is not a leap year. yday is 0-based.
    const y2026: i16 = 2026 - 1900;
    try t.expectEqual(@as(u8, 1), (LocalTime{ .year = y2026, .yday = 0, .hour = 0, .minute = 0, .second = 0 }).monthDay().month);
    try t.expectEqual(@as(u8, 1), (LocalTime{ .year = y2026, .yday = 0, .hour = 0, .minute = 0, .second = 0 }).monthDay().day);
    // 2026-08-21 is yday 232.
    const aug = (LocalTime{ .year = y2026, .yday = 232, .hour = 0, .minute = 0, .second = 0 }).monthDay();
    try t.expectEqual(@as(u8, 8), aug.month);
    try t.expectEqual(@as(u8, 21), aug.day);
    // Last day of a common year.
    const dec = (LocalTime{ .year = y2026, .yday = 364, .hour = 0, .minute = 0, .second = 0 }).monthDay();
    try t.expectEqual(@as(u8, 12), dec.month);
    try t.expectEqual(@as(u8, 31), dec.day);

    // 2028 IS a leap year: yday 59 is 29 February, not 1 March. Getting this
    // wrong is invisible for four years at a time.
    const y2028: i16 = 2028 - 1900;
    const feb29 = (LocalTime{ .year = y2028, .yday = 59, .hour = 0, .minute = 0, .second = 0 }).monthDay();
    try t.expectEqual(@as(u8, 2), feb29.month);
    try t.expectEqual(@as(u8, 29), feb29.day);
    const mar1 = (LocalTime{ .year = y2028, .yday = 60, .hour = 0, .minute = 0, .second = 0 }).monthDay();
    try t.expectEqual(@as(u8, 3), mar1.month);
    try t.expectEqual(@as(u8, 1), mar1.day);

    // 2100 is NOT a leap year — the century rule, which a naive %4 gets wrong.
    const y2100: i16 = 2100 - 1900;
    const mar1_2100 = (LocalTime{ .year = y2100, .yday = 59, .hour = 0, .minute = 0, .second = 0 }).monthDay();
    try t.expectEqual(@as(u8, 3), mar1_2100.month);
    try t.expectEqual(@as(u8, 1), mar1_2100.day);

    // 2000 IS a leap year — the 400 rule.
    const y2000: i16 = 2000 - 1900;
    const feb29_2000 = (LocalTime{ .year = y2000, .yday = 59, .hour = 0, .minute = 0, .second = 0 }).monthDay();
    try t.expectEqual(@as(u8, 2), feb29_2000.month);
    try t.expectEqual(@as(u8, 29), feb29_2000.day);
}

test "civilYear undoes tm_year's 1900 base" {
    try std.testing.expectEqual(@as(i32, 2026), (LocalTime{ .year = 126, .yday = 0, .hour = 0, .minute = 0, .second = 0 }).civilYear());
}

test "Semantic Check" {
    std.testing.refAllDecls(@This());
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
//
// Two kinds here, and the difference is whether the test may name a timezone.
//
// **The `localNow` tests may not.** The machine's zone is not ours to choose,
// so they assert only what holds anywhere: fields in range, the entry points
// agreeing, and the conversion being applied at all (checked against libc's own
// `tm_gmtoff` rather than a hardcoded offset).
//
// **The `localAt` tests pin TZ to Europe/London and restore it after.** An
// instant plus a named zone has exactly one right answer, so these are ordinary
// deterministic tests — and they are the ones that cover DST, which is the
// behaviour worth having pinned. Every expected value below was cross-checked
// against the IANA database.

const testing = std.testing;

/// libc's timezone plumbing, needed only to make the DST tests deterministic.
/// Kept beside the tests rather than in `c` above, since nothing in the module
/// proper touches the environment.
const c_tz = struct {
    extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern fn unsetenv(name: [*:0]const u8) c_int;
    extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
    /// Re-reads TZ. libc caches the zone, so changing the variable without
    /// this has no effect — and the failure is silent, which is exactly the
    /// kind of thing that makes a timezone test quietly meaningless.
    extern fn tzset() void;
};

/// Runs `body` with TZ pinned, then puts the environment back as it was.
///
/// The restore matters: tests share one process, and a stray TZ would leave
/// every later test in this file measuring London rather than the machine.
fn withTimezone(comptime zone: [:0]const u8, body: fn () anyerror!void) !void {
    const saved = c_tz.getenv("TZ");
    defer {
        if (saved) |s| _ = c_tz.setenv("TZ", s, 1) else _ = c_tz.unsetenv("TZ");
        c_tz.tzset();
    }

    _ = c_tz.setenv("TZ", zone.ptr, 1);
    c_tz.tzset();
    try body();
}

/// A UTC instant, by epoch second, as a `std.Io.Timestamp`.
fn at(epoch_seconds: i64) std.Io.Timestamp {
    return std.Io.Timestamp.fromNanoseconds(@as(i96, epoch_seconds) * 1_000_000_000);
}

test "localNow returns a plausible wall clock, and the formatters agree" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const t = localNow(io);
    try testing.expect(t.hour <= 23);
    try testing.expect(t.minute <= 59);
    try testing.expect(t.second <= 60); // 60 for a leap second
    try testing.expect(t.yday >= 0 and t.yday <= 365);
    // `tm_year` is years since 1900, passed through unchanged.
    try testing.expect(t.year >= 125);

    var buf: [8]u8 = undefined;
    const from_timeNow = try timeNow(io, &buf);

    var fmt_buf: [8]u8 = undefined;
    var w = std.Io.Writer.fixed(&fmt_buf);
    try formatLocalTime(io, &w);

    // Both read the clock independently, so a second can tick between them.
    // The hour and minute are what must agree.
    try testing.expectEqualStrings(from_timeNow[0..5], fmt_buf[0..5]);
}

test "the conversion is applied: local == UTC shifted by libc's own offset" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // One instant, read two ways, so the two cannot drift a second apart
    // mid-test the way two separate clock reads can.
    const secs: i64 = @intCast(std.Io.Timestamp.now(io, .real).toSeconds());

    const utc = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
    const utc_day = utc.getDaySeconds();
    const utc_minutes: i32 = @as(i32, utc_day.getHoursIntoDay()) * 60 +
        @as(i32, utc_day.getMinutesIntoHour());

    // `tm_gmtoff` is the zone's offset in seconds, straight from libc — the
    // authority we are checking ourselves against, rather than a hardcoded
    // guess that would fail on a rig set to any other timezone.
    var tm: c.Tm = undefined;
    _ = c.localtime_r(&secs, &tm);

    // **Minutes, not hours.** Not every zone is a whole number of hours from
    // UTC: India is +05:30, Nepal +05:45, Chatham +12:45. An earlier version of
    // this test divided the offset by 3600 and was found by running the suite
    // under `TZ=Australia/Lord_Howe` (+10:30), where it failed by exactly the
    // half hour it had discarded.
    const offset_minutes = @divTrunc(@as(i32, @intCast(tm.tm_gmtoff)), 60);
    const local_minutes: i32 = @as(i32, tm.tm_hour) * 60 + @as(i32, tm.tm_min);

    try testing.expectEqual(@mod(utc_minutes + offset_minutes, 24 * 60), local_minutes);

    // On a UTC machine `offset_minutes` is 0 and this still holds. On the
    // development rig in BST it is 60 — which is the case that would have
    // caught the bug that shipped all summer, where the wall clock came from
    // the timezone-blind `EpochSeconds` path and ignored the offset entirely.
    if (offset_minutes != 0) try testing.expect(utc_minutes != local_minutes);
}

test "localAt: the same instant reads differently in winter and summer" {
    try withTimezone("Europe/London", struct {
        fn f() !void {
            // 2026-01-15T12:00:00Z — GMT, so local == UTC.
            const winter = localAt(at(1768478400));
            try testing.expectEqual(@as(u8, 12), winter.hour);
            try testing.expectEqual(@as(u8, 0), winter.minute);

            // 2026-07-15T12:00:00Z — BST, so local is an hour ahead. This is
            // the difference the old clock was blind to.
            const summer = localAt(at(1784116800));
            try testing.expectEqual(@as(u8, 13), summer.hour);
            try testing.expectEqual(@as(u8, 0), summer.minute);
        }
    }.f);
}

test "localAt: spring forward — the 01:00 hour never happens" {
    // The fact a clock face relies on: at the spring transition the
    // quotes for 01:00-01:59 are never displayed, because that hour does not
    // occur. Pinned here so it is a property of the code, not a note in prose.
    try withTimezone("Europe/London", struct {
        fn f() !void {
            // 2026-03-29T00:59:59Z, one second before the transition.
            const before = localAt(at(1774745999));
            try testing.expectEqual(@as(u8, 0), before.hour);
            try testing.expectEqual(@as(u8, 59), before.minute);
            try testing.expectEqual(@as(u8, 59), before.second);

            // 2026-03-29T01:00:00Z, the transition itself. The wall clock jumps
            // from 00:59:59 straight to 02:00:00 — 01:xx is skipped entirely.
            const after = localAt(at(1774746000));
            try testing.expectEqual(@as(u8, 2), after.hour);
            try testing.expectEqual(@as(u8, 0), after.minute);

            // Every second of the missing hour maps to 02:xx or later, never
            // to 01:xx. Sampled across the whole hour rather than at its edges,
            // since an off-by-one in a zone table would show up mid-hour.
            var s: i64 = 1774746000;
            while (s < 1774746000 + 3600) : (s += 137) {
                try testing.expect(localAt(at(s)).hour != 1);
            }
        }
    }.f);
}

test "localAt: fall back — the 01:00 hour happens twice" {
    // The autumn half of 6.28: those quotes are shown twice. Same instant
    // arithmetic, opposite direction.
    try withTimezone("Europe/London", struct {
        fn f() !void {
            // 2026-10-25T00:59:59Z — still BST, so 01:59:59 local.
            const first = localAt(at(1792889999));
            try testing.expectEqual(@as(u8, 1), first.hour);
            try testing.expectEqual(@as(u8, 59), first.minute);

            // 2026-10-25T01:00:00Z — GMT resumes, and the clock returns to
            // 01:00:00. Two distinct instants, one hour apart, both reading
            // 01:xx on the wall.
            const second = localAt(at(1792890000));
            try testing.expectEqual(@as(u8, 1), second.hour);
            try testing.expectEqual(@as(u8, 0), second.minute);

            // Stated as the ambiguity it is: one wall-clock time, two instants
            // an hour of UTC apart. 00:30Z is 01:30 BST; 01:30Z is 01:30 GMT.
            const bst_0130 = localAt(at(1792888200));
            const gmt_0130 = localAt(at(1792891800));
            try testing.expectEqual(@as(u8, 1), bst_0130.hour);
            try testing.expectEqual(@as(u8, 30), bst_0130.minute);
            try testing.expectEqual(bst_0130.hour, gmt_0130.hour);
            try testing.expectEqual(bst_0130.minute, gmt_0130.minute);
        }
    }.f);
}

test "localAt: localNow is the same conversion, applied to now" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Whatever the machine's zone, the two must agree for one instant — which
    // is what makes the DST tests above cover `localNow` as well.
    const now = std.Io.Timestamp.now(io, .real);
    const via_at = localAt(now);
    const via_now = localNow(io);
    try testing.expectEqual(via_at.hour, via_now.hour);
    try testing.expectEqual(via_at.minute, via_now.minute);
    try testing.expectEqual(via_at.yday, via_now.yday);
}
