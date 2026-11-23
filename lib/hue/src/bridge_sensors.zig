//! A motion sensor's timetable on the Bridge, in and out of CLIP v2's behaviour format,
//! and the scene copies a sensor acting on part of a room recalls.
//!
//! The Bridge publishes no schema for a sensor's `configuration`, so the shapes here
//! are the ones its own sensors hold: one `Hue Accessories` instance per sensor, whose
//! `motion` holds `where` and `when.timeslots`, and whose `light_level` says when it's
//! dark. A write starts from the sensor's whole configuration and replaces only those,
//! so a field this file doesn't know about survives it. Pure: JSON in, JSON out.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_get = @import("json_get").json_get;

/// When the sensor counts as dark.
pub const Dark = union(enum) {
    /// Between sunset and sunrise, from the Bridge's location.
    sunset,
    /// Below this light level, read by the sensor itself.
    below: u32,

    pub fn eql(a: Dark, b: Dark) bool {
        return switch (a) {
            .sunset => b == .sunset,
            .below => |n| b == .below and b.below == n,
        };
    }
};

/// One period of the timetable, from its start until the next one's.
pub const Slot = struct {
    hour: u8,
    minute: u8,
    /// The scene recalled on motion in the dark; null does nothing.
    scene: ?[]const u8 = null,
    /// Minutes without motion before its lights go off; null leaves them on.
    off_after: ?u32 = null,
    /// Lights already on are left alone, by the scene and by the off.
    do_not_disturb: bool = false,

    pub fn eql(a: Slot, b: Slot) bool {
        return a.hour == b.hour and a.minute == b.minute and a.off_after == b.off_after and
            a.do_not_disturb == b.do_not_disturb and optEql(a.scene, b.scene);
    }
};

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

pub const Sensor = struct {
    /// The `behavior_instance`: what a write goes to.
    instance: []const u8,
    dev: []const u8,
    name: []const u8,
    /// The groups its motion acts on, by id.
    where: []const []const u8,
    /// Null when `light_level` is in a form this file doesn't know.
    dark: ?Dark,
    /// Null when a timeslot is in a form this file doesn't know: it then differs from
    /// anything wanted, and a write replaces it.
    slots: ?[]const Slot,
    /// The sensor's own light level service, for a threshold it doesn't have yet.
    light_level: ?[]const u8,
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

fn items(arena: Allocator, resources: []const u8) ![]const Value {
    const root = try std.json.parseFromSliceLeaky(Value, arena, resources, .{});
    return (try json_get.Array(root.object, "data")).items;
}

/// Every motion sensor's behaviour in a `/clip/v2/resource` reply. Strings and
/// configurations live in `arena`.
pub fn parse(arena: Allocator, resources: []const u8) ![]const Sensor {
    const all = try items(arena, resources);
    var accessories: std.StringHashMapUnmanaged(void) = .empty;
    var macs: std.StringHashMapUnmanaged([]const u8) = .empty;
    var light_level: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (all) |item| {
        const o = object(item) orelse continue;
        const id = json_get.optionalString(o, "id") orelse continue;
        if (typeIs(o, "behavior_script")) {
            if (std.mem.eql(u8, nameOf(o), "Hue Accessories")) try accessories.put(arena, id, {});
            continue;
        }
        const owner = json_get.optionalObject(o, "owner") orelse continue;
        const device = json_get.optionalString(owner, "rid") orelse continue;
        if (typeIs(o, "zigbee_connectivity")) {
            const mac = json_get.optionalString(o, "mac_address") orelse continue;
            try macs.put(arena, device, try std.ascii.allocLowerString(arena, mac));
        } else if (typeIs(o, "light_level")) {
            try light_level.put(arena, device, id);
        }
    }
    var out: std.ArrayList(Sensor) = .empty;
    for (all) |item| {
        const o = object(item) orelse continue;
        if (!typeIs(o, "behavior_instance")) continue;
        if (!accessories.contains(json_get.optionalString(o, "script_id") orelse continue)) continue;
        const configuration = o.get("configuration") orelse continue;
        const config = object(configuration) orelse continue;
        const motion = json_get.optionalObject(config, "motion") orelse continue;
        const source = json_get.optionalObject(config, "source") orelse continue;
        const device = json_get.optionalString(source, "rid") orelse continue;
        var where: std.ArrayList([]const u8) = .empty;
        if (json_get.optionalArray(motion, "where")) |w| for (w.items) |entry| {
            const e = object(entry) orelse continue;
            const g = json_get.optionalObject(e, "group") orelse continue;
            try where.append(arena, json_get.optionalString(g, "rid") orelse continue);
        };
        try out.append(arena, .{
            .instance = json_get.optionalString(o, "id") orelse continue,
            .dev = macs.get(device) orelse continue,
            .name = nameOf(o),
            .where = where.items,
            .dark = darkOf(config),
            .slots = try slotsOf(arena, motion),
            .light_level = light_level.get(device),
            .configuration = configuration,
        });
    }
    return out.items;
}

fn darkOf(config: std.json.ObjectMap) ?Dark {
    const ll = json_get.optionalObject(config, "light_level") orelse return null;
    const daylight = json_get.optionalObject(ll, "daylight") orelse return null;
    if (daylight.contains("sunrise_sunset")) return .sunset;
    const ds = json_get.optionalObject(daylight, "daylight_sensitivity") orelse return null;
    const settings = json_get.optionalObject(ds, "settings") orelse return null;
    const n = json_get.optionalInt(settings, "dark_threshold") orelse return null;
    if (n <= 0 or n > std.math.maxInt(u32)) return null;
    return .{ .below = @intCast(n) };
}

/// The one action of a `recall_single` list: a scene's id, a plain action's name, or
/// null for anything else.
const Action = union(enum) { scene: []const u8, plain: []const u8 };

fn actionOf(holder: std.json.ObjectMap) ?Action {
    const list = json_get.optionalArray(holder, "recall_single") orelse return null;
    if (list.items.len != 1) return null;
    const entry = object(list.items[0]) orelse return null;
    const action = entry.get("action") orelse return null;
    switch (action) {
        .string => |s| return .{ .plain = s },
        .object => |a| {
            const recall = json_get.optionalObject(a, "recall") orelse return null;
            if (!std.mem.eql(u8, json_get.optionalString(recall, "rtype") orelse "", "scene")) return null;
            return .{ .scene = json_get.optionalString(recall, "rid") orelse return null };
        },
        else => return null,
    }
}

fn slotsOf(arena: Allocator, motion: std.json.ObjectMap) !?[]const Slot {
    const when = json_get.optionalObject(motion, "when") orelse return null;
    const timeslots = json_get.optionalArray(when, "timeslots") orelse return null;
    const out = try arena.alloc(Slot, timeslots.items.len);
    for (timeslots.items, out) |item, *slot| {
        const t = object(item) orelse return null;
        const start = json_get.optionalObject(t, "start_time") orelse return null;
        if (!std.mem.eql(u8, json_get.optionalString(start, "type") orelse "", "time")) return null;
        const time = json_get.optionalObject(start, "time") orelse return null;
        const hour = json_get.optionalInt(time, "hour") orelse return null;
        const minute = json_get.optionalInt(time, "minute") orelse return null;
        if (hour < 0 or hour > 23 or minute < 0 or minute > 59) return null;
        const on = json_get.optionalObject(t, "on_motion") orelse return null;
        const scene: ?[]const u8 = switch (actionOf(on) orelse return null) {
            .scene => |id| id,
            .plain => |p| if (std.mem.eql(u8, p, "do_nothing")) null else return null,
        };
        const no = json_get.optionalObject(t, "on_no_motion") orelse return null;
        const off_after: ?u32 = switch (actionOf(no) orelse return null) {
            .scene => return null,
            .plain => |p| if (std.mem.eql(u8, p, "do_nothing")) null else if (std.mem.eql(u8, p, "all_off")) blk: {
                const after = json_get.optionalObject(no, "after") orelse return null;
                const m = json_get.optionalInt(after, "minutes") orelse return null;
                if (m <= 0 or m > std.math.maxInt(u32)) return null;
                break :blk @intCast(m);
            } else return null,
        };
        slot.* = .{
            .hour = @intCast(hour),
            .minute = @intCast(minute),
            .scene = scene,
            .off_after = off_after,
            .do_not_disturb = json_get.optionalBool(t, "do_not_disturb") orelse false,
        };
    }
    return out;
}

/// What a sensor should do: the group it acts on, and its timetable by scene id.
pub const Want = struct {
    group_id: []const u8,
    /// `room` or `zone`.
    group_rtype: []const u8,
    dark: Dark,
    slots: []const Slot,
};

/// Whether the sensor already does what's wanted.
pub fn matches(s: Sensor, want: Want) bool {
    if (s.where.len != 1 or !std.mem.eql(u8, s.where[0], want.group_id)) return false;
    const dark = s.dark orelse return false;
    if (!dark.eql(want.dark)) return false;
    const slots = s.slots orelse return false;
    if (slots.len != want.slots.len) return false;
    // A single period runs round the clock, whenever it says it starts.
    if (slots.len == 1) {
        var a = slots[0];
        a.hour = want.slots[0].hour;
        a.minute = want.slots[0].minute;
        return a.eql(want.slots[0]);
    }
    for (slots, want.slots) |a, b| if (!a.eql(b)) return false;
    return true;
}

/// The Hue app's offset for a light-level threshold, used where the sensor has none.
const DEFAULT_OFFSET: i64 = 7000;
/// A timeslot that leaves its lights on still carries a wait, as the app's do.
const IDLE_MINUTES: u32 = 10;

pub const BodyError = error{ NotASensor, NoLightLevel } || Allocator.Error || std.Io.Writer.Error;

/// `PUT /behavior_instance/{id}`'s body: the sensor's whole configuration with
/// `motion.where`, `motion.when.timeslots` and `light_level` replaced.
pub fn body(arena: Allocator, s: Sensor, want: Want) BodyError![]const u8 {
    const config = object(s.configuration) orelse return error.NotASensor;
    const motion = json_get.optionalObject(config, "motion") orelse return error.NotASensor;
    var aw: std.Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    try jw.beginObject();
    try jw.objectField("configuration");
    try jw.beginObject();
    var it = config.iterator();
    var wrote_light_level = false;
    while (it.next()) |e| {
        const key = e.key_ptr.*;
        try jw.objectField(key);
        if (std.mem.eql(u8, key, "motion")) {
            try writeMotion(&jw, motion, want);
        } else if (std.mem.eql(u8, key, "light_level")) {
            try writeLightLevel(&jw, config, s, want.dark);
            wrote_light_level = true;
        } else try jw.write(e.value_ptr.*);
    }
    if (!wrote_light_level) {
        try jw.objectField("light_level");
        try writeLightLevel(&jw, config, s, want.dark);
    }
    try jw.endObject();
    try jw.endObject();
    return aw.written();
}

fn writeMotion(jw: *std.json.Stringify, motion: std.json.ObjectMap, want: Want) !void {
    try jw.beginObject();
    var it = motion.iterator();
    while (it.next()) |e| {
        const key = e.key_ptr.*;
        if (std.mem.eql(u8, key, "where") or std.mem.eql(u8, key, "when")) continue;
        try jw.objectField(key);
        try jw.write(e.value_ptr.*);
    }
    try jw.objectField("where");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("group");
    try jw.beginObject();
    try jw.objectField("rid");
    try jw.write(want.group_id);
    try jw.objectField("rtype");
    try jw.write(want.group_rtype);
    try jw.endObject();
    try jw.endObject();
    try jw.endArray();
    try jw.objectField("when");
    try jw.beginObject();
    if (json_get.optionalObject(motion, "when")) |when| {
        var wi = when.iterator();
        while (wi.next()) |e| {
            if (std.mem.eql(u8, e.key_ptr.*, "timeslots")) continue;
            try jw.objectField(e.key_ptr.*);
            try jw.write(e.value_ptr.*);
        }
    }
    try jw.objectField("timeslots");
    try jw.beginArray();
    for (want.slots) |slot| try writeSlot(jw, slot);
    try jw.endArray();
    try jw.endObject();
    try jw.endObject();
}

fn writeRecall(jw: *std.json.Stringify, scene: ?[]const u8, plain: []const u8) !void {
    try jw.objectField("recall_single");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("action");
    if (scene) |id| {
        try jw.beginObject();
        try jw.objectField("recall");
        try jw.beginObject();
        try jw.objectField("rid");
        try jw.write(id);
        try jw.objectField("rtype");
        try jw.write("scene");
        try jw.endObject();
        try jw.endObject();
    } else try jw.write(plain);
    try jw.endObject();
    try jw.endArray();
}

fn writeSlot(jw: *std.json.Stringify, slot: Slot) !void {
    try jw.beginObject();
    if (slot.do_not_disturb) {
        try jw.objectField("do_not_disturb");
        try jw.write(true);
    }
    try jw.objectField("on_motion");
    try jw.beginObject();
    try writeRecall(jw, slot.scene, "do_nothing");
    try jw.endObject();
    try jw.objectField("on_no_motion");
    try jw.beginObject();
    try jw.objectField("after");
    try jw.beginObject();
    try jw.objectField("minutes");
    try jw.write(slot.off_after orelse IDLE_MINUTES);
    try jw.endObject();
    try writeRecall(jw, null, if (slot.off_after != null) "all_off" else "do_nothing");
    try jw.endObject();
    try jw.objectField("start_time");
    try jw.beginObject();
    try jw.objectField("time");
    try jw.beginObject();
    try jw.objectField("hour");
    try jw.write(slot.hour);
    try jw.objectField("minute");
    try jw.write(slot.minute);
    try jw.endObject();
    try jw.objectField("type");
    try jw.write("time");
    try jw.endObject();
    try jw.endObject();
}

fn writeLightLevel(jw: *std.json.Stringify, config: std.json.ObjectMap, s: Sensor, dark: Dark) !void {
    try jw.beginObject();
    try jw.objectField("daylight");
    try jw.beginObject();
    switch (dark) {
        .sunset => {
            try jw.objectField("sunrise_sunset");
            try jw.beginObject();
            try jw.objectField("sunrise_offset");
            try jw.beginObject();
            try jw.objectField("hours");
            try jw.write(0);
            try jw.endObject();
            try jw.objectField("sunset_offset");
            try jw.beginObject();
            try jw.objectField("hours");
            try jw.write(0);
            try jw.endObject();
            try jw.endObject();
        },
        .below => |n| {
            // The sensor's own service and offset where it has a threshold already.
            var service: ?Value = null;
            var offset: i64 = DEFAULT_OFFSET;
            if (json_get.optionalObject(config, "light_level")) |ll| if (json_get.optionalObject(ll, "daylight")) |d| if (json_get.optionalObject(d, "daylight_sensitivity")) |ds| {
                service = ds.get("light_level_service");
                if (json_get.optionalObject(ds, "settings")) |st| offset = json_get.optionalInt(st, "offset") orelse DEFAULT_OFFSET;
            };
            try jw.objectField("daylight_sensitivity");
            try jw.beginObject();
            try jw.objectField("light_level_service");
            if (service) |v| try jw.write(v) else {
                const id = s.light_level orelse return error.NoLightLevel;
                try jw.beginObject();
                try jw.objectField("rid");
                try jw.write(id);
                try jw.objectField("rtype");
                try jw.write("light_level");
                try jw.endObject();
            }
            try jw.objectField("settings");
            try jw.beginObject();
            try jw.objectField("dark_threshold");
            try jw.write(n);
            try jw.objectField("offset");
            try jw.write(offset);
            try jw.endObject();
            try jw.endObject();
        },
    }
    try jw.endObject();
    try jw.endObject();
}

/// A scene and the IEEE addresses of the devices whose lights it turns on.
pub const SceneLights = struct {
    id: []const u8,
    group_id: []const u8,
    name: []const u8,
    lit: []const []const u8,
};

/// Every scene, with what it lights.
pub fn scenes(arena: Allocator, resources: []const u8) ![]const SceneLights {
    const all = try items(arena, resources);
    const owners = try lightOwners(arena, all);
    var out: std.ArrayList(SceneLights) = .empty;
    for (all) |item| {
        const o = object(item) orelse continue;
        if (!typeIs(o, "scene")) continue;
        const group = json_get.optionalObject(o, "group") orelse continue;
        var lit: std.ArrayList([]const u8) = .empty;
        if (json_get.optionalArray(o, "actions")) |actions| for (actions.items) |a| {
            const ao = object(a) orelse continue;
            const target = json_get.optionalObject(ao, "target") orelse continue;
            const action = json_get.optionalObject(ao, "action") orelse continue;
            const on = json_get.optionalObject(action, "on") orelse continue;
            if (!(json_get.optionalBool(on, "on") orelse false)) continue;
            const mac = owners.get(json_get.optionalString(target, "rid") orelse continue) orelse continue;
            try lit.append(arena, mac);
        };
        try out.append(arena, .{
            .id = json_get.optionalString(o, "id") orelse continue,
            .group_id = json_get.optionalString(group, "rid") orelse continue,
            .name = nameOf(o),
            .lit = lit.items,
        });
    }
    return out.items;
}

/// Each light's device's IEEE address, by light id.
fn lightOwners(arena: Allocator, all: []const Value) !std.StringHashMapUnmanaged([]const u8) {
    var macs: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (all) |item| {
        const o = object(item) orelse continue;
        if (!typeIs(o, "zigbee_connectivity")) continue;
        const owner = json_get.optionalObject(o, "owner") orelse continue;
        const mac = json_get.optionalString(o, "mac_address") orelse continue;
        try macs.put(arena, json_get.optionalString(owner, "rid") orelse continue, try std.ascii.allocLowerString(arena, mac));
    }
    var out: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (all) |item| {
        const o = object(item) orelse continue;
        if (!typeIs(o, "light")) continue;
        const owner = json_get.optionalObject(o, "owner") orelse continue;
        const mac = macs.get(json_get.optionalString(owner, "rid") orelse continue) orelse continue;
        try out.put(arena, json_get.optionalString(o, "id") orelse continue, mac);
    }
    return out;
}

/// What a zone's copy of a room scene needs: null `body` when it's already right.
pub const Copy = struct {
    /// The zone's scene of that name now, if any: a write updates it.
    id: ?[]const u8,
    /// `POST /scene` when `id` is null, else `PUT /scene/{id}`.
    body: ?[]const u8,
    lights: usize,
};

/// The scene `name` that zone `zone_id` should hold: the room scene `from_id`'s
/// actions for the zone's own lights, verbatim, so the room's values set by eye are
/// the only ones. A zone lists lights; a room's scene targets lights too.
pub fn copyScene(arena: Allocator, resources: []const u8, from_id: []const u8, zone_id: []const u8, name: []const u8) !Copy {
    const all = try items(arena, resources);
    var from: ?std.json.ObjectMap = null;
    var zone: ?std.json.ObjectMap = null;
    var existing: ?std.json.ObjectMap = null;
    var existing_id: ?[]const u8 = null;
    var owner_of: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (all) |item| {
        const o = object(item) orelse continue;
        const id = json_get.optionalString(o, "id") orelse continue;
        if (std.mem.eql(u8, id, from_id)) from = o;
        if (std.mem.eql(u8, id, zone_id)) zone = o;
        if (typeIs(o, "light")) if (json_get.optionalObject(o, "owner")) |ow| {
            try owner_of.put(arena, id, json_get.optionalString(ow, "rid") orelse continue);
        };
        if (typeIs(o, "scene") and std.mem.eql(u8, nameOf(o), name)) {
            const g = json_get.optionalObject(o, "group") orelse continue;
            if (!std.mem.eql(u8, json_get.optionalString(g, "rid") orelse "", zone_id)) continue;
            if (existing != null) return error.AmbiguousScene;
            existing = o;
            existing_id = id;
        }
    }
    const f = from orelse return error.NoScene;
    const z = zone orelse return error.NoGroup;
    // The zone's lights, whether it lists lights or their devices.
    var members: std.StringHashMapUnmanaged(void) = .empty;
    const children = json_get.optionalArray(z, "children") orelse return error.NoGroup;
    for (children.items) |c| {
        const co = object(c) orelse continue;
        const rid = json_get.optionalString(co, "rid") orelse continue;
        if (std.mem.eql(u8, json_get.optionalString(co, "rtype") orelse "", "light")) {
            try members.put(arena, rid, {});
        } else {
            var oi = owner_of.iterator();
            while (oi.next()) |e| if (std.mem.eql(u8, e.value_ptr.*, rid)) try members.put(arena, e.key_ptr.*, {});
        }
    }
    var kept: std.ArrayList(Value) = .empty;
    const actions = json_get.optionalArray(f, "actions") orelse return error.NoScene;
    for (actions.items) |a| {
        const ao = object(a) orelse continue;
        const target = json_get.optionalObject(ao, "target") orelse continue;
        if (members.contains(json_get.optionalString(target, "rid") orelse continue)) try kept.append(arena, a);
    }
    if (existing) |e| if (try sameActions(arena, e, kept.items)) return .{ .id = existing_id, .body = null, .lights = kept.items.len };

    var aw: std.Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    try jw.beginObject();
    if (existing_id == null) {
        try jw.objectField("type");
        try jw.write("scene");
        try jw.objectField("metadata");
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(name);
        try jw.endObject();
        try jw.objectField("group");
        try jw.beginObject();
        try jw.objectField("rid");
        try jw.write(zone_id);
        try jw.objectField("rtype");
        try jw.write("zone");
        try jw.endObject();
    }
    try jw.objectField("actions");
    try jw.write(kept.items);
    try jw.endObject();
    return .{ .id = existing_id, .body = aw.written(), .lights = kept.items.len };
}

/// One light's part of a scene, in a form two readings can be compared by: the
/// Bridge may reorder fields or lights, and stores what it was given otherwise.
fn summary(arena: Allocator, a: Value) !?[]const u8 {
    const ao = object(a) orelse return null;
    const target = json_get.optionalObject(ao, "target") orelse return null;
    const action = json_get.optionalObject(ao, "action") orelse return null;
    const on = if (json_get.optionalObject(action, "on")) |x| json_get.optionalBool(x, "on") orelse false else false;
    const bri: ?f64 = if (json_get.optionalObject(action, "dimming")) |d| json_get.optionalFloat(d, "brightness") else null;
    const mirek: ?i64 = if (json_get.optionalObject(action, "color_temperature")) |ct| json_get.optionalInt(ct, "mirek") else null;
    var x: ?f64 = null;
    var y: ?f64 = null;
    if (json_get.optionalObject(action, "color")) |c| if (json_get.optionalObject(c, "xy")) |p| {
        x = json_get.optionalFloat(p, "x");
        y = json_get.optionalFloat(p, "y");
    };
    const r = struct {
        fn r(v: ?f64, scale: f64) ?i64 {
            return if (v) |f| @intFromFloat(@round(f * scale)) else null;
        }
    }.r;
    return try std.fmt.allocPrint(arena, "{s} {} {?d} {?d} {?d} {?d}", .{ json_get.optionalString(target, "rid") orelse return null, on, r(bri, 100), mirek, r(x, 10000), r(y, 10000) });
}

fn sorted(arena: Allocator, actions: []const Value) !?[]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (actions) |a| try out.append(arena, (try summary(arena, a)) orelse return null);
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, p: []const u8, q: []const u8) bool {
            return std.mem.order(u8, p, q) == .lt;
        }
    }.lt);
    return out.items;
}

fn sameActions(arena: Allocator, scene: std.json.ObjectMap, want: []const Value) !bool {
    const have = json_get.optionalArray(scene, "actions") orelse return false;
    const h = (try sorted(arena, have.items)) orelse return false;
    const w = (try sorted(arena, want)) orelse return false;
    if (h.len != w.len) return false;
    for (h, w) |p, q| if (!std.mem.eql(u8, p, q)) return false;
    return true;
}

const testing = std.testing;

// A sensor as the Bridge holds one, trimmed: two periods, a threshold, and a field this
// file doesn't know (`extra`), which a write must carry along.
const fixture =
    \\{"errors":[],"data":[
    \\ {"id":"script-acc","type":"behavior_script","metadata":{"name":"Hue Accessories"}},
    \\ {"id":"dev-s","type":"device","metadata":{"name":"Kitchen sensor"}},
    \\ {"id":"zc-s","type":"zigbee_connectivity","owner":{"rid":"dev-s","rtype":"device"},"mac_address":"00:17:88:01:0B:09:EC:13"},
    \\ {"id":"ll-s","type":"light_level","owner":{"rid":"dev-s","rtype":"device"}},
    \\ {"id":"dev-l1","type":"device"},{"id":"dev-l2","type":"device"},
    \\ {"id":"zc-l1","type":"zigbee_connectivity","owner":{"rid":"dev-l1","rtype":"device"},"mac_address":"aa:00:00:00:00:00:00:01"},
    \\ {"id":"zc-l2","type":"zigbee_connectivity","owner":{"rid":"dev-l2","rtype":"device"},"mac_address":"aa:00:00:00:00:00:00:02"},
    \\ {"id":"light-1","type":"light","owner":{"rid":"dev-l1","rtype":"device"}},
    \\ {"id":"light-2","type":"light","owner":{"rid":"dev-l2","rtype":"device"}},
    \\ {"id":"room-k","type":"room","metadata":{"name":"Kitchen"},"children":[{"rid":"dev-l1","rtype":"device"},{"rid":"dev-l2","rtype":"device"}]},
    \\ {"id":"zone-k","type":"zone","metadata":{"name":"Kitchen part"},"children":[{"rid":"light-1","rtype":"light"}]},
    \\ {"id":"bright","type":"scene","group":{"rid":"room-k","rtype":"room"},"metadata":{"name":"Bright"},"actions":[
    \\   {"target":{"rid":"light-1","rtype":"light"},"action":{"on":{"on":true},"dimming":{"brightness":100.0},"color_temperature":{"mirek":370}}},
    \\   {"target":{"rid":"light-2","rtype":"light"},"action":{"on":{"on":false}}}]},
    \\ {"id":"dimmed","type":"scene","group":{"rid":"room-k","rtype":"room"},"metadata":{"name":"Dimmed"},"actions":[
    \\   {"target":{"rid":"light-1","rtype":"light"},"action":{"on":{"on":true},"dimming":{"brightness":30.0}}},
    \\   {"target":{"rid":"light-2","rtype":"light"},"action":{"on":{"on":true},"dimming":{"brightness":30.0}}}]},
    \\ {"id":"inst-s","type":"behavior_instance","script_id":"script-acc","metadata":{"name":"Kitchen "},"configuration":{
    \\   "light_level":{"daylight":{"daylight_sensitivity":{"light_level_service":{"rid":"ll-s","rtype":"light_level"},"settings":{"dark_threshold":18314,"offset":7000}}}},
    \\   "motion":{"motion_service":{"rid":"m-s","rtype":"motion"},"when":{"timeslots":[
    \\     {"do_not_disturb":true,"on_motion":{"recall_single":[{"action":{"recall":{"rid":"bright","rtype":"scene"}}}]},"on_no_motion":{"after":{"minutes":10},"recall_single":[{"action":"do_nothing"}]},"start_time":{"time":{"hour":6,"minute":30},"type":"time"}},
    \\     {"on_motion":{"recall_single":[{"action":{"recall":{"rid":"dimmed","rtype":"scene"}}}]},"on_no_motion":{"after":{"minutes":5},"recall_single":[{"action":"all_off"}]},"start_time":{"time":{"hour":23,"minute":0},"type":"time"}}]},
    \\   "where":[{"group":{"rid":"room-k","rtype":"room"}}]},
    \\   "source":{"rid":"dev-s","rtype":"device"},"extra":{"kept":1}}},
    \\ {"id":"inst-d","type":"behavior_instance","script_id":"script-acc","metadata":{"name":"A dimmer"},"configuration":{"buttons":{},"device":{"rid":"dev-l1","rtype":"device"}}}
    \\]}
;

const kitchen_slots = [_]Slot{
    .{ .hour = 6, .minute = 30, .scene = "bright", .do_not_disturb = true },
    .{ .hour = 23, .minute = 0, .scene = "dimmed", .off_after = 5 },
};

test "a sensor's timetable reads as the Bridge holds it, and a dimmer isn't a sensor" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const found = try parse(arena.allocator(), fixture);
    try testing.expectEqual(@as(usize, 1), found.len);
    const s = found[0];
    try testing.expectEqualStrings("00:17:88:01:0b:09:ec:13", s.dev);
    try testing.expectEqualStrings("Kitchen", s.name);
    try testing.expectEqualStrings("ll-s", s.light_level.?);
    try testing.expect(s.dark.?.eql(.{ .below = 18314 }));
    try testing.expectEqual(@as(usize, 2), s.slots.?.len);
    for (s.slots.?, kitchen_slots) |a, b| try testing.expect(a.eql(b));
    try testing.expect(matches(s, .{ .group_id = "room-k", .group_rtype = "room", .dark = .{ .below = 18314 }, .slots = &kitchen_slots }));
    try testing.expect(!matches(s, .{ .group_id = "zone-k", .group_rtype = "zone", .dark = .{ .below = 18314 }, .slots = &kitchen_slots }));
    try testing.expect(!matches(s, .{ .group_id = "room-k", .group_rtype = "room", .dark = .sunset, .slots = &kitchen_slots }));
    try testing.expect(!matches(s, .{ .group_id = "room-k", .group_rtype = "room", .dark = .{ .below = 18314 }, .slots = kitchen_slots[0..1] }));
}

test "a written timetable reads back as what was wanted, keeping what it doesn't know" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = (try parse(a, fixture))[0];
    const want: Want = .{ .group_id = "zone-k", .group_rtype = "zone", .dark = .sunset, .slots = &.{
        .{ .hour = 0, .minute = 0, .scene = "bright", .off_after = 10 },
    } };
    const text = try body(a, s, want);
    // Back into a resource list, as the Bridge would then report it.
    const parsed = try std.json.parseFromSliceLeaky(Value, a, text, .{});
    const again: Sensor = .{
        .instance = s.instance,
        .dev = s.dev,
        .name = s.name,
        .where = &.{"zone-k"},
        .dark = darkOf(parsed.object.get("configuration").?.object),
        .slots = try slotsOf(a, parsed.object.get("configuration").?.object.get("motion").?.object),
        .light_level = s.light_level,
        .configuration = parsed.object.get("configuration").?,
    };
    try testing.expect(matches(again, want));
    // One period is all day, so its start doesn't count; its scene still does.
    try testing.expect(matches(again, .{ .group_id = "zone-k", .group_rtype = "zone", .dark = .sunset, .slots = &.{.{ .hour = 8, .minute = 0, .scene = "bright", .off_after = 10 }} }));
    try testing.expect(!matches(again, .{ .group_id = "zone-k", .group_rtype = "zone", .dark = .sunset, .slots = &.{.{ .hour = 8, .minute = 0, .scene = "dimmed", .off_after = 10 }} }));
    try testing.expect(std.mem.indexOf(u8, text, "\"extra\":{\"kept\":1}") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"motion_service\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"where\":[{\"group\":{\"rid\":\"zone-k\",\"rtype\":\"zone\"}}]") != null);

    // A threshold keeps the sensor's own service and offset.
    const below = try body(a, s, .{ .group_id = "room-k", .group_rtype = "room", .dark = .{ .below = 9000 }, .slots = &kitchen_slots });
    try testing.expect(std.mem.indexOf(u8, below, "\"light_level_service\":{\"rid\":\"ll-s\",\"rtype\":\"light_level\"},\"settings\":{\"dark_threshold\":9000,\"offset\":7000}") != null);
    // Leaving lights on still writes a wait, and no do_not_disturb unless asked.
    try testing.expect(std.mem.indexOf(u8, below, "{\"do_not_disturb\":true,\"on_motion\"") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, below, "do_not_disturb"));
}

test "a scene's lit devices, and a zone's copy of a room scene" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const all = try scenes(a, fixture);
    for (all) |sc| if (std.mem.eql(u8, sc.id, "bright")) {
        try testing.expectEqual(@as(usize, 1), sc.lit.len);
        try testing.expectEqualStrings("aa:00:00:00:00:00:00:01", sc.lit[0]);
    };
    const copy = try copyScene(a, fixture, "bright", "zone-k", "Bright");
    try testing.expect(copy.id == null);
    try testing.expectEqual(@as(usize, 1), copy.lights);
    try testing.expect(std.mem.indexOf(u8, copy.body.?, "\"group\":{\"rid\":\"zone-k\",\"rtype\":\"zone\"}") != null);
    try testing.expect(std.mem.indexOf(u8, copy.body.?, "light-2") == null);

    // Already there and the same: nothing to write. Different: corrected in place.
    const with_copy = try std.mem.concat(a, u8, &.{ fixture[0 .. fixture.len - 2], ",{\"id\":\"zb\",\"type\":\"scene\",\"group\":{\"rid\":\"zone-k\",\"rtype\":\"zone\"},\"metadata\":{\"name\":\"Bright\"},\"actions\":[{\"target\":{\"rid\":\"light-1\",\"rtype\":\"light\"},\"action\":{\"color_temperature\":{\"mirek\":370},\"dimming\":{\"brightness\":100.0},\"on\":{\"on\":true}}}]}]}" });
    const same = try copyScene(a, with_copy, "bright", "zone-k", "Bright");
    try testing.expectEqualStrings("zb", same.id.?);
    try testing.expect(same.body == null);
    const stale = try std.mem.replaceOwned(u8, a, with_copy, "\"brightness\":100.0},\"on\"", "\"brightness\":40.0},\"on\"");
    const fix = try copyScene(a, stale, "bright", "zone-k", "Bright");
    try testing.expectEqualStrings("zb", fix.id.?);
    try testing.expect(std.mem.startsWith(u8, fix.body.?, "{\"actions\":"));
}
