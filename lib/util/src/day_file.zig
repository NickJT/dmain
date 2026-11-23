//! An append-only file per local day: `dir/YYYY-MM-DD.<ext>`.
//!
//! **Named by local date, because the day a person asks about is a local
//! one.** What goes inside is the caller's; a caller recording instants should
//! stamp them in UTC, which never repeats an hour.
//!
//! **Each `append` is one positional write**, so there is nothing to flush and
//! a reader — `tail`, rsync, a replaying consumer — sees every completed write
//! the moment it lands. The only thing a reader can catch half-written is the
//! last line, which it recognises by its missing newline. A day's file is
//! closed by the first append of the next day, and is never rewritten.
//!
//! Best-effort: a failed write disables the file with one warning rather than
//! taking its process down, because a logger that dies over a full card logs
//! nothing at all.

const std = @import("std");
const Io = std.Io;
const Local = @import("local_time");

pub const Day = struct {
    year: i32,
    month: u8,
    day: u8,

    pub fn of(ts: Io.Timestamp) Day {
        const lt = Local.localAt(ts);
        const md = lt.monthDay();
        return .{ .year = lt.civilYear(), .month = md.month, .day = md.day };
    }

    pub fn eql(a: Day, b: Day) bool {
        return a.year == b.year and a.month == b.month and a.day == b.day;
    }

    /// `YYYY-MM-DD.<ext>`. The year is printed unsigned: `{d:0>4}` on a signed
    /// integer emits a `+`, which would name every file `+2026-…`.
    pub fn fileName(self: Day, buf: []u8, ext: []const u8) ![]const u8 {
        const year: u32 = @intCast(@max(0, self.year));
        return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}.{s}", .{ year, self.month, self.day, ext });
    }

    /// The inverse of `fileName`'s stem: `YYYY-MM-DD`.
    pub fn parse(s: []const u8) !Day {
        if (s.len != 10 or s[4] != '-' or s[7] != '-') return error.BadDay;
        return .{
            .year = try std.fmt.parseInt(i32, s[0..4], 10),
            .month = try std.fmt.parseInt(u8, s[5..7], 10),
            .day = try std.fmt.parseInt(u8, s[8..10], 10),
        };
    }
};

pub const DayFile = struct {
    io: Io,
    dir: Io.Dir,
    ext: []const u8,
    /// Written once when a file is created empty; null for none.
    header: ?[]const u8,
    day: ?Day = null,
    file: ?Io.File = null,
    offset: u64 = 0,
    /// Set after a failure, so a full card warns once rather than per write.
    failed: bool = false,

    pub fn init(io: Io, dir: Io.Dir, ext: []const u8, header: ?[]const u8) DayFile {
        return .{ .io = io, .dir = dir, .ext = ext, .header = header };
    }

    pub fn close(self: *DayFile) void {
        if (self.file) |f| f.close(self.io);
        self.file = null;
        self.day = null;
    }

    /// Append `bytes` to the file for the local day of `at`.
    pub fn append(self: *DayFile, at: Io.Timestamp, bytes: []const u8) void {
        if (self.failed) return;
        const day = Day.of(at);
        if (self.day == null or !self.day.?.eql(day)) self.open(day) catch |err| {
            std.log.warn("day_file: cannot open the .{s} file ({t}) — writing stopped", .{ self.ext, err });
            self.failed = true;
            return;
        };
        self.file.?.writePositionalAll(self.io, bytes, self.offset) catch |err| {
            std.log.warn("day_file: write failed ({t}) — writing stopped", .{err});
            self.failed = true;
            return;
        };
        self.offset += bytes.len;
    }

    /// Open, or create with its header, the file for `day`. Appends to an
    /// existing one, so a restart mid-day continues the same file.
    fn open(self: *DayFile, day: Day) !void {
        self.close();
        var name_buf: [64]u8 = undefined;
        const name = try day.fileName(&name_buf, self.ext);
        const f = try self.dir.createFile(self.io, name, .{ .truncate = false });
        errdefer f.close(self.io);
        var offset = (try f.stat(self.io)).size;
        if (offset == 0) if (self.header) |h| {
            try f.writePositionalAll(self.io, h, 0);
            offset = h.len;
        };
        self.file = f;
        self.offset = offset;
        self.day = day;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn instant(unix_s: i64) Io.Timestamp {
    return .{ .nanoseconds = @as(i96, unix_s) * std.time.ns_per_s };
}

test "Day.fileName has no sign on the year, and parse inverts it" {
    var buf: [32]u8 = undefined;
    const d: Day = .{ .year = 2026, .month = 11, .day = 3 };
    try testing.expectEqualStrings("2026-11-03.csv", try d.fileName(&buf, "csv"));
    try testing.expect(d.eql(try Day.parse("2026-11-03")));
    try testing.expectError(error.BadDay, Day.parse("2026-1-03"));
}

test "DayFile: header once, appends across a reopen, a new file per day" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    // Midday UTC on two days: the same local date anywhere from UTC-11 to +11.
    const d1 = instant(1793707200); // 2026-11-03T12:00:00Z
    const d2 = instant(1793793600); // 2026-11-04T12:00:00Z

    var f = DayFile.init(io, tmp.dir, "txt", "head\n");
    f.append(d1, "a\n");
    f.close();
    f = DayFile.init(io, tmp.dir, "txt", "head\n");
    f.append(d1, "b\n");
    f.append(d2, "c\n");
    f.close();
    try testing.expect(!f.failed);

    var name_buf: [32]u8 = undefined;
    const one = try tmp.dir.readFileAlloc(io, try Day.of(d1).fileName(&name_buf, "txt"), testing.allocator, .limited(256));
    defer testing.allocator.free(one);
    try testing.expectEqualStrings("head\na\nb\n", one);
    const two = try tmp.dir.readFileAlloc(io, try Day.of(d2).fileName(&name_buf, "txt"), testing.allocator, .limited(256));
    defer testing.allocator.free(two);
    try testing.expectEqualStrings("head\nc\n", two);
}
