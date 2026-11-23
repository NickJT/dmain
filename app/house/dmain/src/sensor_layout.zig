//! What each motion sensor should do, from `rooms.json`: its timetable of its room's
//! scenes, on the lights those scenes light.
//!
//! A scene sets every light of its group, off included, so a sensor recalling a room
//! scene on the room would reach lights it never lit: the Nightlights sensor's
//! `Footlight` would put out the bedside lamps. `do_not_disturb` makes that safe: with
//! any light on nothing changes, and with all off its scene's off lights are off
//! already. So a sensor acts on the whole room when every period with a scene has it,
//! when its scenes light every light there, or when it has no scene; otherwise on a
//! zone of exactly the lights they light, whatever the zone is called, holding copies
//! of the room's scenes made from the room's own values. A room holding a load is
//! always reached through such a zone, as the Bridge counts a plug as a light.
//!
//! Pure: it compares what it's given, and says nothing about any network.

const std = @import("std");
const Allocator = std.mem.Allocator;
const rf = @import("rooms_file.zig");
const switch_layout = @import("switch_layout.zig");

pub const Group = switch_layout.Group;
pub const Refusal = switch_layout.Refusal;

/// A scene on the network, and the devices whose lights it turns on.
pub const Scene = struct {
    id: []const u8,
    group_id: []const u8,
    name: []const u8,
    lit: []const []const u8,
};

pub const Period = struct {
    hour: u8,
    minute: u8,
    /// The scene's name, found in `Target.group`.
    scene: ?[]const u8,
    off_after: ?u32,
    do_not_disturb: bool,
};

/// A room scene a zone needs a copy of, by the room scene's id.
pub const Copy = struct { name: []const u8, from: []const u8 };

pub const Target = struct {
    dev: []const u8,
    name: []const u8,
    room: []const u8,
    /// Where its motion acts, and where its scenes are found.
    group: Group,
    dark: rf.Dark,
    periods: []const Period,
    /// Empty when `group` is the room itself.
    copies: []const Copy,
};

pub const Targets = struct { targets: []const Target, refusals: []const Refusal };

/// Every sensor `wanted` gives a timetable.
pub fn targets(arena: Allocator, wanted: rf.Wanted, groups: []const Group, scenes: []const Scene) !Targets {
    var out: std.ArrayList(Target) = .empty;
    var refusals: std.ArrayList(Refusal) = .empty;
    for (wanted.devices) |d| {
        const s = d.sensor orelse continue;
        const room_name = d.controls orelse continue;
        if (try targetFor(arena, wanted, d, s, room_name, groups, scenes)) |t| switch (t) {
            .target => |x| try out.append(arena, x),
            .refused => |why| try refusals.append(arena, .{ .name = d.name, .why = why }),
        };
    }
    return .{ .targets = out.items, .refusals = refusals.items };
}

const Outcome = union(enum) { target: Target, refused: []const u8 };

fn targetFor(arena: Allocator, wanted: rf.Wanted, d: rf.Device, s: rf.Sensor, room_name: []const u8, groups: []const Group, scenes: []const Scene) !?Outcome {
    const fmt = std.fmt.allocPrint;
    const room = for (groups) |g| {
        if (std.mem.eql(u8, g.rtype, "room") and std.mem.eql(u8, g.name, room_name)) break g;
    } else return .{ .refused = try fmt(arena, "the network has no room {s}", .{room_name}) };

    // The room's lights, its loads left out.
    var lights: std.ArrayList([]const u8) = .empty;
    var has_load = false;
    for (room.devs) |dev| {
        const w = wanted.device(dev);
        if (w != null and w.?.load != null) {
            has_load = true;
        } else try lights.append(arena, dev);
    }

    // What its scenes light, and each scene's room id.
    var lit: std.ArrayList([]const u8) = .empty;
    var from: std.ArrayList(Copy) = .empty;
    var all_leave_lit = true;
    for (s.periods) |p| {
        const name = p.on orelse continue;
        if (!(p.do_not_disturb orelse false)) all_leave_lit = false;
        const scene = sceneIn(scenes, room.id, name) catch |err| return .{ .refused = switch (err) {
            error.NoScene => try fmt(arena, "no scene {s} in {s}", .{ name, room_name }),
            error.AmbiguousScene => try fmt(arena, "two scenes called {s} in {s}", .{ name, room_name }),
        } };
        for (scene.lit) |dev| if (among(lights.items, dev) and !among(lit.items, dev)) try lit.append(arena, dev);
        if (!for (from.items) |c| {
            if (std.mem.eql(u8, c.name, name)) break true;
        } else false) try from.append(arena, .{ .name = name, .from = scene.id });
    }
    if (from.items.len > 0 and lit.items.len == 0) return .{ .refused = try fmt(arena, "its scenes light nothing in {s}", .{room_name}) };
    const whole = from.items.len == 0 or lit.items.len == lights.items.len or all_leave_lit;

    const periods = try arena.alloc(Period, s.periods.len);
    for (s.periods, periods) |p, *q| q.* = .{
        .hour = std.fmt.parseInt(u8, p.from[0..2], 10) catch unreachable,
        .minute = std.fmt.parseInt(u8, p.from[3..5], 10) catch unreachable,
        .scene = p.on,
        .off_after = p.off_after,
        .do_not_disturb = p.do_not_disturb orelse false,
    };
    const base: Target = .{ .dev = d.dev, .name = d.name, .room = room_name, .group = room, .dark = s.dark, .periods = periods, .copies = &.{} };
    if (whole and !has_load) return .{ .target = base };

    const need = if (whole) lights.items else lit.items;
    const zone = for (groups) |g| {
        if (!std.mem.eql(u8, g.rtype, "zone") or g.devs.len != need.len) continue;
        for (need) |l| {
            if (!among(g.devs, l)) break;
        } else break g;
    } else {
        var names: std.Io.Writer.Allocating = .init(arena);
        for (need, 0..) |dev, i| {
            if (i > 0) try names.writer.writeAll(", ");
            try names.writer.writeAll(if (wanted.device(dev)) |w| w.name else dev);
        }
        return .{ .refused = try fmt(arena, "no zone holds exactly {s}: make one in the Hue app", .{names.written()}) };
    };
    var t = base;
    t.group = zone;
    t.copies = from.items;
    return .{ .target = t };
}

pub fn sceneIn(scenes: []const Scene, group_id: []const u8, name: []const u8) error{ NoScene, AmbiguousScene }!Scene {
    var found: ?Scene = null;
    for (scenes) |sc| {
        if (!std.mem.eql(u8, sc.group_id, group_id) or !std.mem.eql(u8, sc.name, name)) continue;
        if (found != null) return error.AmbiguousScene;
        found = sc;
    }
    return found orelse error.NoScene;
}

fn among(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

const testing = std.testing;

const house =
    \\{"v":2,
    \\  "rooms": [
    \\    {"name":"Bedroom","default":"Lamps"},
    \\    {"name":"Ensuite","default":"Bright"},
    \\    {"name":"Kitchen","default":"Bright"},
    \\    {"name":"Lounge","default":"Relax"}
    \\  ],
    \\  "devices": [
    \\    {"dev":"foot","name":"Footlight","room":"Bedroom"},
    \\    {"dev":"lamp","name":"Bedside lamp","room":"Bedroom"},
    \\    {"dev":"d1","name":"Bedroom","room":"Bedroom","controls":"Bedroom"},
    \\    {"dev":"s1","name":"Nightlights","room":"Bedroom","controls":"Bedroom","sensor":{"dark":"sunset","periods":[{"from":"08:00","off_after":10},{"from":"21:00","on":"Footlight","off_after":1}]}},
    \\    {"dev":"ens","name":"Ensuite light","room":"Ensuite"},
    \\    {"dev":"fan","name":"Ensuite Extractor","room":"Ensuite","load":"fan"},
    \\    {"dev":"s2","name":"Ensuite","room":"Ensuite","controls":"Ensuite","sensor":{"dark":{"below":22218},"periods":[{"from":"05:45","on":"Bright","off_after":10,"do_not_disturb":true}]}},
    \\    {"dev":"k1","name":"Kitchen 1","room":"Kitchen"},
    \\    {"dev":"k2","name":"Kitchen 2","room":"Kitchen"},
    \\    {"dev":"s3","name":"Kitchen","room":"Kitchen","controls":"Kitchen","sensor":{"dark":{"below":18314},"periods":[{"from":"23:00","on":"Dimmed","off_after":5}]}},
    \\    {"dev":"lo1","name":"Lamp","room":"Lounge"},
    \\    {"dev":"lo2","name":"Ceiling","room":"Lounge"},
    \\    {"dev":"s4","name":"Lounge","room":"Lounge","controls":"Lounge","sensor":{"dark":"sunset","periods":[{"from":"08:00","on":"Relax","off_after":10,"do_not_disturb":true}]}}
    \\  ],
    \\  "actions": [],
    \\  "schedules": []
    \\}
    \\
;

const test_groups = [_]Group{
    .{ .id = "r-bed", .name = "Bedroom", .rtype = "room", .devs = &.{ "foot", "lamp" } },
    .{ .id = "z-foot", .name = "Nightlight", .rtype = "zone", .devs = &.{"foot"} },
    .{ .id = "r-ens", .name = "Ensuite", .rtype = "room", .devs = &.{ "ens", "fan" } },
    .{ .id = "z-ens", .name = "Ensuite", .rtype = "zone", .devs = &.{"ens"} },
    .{ .id = "r-kit", .name = "Kitchen", .rtype = "room", .devs = &.{ "k1", "k2" } },
    .{ .id = "r-lou", .name = "Lounge", .rtype = "room", .devs = &.{ "lo1", "lo2" } },
};

const test_scenes = [_]Scene{
    .{ .id = "sc-foot", .group_id = "r-bed", .name = "Footlight", .lit = &.{"foot"} },
    .{ .id = "sc-ens", .group_id = "r-ens", .name = "Bright", .lit = &.{ "ens", "fan" } },
    .{ .id = "sc-dim", .group_id = "r-kit", .name = "Dimmed", .lit = &.{ "k1", "k2" } },
    .{ .id = "sc-rel", .group_id = "r-lou", .name = "Relax", .lit = &.{"lo1"} },
};

fn target(t: Targets, name: []const u8) Target {
    for (t.targets) |x| if (std.mem.eql(u8, x.name, name)) return x;
    unreachable;
}

test "a sensor acts on the lights its scenes light: the room, or a zone of exactly those" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = try rf.parse(a, house);
    const t = try targets(a, w, &test_groups, &test_scenes);
    try testing.expectEqual(@as(usize, 0), t.refusals.len);

    // Its scene lights only the Footlight, so the bedside lamp is never touched.
    const night = target(t, "Nightlights");
    try testing.expectEqualStrings("z-foot", night.group.id);
    try testing.expectEqualStrings("sc-foot", night.copies[0].from);
    try testing.expectEqual(@as(u8, 21), night.periods[1].hour);
    try testing.expect(night.periods[0].scene == null);

    // A room holding a load is reached through a zone without it.
    const ens = target(t, "Ensuite");
    try testing.expectEqualStrings("z-ens", ens.group.id);
    try testing.expect(ens.periods[0].do_not_disturb);

    // Every light lit: the room itself, and nothing to copy.
    const kit = target(t, "Kitchen");
    try testing.expectEqualStrings("r-kit", kit.group.id);
    try testing.expectEqual(@as(usize, 0), kit.copies.len);

    // Its scene lights the lamp alone, but leaves lit lights alone: the whole room, so
    // its off reaches the ceiling too.
    const lounge = target(t, "Lounge");
    try testing.expectEqualStrings("r-lou", lounge.group.id);
    try testing.expectEqual(@as(usize, 0), lounge.copies.len);

    // Without do_not_disturb the same scene would put the ceiling out: it needs a zone.
    const strict = try rf.parse(a, try std.mem.replaceOwned(u8, a, house, "\"off_after\":10,\"do_not_disturb\":true}]}}\n  ],", "\"off_after\":10}]}}\n  ],"));
    const u = try targets(a, strict, &test_groups, &test_scenes);
    try testing.expectEqualStrings("Lounge", u.refusals[0].name);
    try testing.expectEqualStrings("no zone holds exactly Lamp: make one in the Hue app", u.refusals[0].why);
}

test "a sensor is refused, by name, where the network can't carry it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = try rf.parse(a, house);
    // No zone of exactly the Footlight.
    const t = try targets(a, w, &.{ test_groups[0], test_groups[2], test_groups[3], test_groups[4], test_groups[5] }, &test_scenes);
    try testing.expectEqual(@as(usize, 1), t.refusals.len);
    try testing.expectEqualStrings("Nightlights", t.refusals[0].name);
    try testing.expectEqualStrings("no zone holds exactly Footlight: make one in the Hue app", t.refusals[0].why);
    // No such scene in the room.
    const u = try targets(a, w, &test_groups, test_scenes[1..]);
    try testing.expectEqualStrings("no scene Footlight in Bedroom", u.refusals[0].why);
    // Two of that name.
    const twice = [_]Scene{ test_scenes[0], test_scenes[0], test_scenes[1], test_scenes[2] };
    const v = try targets(a, w, &test_groups, &twice);
    try testing.expectEqualStrings("two scenes called Footlight in Bedroom", v.refusals[0].why);
}
