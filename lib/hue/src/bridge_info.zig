//! What the Bridge is and what it holds, from one CLIP v2 resource list: its id,
//! model and software, whether an update is waiting, its Zigbee channel, the state of
//! its device search, and how many of each kind of resource it has. Pure: JSON in,
//! a struct out.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_get = @import("json_get").json_get;

pub const Counts = struct {
    devices: u32 = 0,
    lights: u32 = 0,
    rooms: u32 = 0,
    zones: u32 = 0,
    scenes: u32 = 0,
    /// `behavior_instance`: the Hue app's automations, sensors' and switches' setups among them.
    automations: u32 = 0,
};

pub const Info = struct {
    name: ?[]const u8 = null,
    bridge_id: ?[]const u8 = null,
    time_zone: ?[]const u8 = null,
    model: ?[]const u8 = null,
    product: ?[]const u8 = null,
    software: ?[]const u8 = null,
    /// `no_update`, `update_pending`, `ready_to_install` or `installing`.
    update: ?[]const u8 = null,
    /// `channel_11` and the like, as the Bridge words it.
    channel: ?[]const u8 = null,
    /// `set`, or `changing` while it moves.
    channel_status: ?[]const u8 = null,
    /// The device search's resource, and `active` or `ready`.
    discovery_id: ?[]const u8 = null,
    discovery: ?[]const u8 = null,
    counts: Counts = .{},
};

fn objectOf(v: Value) ?std.json.ObjectMap {
    return if (v == .object) v.object else null;
}

fn ownerRid(o: std.json.ObjectMap) ?[]const u8 {
    const owner = json_get.optionalObject(o, "owner") orelse return null;
    return json_get.optionalString(owner, "rid");
}

fn eql(a: ?[]const u8, b: []const u8) bool {
    return if (a) |x| std.mem.eql(u8, x, b) else false;
}

pub fn parse(arena: Allocator, resources: []const u8) !Info {
    const root = try std.json.parseFromSliceLeaky(Value, arena, resources, .{});
    const items = (try json_get.Array(objectOf(root) orelse return error.NoData, "data")).items;
    var info: Info = .{};
    // The Bridge's own device is what owns the `bridge` resource.
    var device_id: ?[]const u8 = null;
    for (items) |item| {
        const o = objectOf(item) orelse continue;
        const t = json_get.optionalString(o, "type") orelse continue;
        if (std.mem.eql(u8, t, "bridge")) {
            device_id = ownerRid(o);
            info.bridge_id = json_get.optionalString(o, "bridge_id");
            if (json_get.optionalObject(o, "time_zone")) |tz| info.time_zone = json_get.optionalString(tz, "time_zone");
        } else if (std.mem.eql(u8, t, "device")) {
            info.counts.devices += 1;
        } else if (std.mem.eql(u8, t, "light")) {
            info.counts.lights += 1;
        } else if (std.mem.eql(u8, t, "room")) {
            info.counts.rooms += 1;
        } else if (std.mem.eql(u8, t, "zone")) {
            info.counts.zones += 1;
        } else if (std.mem.eql(u8, t, "scene")) {
            info.counts.scenes += 1;
        } else if (std.mem.eql(u8, t, "behavior_instance")) {
            info.counts.automations += 1;
        } else if (std.mem.eql(u8, t, "zigbee_device_discovery")) {
            info.discovery_id = json_get.optionalString(o, "id");
            info.discovery = json_get.optionalString(o, "status");
        }
    }
    const dev = device_id orelse return info;
    for (items) |item| {
        const o = objectOf(item) orelse continue;
        const t = json_get.optionalString(o, "type") orelse continue;
        if (std.mem.eql(u8, t, "device") and eql(json_get.optionalString(o, "id"), dev)) {
            if (json_get.optionalObject(o, "metadata")) |m| info.name = json_get.optionalString(m, "name");
            if (json_get.optionalObject(o, "product_data")) |p| {
                info.model = json_get.optionalString(p, "model_id");
                info.product = json_get.optionalString(p, "product_name");
                info.software = json_get.optionalString(p, "software_version");
            }
        } else if (!eql(ownerRid(o), dev)) {
            continue;
        } else if (std.mem.eql(u8, t, "device_software_update")) {
            info.update = json_get.optionalString(o, "state");
        } else if (std.mem.eql(u8, t, "zigbee_connectivity")) {
            if (json_get.optionalObject(o, "channel")) |c| {
                info.channel = json_get.optionalString(c, "value");
                info.channel_status = json_get.optionalString(c, "status");
            }
        }
    }
    return info;
}

/// Starts the Bridge's device search, as `zigbee_device_discovery` takes it. A
/// device's serial number and install codes stay the Hue app's.
pub const SEARCH_BODY = "{\"action\":{\"action_type\":\"search\"}}";

const testing = std.testing;

test "the Bridge's facts from its own device, and a count of each kind" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const list =
        \\{"errors":[],"data":[
        \\ {"type":"bridge","id":"b1","owner":{"rid":"dev-b","rtype":"device"},"bridge_id":"001788fffe21055d","time_zone":{"time_zone":"Europe/London"}},
        \\ {"type":"device","id":"dev-b","metadata":{"name":"Hue Bridge"},"product_data":{"model_id":"BSB002","product_name":"Hue Bridge","software_version":"1.68.1968"}},
        \\ {"type":"device","id":"dev-l","metadata":{"name":"Lamp"},"product_data":{"model_id":"LTW013","software_version":"1.122.2"}},
        \\ {"type":"device_software_update","id":"u1","owner":{"rid":"dev-b","rtype":"device"},"state":"no_update","problems":[]},
        \\ {"type":"device_software_update","id":"u2","owner":{"rid":"dev-l","rtype":"device"},"state":"ready_to_install","problems":[]},
        \\ {"type":"zigbee_connectivity","id":"z1","owner":{"rid":"dev-b","rtype":"device"},"status":"connected","mac_address":"00:17:88:ff:fe:21:05:5d","channel":{"status":"set","value":"channel_25"}},
        \\ {"type":"zigbee_connectivity","id":"z2","owner":{"rid":"dev-l","rtype":"device"},"status":"connected","mac_address":"00:17:88:01:00:00:00:01"},
        \\ {"type":"light","id":"l1","owner":{"rid":"dev-l","rtype":"device"}},
        \\ {"type":"room","id":"r1"},{"type":"zone","id":"z"},{"type":"scene","id":"s1"},{"type":"scene","id":"s2"},
        \\ {"type":"behavior_instance","id":"i1"},
        \\ {"type":"zigbee_device_discovery","id":"d1","owner":{"rid":"dev-b","rtype":"device"},"status":"ready","action":{"action_type_values":["search"]}}
        \\]}
    ;
    const info = try parse(arena.allocator(), list);
    try testing.expectEqualStrings("Hue Bridge", info.name.?);
    try testing.expectEqualStrings("BSB002", info.model.?);
    try testing.expectEqualStrings("1.68.1968", info.software.?);
    // Its own update, not a lamp's.
    try testing.expectEqualStrings("no_update", info.update.?);
    try testing.expectEqualStrings("channel_25", info.channel.?);
    try testing.expectEqualStrings("set", info.channel_status.?);
    try testing.expectEqualStrings("Europe/London", info.time_zone.?);
    try testing.expectEqualStrings("d1", info.discovery_id.?);
    try testing.expectEqualStrings("ready", info.discovery.?);
    try testing.expectEqual(Counts{ .devices = 2, .lights = 1, .rooms = 1, .zones = 1, .scenes = 2, .automations = 1 }, info.counts);
}

test "a list with no bridge resource still counts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const info = try parse(arena.allocator(), "{\"errors\":[],\"data\":[{\"type\":\"scene\",\"id\":\"s\"}]}");
    try testing.expect(info.name == null);
    try testing.expectEqual(@as(u32, 1), info.counts.scenes);
}
