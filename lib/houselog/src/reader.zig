//! Reading the house log: a day replayed from its start, then followed as it
//! grows and across midnight into the next day's file.
//!
//! **One mechanism for both.** A consumer starting mid-day rebuilds its state
//! by replaying today's file from the top, and carries on from where the replay
//! ended; an export is a replay with no carrying on. Neither needs the writer
//! to be running, or to know the reader exists.
//!
//! **Only complete lines are delivered.** The writer puts each record down in
//! one write, so the only thing a reader can catch half-written is the last
//! line; it is held back until its newline arrives.
//!
//! The handler is any pointer type with:
//!
//! ```
//! fn record(h, r: houselog.Record) void
//!     One record. Its strings live only until the call returns.
//! fn bad(h, line: []const u8, err: houselog.ParseError) void
//!     A line that did not parse. Reading carries on.
//! ```
//!
//! or, to pass the log on without reading it, `pub fn line(h, bytes: []const u8) void`
//! alone, which gets every complete line unparsed.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const houselog = @import("houselog");
const Day = @import("day_file").Day;

pub const ext = "jsonl";

/// Read in chunks this size, so a day of history does not need to fit in one
/// allocation to be replayed.
const chunk = 256 * 1024;

pub const Follower = struct {
    dir: Io.Dir,
    day: Day,
    offset: u64 = 0,
    /// The start of a line whose newline has not arrived yet.
    partial: std.ArrayList(u8) = .empty,

    /// Follow from the first line of `day`.
    pub fn init(dir: Io.Dir, day: Day) Follower {
        return .{ .dir = dir, .day = day };
    }

    pub fn deinit(self: *Follower, gpa: Allocator) void {
        self.partial.deinit(gpa);
    }

    /// Deliver every complete line written since the last call. Once the
    /// current day's file has nothing more and `today` is a later day, move to
    /// `today`'s file — days in between had no logger, and have no file.
    /// Returns how many lines were delivered.
    pub fn poll(self: *Follower, gpa: Allocator, io: Io, today: Day, handler: anytype) !usize {
        const n = try self.drain(gpa, io, handler);
        if (n == 0 and !self.day.eql(today)) {
            self.day = today;
            self.offset = 0;
            self.partial.clearRetainingCapacity();
            return self.drain(gpa, io, handler);
        }
        return n;
    }

    fn drain(self: *Follower, gpa: Allocator, io: Io, handler: anytype) !usize {
        var name_buf: [32]u8 = undefined;
        const name = try self.day.fileName(&name_buf, ext);
        const file = self.dir.openFile(io, name, .{}) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => return err,
        };
        defer file.close(io);

        const buf = try gpa.alloc(u8, chunk);
        defer gpa.free(buf);

        var delivered: usize = 0;
        while (true) {
            const got = try file.readPositionalAll(io, buf, self.offset);
            if (got == 0) break;
            self.offset += got;
            try self.partial.appendSlice(gpa, buf[0..got]);
            delivered += try self.deliverLines(gpa, handler);
            if (got < buf.len) break;
        }
        return delivered;
    }

    fn deliverLines(self: *Follower, gpa: Allocator, handler: anytype) !usize {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();

        var n: usize = 0;
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, self.partial.items, start, '\n')) |end| {
            const line = self.partial.items[start..end];
            start = end + 1;
            if (line.len == 0) continue;
            n += 1;
            if (comptime handlesLines(@TypeOf(handler))) {
                handler.line(line);
            } else {
                _ = arena.reset(.retain_capacity);
                if (houselog.parse(arena.allocator(), line)) |r| {
                    handler.record(r);
                } else |err| {
                    handler.bad(line, err);
                }
            }
        }
        // Keep the unterminated tail for next time.
        const rest = self.partial.items.len - start;
        std.mem.copyForwards(u8, self.partial.items[0..rest], self.partial.items[start..]);
        self.partial.shrinkRetainingCapacity(rest);
        return n;
    }
};

/// A handler is usually a pointer, but can be a struct of pointers passed by value.
fn handlesLines(comptime H: type) bool {
    const T = if (@typeInfo(H) == .pointer) std.meta.Child(H) else H;
    return @hasDecl(T, "line");
}

/// Every record of one day's file, in order: a follower polled once.
pub fn replay(gpa: Allocator, io: Io, dir: Io.Dir, day: Day, handler: anytype) !usize {
    var f = Follower.init(dir, day);
    defer f.deinit(gpa);
    return f.drain(gpa, io, handler);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Collect = struct {
    kinds: std.ArrayList(houselog.Kind) = .empty,
    bad_lines: usize = 0,

    fn record(self: *Collect, r: houselog.Record) void {
        self.kinds.append(testing.allocator, std.meta.activeTag(r.body)) catch unreachable;
    }
    fn bad(self: *Collect, line: []const u8, _: houselog.ParseError) void {
        _ = line;
        self.bad_lines += 1;
    }
};

const up = "{\"v\":3,\"src\":\"s\",\"t\":\"2026-11-04T00:00:00Z\",\"kind\":\"up\"}\n";
const beat = "{\"v\":3,\"src\":\"s\",\"t\":\"2026-11-04T00:05:00Z\",\"kind\":\"heartbeat\"}\n";

fn appendTo(dir: Io.Dir, name: []const u8, bytes: []const u8) !void {
    const f = try dir.createFile(testing.io, name, .{ .truncate = false });
    defer f.close(testing.io);
    try f.writePositionalAll(testing.io, bytes, try f.length(testing.io));
}

test "a half-written line waits for its newline; a bad one is reported and skipped" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const d3: Day = .{ .year = 2026, .month = 11, .day = 3 };

    var c: Collect = .{};
    defer c.kinds.deinit(testing.allocator);
    var f = Follower.init(tmp.dir, d3);
    defer f.deinit(testing.allocator);

    // No file yet: nothing, and no error.
    try testing.expectEqual(@as(usize, 0), try f.poll(testing.allocator, testing.io, d3, &c));

    try appendTo(tmp.dir, "2026-11-03.jsonl", up ++ beat[0..20]);
    try testing.expectEqual(@as(usize, 1), try f.poll(testing.allocator, testing.io, d3, &c));
    try appendTo(tmp.dir, "2026-11-03.jsonl", beat[20..] ++ "garbage\n");
    try testing.expectEqual(@as(usize, 2), try f.poll(testing.allocator, testing.io, d3, &c));
    try testing.expectEqualSlices(houselog.Kind, &.{ .up, .heartbeat }, c.kinds.items);
    try testing.expectEqual(@as(usize, 1), c.bad_lines);
}

test "a handler with `line` gets the lines as written, bad ones too" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const d3: Day = .{ .year = 2026, .month = 11, .day = 3 };
    const Raw = struct {
        text: std.ArrayList(u8) = .empty,
        pub fn line(self: *@This(), bytes: []const u8) void {
            self.text.appendSlice(testing.allocator, bytes) catch unreachable;
            self.text.append(testing.allocator, '\n') catch unreachable;
        }
    };
    var raw: Raw = .{};
    defer raw.text.deinit(testing.allocator);
    try appendTo(tmp.dir, "2026-11-03.jsonl", up ++ "garbage\n\n" ++ beat ++ "{\"v\":3");
    try testing.expectEqual(@as(usize, 3), try replay(testing.allocator, testing.io, tmp.dir, d3, &raw));
    try testing.expectEqualStrings(up ++ "garbage\n" ++ beat, raw.text.items);
}

test "the follower finishes a day before moving to the next" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const d3: Day = .{ .year = 2026, .month = 11, .day = 3 };
    const d4: Day = .{ .year = 2026, .month = 11, .day = 4 };

    var c: Collect = .{};
    defer c.kinds.deinit(testing.allocator);
    var f = Follower.init(tmp.dir, d3);
    defer f.deinit(testing.allocator);

    try appendTo(tmp.dir, "2026-11-03.jsonl", up);
    try appendTo(tmp.dir, "2026-11-04.jsonl", beat);
    // The date has turned, but yesterday still had a line to give.
    try testing.expectEqual(@as(usize, 1), try f.poll(testing.allocator, testing.io, d4, &c));
    try testing.expect(f.day.eql(d3));
    try testing.expectEqual(@as(usize, 1), try f.poll(testing.allocator, testing.io, d4, &c));
    try testing.expect(f.day.eql(d4));
    try testing.expectEqualSlices(houselog.Kind, &.{ .up, .heartbeat }, c.kinds.items);

    try testing.expectEqual(@as(usize, 1), try replay(testing.allocator, testing.io, tmp.dir, d4, &c));
}
