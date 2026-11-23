//! What the Bridge's timed automations should be, from `rooms.json`'s schedules: each
//! load switched on and off at its times, through the Bridge room it's alone in. On is
//! that room's `Bright`, the only on Hue has for a plug, and off Hue's off recipe; a
//! room holding two loads would switch them together. An on followed by an off on the
//! same days is one automation with an end, as the Hue app makes them.
//!
//! Only a load's on and off reach the Bridge yet: a schedule naming a room, or a device
//! that isn't a load, is refused rather than half written.
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
pub const ON_SCENE = "Bright";

pub const Time = struct { hour: u8, minute: u8 };

/// A set of weekdays, bit 0 Sunday.
pub const Days = u7;
pub const EVERY_DAY: Days = 0x7f;
const DAYS = [_][]const u8{ "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday" };

/// One automation: on at `start` and, with `end`, off again; or off at `start`.
pub const Entry = struct {
    on: bool,
    start: Time,
    end: ?Time = null,
    days: Days,
};

/// A load and every automation it should have.
pub const Target = struct {
    dev: []const u8,
    name: []const u8,
    /// The room it's alone in.
    group: Group,
    /// That room's `Bright`.
    on_scene: []const u8,
    entries: []const Entry,
};

pub const Targets = struct { targets: []const Target, refusals: []const Refusal };

const Moment = struct { at: Time, days: Days, on: bool };

fn minutes(t: Time) u16 {
    return @as(u16, t.hour) * 60 + t.minute;
}

pub fn targets(arena: Allocator, wanted: rf.Wanted, groups: []const Group, scenes: []const Scene) !Targets {
    const fmt = std.fmt.allocPrint;
    var refusals: std.ArrayList(Refusal) = .empty;
    // Each device's moments, in the file's order.
    var devs: std.ArrayList([]const u8) = .empty;
    var moments: std.ArrayList(std.ArrayList(Moment)) = .empty;
    for (wanted.schedules) |s| {
        const days: Days = if (s.days) |names| maskOf(names) else EVERY_DAY;
        const at: Time = .{
            .hour = std.fmt.parseInt(u8, s.at[0..2], 10) catch unreachable,
            .minute = std.fmt.parseInt(u8, s.at[3..5], 10) catch unreachable,
        };
        for (s.do) |st| {
            const label = try fmt(arena, "the {s} schedule", .{s.at});
            const dev = st.dev orelse {
                try refusals.append(arena, .{ .name = label, .why = "only a load's on or off goes to the Bridge yet, not a room" });
                continue;
            };
            const d = wanted.device(dev).?;
            if (d.load == null) {
                try refusals.append(arena, .{ .name = label, .why = try fmt(arena, "{s} isn't a load, and only a load's on or off goes to the Bridge yet", .{d.name}) });
                continue;
            }
            const i = for (devs.items, 0..) |x, i| {
                if (std.mem.eql(u8, x, dev)) break i;
            } else blk: {
                try devs.append(arena, dev);
                try moments.append(arena, .empty);
                break :blk devs.items.len - 1;
            };
            try moments.items[i].append(arena, .{ .at = at, .days = days, .on = std.mem.eql(u8, st.to, "on") });
        }
    }

    var out: std.ArrayList(Target) = .empty;
    for (devs.items, moments.items) |dev, list| {
        const d = wanted.device(dev).?;
        const group = for (groups) |g| {
            if (std.mem.eql(u8, g.rtype, "room") and g.devs.len == 1 and std.mem.eql(u8, g.devs[0], dev)) break g;
        } else {
            try refusals.append(arena, .{ .name = d.name, .why = "it isn't alone in a Bridge room of its own, so its on and off would reach whatever shares one" });
            continue;
        };
        const scene = sensor_layout.sceneIn(scenes, group.id, ON_SCENE) catch |err| {
            try refusals.append(arena, .{ .name = d.name, .why = switch (err) {
                error.NoScene => try fmt(arena, "{s} has no {s} scene to switch it on", .{ group.name, ON_SCENE }),
                error.AmbiguousScene => try fmt(arena, "{s} has two {s} scenes", .{ group.name, ON_SCENE }),
            } });
            continue;
        };
        try out.append(arena, .{ .dev = dev, .name = d.name, .group = group, .on_scene = scene.id, .entries = try pair(arena, list.items) });
    }
    return .{ .targets = out.items, .refusals = refusals.items };
}

fn maskOf(names: []const []const u8) Days {
    var m: Days = 0;
    for (names) |n| for (DAYS, 0..) |d, i| {
        if (std.mem.eql(u8, d, n)) m |= @as(Days, 1) << @intCast(i);
    };
    return m;
}

/// An on followed, on the same days, by an off is one entry with an end.
fn pair(arena: Allocator, list: []const Moment) ![]const Entry {
    const sorted = try arena.dupe(Moment, list);
    std.mem.sort(Moment, sorted, {}, struct {
        fn lt(_: void, a: Moment, b: Moment) bool {
            if (a.days != b.days) return a.days < b.days;
            return minutes(a.at) < minutes(b.at);
        }
    }.lt);
    var out: std.ArrayList(Entry) = .empty;
    var i: usize = 0;
    while (i < sorted.len) : (i += 1) {
        const m = sorted[i];
        if (m.on and i + 1 < sorted.len and !sorted[i + 1].on and sorted[i + 1].days == m.days) {
            try out.append(arena, .{ .on = true, .start = m.at, .end = sorted[i + 1].at, .days = m.days });
            i += 1;
        } else try out.append(arena, .{ .on = m.on, .start = m.at, .days = m.days });
    }
    return out.items;
}

const testing = std.testing;

const house =
    \\{"v":2,
    \\  "rooms": [
    \\    {"name":"Services"},
    \\    {"name":"Bedroom Radiator"},
    \\    {"name":"Kitchen","default":"Bright"}
    \\  ],
    \\  "devices": [
    \\    {"dev":"pump","name":"Pump","room":"Services","load":"pump"},
    \\    {"dev":"rad","name":"Radiator","room":"Bedroom Radiator","load":"heater"},
    \\    {"dev":"k1","name":"Kitchen light","room":"Kitchen"}
    \\  ],
    \\  "actions": [],
    \\  "schedules": [
    \\    {"at":"06:00","do":[{"dev":"pump","to":"on"}]},
    \\    {"at":"08:00","do":[{"dev":"pump","to":"off"}]},
    \\    {"at":"19:00","do":[{"dev":"pump","to":"on"}]},
    \\    {"at":"20:30","do":[{"dev":"rad","to":"on"}]},
    \\    {"at":"21:30","do":[{"dev":"pump","to":"off"}]},
    \\    {"at":"22:00","days":["saturday","sunday"],"do":[{"dev":"rad","to":"off"}]}
    \\  ]
    \\}
    \\
;

const test_groups = [_]Group{
    .{ .id = "r-svc", .name = "Services", .rtype = "room", .devs = &.{"pump"} },
    .{ .id = "r-rad", .name = "Bedroom Radiator", .rtype = "room", .devs = &.{"rad"} },
};
const test_scenes = [_]Scene{
    .{ .id = "on-svc", .group_id = "r-svc", .name = "Bright", .lit = &.{"pump"} },
    .{ .id = "on-rad", .group_id = "r-rad", .name = "Bright", .lit = &.{"rad"} },
};

test "each load's ons and offs, an on and its off on the same days paired" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = try rf.parse(a, house);
    const t = try targets(a, w, &test_groups, &test_scenes);
    try testing.expectEqual(@as(usize, 0), t.refusals.len);
    const pump = t.targets[0];
    try testing.expectEqualStrings("r-svc", pump.group.id);
    try testing.expectEqualStrings("on-svc", pump.on_scene);
    try testing.expectEqual(@as(usize, 2), pump.entries.len);
    try testing.expectEqual(@as(u8, 6), pump.entries[0].start.hour);
    try testing.expectEqual(@as(u8, 8), pump.entries[0].end.?.hour);
    try testing.expectEqual(@as(u8, 21), pump.entries[1].end.?.hour);
    // Its off is weekends only, so the radiator's on stands alone.
    const rad = t.targets[1];
    try testing.expectEqual(@as(usize, 2), rad.entries.len);
    for (rad.entries) |e| try testing.expect(e.end == null);
}

test "a schedule the Bridge can't carry is refused, by name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = try rf.parse(a, house);
    // The radiator sharing a room with a light.
    const shared = [_]Group{ test_groups[0], .{ .id = "r-rad", .name = "Bedroom Radiator", .rtype = "room", .devs = &.{ "rad", "k1" } } };
    const t = try targets(a, w, &shared, &test_scenes);
    try testing.expectEqualStrings("Radiator", t.refusals[0].name);
    try testing.expect(std.mem.indexOf(u8, t.refusals[0].why, "isn't alone") != null);
    // No Bright to switch it on.
    const u = try targets(a, w, &test_groups, test_scenes[0..1]);
    try testing.expectEqualStrings("Bedroom Radiator has no Bright scene to switch it on", u.refusals[0].why);
    // A light's on.
    const lit = try rf.parse(a, try std.mem.replaceOwned(u8, a, house, "{\"at\":\"06:00\",\"do\":[{\"dev\":\"pump\",\"to\":\"on\"}]}", "{\"at\":\"06:00\",\"do\":[{\"dev\":\"k1\",\"to\":\"on\"}]}"));
    const v = try targets(a, lit, &test_groups, &test_scenes);
    try testing.expectEqualStrings("Kitchen light isn't a load, and only a load's on or off goes to the Bridge yet", v.refusals[0].why);
}
