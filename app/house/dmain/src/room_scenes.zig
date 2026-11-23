//! Each Bridge room's scenes by name, which are what a room's default can be chosen
//! from. Zones are left out: their scenes are dmain's own copies, made from a room's.
//! So is `Max`, which dmain makes for the dimmers and a default never names.
//!
//! Pure: it sorts what it's given.

const std = @import("std");
const Allocator = std.mem.Allocator;
const switch_layout = @import("switch_layout.zig");
const sensor_layout = @import("sensor_layout.zig");

pub const Group = switch_layout.Group;
pub const Scene = sensor_layout.Scene;

/// The scene the dimmers' Max is, made by dmain.
pub const GENERATED = "Max";

pub const RoomScenes = struct {
    room: []const u8,
    /// Sorted, each once.
    scenes: []const []const u8,
};

/// Every room, by name, with its scenes: a room with none is listed with none.
pub fn list(arena: Allocator, groups: []const Group, scenes: []const Scene) ![]const RoomScenes {
    var out: std.ArrayList(RoomScenes) = .empty;
    for (groups) |g| {
        if (!std.mem.eql(u8, g.rtype, "room")) continue;
        var names: std.ArrayList([]const u8) = .empty;
        for (scenes) |s| {
            if (!std.mem.eql(u8, s.group_id, g.id) or std.mem.eql(u8, s.name, GENERATED)) continue;
            for (names.items) |n| {
                if (std.mem.eql(u8, n, s.name)) break;
            } else try names.append(arena, s.name);
        }
        std.mem.sort([]const u8, names.items, {}, lessName);
        try out.append(arena, .{ .room = g.name, .scenes = names.items });
    }
    std.mem.sort(RoomScenes, out.items, {}, struct {
        fn lt(_: void, a: RoomScenes, b: RoomScenes) bool {
            return lessName({}, a.room, b.room);
        }
    }.lt);
    return out.items;
}

fn lessName(_: void, a: []const u8, b: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(a, b);
}

const testing = std.testing;

test "rooms only, by name, each scene once and never Max" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const groups = [_]Group{
        .{ .id = "r-l", .name = "Lounge", .rtype = "room", .devs = &.{} },
        .{ .id = "z-l", .name = "Lounge Lamps", .rtype = "zone", .devs = &.{} },
        .{ .id = "r-h", .name = "Hall", .rtype = "room", .devs = &.{} },
    };
    const scenes = [_]Scene{
        .{ .id = "1", .group_id = "r-l", .name = "Relax", .lit = &.{} },
        .{ .id = "2", .group_id = "r-l", .name = "Max", .lit = &.{} },
        .{ .id = "3", .group_id = "r-l", .name = "bright", .lit = &.{} },
        .{ .id = "4", .group_id = "r-l", .name = "Relax", .lit = &.{} },
        .{ .id = "5", .group_id = "z-l", .name = "Relax", .lit = &.{} },
    };
    const l = try list(arena.allocator(), &groups, &scenes);
    try testing.expectEqual(@as(usize, 2), l.len);
    try testing.expectEqualStrings("Hall", l[0].room);
    try testing.expectEqual(@as(usize, 0), l[0].scenes.len);
    try testing.expectEqualStrings("Lounge", l[1].room);
    try testing.expectEqual(@as(usize, 2), l[1].scenes.len);
    try testing.expectEqualStrings("bright", l[1].scenes[0]);
    try testing.expectEqualStrings("Relax", l[1].scenes[1]);
}
