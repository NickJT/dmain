//! Timestamp arithmetic and formatting — **freestanding-safe**.
//!
//! Everything here is pure computation over a `std.Io.Timestamp` or a string:
//! no libc, no OS, no allocator except one handed in. That is the whole reason
//! this file exists separately from `local_time.zig`.
//!
//! ## Why the split
//!
//! Converting an instant to *local* wall-clock time needs libc's
//! `localtime_r` — `std.Io` has no equivalent in this Zig version — and libc is
//! exactly what a freestanding target does not have. Keeping the two halves in
//! one module would mean every caller of `formatTimestamp` dragged in a libc
//! dependency to get it, including a future Pico frontend that only ever wanted
//! to print a duration.
//!
//! So: **the arithmetic lives here and the timezone conversion lives in
//! `local_time.zig`.** A caller takes whichever it needs, and only a caller that
//! genuinely needs a wall clock pays for libc.
//!
//! Ported from `app/house/hub` and an earlier Hue monitor, which held byte-identical copies.

const std = @import("std");

/// Parse an ISO 8601 timestamp — `YYYY-MM-DDTHH:MM:SS`, with optional
/// fractional seconds.
///
/// **Interprets the string as UTC**, and ignores any zone suffix. Every caller
/// today is parsing a Hue bridge timestamp, which is UTC and carries a `Z`.
pub fn ISO2Timestamp(time_str: []const u8) !std.Io.Timestamp {
    if (time_str.len < 19) return error.TruncatedTimeString;

    // Enforce ISO 8601 syntax boundaries
    if (time_str[4] != '-' or time_str[7] != '-' or time_str[10] != 'T' or
        time_str[13] != ':' or time_str[16] != ':')
    {
        return error.BadTimeString;
    }

    // Parse explicit components safely
    const year = std.fmt.parseInt(i64, time_str[0..4], 10) catch return error.InvalidTimeString;
    const month = std.fmt.parseInt(u8, time_str[5..7], 10) catch return error.InvalidTimeString;
    const day = std.fmt.parseInt(u8, time_str[8..10], 10) catch return error.InvalidTimeString;
    const hour = std.fmt.parseInt(u8, time_str[11..13], 10) catch return error.InvalidTimeString;
    const minute = std.fmt.parseInt(u8, time_str[14..16], 10) catch return error.InvalidTimeString;
    const second = std.fmt.parseInt(u8, time_str[17..19], 10) catch return error.InvalidTimeString;

    // Extract sub-second ms bounds if present
    var ms: i64 = 0;
    if (time_str.len > 20 and time_str[19] == '.') {
        var end_idx: usize = 20;
        while (end_idx < time_str.len and time_str[end_idx] >= '0' and time_str[end_idx] <= '9') : (end_idx += 1) {}
        if (end_idx > 20) {
            const ms_str = time_str[20..end_idx];
            const parsed_ms = std.fmt.parseInt(i64, ms_str, 10) catch return error.InvalidTimeString;

            ms = switch (ms_str.len) {
                1 => parsed_ms * 100,
                2 => parsed_ms * 10,
                3 => parsed_ms,
                else => @divFloor(parsed_ms, std.math.pow(i64, 10, @intCast(ms_str.len - 3))),
            };
        }
    }

    // Validate operational date logic
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 59) {
        return error.InvalidTimeString;
    }

    const native_ms = dateToUnixTimestampMs(year, month, day, hour, minute, second, ms);

    // Convert to Zig 0.16 std.Io.Timestamp (which accepts an i96 nanosecond parameter)
    const ns: i96 = @intCast(native_ms * 1_000_000);
    const timestamp = std.Io.Timestamp.fromNanoseconds(ns);

    return timestamp;
}

pub fn dateToUnixTimestampMs(year: i64, month: i64, day: i64, hour: i64, minute: i64, second: i64, ms: i64) i64 {
    const days_in_months = [12]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var days: i64 = 0;

    var y: i64 = 1970;
    if (year >= 1970) {
        while (y < year) : (y += 1) {
            // Fixed: Changed % to @rem for signed i64 logic
            days += if ((@rem(y, 4) == 0 and @rem(y, 100) != 0) or (@rem(y, 400) == 0)) @as(i64, 366) else @as(i64, 365);
        }
    } else {
        while (y > year) : (y -= 1) {
            // Fixed: Changed % to @rem here as well
            days -= if ((@rem(y - 1, 4) == 0 and @rem(y - 1, 100) != 0) or (@rem(y - 1, 400) == 0)) @as(i64, 366) else @as(i64, 365);
        }
    }

    var m: i64 = 1;
    while (m < month) : (m += 1) {
        // Fixed: Swapped out the final % operators for the leap year check
        if (m == 2 and ((@rem(year, 4) == 0 and @rem(year, 100) != 0) or (@rem(year, 400) == 0))) {
            days += 29;
        } else {
            days += days_in_months[@intCast(m - 1)];
        }
    }

    days += (day - 1);
    const total_seconds = (days * 86400) + (hour * 3600) + (minute * 60) + second;
    return (total_seconds * 1000) + ms;
}

/// Prints a stored timestamp as an absolute HH:MM:SS. Unlike changed2Elapsed,
/// this needs no std.Io, since it derives time-of-day from the timestamp's
/// own value rather than comparing it against the current time.
///
/// **UTC**, because `EpochSeconds` knows nothing of timezones. For a clock a
/// human reads against the wall, use `local_time.zig`.
pub fn formatTimestamp(timestamp: std.Io.Timestamp, writer: *std.Io.Writer) !void {
    const total_seconds = timestamp.toSeconds();
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(total_seconds) };
    const day_seconds = epoch_seconds.getDaySeconds();
    try writer.print("{d:0>2}:{d:0>2}:{d:0>2}", .{
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

/// `YYYY-MM-DDTHH:MM:SSZ` — the inverse of `ISO2Timestamp`, to the second.
///
/// UTC for the same reason as `formatTimestamp`. A file meant to outlive a
/// clock change records instants this way: local time repeats an hour every
/// October, and UTC never does.
pub fn formatIsoUtc(timestamp: std.Io.Timestamp, writer: *std.Io.Writer) !void {
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp.toSeconds()) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    try writer.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u8, month_day.day_index) + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

/// `YYYY-MM-DDTHH:MM:SS.mmmZ` — `formatIsoUtc` to the millisecond, for a log
/// whose lines must sort by arrival even within one second.
pub fn formatIsoUtcMillis(timestamp: std.Io.Timestamp, writer: *std.Io.Writer) !void {
    const ms: u64 = @intCast(@mod(timestamp.toMilliseconds(), 1000));
    var buf: [24]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try formatIsoUtc(timestamp, &w);
    const s = w.buffered();
    try writer.print("{s}.{d:0>3}Z", .{ s[0 .. s.len - 1], ms });
}

test "Semantic Check" {
    std.testing.refAllDecls(@This());
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
//
// Added when this file was extracted from the two applications (2026-07-26).
// They serve two purposes: pinning behaviour that only `refAllDecls` covered
// before, and proving the extraction moved the code without changing it —
// every expected value below was computed from the pre-split copies.

const testing = std.testing;

test "dateToUnixTimestampMs: known epochs, leap years and pre-1970" {
    // The epoch itself, and a value easy to check against `date -u -j`.
    try testing.expectEqual(@as(i64, 0), dateToUnixTimestampMs(1970, 1, 1, 0, 0, 0, 0));
    try testing.expectEqual(@as(i64, 1_000_000_000_000), dateToUnixTimestampMs(2001, 9, 9, 1, 46, 40, 0));

    // Leap-year handling on both sides of 29 February. 2024 is a leap year;
    // 1900 is not (divisible by 100, not by 400) and 2000 is.
    try testing.expectEqual(
        @as(i64, 86_400_000),
        dateToUnixTimestampMs(2024, 3, 1, 0, 0, 0, 0) - dateToUnixTimestampMs(2024, 2, 29, 0, 0, 0, 0),
    );
    try testing.expectEqual(
        @as(i64, 366 * 86_400_000),
        dateToUnixTimestampMs(2001, 1, 1, 0, 0, 0, 0) - dateToUnixTimestampMs(2000, 1, 1, 0, 0, 0, 0),
    );
    try testing.expectEqual(
        @as(i64, 365 * 86_400_000),
        dateToUnixTimestampMs(1901, 1, 1, 0, 0, 0, 0) - dateToUnixTimestampMs(1900, 1, 1, 0, 0, 0, 0),
    );

    // Before the epoch, which is the branch using the other loop.
    try testing.expectEqual(@as(i64, -86_400_000), dateToUnixTimestampMs(1969, 12, 31, 0, 0, 0, 0));

    // Milliseconds pass through untouched.
    try testing.expectEqual(@as(i64, 1_500), dateToUnixTimestampMs(1970, 1, 1, 0, 0, 1, 500));
}

test "ISO2Timestamp: parses, and rejects malformed input rather than guessing" {
    const ts = try ISO2Timestamp("2026-07-26T07:56:31Z");
    try testing.expectEqual(@as(i64, 1785052591), @as(i64, @intCast(ts.toSeconds())));

    // Fractional seconds, at each width the switch handles. A trailing `Z` must
    // not be read as a digit.
    const one = try ISO2Timestamp("2026-07-26T07:56:31.5Z");
    const two = try ISO2Timestamp("2026-07-26T07:56:31.05Z");
    const three = try ISO2Timestamp("2026-07-26T07:56:31.005Z");
    const six = try ISO2Timestamp("2026-07-26T07:56:31.005999Z");
    try testing.expectEqual(@as(i96, 500_000_000), one.toNanoseconds() - ts.toNanoseconds());
    try testing.expectEqual(@as(i96, 50_000_000), two.toNanoseconds() - ts.toNanoseconds());
    try testing.expectEqual(@as(i96, 5_000_000), three.toNanoseconds() - ts.toNanoseconds());
    // More than three digits truncates rather than rounding.
    try testing.expectEqual(@as(i96, 5_000_000), six.toNanoseconds() - ts.toNanoseconds());

    try testing.expectError(error.TruncatedTimeString, ISO2Timestamp("2026-07-26"));
    try testing.expectError(error.BadTimeString, ISO2Timestamp("2026/07/26T07:56:31"));
    try testing.expectError(error.InvalidTimeString, ISO2Timestamp("2026-13-26T07:56:31"));
    try testing.expectError(error.InvalidTimeString, ISO2Timestamp("2026-07-26T24:56:31"));
    try testing.expectError(error.InvalidTimeString, ISO2Timestamp("20xx-07-26T07:56:31"));
}

test "formatTimestamp renders UTC time-of-day" {
    const ts = try ISO2Timestamp("2026-07-26T07:56:31Z");

    var buf: [8]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try formatTimestamp(ts, &w);
    try testing.expectEqualStrings("07:56:31", &buf);
}

test "formatIsoUtc round-trips through ISO2Timestamp" {
    var buf: [32]u8 = undefined;
    for ([_][]const u8{ "2026-11-03T08:15:02Z", "2028-02-29T23:59:59Z", "1970-01-01T00:00:00Z" }) |iso| {
        var w = std.Io.Writer.fixed(&buf);
        try formatIsoUtc(try ISO2Timestamp(iso), &w);
        try std.testing.expectEqualStrings(iso, w.buffered());
    }
}

test "formatIsoUtcMillis keeps the milliseconds and parses back" {
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const ts = try ISO2Timestamp("2026-11-04T09:20:04.067Z");
    try formatIsoUtcMillis(ts, &w);
    try std.testing.expectEqualStrings("2026-11-04T09:20:04.067Z", w.buffered());
}
