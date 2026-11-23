//! What each wall dimmer should do, from `rooms.json`: every button on the room it
//! controls, the top its default or off, the middle two dimming on a tap or a hold,
//! the bottom Max. A room holding a load is reached through a zone of its lights
//! alone, as the Bridge counts a plug as a light. A bathroom dimmer's bottom runs its
//! fan and is left as it is.
//!
//! Pure: it compares what it's given, and says nothing about any network.

const std = @import("std");
const Allocator = std.mem.Allocator;
const rf = @import("rooms_file.zig");

pub const MAX = "Max";

/// A room or zone on the network, and the devices whose lights it holds.
pub const Group = struct {
    id: []const u8,
    name: []const u8,
    /// `room` or `zone`.
    rtype: []const u8,
    devs: []const []const u8,
};

/// What one dimmer should be.
pub const Target = struct {
    dev: []const u8,
    name: []const u8,
    group: Group,
    top: []const u8,
    /// Null leaves the bottom as it is: a fan button.
    bottom: ?[]const u8,
};

pub const Refusal = struct { name: []const u8, why: []const u8 };

pub const Targets = struct { targets: []const Target, refusals: []const Refusal };

/// Every dimmer `wanted` names a room for. A sensor and the Dial control rooms too,
/// but aren't wall dimmers. `light_devs` are the devices the network gives a light,
/// a load's plug among them.
pub fn targets(arena: Allocator, wanted: rf.Wanted, groups: []const Group, light_devs: []const []const u8) !Targets {
    var out: std.ArrayList(Target) = .empty;
    var refusals: std.ArrayList(Refusal) = .empty;
    for (wanted.devices) |d| {
        const room_name = d.controls orelse continue;
        if (d.sensor != null or d.buttons != null) continue;
        const room = wanted.room(room_name).?;
        const top = room.default orelse {
            try refusals.append(arena, .{ .name = d.name, .why = try std.fmt.allocPrint(arena, "{s} has no default scene", .{room_name}) });
            continue;
        };
        const group = groupFor(arena, wanted, room_name, groups, light_devs) catch |err| {
            try refusals.append(arena, .{ .name = d.name, .why = switch (err) {
                error.OutOfMemory => return err,
                error.NoRoom => try std.fmt.allocPrint(arena, "the network has no room {s}", .{room_name}),
                error.NoZone => try std.fmt.allocPrint(arena, "{s} holds a load, and no zone has exactly its lights: make one in the Hue app", .{room_name}),
            } });
            continue;
        };
        try out.append(arena, .{ .dev = d.dev, .name = d.name, .group = group, .top = top, .bottom = if (d.fan != null) null else MAX });
    }
    return .{ .targets = out.items, .refusals = refusals.items };
}

fn groupFor(arena: Allocator, wanted: rf.Wanted, room: []const u8, groups: []const Group, light_devs: []const []const u8) (Allocator.Error || error{ NoRoom, NoZone })!Group {
    var lights: std.ArrayList([]const u8) = .empty;
    var has_load = false;
    for (wanted.devices) |d| {
        const r = d.room orelse continue;
        if (!std.mem.eql(u8, r, room)) continue;
        if (d.load != null) {
            has_load = true;
            continue;
        }
        if (among(light_devs, d.dev)) try lights.append(arena, d.dev);
    }
    if (!has_load) {
        for (groups) |g| if (std.mem.eql(u8, g.rtype, "room") and std.mem.eql(u8, g.name, room)) return g;
        return error.NoRoom;
    }
    // Any zone holding exactly the room's lights, whatever it's called.
    for (groups) |g| {
        if (!std.mem.eql(u8, g.rtype, "zone") or g.devs.len != lights.items.len) continue;
        for (lights.items) |l| {
            if (!among(g.devs, l)) break;
        } else return g;
    }
    return error.NoZone;
}

fn among(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

/// A switch as it is now. `top` and `bottom` are null when they aren't the shape the
/// layout gives them, whatever else they may do; each `where` is its group ids.
pub const Current = struct {
    dev: []const u8,
    name: []const u8,
    group: []const u8,
    top: ?[]const u8,
    bottom: ?[]const u8,
    dim_tap_or_hold: bool,
    top_text: []const u8,
    bottom_text: []const u8,
    dim_text: []const u8,
    top_where: []const []const u8,
    dim_where: []const []const u8,
    bottom_where: []const []const u8,
};

pub const Change = struct {
    current: Current,
    target: Target,
    /// Null where this button stays as it is.
    top: ?[]const u8 = null,
    bottom: ?[]const u8 = null,
    dim_tap_or_hold: bool = false,
    /// The buttons move to the target's group, and so take its scenes.
    where: bool = false,
};

pub const Report = struct {
    changes: []const Change,
    /// Wanted but not among the network's dimmers: another network's, or gone.
    unknown: []const Target,
    /// Among the dimmers but controlling nothing in the file, which stay as they are.
    unlisted: []const Current,
};

fn onlyOn(where: []const []const u8, id: []const u8) bool {
    return where.len == 1 and std.mem.eql(u8, where[0], id);
}

fn sameScene(now: ?[]const u8, wanted: []const u8) bool {
    return if (now) |n| std.mem.eql(u8, n, wanted) else false;
}

pub fn compare(arena: Allocator, current: []const Current, wanted: []const Target) !Report {
    var changes: std.ArrayList(Change) = .empty;
    var unlisted: std.ArrayList(Current) = .empty;
    for (current) |c| {
        const t = for (wanted) |t| {
            if (std.mem.eql(u8, t.dev, c.dev)) break t;
        } else {
            try unlisted.append(arena, c);
            continue;
        };
        const id = t.group.id;
        var change: Change = .{ .current = c, .target = t };
        change.where = !onlyOn(c.top_where, id) or !onlyOn(c.dim_where, id) or
            (t.bottom != null and !onlyOn(c.bottom_where, id));
        // Moving a button changes which scenes it can recall, so each is rewritten.
        if (change.where or !sameScene(c.top, t.top)) change.top = t.top;
        if (t.bottom) |b| if (change.where or !sameScene(c.bottom, b)) {
            change.bottom = b;
        };
        change.dim_tap_or_hold = !c.dim_tap_or_hold;
        if (change.where or change.top != null or change.bottom != null or change.dim_tap_or_hold) try changes.append(arena, change);
    }
    var unknown: std.ArrayList(Target) = .empty;
    for (wanted) |t| {
        for (current) |c| {
            if (std.mem.eql(u8, c.dev, t.dev)) break;
        } else try unknown.append(arena, t);
    }
    return .{ .changes = changes.items, .unknown = unknown.items, .unlisted = unlisted.items };
}

const testing = std.testing;

const file =
    \\{"v":2,"rooms":[{"name":"Study","default":"Relax"},{"name":"Bathroom","default":"Bright"},{"name":"Hall"},{"name":"Outside","default":"Bright"}],
    \\ "devices":[
    \\  {"dev":"d1","name":"Study","room":"Study","controls":"Study"},
    \\  {"dev":"l1","name":"Study 1","room":"Study"},
    \\  {"dev":"d2","name":"Bathroom","room":"Bathroom","controls":"Bathroom","fan":"x1"},
    \\  {"dev":"l2","name":"Bathroom ceiling","room":"Bathroom"},
    \\  {"dev":"x1","name":"Extractor","room":"Bathroom","load":"fan"},
    \\  {"dev":"d3","name":"Hall","room":"Hall","controls":"Hall"},
    \\  {"dev":"d4","name":"Outside - Patio","room":"Study","controls":"Outside"},
    \\  {"dev":"s1","name":"Sensor","room":"Study","controls":"Study","sensor":{"dark":"sunset","periods":[{"from":"08:00","off_after":5}]}}]}
;

const study_room: Group = .{ .id = "r-study", .name = "Study", .rtype = "room", .devs = &.{"l1"} };
const bath_room: Group = .{ .id = "r-bath", .name = "Bathroom", .rtype = "room", .devs = &.{ "l2", "x1" } };
const bath_zone: Group = .{ .id = "z-bath", .name = "Bathroom Light", .rtype = "zone", .devs = &.{"l2"} };
const groups_now = [_]Group{ study_room, bath_room, bath_zone, .{ .id = "r-hall", .name = "Hall", .rtype = "room", .devs = &.{} } };
const light_devs_now = [_][]const u8{ "l1", "l2", "x1" };

test "each dimmer controls its room, a room with a load through a zone of its lights" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = try targets(a, try rf.parse(a, file), &groups_now, &light_devs_now);
    try testing.expectEqual(@as(usize, 2), t.targets.len);
    try testing.expectEqualStrings("r-study", t.targets[0].group.id);
    try testing.expectEqualStrings("Relax", t.targets[0].top);
    try testing.expectEqualStrings(MAX, t.targets[0].bottom.?);
    try testing.expectEqualStrings("z-bath", t.targets[1].group.id);
    try testing.expect(t.targets[1].bottom == null); // its fan
    try testing.expectEqual(@as(usize, 2), t.refusals.len);
    try testing.expectEqualStrings("Hall has no default scene", t.refusals[0].why);
    try testing.expectEqualStrings("the network has no room Outside", t.refusals[1].why);

    // Without the zone, the bathroom can't be reached without its fan.
    const no_zone = [_]Group{ study_room, bath_room };
    const u = try targets(a, try rf.parse(a, file), &no_zone, &light_devs_now);
    try testing.expect(std.mem.indexOf(u8, u.refusals[0].why, "Bathroom holds a load") != null);
}

fn dimmerNow(dev: []const u8, where: []const []const u8, top: ?[]const u8, bottom: ?[]const u8) Current {
    return .{ .dev = dev, .name = dev, .group = "", .top = top, .bottom = bottom, .dim_tap_or_hold = true, .top_text = "", .bottom_text = "", .dim_text = "", .top_where = where, .dim_where = where, .bottom_where = where };
}

test "a dimmer on the right group with the right scenes is left alone; one elsewhere moves, scenes and all" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = try targets(a, try rf.parse(a, file), &groups_now, &light_devs_now);
    const fine = dimmerNow("d1", &.{"r-study"}, "Relax", MAX);
    const moved = dimmerNow("d2", &.{"r-bath"}, "Bright", "Bright");
    var no_max = dimmerNow("d1", &.{"r-study"}, "Relax", "Bright");
    no_max.dim_tap_or_hold = false;
    const r = try compare(a, &.{ fine, moved, dimmerNow("other", &.{"x"}, null, null) }, t.targets);
    try testing.expectEqual(@as(usize, 1), r.changes.len);
    const c = r.changes[0];
    try testing.expect(c.where);
    try testing.expectEqualStrings("Bright", c.top.?); // the same name, but the zone's scene
    try testing.expect(c.bottom == null); // the fan stays
    try testing.expectEqualStrings("other", r.unlisted[0].dev);

    const s = try compare(a, &.{no_max}, t.targets);
    try testing.expect(!s.changes[0].where);
    try testing.expect(s.changes[0].top == null);
    try testing.expectEqualStrings(MAX, s.changes[0].bottom.?);
    try testing.expect(s.changes[0].dim_tap_or_hold);
    try testing.expectEqualStrings("d2", s.unknown[0].dev);
}
