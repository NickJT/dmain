//! Which Bridge light each of the house's devices is.
//!
//! The house names a light by `dev` and `ch`, and the Bridge by a UUID. `huelog`
//! holds the Bridge's resource list, so it writes this file, and a program that
//! writes to the Bridge reads it rather than keeping its own copy of that list.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const version = 1;
pub const FILE = "bridge-ids.json";

pub const Light = struct {
    dev: []const u8,
    ch: u8 = 0,
    id: []const u8,
};

pub const File = struct {
    v: u32 = version,
    lights: []const Light,
};

pub fn render(gpa: Allocator, lights: []const Light) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, File{ .lights = lights }, .{ .whitespace = .indent_1 });
}

/// Strings in the result live in `arena`. A field this version doesn't know means
/// a newer writer, so the file is refused rather than guessed at.
pub fn parse(arena: Allocator, text: []const u8) !File {
    const file = try std.json.parseFromSliceLeaky(File, arena, text, .{ .allocate = .alloc_always });
    if (file.v != version) return error.UnknownVersion;
    return file;
}

pub fn find(lights: []const Light, dev: []const u8, ch: u8) ?[]const u8 {
    for (lights) |light| {
        if (light.ch == ch and std.mem.eql(u8, light.dev, dev)) return light.id;
    }
    return null;
}

const testing = std.testing;

test "a file survives its own reader and finds a light by device and channel" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lights = [_]Light{
        .{ .dev = "00:17:88:01:0e:7d:d5:ad", .id = "uuid-a" },
        .{ .dev = "00:17:88:01:0e:7d:d5:ad", .ch = 1, .id = "uuid-b" },
    };
    const back = try parse(a, try render(a, &lights));
    try testing.expectEqualStrings("uuid-b", find(back.lights, "00:17:88:01:0e:7d:d5:ad", 1).?);
    try testing.expect(find(back.lights, "00:17:88:01:0e:7d:d5:ad", 2) == null);
    try testing.expect(find(back.lights, "other", 0) == null);
}

test "an unknown version or field is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.UnknownVersion, parse(a, "{\"v\":2,\"lights\":[]}"));
    try testing.expectError(error.UnknownField, parse(a, "{\"v\":1,\"lights\":[],\"x\":1}"));
}
