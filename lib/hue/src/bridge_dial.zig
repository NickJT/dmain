//! A tap dial's buttons and ring on the Bridge, in and out of CLIP v2's behaviour format.
//!
//! A tap dial is a `Hue Accessories` instance with four `buttons`, keyed by button id,
//! and `rotaries`, keyed by its rotary's id. The shapes are the ones the Hue app
//! writes. A button here either recalls one scene per group in its `where`, or turns
//! its `where` off; the ring brings its group up with one scene and dims it. A write
//! starts from the whole configuration and replaces only what it's given, so the
//! ring's dim-off and anything this file doesn't know survive it. Pure: JSON in,
//! JSON out.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_get = @import("json_get").json_get;

pub const BUTTONS = 4;

pub const GroupRef = struct {
    id: []const u8,
    /// `room`, `zone` or `bridge_home`.
    rtype: []const u8,
};

/// What a press does: a scene for each group, or every group off.
pub const Press = struct {
    where: []const GroupRef,
    /// One scene id per `where` entry; empty turns them off.
    scenes: []const []const u8,

    pub fn eql(a: Press, b: Press) bool {
        if (a.where.len != b.where.len or a.scenes.len != b.scenes.len) return false;
        for (a.where, b.where) |x, y| if (!std.mem.eql(u8, x.id, y.id) or !std.mem.eql(u8, x.rtype, y.rtype)) return false;
        for (a.scenes, b.scenes) |x, y| if (!std.mem.eql(u8, x, y)) return false;
        return true;
    }
};

/// The ring: brought up from off with `scene`, on `group`.
pub const Ring = struct {
    group: GroupRef,
    scene: []const u8,

    pub fn eql(a: Ring, b: Ring) bool {
        return std.mem.eql(u8, a.group.id, b.group.id) and std.mem.eql(u8, a.group.rtype, b.group.rtype) and std.mem.eql(u8, a.scene, b.scene);
    }
};

pub const Dial = struct {
    instance: []const u8,
    dev: []const u8,
    name: []const u8,
    /// Each button's id, by control number less one.
    button_ids: [BUTTONS][]const u8,
    /// Each button as a press, or null in a form this file doesn't read.
    presses: [BUTTONS]?Press,
    ring_id: []const u8,
    ring: ?Ring,
    configuration: Value,
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

/// Every tap dial's behaviour in a `/clip/v2/resource` reply.
pub fn parse(arena: Allocator, resources: []const u8) ![]const Dial {
    const root = try std.json.parseFromSliceLeaky(Value, arena, resources, .{});
    const items = (try json_get.Array(root.object, "data")).items;
    var accessories: std.StringHashMapUnmanaged(void) = .empty;
    var macs: std.StringHashMapUnmanaged([]const u8) = .empty;
    var controls: std.StringHashMapUnmanaged(i64) = .empty;
    for (items) |item| {
        const o = object(item) orelse continue;
        const id = json_get.optionalString(o, "id") orelse continue;
        if (typeIs(o, "behavior_script") and std.mem.eql(u8, nameOf(o), "Hue Accessories")) try accessories.put(arena, id, {});
        if (typeIs(o, "button")) if (json_get.optionalObject(o, "metadata")) |m| try controls.put(arena, id, json_get.optionalInt(m, "control_id") orelse 0);
        if (typeIs(o, "zigbee_connectivity")) {
            const owner = json_get.optionalObject(o, "owner") orelse continue;
            const mac = json_get.optionalString(o, "mac_address") orelse continue;
            try macs.put(arena, json_get.optionalString(owner, "rid") orelse continue, try std.ascii.allocLowerString(arena, mac));
        }
    }
    var out: std.ArrayList(Dial) = .empty;
    for (items) |item| {
        const o = object(item) orelse continue;
        if (!typeIs(o, "behavior_instance")) continue;
        if (!accessories.contains(json_get.optionalString(o, "script_id") orelse continue)) continue;
        const configuration = o.get("configuration") orelse continue;
        const config = object(configuration) orelse continue;
        const rotaries = json_get.optionalObject(config, "rotaries") orelse continue;
        const buttons = json_get.optionalObject(config, "buttons") orelse continue;
        const device = json_get.optionalObject(config, "device") orelse continue;
        if (rotaries.count() != 1 or buttons.count() != BUTTONS) continue;

        var ids: [BUTTONS][]const u8 = @splat("");
        var presses: [BUTTONS]?Press = @splat(null);
        var it = buttons.iterator();
        var complete = true;
        while (it.next()) |e| {
            const c = controls.get(e.key_ptr.*) orelse 0;
            if (c < 1 or c > BUTTONS) {
                complete = false;
                break;
            }
            ids[@intCast(c - 1)] = e.key_ptr.*;
            presses[@intCast(c - 1)] = try pressOf(arena, e.value_ptr.*);
        }
        for (ids) |id| if (id.len == 0) {
            complete = false;
        };
        if (!complete) continue;
        var rit = rotaries.iterator();
        const r = rit.next().?;
        try out.append(arena, .{
            .instance = json_get.optionalString(o, "id") orelse continue,
            .dev = macs.get(json_get.optionalString(device, "rid") orelse continue) orelse continue,
            .name = nameOf(o),
            .button_ids = ids,
            .presses = presses,
            .ring_id = r.key_ptr.*,
            .ring = ringOf(r.value_ptr.*),
            .configuration = configuration,
        });
    }
    return out.items;
}

/// The whole house's group, which the Hue app calls "My entire home".
pub fn homeId(arena: Allocator, resources: []const u8) !?[]const u8 {
    const root = try std.json.parseFromSliceLeaky(Value, arena, resources, .{});
    for ((try json_get.Array(root.object, "data")).items) |item| {
        const o = object(item) orelse continue;
        if (typeIs(o, "bridge_home")) return json_get.optionalString(o, "id");
    }
    return null;
}

fn whereOf(arena: Allocator, o: std.json.ObjectMap) !?[]const GroupRef {
    const where = json_get.optionalArray(o, "where") orelse return null;
    var out: std.ArrayList(GroupRef) = .empty;
    for (where.items) |w| {
        const e = object(w) orelse return null;
        const g = json_get.optionalObject(e, "group") orelse return null;
        try out.append(arena, .{ .id = json_get.optionalString(g, "rid") orelse return null, .rtype = json_get.optionalString(g, "rtype") orelse return null });
    }
    return out.items;
}

fn sceneOf(action: Value) ?[]const u8 {
    const a = object(action) orelse return null;
    const recall = json_get.optionalObject(a, "recall") orelse return null;
    if (!std.mem.eql(u8, json_get.optionalString(recall, "rtype") orelse "", "scene")) return null;
    return json_get.optionalString(recall, "rid");
}

fn plain(v: ?Value, wanted: []const u8) bool {
    const o = object(v orelse return false) orelse return false;
    return std.mem.eql(u8, json_get.optionalString(o, "action") orelse "", wanted);
}

/// A button as a press: a long press that does nothing, so a hold never does
/// something else, and a tap that recalls or turns off.
fn pressOf(arena: Allocator, v: Value) !?Press {
    const b = object(v) orelse return null;
    if (!plain(b.get("on_long_press"), "do_nothing")) return null;
    const where = (try whereOf(arena, b)) orelse return null;
    if (where.len == 0) return null;
    const tap = b.get("on_short_release") orelse return null;
    if (plain(tap, "all_off")) return .{ .where = where, .scenes = &.{} };
    const t = object(tap) orelse return null;
    const single = json_get.optionalObject(t, "recall_single_extended") orelse return null;
    if (json_get.optionalObject(single, "with_off")) |w| if (json_get.optionalBool(w, "enabled") orelse false) return null;
    const actions = json_get.optionalArray(single, "actions") orelse return null;
    if (actions.items.len != where.len) return null;
    const scenes = try arena.alloc([]const u8, actions.items.len);
    for (actions.items, scenes) |a, *s| s.* = sceneOf((object(a) orelse return null).get("action") orelse return null) orelse return null;
    return .{ .where = where, .scenes = scenes };
}

fn ringOf(v: Value) ?Ring {
    const r = object(v) orelse return null;
    const where = json_get.optionalArray(r, "where") orelse return null;
    if (where.items.len != 1) return null;
    const g = json_get.optionalObject(object(where.items[0]) orelse return null, "group") orelse return null;
    const on = json_get.optionalObject(r, "on_dim_on") orelse return null;
    const list = json_get.optionalArray(on, "recall_single") orelse return null;
    if (list.items.len != 1) return null;
    const scene = sceneOf((object(list.items[0]) orelse return null).get("action") orelse return null) orelse return null;
    return .{ .group = .{ .id = json_get.optionalString(g, "rid") orelse return null, .rtype = json_get.optionalString(g, "rtype") orelse return null }, .scene = scene };
}

pub const Want = struct {
    /// By control number less one; null leaves that button as it is.
    presses: [BUTTONS]?Press,
    /// Null leaves the ring as it is.
    ring: ?Ring,
};

pub fn matches(d: Dial, want: Want) bool {
    for (d.presses, want.presses) |have, w| {
        const x = w orelse continue;
        const h = have orelse return false;
        if (!h.eql(x)) return false;
    }
    if (want.ring) |r| {
        const h = d.ring orelse return false;
        if (!h.eql(r)) return false;
    }
    return true;
}

/// `PUT /behavior_instance/{id}`'s body: the dial's whole configuration with the
/// wanted buttons, and the ring's `where` and `on_dim_on`, replaced.
pub fn body(arena: Allocator, d: Dial, want: Want) ![]const u8 {
    const config = object(d.configuration) orelse return error.NotADial;
    var aw: std.Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    try jw.beginObject();
    try jw.objectField("configuration");
    try jw.beginObject();
    var it = config.iterator();
    while (it.next()) |e| {
        const key = e.key_ptr.*;
        try jw.objectField(key);
        if (std.mem.eql(u8, key, "buttons")) {
            try writeButtons(&jw, object(e.value_ptr.*).?, d, want);
        } else if (std.mem.eql(u8, key, "rotaries") and want.ring != null) {
            try writeRotaries(&jw, object(e.value_ptr.*).?, want.ring.?);
        } else try jw.write(e.value_ptr.*);
    }
    try jw.endObject();
    try jw.endObject();
    return aw.written();
}

fn writeWhere(jw: *std.json.Stringify, where: []const GroupRef) !void {
    try jw.objectField("where");
    try jw.beginArray();
    for (where) |g| {
        try jw.beginObject();
        try jw.objectField("group");
        try jw.beginObject();
        try jw.objectField("rid");
        try jw.write(g.id);
        try jw.objectField("rtype");
        try jw.write(g.rtype);
        try jw.endObject();
        try jw.endObject();
    }
    try jw.endArray();
}

fn writeRecall(jw: *std.json.Stringify, scene: []const u8) !void {
    try jw.beginObject();
    try jw.objectField("action");
    try jw.beginObject();
    try jw.objectField("recall");
    try jw.beginObject();
    try jw.objectField("rid");
    try jw.write(scene);
    try jw.objectField("rtype");
    try jw.write("scene");
    try jw.endObject();
    try jw.endObject();
    try jw.endObject();
}

fn writeButtons(jw: *std.json.Stringify, buttons: std.json.ObjectMap, d: Dial, want: Want) !void {
    try jw.beginObject();
    var it = buttons.iterator();
    while (it.next()) |e| {
        try jw.objectField(e.key_ptr.*);
        const i = for (d.button_ids, 0..) |id, i| {
            if (std.mem.eql(u8, id, e.key_ptr.*)) break i;
        } else null;
        const p = if (i) |n| want.presses[n] else null;
        const press = p orelse {
            try jw.write(e.value_ptr.*);
            continue;
        };
        try jw.beginObject();
        try jw.objectField("on_long_press");
        try jw.beginObject();
        try jw.objectField("action");
        try jw.write("do_nothing");
        try jw.endObject();
        try jw.objectField("on_short_release");
        if (press.scenes.len == 0) {
            try jw.beginObject();
            try jw.objectField("action");
            try jw.write("all_off");
            try jw.endObject();
        } else {
            try jw.beginObject();
            try jw.objectField("recall_single_extended");
            try jw.beginObject();
            try jw.objectField("actions");
            try jw.beginArray();
            for (press.scenes) |s| try writeRecall(jw, s);
            try jw.endArray();
            try jw.objectField("with_off");
            try jw.beginObject();
            try jw.objectField("enabled");
            try jw.write(false);
            try jw.endObject();
            try jw.endObject();
            try jw.endObject();
        }
        try writeWhere(jw, press.where);
        try jw.endObject();
    }
    try jw.endObject();
}

fn writeRotaries(jw: *std.json.Stringify, rotaries: std.json.ObjectMap, ring: Ring) !void {
    try jw.beginObject();
    var it = rotaries.iterator();
    while (it.next()) |e| {
        try jw.objectField(e.key_ptr.*);
        const r = object(e.value_ptr.*) orelse {
            try jw.write(e.value_ptr.*);
            continue;
        };
        try jw.beginObject();
        var ri = r.iterator();
        while (ri.next()) |f| {
            const key = f.key_ptr.*;
            if (std.mem.eql(u8, key, "where") or std.mem.eql(u8, key, "on_dim_on")) continue;
            try jw.objectField(key);
            try jw.write(f.value_ptr.*);
        }
        try jw.objectField("on_dim_on");
        try jw.beginObject();
        try jw.objectField("recall_single");
        try jw.beginArray();
        try writeRecall(jw, ring.scene);
        try jw.endArray();
        try jw.endObject();
        try writeWhere(jw, &.{ring.group});
        try jw.endObject();
    }
    try jw.endObject();
}

const testing = std.testing;

// The Dial as the Hue app left it, trimmed: button 1 by time of day, 3 a recall in two
// rooms, 2 and 4 off, and a ring on a zone. A wall dimmer isn't a dial.
const fixture =
    \\{"errors":[],"data":[
    \\ {"id":"acc","type":"behavior_script","metadata":{"name":"Hue Accessories"}},
    \\ {"id":"dev-dial","type":"device"},
    \\ {"id":"zc","type":"zigbee_connectivity","owner":{"rid":"dev-dial","rtype":"device"},"mac_address":"00:17:88:01:0D:34:E4:06"},
    \\ {"id":"b1","type":"button","metadata":{"control_id":1}},{"id":"b2","type":"button","metadata":{"control_id":2}},
    \\ {"id":"b3","type":"button","metadata":{"control_id":3}},{"id":"b4","type":"button","metadata":{"control_id":4}},
    \\ {"id":"dial","type":"behavior_instance","script_id":"acc","metadata":{"name":"Hue tap dial switch 1"},"configuration":{
    \\   "buttons":{
    \\     "b1":{"on_long_press":{"action":"all_off"},"on_short_release":{"time_based_extended":{"slots":[]}},"where":[{"group":{"rid":"bedroom","rtype":"room"}}]},
    \\     "b2":{"on_long_press":{"action":"all_off"},"on_short_release":{"action":"all_off"},"where":[{"group":{"rid":"bedroom","rtype":"room"}}]},
    \\     "b3":{"on_long_press":{"action":"do_nothing"},"on_short_release":{"recall_single_extended":{"actions":[{"action":{"recall":{"rid":"out-bright","rtype":"scene"}}},{"action":{"recall":{"rid":"b2-energise","rtype":"scene"}}}],"with_off":{"enabled":false}}},"where":[{"group":{"rid":"outside","rtype":"room"}},{"group":{"rid":"bed2","rtype":"room"}}]},
    \\     "b4":{"on_long_press":{"action":"do_nothing"},"on_short_release":{"action":"all_off"},"where":[{"group":{"rid":"home","rtype":"bridge_home"}}]}},
    \\   "device":{"rid":"dev-dial","rtype":"device"},"model_id":"RDM002",
    \\   "rotaries":{"rot":{"on_dim_off":{"action":"all_off"},"on_dim_on":{"recall_single":[{"action":{"recall":{"rid":"lamps-relax","rtype":"scene"}}}]},"where":[{"group":{"rid":"lamps","rtype":"zone"}}]}}}},
    \\ {"id":"dimmer","type":"behavior_instance","script_id":"acc","metadata":{"name":"A dimmer"},"configuration":{"buttons":{},"device":{"rid":"dev-dial","rtype":"device"}}}
    \\]}
;

test "a tap dial's presses and ring read as the app left them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dials = try parse(a, fixture);
    try testing.expectEqual(@as(usize, 1), dials.len);
    const d = dials[0];
    try testing.expectEqualStrings("00:17:88:01:0d:34:e4:06", d.dev);
    // A time-of-day tap and a long press that turns off aren't presses.
    try testing.expect(d.presses[0] == null);
    try testing.expect(d.presses[1] == null);
    try testing.expectEqualStrings("b2-energise", d.presses[2].?.scenes[1]);
    try testing.expectEqual(@as(usize, 0), d.presses[3].?.scenes.len);
    try testing.expectEqualStrings("lamps-relax", d.ring.?.scene);
}

test "a written dial reads back as wanted, keeping its dim-off and what it isn't told" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = (try parse(a, fixture))[0];
    const lamps: GroupRef = .{ .id = "lamps", .rtype = "zone" };
    const want: Want = .{
        .presses = .{
            .{ .where = &.{lamps}, .scenes = &.{"lamps-on"} },
            .{ .where = &.{lamps}, .scenes = &.{} },
            null,
            .{ .where = &.{.{ .id = "home", .rtype = "bridge_home" }}, .scenes = &.{} },
        },
        .ring = .{ .group = lamps, .scene = "lamps-on" },
    };
    try testing.expect(!matches(d, want));
    const text = try body(a, d, want);
    const listed = try std.mem.concat(a, u8, &.{ fixture[0..std.mem.indexOf(u8, fixture, "{\"id\":\"dial\"").?], "{\"id\":\"dial\",\"type\":\"behavior_instance\",\"script_id\":\"acc\",\"metadata\":{\"name\":\"Hue tap dial switch 1\"},", text[1 .. text.len - 1], "}\n]}" });
    const back = (try parse(a, listed))[0];
    try testing.expect(matches(back, want));
    // Button 3 wasn't wanted, so it's as it was.
    try testing.expect(back.presses[2].?.eql(d.presses[2].?));
    try testing.expect(std.mem.indexOf(u8, text, "\"on_dim_off\":{\"action\":\"all_off\"}") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"model_id\":\"RDM002\"") != null);
}
