//! A wall dimmer's layout on the Bridge, in and out of CLIP v2's behaviour format.
//!
//! The Bridge publishes no schema for a switch's `configuration`, so the shapes here
//! are the ones its own switches hold. Anything else is described and left alone,
//! and a change starts from the switch's whole configuration, so a field this file
//! doesn't know about survives it. Pure: JSON in, JSON out.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_get = @import("json_get").json_get;

/// A room or zone a button acts on.
pub const Group = struct {
    id: []const u8,
    name: []const u8,
    /// `room`, `zone` or `bridge_home`, as the entry says.
    rtype: []const u8,

    /// The whole house, which the Hue app calls "My entire home".
    pub fn isHome(self: Group) bool {
        return std.mem.eql(u8, self.rtype, "bridge_home");
    }
};

/// What a button does on a tap.
pub const Slot = struct {
    /// The scene, when the tap recalls one of that name in each room or zone the
    /// button acts on, and nothing else.
    scene: ?[]const u8 = null,
    /// Whether a second tap turns the lights off.
    with_off: bool = false,
    text: []const u8,
};

pub const Switch = struct {
    /// The `behavior_instance`: what a write goes to.
    instance: []const u8,
    dev: []const u8,
    name: []const u8,
    model: []const u8,
    group: []const u8,
    /// Where the switch's buttons act, which is where its scenes must be.
    group_id: []const u8,
    top: Slot,
    bottom: Slot,
    /// Where each of those buttons acts, in its own order: a recall writes a scene
    /// for each, as the Bridge refuses one recall for several.
    top_where: []const Group,
    bottom_where: []const Group,
    /// Where the dim-up button acts; dim-down is written with it.
    dim_where: []const Group,
    /// Whether buttons 2 and 3 dim on both a tap and a hold.
    dim_tap_or_hold: bool,
    dim_text: []const u8,
    configuration: Value,
};

pub const Scene = struct { group_id: []const u8, name: []const u8, id: []const u8 };

pub const Found = struct { switches: []const Switch, scenes: []const Scene };

const BUTTONS = 4;

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

const Index = struct {
    scene_names: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// The room or zone each scene belongs to.
    scene_groups: std.StringHashMapUnmanaged([]const u8) = .empty,
    groups: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Which control a button id is.
    controls: std.StringHashMapUnmanaged(i64) = .empty,
    /// A device's IEEE address, from its Zigbee service.
    macs: std.StringHashMapUnmanaged([]const u8) = .empty,
    accessories: std.StringHashMapUnmanaged(void) = .empty,
};

/// Every wall dimmer in a `/clip/v2/resource` reply, and every scene. Strings and
/// configurations live in `arena`. A controller with other buttons, such as a tap
/// dial, isn't a wall dimmer, and is left out.
pub fn parse(arena: Allocator, resources: []const u8) !Found {
    const root = try std.json.parseFromSliceLeaky(Value, arena, resources, .{});
    const items = (try json_get.Array(root.object, "data")).items;

    var index: Index = .{};
    var scenes: std.ArrayList(Scene) = .empty;
    for (items) |item| {
        const o = object(item) orelse continue;
        const id = json_get.optionalString(o, "id") orelse continue;
        if (typeIs(o, "scene")) {
            const name = nameOf(o);
            try index.scene_names.put(arena, id, name);
            const group = json_get.optionalObject(o, "group") orelse continue;
            const group_id = json_get.optionalString(group, "rid") orelse continue;
            try index.scene_groups.put(arena, id, group_id);
            try scenes.append(arena, .{ .group_id = group_id, .name = name, .id = id });
        } else if (typeIs(o, "room") or typeIs(o, "zone")) {
            try index.groups.put(arena, id, nameOf(o));
        } else if (typeIs(o, "bridge_home")) {
            try index.groups.put(arena, id, "the whole house");
        } else if (typeIs(o, "button")) {
            const metadata = json_get.optionalObject(o, "metadata") orelse continue;
            try index.controls.put(arena, id, json_get.optionalInt(metadata, "control_id") orelse 0);
        } else if (typeIs(o, "zigbee_connectivity")) {
            const owner = json_get.optionalObject(o, "owner") orelse continue;
            const device = json_get.optionalString(owner, "rid") orelse continue;
            try index.macs.put(arena, device, json_get.optionalString(o, "mac_address") orelse continue);
        } else if (typeIs(o, "behavior_script")) {
            const metadata = json_get.optionalObject(o, "metadata") orelse continue;
            if (std.mem.eql(u8, json_get.optionalString(metadata, "category") orelse "", "accessory")) {
                try index.accessories.put(arena, id, {});
            }
        }
    }

    var switches: std.ArrayList(Switch) = .empty;
    for (items) |item| {
        const o = object(item) orelse continue;
        if (!typeIs(o, "behavior_instance")) continue;
        if (!index.accessories.contains(json_get.optionalString(o, "script_id") orelse continue)) continue;
        if (try switchFrom(arena, o, &index)) |found| try switches.append(arena, found);
    }
    return .{ .switches = switches.items, .scenes = scenes.items };
}

fn switchFrom(arena: Allocator, o: std.json.ObjectMap, index: *const Index) !?Switch {
    const configuration = o.get("configuration") orelse return null;
    const config = object(configuration) orelse return null;
    if (config.contains("rotaries")) return null;
    const buttons = json_get.optionalObject(config, "buttons") orelse return null;
    if (buttons.count() != BUTTONS) return null;

    var by_control: [BUTTONS]?std.json.ObjectMap = @splat(null);
    var iterator = buttons.iterator();
    while (iterator.next()) |entry| {
        const control = index.controls.get(entry.key_ptr.*) orelse return null;
        if (control < 1 or control > BUTTONS) return null;
        by_control[@intCast(control - 1)] = object(entry.value_ptr.*) orelse return null;
    }
    for (by_control) |b| if (b == null) return null;

    const device = json_get.optionalObject(config, "device") orelse return null;
    const device_id = json_get.optionalString(device, "rid") orelse return null;
    const up = by_control[1].?;
    const down = by_control[2].?;
    const group = groupOf(by_control[0].?) orelse return null;
    const top_where = try groupsOf(arena, by_control[0].?, index);
    const bottom_where = try groupsOf(arena, by_control[3].?, index);
    const dim_where = try groupsOf(arena, up, index);
    return .{
        .instance = json_get.optionalString(o, "id") orelse return null,
        .dev = index.macs.get(device_id) orelse return null,
        .name = nameOf(o),
        .model = json_get.optionalString(config, "model_id") orelse "",
        .group = index.groups.get(group) orelse "",
        .group_id = group,
        .top = try slotOf(arena, by_control[0].?, top_where, index),
        .bottom = try slotOf(arena, by_control[3].?, bottom_where, index),
        .top_where = top_where,
        .bottom_where = bottom_where,
        .dim_where = dim_where,
        .dim_tap_or_hold = dims(up, "dim_up", true) and dims(down, "dim_down", true),
        .dim_text = if (dims(up, "dim_up", false) and dims(down, "dim_down", false)) "hold only" else "other",
        .configuration = configuration,
    };
}

fn groupOf(button: std.json.ObjectMap) ?[]const u8 {
    const where = json_get.optionalArray(button, "where") orelse return null;
    if (where.items.len == 0) return null;
    const first = object(where.items[0]) orelse return null;
    const group = json_get.optionalObject(first, "group") orelse return null;
    return json_get.optionalString(group, "rid");
}

/// Every room and zone in a button's `where`. An entry that isn't a group is left
/// out, so a write can tell it's missing one.
fn groupsOf(arena: Allocator, button: std.json.ObjectMap, index: *const Index) ![]const Group {
    const where = json_get.optionalArray(button, "where") orelse return &.{};
    var out: std.ArrayList(Group) = .empty;
    for (where.items) |item| {
        const entry = object(item) orelse continue;
        const group = json_get.optionalObject(entry, "group") orelse continue;
        const id = json_get.optionalString(group, "rid") orelse continue;
        const rtype = json_get.optionalString(group, "rtype") orelse "";
        try out.append(arena, .{ .id = id, .name = index.groups.get(id) orelse id, .rtype = rtype });
    }
    return out.items;
}

fn actionIs(event: ?Value, wanted: []const u8) bool {
    const o = object(event orelse return false) orelse return false;
    return std.mem.eql(u8, json_get.optionalString(o, "action") orelse "", wanted);
}

/// On a hold, and also on a tap if `tap` says so.
fn dims(button: std.json.ObjectMap, action: []const u8, tap: bool) bool {
    if (!actionIs(button.get("on_repeat"), action)) return false;
    return !tap or actionIs(button.get("on_short_release"), action);
}

fn withOff(o: std.json.ObjectMap) bool {
    const off = json_get.optionalObject(o, "with_off") orelse return false;
    return (off.get("enabled") orelse return false) == .bool and off.get("enabled").?.bool;
}

fn slotOf(arena: Allocator, button: std.json.ObjectMap, where: []const Group, index: *const Index) !Slot {
    const event = object(button.get("on_short_release") orelse return .{ .text = "nothing on a tap" }) orelse return .{ .text = "other" };
    if (json_get.optionalString(event, "action")) |action| return .{ .text = action };
    if (event.contains("behavior_trigger")) return .{ .text = "runs a routine" };
    if (json_get.optionalObject(event, "time_based_extended")) |t| {
        const n = if (json_get.optionalArray(t, "slots")) |s| s.items.len else 0;
        return .{ .with_off = withOff(t), .text = try std.fmt.allocPrint(arena, "by time of day, {d} scenes", .{n}) };
    }
    if (json_get.optionalObject(event, "scene_cycle_extended")) |t| {
        const n = if (json_get.optionalArray(t, "slots")) |s| s.items.len else 0;
        return .{ .with_off = withOff(t), .text = try std.fmt.allocPrint(arena, "cycles {d} scenes", .{n}) };
    }
    const single = json_get.optionalObject(event, "recall_single_extended") orelse return .{ .text = "other" };
    const off = withOff(single);
    const actions = json_get.optionalArray(single, "actions") orelse return .{ .with_off = off, .text = "other" };
    if (actions.items.len == 1) {
        const action = (object(actions.items[0]) orelse return .{ .with_off = off, .text = "other" }).get("action") orelse return .{ .with_off = off, .text = "other" };
        if (action == .string) return .{ .with_off = off, .text = action.string };
    }
    const scene = oneSceneEach(actions.items, where, index) orelse
        return .{ .with_off = off, .text = if (actions.items.len == 1) "a scene that's gone" else "several actions" };
    // A wall dimmer's scene is for its room; on the whole house it is something else.
    for (where) |g| if (g.isHome()) return .{ .with_off = off, .text = try std.fmt.allocPrint(arena, "{s}, on the whole house", .{scene}) };
    return .{ .scene = scene, .with_off = off, .text = scene };
}

/// The scene name, when there's a recall for each entry of `where` and they all
/// recall scenes of that name; null otherwise. A scene needn't belong to its
/// entry: the Bridge holds buttons acting on a zone, or on the whole house, that
/// recall a room's scene, and they work.
fn oneSceneEach(actions: []const Value, where: []const Group, index: *const Index) ?[]const u8 {
    if (actions.len == 0 or actions.len != where.len) return null;
    var name: ?[]const u8 = null;
    for (actions) |item| {
        const action = (object(item) orelse return null).get("action") orelse return null;
        const recall = json_get.optionalObject(object(action) orelse return null, "recall") orelse return null;
        const scene = index.scene_names.get(json_get.optionalString(recall, "rid") orelse return null) orelse return null;
        if (name) |n| if (!std.mem.eql(u8, n, scene)) return null;
        name = scene;
    }
    return name;
}

pub const Layout = struct {
    /// A scene name for the top button, off on the next tap. Null leaves it alone.
    top: ?[]const u8 = null,
    /// A scene name for the bottom button, which stays on. Null leaves it alone.
    bottom: ?[]const u8 = null,
    dim_tap_or_hold: bool = false,
    /// The one room or zone every button is to act on, the bottom's only when it's
    /// written too. Its scenes must be its own: nothing falls back to the switch's
    /// old room. Null leaves each button's `where` as it is.
    where: ?Group = null,
};

pub const LayoutError = error{ SceneNotFound, AmbiguousScene, NoGroup, NoRoomOfItsOwn };

/// Where a button the layout writes will act: its own `where`, except that one
/// acting on the whole house is narrowed to the switch's own room or zone, the
/// top button's. A wall dimmer's layout is for its room; a control meant for the
/// whole house, such as a tap dial's, isn't a wall dimmer and is never written.
pub fn writeWhere(sw: Switch, where: []const Group) LayoutError![]const Group {
    for (where) |g| if (g.isHome()) {
        for (sw.top_where) |own| if (!own.isHome()) return sw.top_where[0..1];
        return error.NoRoomOfItsOwn;
    };
    return where;
}

/// Why a scene name can't be written to a button, and which room or zone says so.
pub const Trouble = struct { err: LayoutError, group: ?Group };

/// The scene of this name for each entry of a button's `where`, in its order,
/// as the Bridge refuses a recall with fewer scenes than entries. Each entry's own
/// scene first. A button with one entry and no such scene there, such as a zone or
/// the whole house, takes the switch's own room's, `home`, as it always has. Two
/// of one name in a group is refused rather than picked between: they needn't
/// look alike. `trouble` says which group failed.
pub fn findScenes(arena: Allocator, found: Found, sw: Switch, where: []const Group, name: []const u8, trouble: *Trouble) ![]const []const u8 {
    if (where.len == 0) {
        trouble.* = .{ .err = error.NoGroup, .group = null };
        return error.NoGroup;
    }
    const ids = try arena.alloc([]const u8, where.len);
    for (where, ids) |group, *id| {
        id.* = findScene(found, group.id, name) catch |err| blk: {
            if (err == error.SceneNotFound and where.len == 1) {
                if (findScene(found, sw.group_id, name)) |home| break :blk home else |_| {}
            }
            trouble.* = .{ .err = err, .group = group };
            return err;
        };
    }
    return ids;
}

pub fn findScene(found: Found, group_id: []const u8, name: []const u8) LayoutError![]const u8 {
    var id: ?[]const u8 = null;
    for (found.scenes) |scene| {
        if (!std.mem.eql(u8, scene.group_id, group_id) or !std.mem.eql(u8, scene.name, name)) continue;
        if (id != null) return error.AmbiguousScene;
        id = scene.id;
    }
    return id orelse error.SceneNotFound;
}

/// One recall per scene, so a button acting on several rooms and zones recalls a
/// scene in each.
fn recallJson(arena: Allocator, scene_ids: []const []const u8, with_off: bool) !Value {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll("{\"recall_single_extended\":{\"actions\":[");
    for (scene_ids, 0..) |id, i| {
        if (i > 0) try out.writer.writeByte(',');
        try out.writer.print("{{\"action\":{{\"recall\":{{\"rid\":\"{s}\",\"rtype\":\"scene\"}}}}}}", .{id});
    }
    try out.writer.print("],\"with_off\":{{\"enabled\":{}}}}}}}", .{with_off});
    return std.json.parseFromSliceLeaky(Value, arena, out.written(), .{});
}

fn whereJson(arena: Allocator, where: []const Group) !Value {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeByte('[');
    for (where, 0..) |g, i| {
        if (i > 0) try out.writer.writeByte(',');
        try out.writer.print("{{\"group\":{{\"rid\":\"{s}\",\"rtype\":\"{s}\"}}}}", .{ g.id, g.rtype });
    }
    try out.writer.writeByte(']');
    return std.json.parseFromSliceLeaky(Value, arena, out.written(), .{});
}

fn dimJson(arena: Allocator, action: []const u8) !Value {
    const text = try std.fmt.allocPrint(arena, "{{\"action\":\"{s}\"}}", .{action});
    return std.json.parseFromSliceLeaky(Value, arena, text, .{});
}

/// The body that changes `sw` to `layout`, from its whole current configuration, so
/// what `layout` doesn't mention stays as it is: `where`, the long press, the device.
pub fn layoutBody(arena: Allocator, found: Found, sw: Switch, buttons: []const ButtonIds, layout: Layout) ![]const u8 {
    const original = try std.json.Stringify.valueAlloc(arena, sw.configuration, .{});
    const copy = try std.json.parseFromSliceLeaky(Value, arena, original, .{});
    const config_buttons = copy.object.getPtr("buttons").?;

    const ids = idsOf(buttons, sw.instance) orelse return error.UnknownSwitch;
    var trouble: Trouble = undefined;
    const target: ?[]const Group = if (layout.where) |*g| g[0..1] else null;
    for ([_]struct { name: ?[]const u8, id: []const u8, where: []const Group, with_off: bool }{
        .{ .name = layout.top, .id = ids.top, .where = sw.top_where, .with_off = true },
        .{ .name = layout.bottom, .id = ids.bottom, .where = sw.bottom_where, .with_off = false },
    }) |b| {
        const name = b.name orelse continue;
        const button = config_buttons.object.getPtr(b.id).?;
        if (target) |where| {
            const scene = findScene(found, where[0].id, name) catch |err| {
                trouble = .{ .err = err, .group = where[0] };
                return err;
            };
            try button.object.put(arena, "on_short_release", try recallJson(arena, &.{scene}, b.with_off));
            try button.object.put(arena, "where", try whereJson(arena, where));
            continue;
        }
        const where = try writeWhere(sw, b.where);
        const scenes = try findScenes(arena, found, sw, where, name, &trouble);
        try button.object.put(arena, "on_short_release", try recallJson(arena, scenes, b.with_off));
        if (where.ptr != b.where.ptr) try button.object.put(arena, "where", try whereJson(arena, where));
    }
    if (target) |where| for ([_][]const u8{ ids.up, ids.down }) |id| {
        try config_buttons.object.getPtr(id).?.object.put(arena, "where", try whereJson(arena, where));
    };
    if (layout.dim_tap_or_hold) {
        for ([_]struct { id: []const u8, action: []const u8 }{
            .{ .id = ids.up, .action = "dim_up" },
            .{ .id = ids.down, .action = "dim_down" },
        }) |b| {
            const button = config_buttons.object.getPtr(b.id).?;
            try button.object.put(arena, "on_short_release", try dimJson(arena, b.action));
            try button.object.put(arena, "on_repeat", try dimJson(arena, b.action));
        }
    }
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll("{\"configuration\":");
    try std.json.Stringify.value(copy, .{}, &out.writer);
    try out.writer.writeByte('}');
    return out.written();
}

/// Which button id is which control, per switch, as a configuration keys its buttons
/// by id alone.
pub const ButtonIds = struct { instance: []const u8, top: []const u8, up: []const u8, down: []const u8, bottom: []const u8 };

fn idsOf(all: []const ButtonIds, instance: []const u8) ?ButtonIds {
    for (all) |ids| {
        if (std.mem.eql(u8, ids.instance, instance)) return ids;
    }
    return null;
}

pub fn buttonIds(arena: Allocator, resources: []const u8, found: Found) ![]const ButtonIds {
    const root = try std.json.parseFromSliceLeaky(Value, arena, resources, .{});
    var controls: std.StringHashMapUnmanaged(i64) = .empty;
    for ((try json_get.Array(root.object, "data")).items) |item| {
        const o = object(item) orelse continue;
        if (!typeIs(o, "button")) continue;
        const metadata = json_get.optionalObject(o, "metadata") orelse continue;
        try controls.put(arena, json_get.optionalString(o, "id") orelse continue, json_get.optionalInt(metadata, "control_id") orelse 0);
    }
    const out = try arena.alloc(ButtonIds, found.switches.len);
    for (found.switches, out) |sw, *ids| {
        ids.instance = sw.instance;
        var iterator = sw.configuration.object.get("buttons").?.object.iterator();
        while (iterator.next()) |entry| {
            switch (controls.get(entry.key_ptr.*) orelse 0) {
                1 => ids.top = entry.key_ptr.*,
                2 => ids.up = entry.key_ptr.*,
                3 => ids.down = entry.key_ptr.*,
                4 => ids.bottom = entry.key_ptr.*,
                else => {},
            }
        }
    }
    return out;
}

/// A room or zone with the IEEE addresses of the devices whose lights it holds.
pub const GroupLights = struct {
    group: Group,
    devs: []const []const u8,
};

pub const Groups = struct {
    groups: []const GroupLights,
    /// Every device with a light, a plug among them.
    light_devs: []const []const u8,

    pub fn named(self: Groups, name: []const u8, rtype: []const u8) ?GroupLights {
        for (self.groups) |g| if (std.mem.eql(u8, g.group.name, name) and std.mem.eql(u8, g.group.rtype, rtype)) return g;
        return null;
    }
};

/// Every room and zone, and which devices' lights each holds: a room lists devices,
/// a zone lights.
pub fn groups(arena: Allocator, resources: []const u8) !Groups {
    const root = try std.json.parseFromSliceLeaky(Value, arena, resources, .{});
    const items = (try json_get.Array(root.object, "data")).items;
    var macs: std.StringHashMapUnmanaged([]const u8) = .empty;
    var owner_of: std.StringHashMapUnmanaged([]const u8) = .empty;
    var lit: std.StringHashMapUnmanaged(void) = .empty;
    for (items) |item| {
        const o = object(item) orelse continue;
        const id = json_get.optionalString(o, "id") orelse continue;
        const owner = json_get.optionalObject(o, "owner") orelse continue;
        const rid = json_get.optionalString(owner, "rid") orelse continue;
        if (typeIs(o, "zigbee_connectivity")) {
            const mac = json_get.optionalString(o, "mac_address") orelse continue;
            try macs.put(arena, rid, try std.ascii.allocLowerString(arena, mac));
        } else if (typeIs(o, "light")) {
            try owner_of.put(arena, id, rid);
            try lit.put(arena, rid, {});
        }
    }
    var out: std.ArrayList(GroupLights) = .empty;
    for (items) |item| {
        const o = object(item) orelse continue;
        const room = typeIs(o, "room");
        if (!room and !typeIs(o, "zone")) continue;
        var devs: std.ArrayList([]const u8) = .empty;
        if (json_get.optionalArray(o, "children")) |children| for (children.items) |c| {
            const co = object(c) orelse continue;
            const rid = json_get.optionalString(co, "rid") orelse continue;
            const device = if (std.mem.eql(u8, json_get.optionalString(co, "rtype") orelse "", "light")) owner_of.get(rid) orelse continue else rid;
            if (!lit.contains(device)) continue;
            try devs.append(arena, macs.get(device) orelse continue);
        };
        try out.append(arena, .{
            .group = .{ .id = json_get.optionalString(o, "id") orelse continue, .name = nameOf(o), .rtype = if (room) "room" else "zone" },
            .devs = devs.items,
        });
    }
    var light_devs: std.ArrayList([]const u8) = .empty;
    var it = lit.keyIterator();
    while (it.next()) |device| if (macs.get(device.*)) |mac| try light_devs.append(arena, mac);
    return .{ .groups = out.items, .light_devs = light_devs.items };
}

/// Max: every light a button acts on, white at full. Generated, never chosen, so
/// it's the same in every room.
pub const MAX_SCENE = "Max";
/// 4000 K, a neutral white.
pub const MAX_MIREK: i64 = 250;
/// The same white for a colour light with no colour temperature, on the Planckian
/// locus at 4000 K.
const MAX_X = 0.3805;
const MAX_Y = 0.3768;

const LightCaps = struct {
    id: []const u8,
    dimming: bool,
    /// The light's own range, when it has a colour temperature.
    mirek: ?[2]i64,
    color: bool,
};

/// What a group's Max scene needs: null `body` when it's already right.
pub const MaxScene = struct {
    /// The Max scene there now, if any: a write updates it rather than adding one.
    id: ?[]const u8,
    /// `POST /scene` when `id` is null, else `PUT /scene/{id}`.
    body: ?[]const u8,
    lights: usize,
};

/// The Max scene `group` should have, from what the Bridge holds now. A room's
/// lights are its devices'; a zone lists lights itself.
pub fn maxScene(arena: Allocator, resources: []const u8, group: Group) !MaxScene {
    const root = try std.json.parseFromSliceLeaky(Value, arena, resources, .{});
    const items = (try json_get.Array(root.object, "data")).items;
    var lights: std.ArrayList(LightCaps) = .empty;
    var owners: std.StringHashMapUnmanaged([]const u8) = .empty;
    var group_obj: ?std.json.ObjectMap = null;
    var existing: ?std.json.ObjectMap = null;
    var existing_id: ?[]const u8 = null;
    for (items) |item| {
        const o = object(item) orelse continue;
        const id = json_get.optionalString(o, "id") orelse continue;
        if (typeIs(o, "light")) {
            const owner = json_get.optionalObject(o, "owner") orelse continue;
            try owners.put(arena, id, json_get.optionalString(owner, "rid") orelse continue);
            var mirek: ?[2]i64 = null;
            if (json_get.optionalObject(o, "color_temperature")) |ct| if (json_get.optionalObject(ct, "mirek_schema")) |ms| {
                mirek = .{ json_get.optionalInt(ms, "mirek_minimum") orelse 153, json_get.optionalInt(ms, "mirek_maximum") orelse 500 };
            };
            try lights.append(arena, .{ .id = id, .dimming = o.contains("dimming"), .mirek = mirek, .color = o.contains("color") });
        } else if (std.mem.eql(u8, id, group.id)) {
            group_obj = o;
        } else if (typeIs(o, "scene") and std.mem.eql(u8, nameOf(o), MAX_SCENE)) {
            const g = json_get.optionalObject(o, "group") orelse continue;
            if (!std.mem.eql(u8, json_get.optionalString(g, "rid") orelse "", group.id)) continue;
            if (existing != null) return error.AmbiguousScene;
            existing = o;
            existing_id = id;
        }
    }
    const g = group_obj orelse return error.NoGroup;
    var members: std.ArrayList(LightCaps) = .empty;
    const children = json_get.optionalArray(g, "children") orelse return error.NoGroup;
    for (children.items) |c| {
        const co = object(c) orelse continue;
        const rid = json_get.optionalString(co, "rid") orelse continue;
        const rtype = json_get.optionalString(co, "rtype") orelse "";
        for (lights.items) |l| {
            const hit = if (std.mem.eql(u8, rtype, "light")) std.mem.eql(u8, l.id, rid) else std.mem.eql(u8, owners.get(l.id) orelse "", rid);
            if (hit) try members.append(arena, l);
        }
    }
    std.mem.sort(LightCaps, members.items, {}, struct {
        fn lt(_: void, x: LightCaps, y: LightCaps) bool {
            return std.mem.order(u8, x.id, y.id) == .lt;
        }
    }.lt);

    var want: std.ArrayList([]const u8) = .empty;
    var actions: std.Io.Writer.Allocating = .init(arena);
    try actions.writer.writeByte('[');
    for (members.items, 0..) |l, n| {
        const mirek: ?i64 = if (l.mirek) |r| std.math.clamp(MAX_MIREK, r[0], r[1]) else null;
        const xy = mirek == null and l.color;
        try want.append(arena, try summary(arena, l.id, true, if (l.dimming) 100 else null, mirek, xy));
        if (n > 0) try actions.writer.writeByte(',');
        try actions.writer.print("{{\"target\":{{\"rid\":\"{s}\",\"rtype\":\"light\"}},\"action\":{{\"on\":{{\"on\":true}}", .{l.id});
        if (l.dimming) try actions.writer.writeAll(",\"dimming\":{\"brightness\":100}");
        if (mirek) |m| try actions.writer.print(",\"color_temperature\":{{\"mirek\":{d}}}", .{m});
        if (xy) try actions.writer.print(",\"color\":{{\"xy\":{{\"x\":{d},\"y\":{d}}}}}", .{ MAX_X, MAX_Y });
        try actions.writer.writeAll("}}");
    }
    try actions.writer.writeByte(']');

    if (existing) |e| if (try sameActions(arena, e, want.items)) return .{ .id = existing_id, .body = null, .lights = members.items.len };
    const body = if (existing_id != null)
        try std.fmt.allocPrint(arena, "{{\"actions\":{s}}}", .{actions.written()})
    else
        try std.fmt.allocPrint(arena, "{{\"type\":\"scene\",\"metadata\":{{\"name\":\"{s}\"}},\"group\":{{\"rid\":\"{s}\",\"rtype\":\"{s}\"}},\"actions\":{s}}}", .{ MAX_SCENE, group.id, group.rtype, actions.written() });
    return .{ .id = existing_id, .body = body, .lights = members.items.len };
}

/// One light's part of a scene, in a form two readings can be compared by.
fn summary(arena: Allocator, id: []const u8, on: bool, brightness: ?f64, mirek: ?i64, xy: bool) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s} {} {?d} {?d} {}", .{ id, on, if (brightness) |b| @as(?i64, @intFromFloat(@round(b))) else null, mirek, xy });
}

fn sameActions(arena: Allocator, scene: std.json.ObjectMap, want: []const []const u8) !bool {
    const actions = json_get.optionalArray(scene, "actions") orelse return false;
    var have: std.ArrayList([]const u8) = .empty;
    for (actions.items) |item| {
        const o = object(item) orelse return false;
        const target = json_get.optionalObject(o, "target") orelse return false;
        const action = json_get.optionalObject(o, "action") orelse return false;
        const on = if (json_get.optionalObject(action, "on")) |x| (x.get("on") orelse return false) == .bool and x.get("on").?.bool else false;
        const bri: ?f64 = if (json_get.optionalObject(action, "dimming")) |d| switch (d.get("brightness") orelse return false) {
            .float => |f| f,
            .integer => |n| @floatFromInt(n),
            else => return false,
        } else null;
        const mirek: ?i64 = if (json_get.optionalObject(action, "color_temperature")) |ct| json_get.optionalInt(ct, "mirek") else null;
        const xy = if (json_get.optionalObject(action, "color")) |c| blk: {
            const p = json_get.optionalObject(c, "xy") orelse break :blk false;
            const x = p.get("x") orelse break :blk false;
            const y = p.get("y") orelse break :blk false;
            break :blk x == .float and y == .float and @abs(x.float - MAX_X) < 0.002 and @abs(y.float - MAX_Y) < 0.002;
        } else false;
        try have.append(arena, try summary(arena, json_get.optionalString(target, "rid") orelse return false, on, bri, mirek, xy));
    }
    if (have.items.len != want.len) return false;
    std.mem.sort([]const u8, have.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    for (have.items, want) |h, w| if (!std.mem.eql(u8, h, w)) return false;
    return true;
}

const testing = std.testing;

fn named(found: Found, name: []const u8) Switch {
    for (found.switches) |sw| {
        if (std.mem.eql(u8, sw.name, name)) return sw;
    }
    unreachable;
}

const fixture =
    \\{"errors":[],"data":[
    \\ {"id":"script-acc","type":"behavior_script","metadata":{"name":"Hue Accessories","category":"accessory"}},
    \\ {"id":"study","type":"room","metadata":{"name":"Study"}},
    \\ {"id":"relax","type":"scene","group":{"rid":"study","rtype":"room"},"metadata":{"name":"Relax"}},
    \\ {"id":"bright","type":"scene","group":{"rid":"study","rtype":"room"},"metadata":{"name":"Bright"}},
    \\ {"id":"twin-a","type":"scene","group":{"rid":"study","rtype":"room"},"metadata":{"name":"Twin"}},
    \\ {"id":"twin-b","type":"scene","group":{"rid":"study","rtype":"room"},"metadata":{"name":"Twin"}},
    \\ {"id":"elsewhere","type":"scene","group":{"rid":"hall","rtype":"room"},"metadata":{"name":"Hall only"}},
    \\ {"id":"upstairs","type":"zone","metadata":{"name":"Upstairs"}},
    \\ {"id":"bright-up","type":"scene","group":{"rid":"upstairs","rtype":"zone"},"metadata":{"name":"Bright"}},
    \\ {"id":"dim-up","type":"scene","group":{"rid":"upstairs","rtype":"zone"},"metadata":{"name":"Dim"}},
    \\ {"id":"c1","type":"button","metadata":{"control_id":1}},
    \\ {"id":"c2","type":"button","metadata":{"control_id":2}},
    \\ {"id":"c3","type":"button","metadata":{"control_id":3}},
    \\ {"id":"c4","type":"button","metadata":{"control_id":4}},
    \\ {"id":"z2","type":"zigbee_connectivity","owner":{"rid":"dev-2","rtype":"device"},"mac_address":"00:17:88:01:00:00:00:02"},
    \\ {"id":"home","type":"bridge_home"},
    \\ {"id":"d1","type":"button","metadata":{"control_id":1}},
    \\ {"id":"d2","type":"button","metadata":{"control_id":2}},
    \\ {"id":"d3","type":"button","metadata":{"control_id":3}},
    \\ {"id":"d4","type":"button","metadata":{"control_id":4}},
    \\ {"id":"z3","type":"zigbee_connectivity","owner":{"rid":"dev-3","rtype":"device"},"mac_address":"00:17:88:01:00:00:00:03"},
    \\ {"id":"sw3","type":"behavior_instance","script_id":"script-acc","metadata":{"name":"Bedside"},"configuration":{
    \\  "device":{"rid":"dev-3","rtype":"device"},"model_id":"RWL022","buttons":{
    \\   "d1":{"where":[{"group":{"rid":"study","rtype":"room"}}],
    \\    "on_short_release":{"recall_single_extended":{"actions":[{"action":{"recall":{"rid":"relax","rtype":"scene"}}}],"with_off":{"enabled":true}}}},
    \\   "d2":{"on_repeat":{"action":"dim_up"},"where":[{"group":{"rid":"study","rtype":"room"}}]},
    \\   "d3":{"on_repeat":{"action":"dim_down"},"where":[{"group":{"rid":"study","rtype":"room"}}]},
    \\   "d4":{"where":[{"group":{"rid":"home","rtype":"bridge_home"}}],
    \\    "on_short_release":{"recall_single_extended":{"actions":[{"action":{"recall":{"rid":"bright","rtype":"scene"}}}],"with_off":{"enabled":false}}}}
    \\ }}},
    \\ {"id":"sw2","type":"behavior_instance","script_id":"script-acc","metadata":{"name":"Stairs"},"configuration":{
    \\  "device":{"rid":"dev-2","rtype":"device"},"model_id":"RWL022","buttons":{
    \\   "c1":{"where":[{"group":{"rid":"study","rtype":"room"}},{"group":{"rid":"upstairs","rtype":"zone"}}],
    \\    "on_short_release":{"recall_single_extended":{"actions":[{"action":{"recall":{"rid":"relax","rtype":"scene"}}},{"action":{"recall":{"rid":"dim-up","rtype":"scene"}}}],"with_off":{"enabled":true}}}},
    \\   "c2":{"on_repeat":{"action":"dim_up"},"where":[{"group":{"rid":"study","rtype":"room"}}]},
    \\   "c3":{"on_repeat":{"action":"dim_down"},"where":[{"group":{"rid":"study","rtype":"room"}}]},
    \\   "c4":{"where":[{"group":{"rid":"upstairs","rtype":"zone"}},{"group":{"rid":"study","rtype":"room"}}],
    \\    "on_short_release":{"recall_single_extended":{"actions":[{"action":{"recall":{"rid":"bright","rtype":"scene"}}},{"action":{"recall":{"rid":"bright-up","rtype":"scene"}}}],"with_off":{"enabled":false}}}}
    \\ }}},
    \\ {"id":"b1","type":"button","metadata":{"control_id":1}},
    \\ {"id":"b2","type":"button","metadata":{"control_id":2}},
    \\ {"id":"b3","type":"button","metadata":{"control_id":3}},
    \\ {"id":"b4","type":"button","metadata":{"control_id":4}},
    \\ {"id":"z1","type":"zigbee_connectivity","owner":{"rid":"dev-1","rtype":"device"},"mac_address":"00:17:88:01:aa:bb:cc:dd"},
    \\ {"id":"sw1","type":"behavior_instance","script_id":"script-acc","metadata":{"name":"Dimmer "},"configuration":{
    \\  "device":{"rid":"dev-1","rtype":"device"},"model_id":"RWL022","buttons":{
    \\   "b1":{"on_long_press":{"action":"do_nothing"},"where":[{"group":{"rid":"study","rtype":"room"}}],
    \\    "on_short_release":{"time_based_extended":{"slots":[{},{},{}],"with_off":{"enabled":true}}}},
    \\   "b2":{"on_repeat":{"action":"dim_up"},"where":[{"group":{"rid":"study","rtype":"room"}}]},
    \\   "b3":{"on_repeat":{"action":"dim_down"},"where":[{"group":{"rid":"study","rtype":"room"}}]},
    \\   "b4":{"where":[{"group":{"rid":"study","rtype":"room"}}],
    \\    "on_short_release":{"recall_single_extended":{"actions":[{"action":{"recall":{"rid":"bright","rtype":"scene"}}}],"with_off":{"enabled":false}}}}
    \\ }}},
    \\ {"id":"dial","type":"behavior_instance","script_id":"script-acc","metadata":{"name":"Dial"},"configuration":{
    \\  "device":{"rid":"dev-1","rtype":"device"},"rotaries":{},"buttons":{"b1":{},"b2":{},"b3":{},"b4":{}}}},
    \\ {"id":"motion","type":"behavior_instance","script_id":"script-acc","metadata":{"name":"Sensor"},"configuration":{"motion":{}}}
    \\]}
;

test "parse finds a wall dimmer and says what its buttons do, and leaves out other controllers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const found = try parse(arena.allocator(), fixture);
    try testing.expectEqual(@as(usize, 3), found.switches.len);
    const sw = named(found, "Dimmer");
    try testing.expectEqualStrings("Dimmer", sw.name);
    try testing.expectEqualStrings("00:17:88:01:aa:bb:cc:dd", sw.dev);
    try testing.expectEqualStrings("Study", sw.group);
    try testing.expectEqualStrings("by time of day, 3 scenes", sw.top.text);
    try testing.expect(sw.top.scene == null);
    try testing.expect(sw.top.with_off);
    try testing.expectEqualStrings("Bright", sw.bottom.scene.?);
    try testing.expect(!sw.bottom.with_off);
    try testing.expect(!sw.dim_tap_or_hold);
    try testing.expectEqualStrings("hold only", sw.dim_text);
}

test "layoutBody changes what it's told, and a read of the result says so" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const found = try parse(a, fixture);
    const ids = try buttonIds(a, fixture, found);
    const body = try layoutBody(a, found, named(found, "Dimmer"), ids, .{ .top = "Relax", .dim_tap_or_hold = true });

    const written = try std.json.parseFromSliceLeaky(Value, a, body, .{});
    const buttons = written.object.get("configuration").?.object.get("buttons").?.object;
    const top = buttons.get("b1").?.object;
    // What wasn't mentioned is still there.
    try testing.expect(top.contains("on_long_press"));
    try testing.expect(top.contains("where"));
    try testing.expect(written.object.get("configuration").?.object.contains("device"));
    const single = top.get("on_short_release").?.object.get("recall_single_extended").?.object;
    try testing.expect(single.get("with_off").?.object.get("enabled").?.bool);
    try testing.expectEqualStrings("dim_up", buttons.get("b2").?.object.get("on_short_release").?.object.get("action").?.string);
    try testing.expectEqualStrings("dim_down", buttons.get("b3").?.object.get("on_repeat").?.object.get("action").?.string);
    // The bottom was left alone.
    try testing.expectEqualStrings("bright", buttons.get("b4").?.object.get("on_short_release").?.object.get("recall_single_extended").?.object.get("actions").?.array.items[0].object.get("action").?.object.get("recall").?.object.get("rid").?.string);

    // The same file, with that written back, reads as the new layout.
    var replaced: std.Io.Writer.Allocating = .init(a);
    const original = try std.json.parseFromSliceLeaky(Value, a, fixture, .{});
    for (original.object.get("data").?.array.items) |*item| {
        if (std.mem.eql(u8, item.object.get("id").?.string, "sw1")) {
            try item.object.put(a, "configuration", written.object.get("configuration").?);
        }
    }
    try std.json.Stringify.value(original, .{}, &replaced.writer);
    const after = named(try parse(a, replaced.written()), "Dimmer");
    try testing.expectEqualStrings("Relax", after.top.scene.?);
    try testing.expect(after.top.with_off);
    try testing.expect(after.dim_tap_or_hold);
}

test "a scene that isn't where the switch acts, or is there twice, is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const found = try parse(a, fixture);
    const sw = named(found, "Dimmer");
    var trouble: Trouble = undefined;
    try testing.expectEqualStrings("relax", (try findScenes(a, found, sw, sw.top_where, "Relax", &trouble))[0]);
    try testing.expectError(error.SceneNotFound, findScenes(a, found, sw, sw.top_where, "Hall only", &trouble));
    try testing.expectEqualStrings("Study", trouble.group.?.name);
    try testing.expectError(error.AmbiguousScene, findScenes(a, found, sw, sw.top_where, "Twin", &trouble));
}

test "a button over a room and a zone reads as one scene name only when each has its own" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const found = try parse(arena.allocator(), fixture);
    const sw = named(found, "Stairs");
    try testing.expectEqualStrings("Stairs", sw.name);
    try testing.expectEqual(@as(usize, 2), sw.top_where.len);
    try testing.expectEqualStrings("Upstairs", sw.top_where[1].name);
    // Relax in one and Dim in the other is two things, not one scene.
    try testing.expect(sw.top.scene == null);
    try testing.expectEqualStrings("several actions", sw.top.text);
    // Bright in each, listed in the other order from `where`, is Bright.
    try testing.expectEqualStrings("Bright", sw.bottom.scene.?);
}

test "a layout over a room and a zone writes a scene for each, and reads back as that name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const found = try parse(a, fixture);
    const ids = try buttonIds(a, fixture, found);
    const sw = named(found, "Stairs");

    // Upstairs has no Relax, and the refusal names it.
    var trouble: Trouble = undefined;
    try testing.expectError(error.SceneNotFound, findScenes(a, found, sw, sw.top_where, "Relax", &trouble));
    try testing.expectEqualStrings("Upstairs", trouble.group.?.name);
    try testing.expectError(error.SceneNotFound, layoutBody(a, found, sw, ids, .{ .top = "Relax" }));

    const body = try layoutBody(a, found, sw, ids, .{ .top = "Bright" });
    const written = try std.json.parseFromSliceLeaky(Value, a, body, .{});
    const top = written.object.get("configuration").?.object.get("buttons").?.object.get("c1").?.object;
    const actions = top.get("on_short_release").?.object.get("recall_single_extended").?.object.get("actions").?.array.items;
    try testing.expectEqual(@as(usize, 2), actions.len);
    // In `where`'s order: the room's scene, then the zone's.
    try testing.expectEqualStrings("bright", actions[0].object.get("action").?.object.get("recall").?.object.get("rid").?.string);
    try testing.expectEqualStrings("bright-up", actions[1].object.get("action").?.object.get("recall").?.object.get("rid").?.string);

    var replaced: std.Io.Writer.Allocating = .init(a);
    const original = try std.json.parseFromSliceLeaky(Value, a, fixture, .{});
    for (original.object.get("data").?.array.items) |*item| {
        if (std.mem.eql(u8, item.object.get("id").?.string, "sw2")) {
            try item.object.put(a, "configuration", written.object.get("configuration").?);
        }
    }
    try std.json.Stringify.value(original, .{}, &replaced.writer);
    const after = named(try parse(a, replaced.written()), "Stairs");
    try testing.expectEqualStrings("Bright", after.top.scene.?);
    try testing.expect(after.top.with_off);
}

test "a button on the whole house reads as such, and the layout narrows it to the switch's own room" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const found = try parse(a, fixture);
    const ids = try buttonIds(a, fixture, found);
    const sw = named(found, "Bedside");
    try testing.expectEqualStrings("the whole house", sw.bottom_where[0].name);
    try testing.expect(sw.bottom.scene == null);
    try testing.expectEqualStrings("Bright, on the whole house", sw.bottom.text);

    const where = try writeWhere(sw, sw.bottom_where);
    try testing.expectEqualStrings("Study", where[0].name);
    const body = try layoutBody(a, found, sw, ids, .{ .bottom = "Bright" });
    const written = try std.json.parseFromSliceLeaky(Value, a, body, .{});
    const bottom = written.object.get("configuration").?.object.get("buttons").?.object.get("d4").?.object;
    const entry = bottom.get("where").?.array.items[0].object.get("group").?.object;
    try testing.expectEqualStrings("study", entry.get("rid").?.string);
    try testing.expectEqualStrings("room", entry.get("rtype").?.string);

    var replaced: std.Io.Writer.Allocating = .init(a);
    const original = try std.json.parseFromSliceLeaky(Value, a, fixture, .{});
    for (original.object.get("data").?.array.items) |*item| {
        if (std.mem.eql(u8, item.object.get("id").?.string, "sw3")) {
            try item.object.put(a, "configuration", written.object.get("configuration").?);
        }
    }
    try std.json.Stringify.value(original, .{}, &replaced.writer);
    try testing.expectEqualStrings("Bright", named(try parse(a, replaced.written()), "Bedside").bottom.scene.?);
}

test "a zone with no scene of the name takes the switch's own room's, as it always has" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const found = try parse(a, fixture);
    const sw = named(found, "Dimmer");
    const zone = [_]Group{.{ .id = "upstairs", .name = "Upstairs", .rtype = "zone" }};
    var trouble: Trouble = undefined;
    try testing.expectEqualStrings("relax", (try findScenes(a, found, sw, &zone, "Relax", &trouble))[0]);
}

test "a layout with a where points every button at it, from that group's own scenes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const found = try parse(a, fixture);
    const ids = try buttonIds(a, fixture, found);
    const upstairs: Group = .{ .id = "upstairs", .name = "Upstairs", .rtype = "zone" };
    // The switch's own room has a Relax; Upstairs hasn't, and nothing falls back to it.
    try testing.expectError(error.SceneNotFound, layoutBody(a, found, named(found, "Dimmer"), ids, .{ .top = "Relax", .where = upstairs }));
    const body = try layoutBody(a, found, named(found, "Dimmer"), ids, .{ .top = "Dim", .bottom = "Bright", .dim_tap_or_hold = true, .where = upstairs });
    var replaced: std.Io.Writer.Allocating = .init(a);
    const written = try std.json.parseFromSliceLeaky(Value, a, body, .{});
    const original = try std.json.parseFromSliceLeaky(Value, a, fixture, .{});
    for (original.object.get("data").?.array.items) |*item| {
        if (std.mem.eql(u8, item.object.get("id").?.string, "sw1")) try item.object.put(a, "configuration", written.object.get("configuration").?);
    }
    try std.json.Stringify.value(original, .{}, &replaced.writer);
    const after = named(try parse(a, replaced.written()), "Dimmer");
    for ([_][]const Group{ after.top_where, after.dim_where, after.bottom_where }) |w| {
        try testing.expectEqual(@as(usize, 1), w.len);
        try testing.expectEqualStrings("upstairs", w[0].id);
    }
    try testing.expectEqualStrings("Dim", after.top.scene.?);
    try testing.expectEqualStrings("Bright", after.bottom.scene.?);

    // A bottom left alone keeps its own where: a fan button runs a routine.
    const kept = try layoutBody(a, found, named(found, "Dimmer"), ids, .{ .top = "Dim", .where = upstairs });
    const kept_buttons = (try std.json.parseFromSliceLeaky(Value, a, kept, .{})).object.get("configuration").?.object.get("buttons").?.object;
    try testing.expectEqualStrings("study", kept_buttons.get("b4").?.object.get("where").?.array.items[0].object.get("group").?.object.get("rid").?.string);
}

const max_fixture =
    \\{"errors":[],"data":[
    \\ {"id":"room","type":"room","metadata":{"name":"Hall"},"children":[{"rid":"dev-a","rtype":"device"},{"rid":"dev-b","rtype":"device"},{"rid":"dev-c","rtype":"device"},{"rid":"dev-d","rtype":"device"}]},
    \\ {"id":"zone","type":"zone","metadata":{"name":"Lamps"},"children":[{"rid":"lb","rtype":"light"}]},
    \\ {"id":"la","type":"light","owner":{"rid":"dev-a","rtype":"device"},"dimming":{"brightness":5},"color_temperature":{"mirek":300,"mirek_schema":{"mirek_minimum":153,"mirek_maximum":454}}},
    \\ {"id":"lb","type":"light","owner":{"rid":"dev-b","rtype":"device"},"dimming":{"brightness":5},"color":{"xy":{"x":0.5,"y":0.4}}},
    \\ {"id":"lc","type":"light","owner":{"rid":"dev-c","rtype":"device"},"dimming":{"brightness":5},"color_temperature":{"mirek":null,"mirek_schema":{"mirek_minimum":300,"mirek_maximum":454}}},
    \\ {"id":"ld","type":"light","owner":{"rid":"dev-d","rtype":"device"}},
    \\ {"id":"old-max","type":"scene","group":{"rid":"zone","rtype":"zone"},"metadata":{"name":"Max"},"actions":[
    \\  {"target":{"rid":"lb","rtype":"light"},"action":{"on":{"on":true},"dimming":{"brightness":100.0},"color":{"xy":{"x":0.3805,"y":0.3768}}}}]}
    \\]}
;

test "Max is every light on at full, at 4000 K or its nearest, and is left alone once right" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const room = try maxScene(a, max_fixture, .{ .id = "room", .name = "Hall", .rtype = "room" });
    try testing.expect(room.id == null);
    try testing.expectEqual(@as(usize, 4), room.lights);
    const body = room.body.?;
    try testing.expect(std.mem.indexOf(u8, body, "\"name\":\"Max\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"group\":{\"rid\":\"room\",\"rtype\":\"room\"}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"rid\":\"la\",\"rtype\":\"light\"},\"action\":{\"on\":{\"on\":true},\"dimming\":{\"brightness\":100},\"color_temperature\":{\"mirek\":250}}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"rid\":\"lb\",\"rtype\":\"light\"},\"action\":{\"on\":{\"on\":true},\"dimming\":{\"brightness\":100},\"color\":{\"xy\":{\"x\":0.3805,\"y\":0.3768}}}") != null);
    // Its warmest is 300: the nearest it can get.
    try testing.expect(std.mem.indexOf(u8, body, "\"mirek\":300") != null);
    // An on/off light is only switched on.
    try testing.expect(std.mem.indexOf(u8, body, "\"rid\":\"ld\",\"rtype\":\"light\"},\"action\":{\"on\":{\"on\":true}}}") != null);
    _ = try std.json.parseFromSliceLeaky(Value, a, body, .{});

    // The zone's Max already says this, so there's nothing to write.
    const zone = try maxScene(a, max_fixture, .{ .id = "zone", .name = "Lamps", .rtype = "zone" });
    try testing.expectEqualStrings("old-max", zone.id.?);
    try testing.expect(zone.body == null);

    // Wrong, it's rewritten in place rather than added again.
    const off = try std.mem.replaceOwned(u8, a, max_fixture, "\"brightness\":100.0", "\"brightness\":40.0");
    const fix = try maxScene(a, off, .{ .id = "zone", .name = "Lamps", .rtype = "zone" });
    try testing.expectEqualStrings("old-max", fix.id.?);
    try testing.expect(std.mem.startsWith(u8, fix.body.?, "{\"actions\":["));
}

test "groups say which devices' lights each room and zone holds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\{"errors":[],"data":[
        \\ {"id":"room","type":"room","metadata":{"name":"Hall"},"children":[{"rid":"dev-a","rtype":"device"},{"rid":"dev-s","rtype":"device"}]},
        \\ {"id":"zone","type":"zone","metadata":{"name":"Hall"},"children":[{"rid":"la","rtype":"light"}]},
        \\ {"id":"la","type":"light","owner":{"rid":"dev-a","rtype":"device"}},
        \\ {"id":"za","type":"zigbee_connectivity","owner":{"rid":"dev-a","rtype":"device"},"mac_address":"00:17:88:01:00:00:00:AA"},
        \\ {"id":"zs","type":"zigbee_connectivity","owner":{"rid":"dev-s","rtype":"device"},"mac_address":"00:17:88:01:00:00:00:05"}
        \\]}
    ;
    const g = try groups(a, text);
    // A room and a zone can share a name, so each is asked for by both.
    const room = g.named("Hall", "room").?;
    try testing.expectEqual(@as(usize, 1), room.devs.len); // the sensor has no light
    try testing.expectEqualStrings("00:17:88:01:00:00:00:aa", room.devs[0]);
    try testing.expectEqualStrings("00:17:88:01:00:00:00:aa", g.named("Hall", "zone").?.devs[0]);
    try testing.expectEqual(@as(usize, 1), g.light_devs.len);
}
