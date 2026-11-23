//! What runs by the clock: a snapshot in the house's words, like `settings`.
//!
//! A source's own automations, named and timed. Replaced whole when something
//! changes, and with no source's protocol in it, so a reader can show every source
//! the same way.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const version = 1;
pub const FILE = "schedules.json";

pub const Entry = struct {
    name: []const u8,
    /// What sort of thing it is, in the source's words: "Schedule", "Timers".
    kind: []const u8,
    enabled: bool,
    /// Lower case weekday names. Empty when it isn't tied to days.
    days: []const []const u8 = &.{},
    /// Local "HH:MM". Null when it has no fixed time, such as one that runs from a
    /// button or at sunset.
    at: ?[]const u8 = null,
    until: ?[]const u8 = null,
};

pub const File = struct {
    v: u32 = version,
    src: []const u8,
    schedules: []const Entry,
};

pub fn render(gpa: Allocator, src: []const u8, entries: []const Entry) ![]u8 {
    return std.json.Stringify.valueAlloc(
        gpa,
        File{ .src = src, .schedules = entries },
        .{ .emit_null_optional_fields = false, .whitespace = .indent_1 },
    );
}

/// Strings in the result live in `arena`. A field this version doesn't know means
/// a newer writer, so the file is refused rather than guessed at.
pub fn parse(arena: Allocator, text: []const u8) !File {
    const file = try std.json.parseFromSliceLeaky(File, arena, text, .{ .allocate = .alloc_always });
    if (file.v != version) return error.UnknownVersion;
    return file;
}

const testing = std.testing;

test "a file survives its own strict reader" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = [_]Entry{
        .{ .name = "Pump", .kind = "Schedule", .enabled = true, .days = &.{ "monday", "friday" }, .at = "06:30", .until = "08:00" },
        .{ .name = "Fan", .kind = "Timers", .enabled = false },
    };
    const back = try parse(a, try render(a, "hue-bridge", &entries));
    try testing.expectEqualStrings("hue-bridge", back.src);
    try testing.expectEqual(@as(usize, 2), back.schedules.len);
    try testing.expectEqualStrings("friday", back.schedules[0].days[1]);
    try testing.expectEqualStrings("08:00", back.schedules[0].until.?);
    try testing.expect(back.schedules[1].at == null);
}

test "an unknown version or field is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.UnknownVersion, parse(a, "{\"v\":2,\"src\":\"x\",\"schedules\":[]}"));
    try testing.expectError(error.UnknownField, parse(a, "{\"v\":1,\"src\":\"x\",\"schedules\":[],\"y\":1}"));
}
