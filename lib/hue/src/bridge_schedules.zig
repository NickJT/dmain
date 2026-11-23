//! Timed automations on the Bridge, in and out of CLIP v2's behaviour format: the
//! `Schedule` script's instances, read as the moments they switch something on or off.
//!
//! The Bridge publishes no schema for them, so the shapes here are the ones the Hue app
//! writes. One recalls a scene or Hue's off recipe on a group at `start_at`, on the
//! `recurrence_days`; an `end_at` switches the group off again, which the house log
//! shows to the second. Reading them as moments means two forms of the same timetable,
//! an on with an end or an on and an off apart, compare as the same. Pure: JSON in,
//! JSON out.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_get = @import("json_get").json_get;

/// The recipe every off the Hue app writes recalls. No resource list names it, and no
/// reference page; it's the same in every app-made off on this Bridge.
pub const OFF_RECIPE = "caabcf9c-984b-4a2c-a97a-0ed61a299258";
pub const SCRIPT = "Schedule";

pub const DAYS = [_][]const u8{ "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday" };
pub const EVERY_DAY: u7 = 0x7f;

/// A set of weekdays, bit 0 Sunday.
pub fn dayMask(names: []const []const u8) ?u7 {
    var m: u7 = 0;
    for (names) |n| {
        const i = for (DAYS, 0..) |d, i| {
            if (std.mem.eql(u8, d, n)) break i;
        } else return null;
        m |= @as(u7, 1) << @intCast(i);
    }
    return if (m == 0) null else m;
}

pub const Time = struct {
    hour: u8,
    minute: u8,

    pub fn order(a: Time, b: Time) std.math.Order {
        return std.math.order(@as(u16, a.hour) * 60 + a.minute, @as(u16, b.hour) * 60 + b.minute);
    }
};

/// One moment a group is switched: on by a scene, or off.
pub const Point = struct {
    group_id: []const u8,
    at: Time,
    days: u7,
    /// The scene recalled; null is off.
    on: ?[]const u8,

    pub fn eql(a: Point, b: Point) bool {
        if (!std.mem.eql(u8, a.group_id, b.group_id) or a.at.order(b.at) != .eq or a.days != b.days) return false;
        if (a.on == null or b.on == null) return a.on == null and b.on == null;
        return std.mem.eql(u8, a.on.?, b.on.?);
    }
};

pub const Schedule = struct {
    instance: []const u8,
    name: []const u8,
    enabled: bool,
    /// The group it acts on, when it acts on one.
    group_id: ?[]const u8,
    /// Null when it's in a form this file doesn't know.
    points: ?[]const Point,
    configuration: Value,
};

pub const Found = struct {
    schedules: []const Schedule,
    /// The `Schedule` script, which a new instance names.
    script_id: ?[]const u8,
};

fn object(v: Value) ?std.json.ObjectMap {
    return if (v == .object) v.object else null;
}

fn typeIs(o: std.json.ObjectMap, wanted: []const u8) bool {
    return std.mem.eql(u8, json_get.optionalString(o, "type") orelse "", wanted);
}

fn nameOf(o: std.json.ObjectMap) []const u8 {
    const metadata = json_get.optionalObject(o, "metadata") orelse return "";
    return std.mem.trim(u8, json_get.optionalString(metadata, "name") orelse "", " ");
}

pub fn parse(arena: Allocator, resources: []const u8) !Found {
    const root = try std.json.parseFromSliceLeaky(Value, arena, resources, .{});
    const items = (try json_get.Array(root.object, "data")).items;
    var script: ?[]const u8 = null;
    for (items) |item| {
        const o = object(item) orelse continue;
        if (typeIs(o, "behavior_script") and std.mem.eql(u8, nameOf(o), SCRIPT)) script = json_get.optionalString(o, "id");
    }
    var out: std.ArrayList(Schedule) = .empty;
    const id = script orelse return .{ .schedules = &.{}, .script_id = null };
    for (items) |item| {
        const o = object(item) orelse continue;
        if (!typeIs(o, "behavior_instance")) continue;
        if (!std.mem.eql(u8, json_get.optionalString(o, "script_id") orelse "", id)) continue;
        const configuration = o.get("configuration") orelse continue;
        const config = object(configuration) orelse continue;
        const group = groupOf(config);
        try out.append(arena, .{
            .instance = json_get.optionalString(o, "id") orelse continue,
            .name = nameOf(o),
            .enabled = json_get.optionalBool(o, "enabled") orelse false,
            .group_id = group,
            .points = if (group) |g| try pointsOf(arena, config, g) else null,
            .configuration = configuration,
        });
    }
    return .{ .schedules = out.items, .script_id = id };
}

fn groupOf(config: std.json.ObjectMap) ?[]const u8 {
    const where = json_get.optionalArray(config, "where") orelse return null;
    if (where.items.len != 1) return null;
    const e = object(where.items[0]) orelse return null;
    const g = json_get.optionalObject(e, "group") orelse return null;
    return json_get.optionalString(g, "rid");
}

fn timeOf(holder: std.json.ObjectMap, key: []const u8) ?Time {
    const at = json_get.optionalObject(holder, key) orelse return null;
    const tp = json_get.optionalObject(at, "time_point") orelse return null;
    if (!std.mem.eql(u8, json_get.optionalString(tp, "type") orelse "", "time")) return null;
    const t = json_get.optionalObject(tp, "time") orelse return null;
    const h = json_get.optionalInt(t, "hour") orelse return null;
    const m = json_get.optionalInt(t, "minute") orelse return null;
    if (h < 0 or h > 23 or m < 0 or m > 59) return null;
    return .{ .hour = @intCast(h), .minute = @intCast(m) };
}

fn pointsOf(arena: Allocator, config: std.json.ObjectMap, group: []const u8) !?[]const Point {
    const what = json_get.optionalArray(config, "what") orelse return null;
    if (what.items.len != 1) return null;
    const w = object(what.items[0]) orelse return null;
    const wg = json_get.optionalObject(w, "group") orelse return null;
    if (!std.mem.eql(u8, json_get.optionalString(wg, "rid") orelse "", group)) return null;
    const recall = json_get.optionalObject(w, "recall") orelse return null;
    const rid = json_get.optionalString(recall, "rid") orelse return null;
    const rtype = json_get.optionalString(recall, "rtype") orelse return null;
    const on: ?[]const u8 = if (std.mem.eql(u8, rtype, "scene"))
        rid
    else if (std.mem.eql(u8, rtype, "recipe") and std.mem.eql(u8, rid, OFF_RECIPE))
        null
    else
        return null;

    const when = json_get.optionalObject(config, "when_extended") orelse return null;
    const days_list = json_get.optionalArray(when, "recurrence_days") orelse return null;
    var names: std.ArrayList([]const u8) = .empty;
    for (days_list.items) |d| try names.append(arena, if (d == .string) d.string else return null);
    const days = dayMask(names.items) orelse return null;
    const start = timeOf(when, "start_at") orelse return null;
    var out: std.ArrayList(Point) = .empty;
    try out.append(arena, .{ .group_id = group, .at = start, .days = days, .on = on });
    if (when.contains("end_at")) {
        // An end only ever switches off, and only an on has one.
        if (on == null) return null;
        const end = timeOf(when, "end_at") orelse return null;
        try out.append(arena, .{ .group_id = group, .at = end, .days = days, .on = null });
    }
    return out.items;
}

/// One instance to make: an on, or an off, at `start`, and an on may end at `end`.
pub const Entry = struct {
    name: []const u8,
    group_id: []const u8,
    group_rtype: []const u8,
    /// The scene recalled; null is off.
    on: ?[]const u8,
    start: Time,
    end: ?Time = null,
    days: u7,
};

/// `POST /behavior_instance`'s body, in the shape the Hue app writes.
pub fn createBody(arena: Allocator, script_id: []const u8, e: Entry) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("behavior_instance");
    try jw.objectField("script_id");
    try jw.write(script_id);
    try jw.objectField("enabled");
    try jw.write(true);
    try jw.objectField("metadata");
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write(e.name);
    try jw.endObject();
    try jw.objectField("configuration");
    try jw.beginObject();
    try jw.objectField("what");
    try jw.beginArray();
    try jw.beginObject();
    try writeGroup(&jw, e);
    try jw.objectField("recall");
    try jw.beginObject();
    try jw.objectField("rid");
    try jw.write(e.on orelse OFF_RECIPE);
    try jw.objectField("rtype");
    try jw.write(if (e.on != null) "scene" else "recipe");
    try jw.endObject();
    try jw.endObject();
    try jw.endArray();
    try jw.objectField("when_extended");
    try jw.beginObject();
    if (e.end) |t| {
        try jw.objectField("end_at");
        try writeTime(&jw, t);
    }
    try jw.objectField("recurrence_days");
    try jw.beginArray();
    for (DAYS, 0..) |d, i| if (e.days & (@as(u7, 1) << @intCast(i)) != 0) try jw.write(d);
    try jw.endArray();
    try jw.objectField("start_at");
    try writeTime(&jw, e.start);
    try jw.endObject();
    try jw.objectField("where");
    try jw.beginArray();
    try jw.beginObject();
    try writeGroup(&jw, e);
    try jw.endObject();
    try jw.endArray();
    try jw.endObject();
    try jw.endObject();
    return aw.written();
}

fn writeGroup(jw: *std.json.Stringify, e: Entry) !void {
    try jw.objectField("group");
    try jw.beginObject();
    try jw.objectField("rid");
    try jw.write(e.group_id);
    try jw.objectField("rtype");
    try jw.write(e.group_rtype);
    try jw.endObject();
}

fn writeTime(jw: *std.json.Stringify, t: Time) !void {
    try jw.beginObject();
    try jw.objectField("time_point");
    try jw.beginObject();
    try jw.objectField("time");
    try jw.beginObject();
    try jw.objectField("hour");
    try jw.write(t.hour);
    try jw.objectField("minute");
    try jw.write(t.minute);
    try jw.endObject();
    try jw.objectField("type");
    try jw.write("time");
    try jw.endObject();
    try jw.endObject();
}

/// The moments `entry` switches, as `parse` would read them back.
pub fn pointsOfEntry(arena: Allocator, e: Entry) ![]const Point {
    var out: std.ArrayList(Point) = .empty;
    try out.append(arena, .{ .group_id = e.group_id, .at = e.start, .days = e.days, .on = e.on });
    if (e.end) |t| try out.append(arena, .{ .group_id = e.group_id, .at = t, .days = e.days, .on = null });
    return out.items;
}

/// Whether two lists hold the same moments, in any order.
pub fn samePoints(arena: Allocator, a: []const Point, b: []const Point) !bool {
    if (a.len != b.len) return false;
    const used = try arena.alloc(bool, b.len);
    @memset(used, false);
    for (a) |p| {
        const i = for (b, 0..) |q, i| {
            if (!used[i] and p.eql(q)) break i;
        } else return false;
        used[i] = true;
    }
    return true;
}

const testing = std.testing;

// The pump's morning and the radiator's evening as the Hue app wrote them: an on with
// an end, and an on and an off apart.
const fixture =
    \\{"errors":[],"data":[
    \\ {"id":"script-sched","type":"behavior_script","metadata":{"name":"Schedule"}},
    \\ {"id":"pump-am","type":"behavior_instance","script_id":"script-sched","enabled":true,"metadata":{"name":"Circulating Pump - AM"},"configuration":{
    \\   "what":[{"group":{"rid":"services","rtype":"room"},"recall":{"rid":"bright-s","rtype":"scene"}}],
    \\   "when_extended":{"end_at":{"time_point":{"time":{"hour":8,"minute":0},"type":"time"}},"recurrence_days":["sunday","monday","tuesday","wednesday","thursday","friday","saturday"],"start_at":{"time_point":{"time":{"hour":6,"minute":0},"type":"time"}}},
    \\   "where":[{"group":{"rid":"services","rtype":"room"}}]}},
    \\ {"id":"rad-on","type":"behavior_instance","script_id":"script-sched","enabled":true,"metadata":{"name":"Radiator On"},"configuration":{
    \\   "what":[{"group":{"rid":"radiator","rtype":"room"},"recall":{"rid":"bright-r","rtype":"scene"}}],
    \\   "when_extended":{"recurrence_days":["sunday","monday","tuesday","wednesday","thursday","friday","saturday"],"start_at":{"time_point":{"time":{"hour":20,"minute":30},"type":"time"}}},
    \\   "where":[{"group":{"rid":"radiator","rtype":"room"}}]}},
    \\ {"id":"rad-off","type":"behavior_instance","script_id":"script-sched","enabled":true,"metadata":{"name":"Radiator off"},"configuration":{
    \\   "what":[{"group":{"rid":"radiator","rtype":"room"},"recall":{"rid":"caabcf9c-984b-4a2c-a97a-0ed61a299258","rtype":"recipe"}}],
    \\   "when_extended":{"recurrence_days":["saturday","sunday"],"start_at":{"time_point":{"time":{"hour":22,"minute":0},"type":"time"}}},
    \\   "where":[{"group":{"rid":"radiator","rtype":"room"}}]}},
    \\ {"id":"sleep","type":"behavior_instance","script_id":"script-other","enabled":false,"metadata":{"name":"Extractor"},"configuration":{}}
    \\]}
;

test "a schedule reads as the moments it switches, an end being an off" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const found = try parse(a, fixture);
    try testing.expectEqualStrings("script-sched", found.script_id.?);
    try testing.expectEqual(@as(usize, 3), found.schedules.len);
    const am = found.schedules[0];
    try testing.expectEqual(@as(usize, 2), am.points.?.len);
    try testing.expectEqualStrings("bright-s", am.points.?[0].on.?);
    try testing.expect(am.points.?[1].on == null);
    try testing.expectEqual(@as(u8, 8), am.points.?[1].at.hour);
    try testing.expectEqual(EVERY_DAY, am.points.?[0].days);
    const off = found.schedules[2];
    try testing.expect(off.points.?[0].on == null);
    try testing.expectEqual(dayMask(&.{ "sunday", "saturday" }).?, off.points.?[0].days);
}

test "an on with an end and an on and an off apart are the same moments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const found = try parse(a, fixture);
    const paired: Entry = .{ .name = "x", .group_id = "radiator", .group_rtype = "room", .on = "bright-r", .start = .{ .hour = 20, .minute = 30 }, .end = .{ .hour = 22, .minute = 0 }, .days = dayMask(&.{ "saturday", "sunday" }).? };
    const apart = try std.mem.concat(a, Point, &.{ found.schedules[1].points.?, found.schedules[2].points.? });
    // The fixture's on is every day and its off weekends only, so not the same...
    try testing.expect(!try samePoints(a, apart, try pointsOfEntry(a, paired)));
    // ...but the same days are.
    var every = paired;
    every.days = EVERY_DAY;
    const on_every = found.schedules[1].points.?;
    var off_every = found.schedules[2].points.?[0];
    off_every.days = EVERY_DAY;
    try testing.expect(try samePoints(a, try std.mem.concat(a, Point, &.{ on_every, &.{off_every} }), try pointsOfEntry(a, every)));
}

test "a made schedule reads back as what it was made from" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]Entry{
        .{ .name = "Pump 19:00-21:30", .group_id = "services", .group_rtype = "room", .on = "bright-s", .start = .{ .hour = 19, .minute = 0 }, .end = .{ .hour = 21, .minute = 30 }, .days = EVERY_DAY },
        .{ .name = "Radiator off 22:00", .group_id = "radiator", .group_rtype = "room", .on = null, .start = .{ .hour = 22, .minute = 0 }, .days = dayMask(&.{"monday"}).? },
    }) |e| {
        const body = try createBody(a, "script-sched", e);
        const listed = try std.fmt.allocPrint(a, "{{\"errors\":[],\"data\":[{{\"id\":\"script-sched\",\"type\":\"behavior_script\",\"metadata\":{{\"name\":\"Schedule\"}}}},{s}]}}", .{try std.mem.replaceOwned(u8, a, body, "{\"type\":\"behavior_instance\"", "{\"id\":\"new\",\"type\":\"behavior_instance\"")});
        const back = (try parse(a, listed)).schedules[0];
        try testing.expectEqualStrings(e.name, back.name);
        try testing.expect(back.enabled);
        try testing.expect(try samePoints(a, back.points.?, try pointsOfEntry(a, e)));
    }
}
