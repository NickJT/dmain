//! What a control that runs actions should do, from `rooms.json`: the Dial, whose four
//! buttons each run a named action and whose ring dims the room it controls.
//!
//! An action is the same on every press, so each becomes one of the Bridge's fixed
//! presses. Devices switched on are a zone of exactly them recalling their room
//! default's values, as a copy dmain makes there, so "on" is never a second set of
//! values; devices switched off are that zone off. Rooms set to their default recall
//! it, through a zone of their lights when they hold a load. Every room off is the
//! whole house off, which reaches the loads too, as the Bridge counts a plug as a
//! light. The ring brings up the room's default on the lights that default lights,
//! and never the others: the Bedroom's ring raises the bedside lamps, not the ceiling.
//!
//! Pure: it compares what it's given, and says nothing about any network.

const std = @import("std");
const Allocator = std.mem.Allocator;
const rf = @import("rooms_file.zig");
const switch_layout = @import("switch_layout.zig");
const sensor_layout = @import("sensor_layout.zig");

pub const Group = switch_layout.Group;
pub const Scene = sensor_layout.Scene;
pub const Refusal = switch_layout.Refusal;
pub const BUTTONS = 4;

/// A scene a press recalls: a room's own, or a copy of it in a zone, made by dmain.
pub const SceneRef = struct {
    name: []const u8,
    /// The room scene's id.
    from: []const u8,
    /// A copy in the entry's zone, found or made by name.
    copied: bool,
};

pub const Entry = struct { group: Group, scene: ?SceneRef };

pub const Press = struct {
    action: []const u8,
    /// One scene each, or none to turn them all off.
    entries: []const Entry,
    off: bool,
};

pub const Ring = struct { group: Group, scene: SceneRef };

pub const Target = struct {
    dev: []const u8,
    name: []const u8,
    presses: [BUTTONS]?Press,
    ring: ?Ring,
};

pub const Targets = struct { targets: []const Target, refusals: []const Refusal };

/// The whole house, which a press turning every room off acts on.
pub const HOME_RTYPE = "bridge_home";

pub fn targets(arena: Allocator, wanted: rf.Wanted, groups: []const Group, scenes: []const Scene, home: ?Group) !Targets {
    var out: std.ArrayList(Target) = .empty;
    var refusals: std.ArrayList(Refusal) = .empty;
    for (wanted.devices) |d| {
        const buttons = d.buttons orelse continue;
        var t: Target = .{ .dev = d.dev, .name = d.name, .presses = @splat(null), .ring = null };
        var refused = false;
        for (buttons, 0..) |b, i| {
            if (i >= BUTTONS) break;
            const name = b orelse continue;
            const action = for (wanted.actions) |a| {
                if (std.mem.eql(u8, a.name, name)) break a;
            } else unreachable; // the reader refuses an unknown action
            t.presses[i] = pressFor(arena, wanted, action, groups, scenes, home) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    try refusals.append(arena, .{ .name = try std.fmt.allocPrint(arena, "{s}'s button {d}, {s}", .{ d.name, i + 1, name }), .why = why(err) });
                    refused = true;
                    continue;
                },
            };
        }
        if (d.controls) |room| {
            t.ring = ringFor(arena, wanted, room, groups, scenes) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => blk: {
                    try refusals.append(arena, .{ .name = try std.fmt.allocPrint(arena, "{s}'s ring", .{d.name}), .why = why(err) });
                    refused = true;
                    break :blk null;
                },
            };
        }
        if (!refused) try out.append(arena, t);
    }
    return .{ .targets = out.items, .refusals = refusals.items };
}

const Error = error{ OutOfMemory, NoRoom, NoZone, NoDefault, NoScene, AmbiguousScene, Mixed, NoHome, OnLeavesOff, SeveralRooms };

fn why(err: Error) []const u8 {
    return switch (err) {
        error.NoRoom => "the network has no such room",
        error.NoZone => "no zone holds exactly those lights: make one in the Hue app",
        error.NoDefault => "the room has no default",
        error.NoScene => "the room's default scene isn't on the network",
        error.AmbiguousScene => "the room has two scenes of its default's name",
        error.Mixed => "it mixes ons and offs, or rooms and devices, which no one press can do",
        error.NoHome => "the network has no whole-house group",
        error.OnLeavesOff => "the room's default leaves one of those devices off",
        error.SeveralRooms => "those devices aren't all in one room",
        error.OutOfMemory => "out of memory",
    };
}

fn roomGroup(groups: []const Group, name: []const u8) Error!Group {
    for (groups) |g| if (std.mem.eql(u8, g.rtype, "room") and std.mem.eql(u8, g.name, name)) return g;
    return error.NoRoom;
}

fn zoneOf(groups: []const Group, devs: []const []const u8) Error!Group {
    for (groups) |g| {
        if (!std.mem.eql(u8, g.rtype, "zone") or g.devs.len != devs.len) continue;
        for (devs) |d| {
            if (!among(g.devs, d)) break;
        } else return g;
    }
    return error.NoZone;
}

/// The room's lights, its loads left out.
fn lightsOf(arena: Allocator, wanted: rf.Wanted, room: Group) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (room.devs) |dev| {
        const w = wanted.device(dev);
        if (w == null or w.?.load == null) try out.append(arena, dev);
    }
    return out.items;
}

fn defaultScene(wanted: rf.Wanted, room_name: []const u8, room: Group, scenes: []const Scene) Error!Scene {
    const r = wanted.room(room_name) orelse return error.NoRoom;
    const name = r.default orelse return error.NoDefault;
    return sensor_layout.sceneIn(scenes, room.id, name) catch |err| switch (err) {
        error.NoScene => error.NoScene,
        error.AmbiguousScene => error.AmbiguousScene,
    };
}

fn pressFor(arena: Allocator, wanted: rf.Wanted, action: rf.Action, groups: []const Group, scenes: []const Scene, home: ?Group) Error!Press {
    var on = false;
    var off = false;
    var rooms = false;
    var devs = false;
    var every = false;
    for (action.do) |st| {
        if (st.room) |r| {
            if (std.mem.eql(u8, r, "*")) every = true else rooms = true;
        } else devs = true;
        if (std.mem.eql(u8, st.to, "off")) off = true else on = true;
    }
    if (on and off) return error.Mixed;

    // Every room off, and any devices off with it: the whole house.
    if (every) {
        if (on or rooms) return error.Mixed;
        const h = home orelse return error.NoHome;
        const entries = try arena.alloc(Entry, 1);
        entries[0] = .{ .group = h, .scene = null };
        return .{ .action = action.name, .entries = entries, .off = true };
    }
    if (rooms and devs) return error.Mixed;

    if (rooms) {
        if (off) return error.Mixed;
        const entries = try arena.alloc(Entry, action.do.len);
        for (action.do, entries) |st, *e| {
            const room = try roomGroup(groups, st.room.?);
            const scene = try defaultScene(wanted, st.room.?, room, scenes);
            const lights = try lightsOf(arena, wanted, room);
            if (lights.len == room.devs.len) {
                e.* = .{ .group = room, .scene = .{ .name = scene.name, .from = scene.id, .copied = false } };
            } else {
                e.* = .{ .group = try zoneOf(groups, lights), .scene = .{ .name = scene.name, .from = scene.id, .copied = true } };
            }
        }
        return .{ .action = action.name, .entries = entries, .off = false };
    }

    // Devices: one zone of exactly them, in one room.
    var list: std.ArrayList([]const u8) = .empty;
    var room_name: ?[]const u8 = null;
    for (action.do) |st| {
        const d = wanted.device(st.dev.?).?;
        const r = d.room orelse return error.NoRoom;
        if (room_name) |n| if (!std.mem.eql(u8, n, r)) return error.SeveralRooms;
        room_name = r;
        try list.append(arena, st.dev.?);
    }
    const zone = try zoneOf(groups, list.items);
    const entries = try arena.alloc(Entry, 1);
    if (off) {
        entries[0] = .{ .group = zone, .scene = null };
        return .{ .action = action.name, .entries = entries, .off = true };
    }
    const room = try roomGroup(groups, room_name.?);
    const scene = try defaultScene(wanted, room_name.?, room, scenes);
    for (list.items) |dev| if (!among(scene.lit, dev)) return error.OnLeavesOff;
    entries[0] = .{ .group = zone, .scene = .{ .name = scene.name, .from = scene.id, .copied = true } };
    return .{ .action = action.name, .entries = entries, .off = false };
}

fn ringFor(arena: Allocator, wanted: rf.Wanted, room_name: []const u8, groups: []const Group, scenes: []const Scene) Error!Ring {
    const room = try roomGroup(groups, room_name);
    const scene = try defaultScene(wanted, room_name, room, scenes);
    const lights = try lightsOf(arena, wanted, room);
    var lit: std.ArrayList([]const u8) = .empty;
    for (lights) |dev| if (among(scene.lit, dev)) try lit.append(arena, dev);
    if (lit.items.len == lights.len and lights.len == room.devs.len)
        return .{ .group = room, .scene = .{ .name = scene.name, .from = scene.id, .copied = false } };
    return .{ .group = try zoneOf(groups, lit.items), .scene = .{ .name = scene.name, .from = scene.id, .copied = true } };
}

fn among(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

const testing = std.testing;

const house =
    \\{"v":2,
    \\  "rooms": [
    \\    {"name":"Bedroom","default":"Lamps only"},
    \\    {"name":"Bedroom 2","default":"Energise"},
    \\    {"name":"Outside","default":"Bright"},
    \\    {"name":"Services"}
    \\  ],
    \\  "devices": [
    \\    {"dev":"ceil","name":"Ceiling","room":"Bedroom"},
    \\    {"dev":"l1","name":"Lamp left","room":"Bedroom"},
    \\    {"dev":"l2","name":"Lamp right","room":"Bedroom"},
    \\    {"dev":"dial","name":"Dial","room":"Bedroom","controls":"Bedroom","buttons":["Lamps on","Lamps off","Awake","Bedtime"]},
    \\    {"dev":"b2","name":"Bedroom 2 light","room":"Bedroom 2"},
    \\    {"dev":"o1","name":"Garden","room":"Outside"},
    \\    {"dev":"pump","name":"Pump","room":"Services","load":"pump"}
    \\  ],
    \\  "actions": [
    \\    {"name":"Lamps on","do":[{"dev":"l1","to":"on"},{"dev":"l2","to":"on"}]},
    \\    {"name":"Lamps off","do":[{"dev":"l1","to":"off"},{"dev":"l2","to":"off"}]},
    \\    {"name":"Awake","do":[{"room":"Bedroom 2","to":"default"},{"room":"Outside","to":"default"}]},
    \\    {"name":"Bedtime","do":[{"room":"*","to":"off"},{"dev":"pump","to":"off"}]}
    \\  ],
    \\  "schedules": []
    \\}
    \\
;

const test_groups = [_]Group{
    .{ .id = "r-bed", .name = "Bedroom", .rtype = "room", .devs = &.{ "ceil", "l1", "l2" } },
    .{ .id = "z-lamps", .name = "Bedside Lamps", .rtype = "zone", .devs = &.{ "l2", "l1" } },
    .{ .id = "r-b2", .name = "Bedroom 2", .rtype = "room", .devs = &.{"b2"} },
    .{ .id = "r-out", .name = "Outside", .rtype = "room", .devs = &.{"o1"} },
};
const test_scenes = [_]Scene{
    .{ .id = "s-lamps", .group_id = "r-bed", .name = "Lamps only", .lit = &.{ "l1", "l2" } },
    .{ .id = "s-b2", .group_id = "r-b2", .name = "Energise", .lit = &.{"b2"} },
    .{ .id = "s-out", .group_id = "r-out", .name = "Bright", .lit = &.{"o1"} },
};
const test_home: Group = .{ .id = "home", .name = "the whole house", .rtype = HOME_RTYPE, .devs = &.{} };

test "each button's action becomes one press, and the ring raises only what the default lights" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = try rf.parse(a, house);
    const t = try targets(a, w, &test_groups, &test_scenes, test_home);
    try testing.expectEqual(@as(usize, 0), t.refusals.len);
    const p = t.targets[0].presses;
    // On: the lamps' zone, with a copy of the Bedroom's default there.
    try testing.expectEqualStrings("z-lamps", p[0].?.entries[0].group.id);
    try testing.expect(p[0].?.entries[0].scene.?.copied);
    try testing.expectEqualStrings("s-lamps", p[0].?.entries[0].scene.?.from);
    // Off: the same zone, off.
    try testing.expect(p[1].?.off);
    try testing.expectEqualStrings("z-lamps", p[1].?.entries[0].group.id);
    // Two rooms to their defaults: each room's own scene, in the file's order.
    try testing.expectEqualStrings("s-b2", p[2].?.entries[0].scene.?.from);
    try testing.expectEqualStrings("r-out", p[2].?.entries[1].group.id);
    try testing.expect(!p[2].?.entries[1].scene.?.copied);
    // Every room off, the pump with it: the whole house.
    try testing.expectEqualStrings("home", p[3].?.entries[0].group.id);
    // The ring: Lamps only lights the lamps, not the ceiling.
    try testing.expectEqualStrings("z-lamps", t.targets[0].ring.?.group.id);
}

test "an action no one press can do is refused, by button" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mixed = try rf.parse(a, try std.mem.replaceOwned(u8, a, house, "{\"dev\":\"l1\",\"to\":\"on\"},{\"dev\":\"l2\",\"to\":\"on\"}", "{\"dev\":\"l1\",\"to\":\"on\"},{\"dev\":\"l2\",\"to\":\"off\"}"));
    const t = try targets(a, mixed, &test_groups, &test_scenes, test_home);
    try testing.expectEqualStrings("Dial's button 1, Lamps on", t.refusals[0].name);
    try testing.expectEqualStrings("it mixes ons and offs, or rooms and devices, which no one press can do", t.refusals[0].why);
    try testing.expectEqual(@as(usize, 0), t.targets.len);
    // No zone of exactly the lamps.
    const u = try targets(a, try rf.parse(a, house), &.{ test_groups[0], test_groups[2], test_groups[3] }, &test_scenes, test_home);
    try testing.expectEqualStrings("no zone holds exactly those lights: make one in the Hue app", u.refusals[0].why);
}
