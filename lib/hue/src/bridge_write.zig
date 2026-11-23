//! Writing to the Bridge: one light at a time, in the house's words going in.
//!
//! The one place that knows what a write looks like in CLIP v2. Each request is a
//! connection of its own, so it blocks for a TLS handshake, and a caller with a
//! deadline runs it on a task of its own.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const tls_http = @import("tls_http");
const PowerOn = @import("houselog").settings.PowerOn;

/// Holds the application key, so a parse failure is reported by name only.
pub const Credentials = struct {
    host: []const u8,
    port: u16 = 443,
    id: []const u8,
    key: []const u8,
};

pub fn parseCredentials(arena: Allocator, text: []const u8) !Credentials {
    return std.json.parseFromSliceLeaky(Credentials, arena, text, .{ .allocate = .alloc_always });
}

/// What the Bridge said when it refused a write.
pub const Reply = tls_http.Reply;

/// `reply`, if given, holds the Bridge's reason when it refuses.
pub fn setLight(gpa: Allocator, io: Io, bridge: Credentials, light_id: []const u8, body: []const u8, reply: ?*Reply) !void {
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/clip/v2/resource/light/{s}", .{light_id});
    try tls_http.put(gpa, io, bridge.host, bridge.port, bridge.id, path, bridge.key, body, reply);
}

/// A switch or automation. `body` holds its whole `configuration`, as the Bridge
/// checks one against a schema it doesn't publish.
pub fn setBehaviour(gpa: Allocator, io: Io, bridge: Credentials, instance_id: []const u8, body: []const u8, reply: ?*Reply) !void {
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/clip/v2/resource/behavior_instance/{s}", .{instance_id});
    try tls_http.put(gpa, io, bridge.host, bridge.port, bridge.id, path, bridge.key, body, reply);
}

/// A new automation from a script; the Bridge gives it an id, which a fresh read finds.
pub fn createBehaviour(gpa: Allocator, io: Io, bridge: Credentials, body: []const u8, reply: ?*Reply) !void {
    try tls_http.post(gpa, io, bridge.host, bridge.port, bridge.id, "/clip/v2/resource/behavior_instance", bridge.key, body, reply);
}

pub fn deleteBehaviour(gpa: Allocator, io: Io, bridge: Credentials, instance_id: []const u8, reply: ?*Reply) !void {
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/clip/v2/resource/behavior_instance/{s}", .{instance_id});
    try tls_http.delete(gpa, io, bridge.host, bridge.port, bridge.id, path, bridge.key, reply);
}

/// A device, which is what identifies: a light breathes once, a sensor flashes its LED.
pub fn setDevice(gpa: Allocator, io: Io, bridge: Credentials, device_id: []const u8, body: []const u8, reply: ?*Reply) !void {
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/clip/v2/resource/device/{s}", .{device_id});
    try tls_http.put(gpa, io, bridge.host, bridge.port, bridge.id, path, bridge.key, body, reply);
}

/// Deletes a device, which un-joins it from the Bridge's network. Undone only by
/// pairing it again.
pub fn deleteDevice(gpa: Allocator, io: Io, bridge: Credentials, device_id: []const u8, reply: ?*Reply) !void {
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/clip/v2/resource/device/{s}", .{device_id});
    try tls_http.delete(gpa, io, bridge.host, bridge.port, bridge.id, path, bridge.key, reply);
}

/// The Bridge's device search, which `body` starts.
pub fn setDiscovery(gpa: Allocator, io: Io, bridge: Credentials, discovery_id: []const u8, body: []const u8, reply: ?*Reply) !void {
    var path_buf: [112]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/clip/v2/resource/zigbee_device_discovery/{s}", .{discovery_id});
    try tls_http.put(gpa, io, bridge.host, bridge.port, bridge.id, path, bridge.key, body, reply);
}

/// A new scene; the Bridge gives it an id, which a fresh read of the resource list
/// then finds by its group and name.
pub fn createScene(gpa: Allocator, io: Io, bridge: Credentials, body: []const u8, reply: ?*Reply) !void {
    try tls_http.post(gpa, io, bridge.host, bridge.port, bridge.id, "/clip/v2/resource/scene", bridge.key, body, reply);
}

pub fn setScene(gpa: Allocator, io: Io, bridge: Credentials, scene_id: []const u8, body: []const u8, reply: ?*Reply) !void {
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/clip/v2/resource/scene/{s}", .{scene_id});
    try tls_http.put(gpa, io, bridge.host, bridge.port, bridge.id, path, bridge.key, body, reply);
}

pub const IDENTIFY_BODY = "{\"identify\":{\"action\":\"identify\"}}";

/// The Bridge's id for the device the house calls `dev`: its Zigbee address, any
/// case, or `hue:<id>` for one with none. Null when the list doesn't hold it.
pub fn deviceFor(arena: Allocator, resources_json: []const u8, dev: []const u8) !?[]const u8 {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, resources_json, .{});
    const data = switch (root) {
        .object => |o| o.get("data") orelse return error.NoData,
        else => return error.NoData,
    };
    if (data != .array) return error.NoData;
    const uuid_prefix = "hue:";
    for (data.array.items) |item| {
        if (item != .object) continue;
        const o = item.object;
        const t = str(o, "type") orelse continue;
        if (std.mem.startsWith(u8, dev, uuid_prefix)) {
            if (!std.mem.eql(u8, t, "device")) continue;
            const id = str(o, "id") orelse continue;
            if (std.mem.eql(u8, id, dev[uuid_prefix.len..])) return id;
            continue;
        }
        if (!std.mem.eql(u8, t, "zigbee_connectivity")) continue;
        const mac = str(o, "mac_address") orelse continue;
        if (!std.ascii.eqlIgnoreCase(mac, dev)) continue;
        const owner = o.get("owner") orelse continue;
        if (owner != .object) continue;
        return str(owner.object, "rid");
    }
    return null;
}

/// A device as the Bridge holds it: its id, the house's name for it (its Zigbee
/// address in lower case, or `hue:<id>` with none, as `deviceFor` reads it), the
/// name it's given, and the room holding it.
pub const Placed = struct {
    id: []const u8,
    dev: []const u8,
    name: []const u8,
    room_id: ?[]const u8,
    /// It has a light service. A plug has one too, whatever it drives.
    light: bool = false,
};

pub const Child = struct { rid: []const u8, rtype: []const u8 };

pub const RoomNow = struct {
    id: []const u8,
    name: []const u8,
    children: []const Child,
};

/// Every device and room, from one read of the resource list.
pub const Layout = struct {
    devices: []const Placed,
    rooms: []const RoomNow,

    pub fn roomNamed(self: *const Layout, name: []const u8) ?*const RoomNow {
        for (self.rooms) |*r| if (std.mem.eql(u8, r.name, name)) return r;
        return null;
    }

    pub fn roomById(self: *const Layout, id: []const u8) ?*const RoomNow {
        for (self.rooms) |*r| if (std.mem.eql(u8, r.id, id)) return r;
        return null;
    }
};

pub fn layout(arena: Allocator, resources_json: []const u8) !Layout {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, resources_json, .{});
    const data = switch (root) {
        .object => |o| o.get("data") orelse return error.NoData,
        else => return error.NoData,
    };
    if (data != .array) return error.NoData;
    var devices: std.ArrayList(Placed) = .empty;
    var rooms: std.ArrayList(RoomNow) = .empty;
    for (data.array.items) |item| {
        if (item != .object) continue;
        const o = item.object;
        const t = str(o, "type") orelse continue;
        const id = str(o, "id") orelse continue;
        if (std.mem.eql(u8, t, "device")) {
            var light = false;
            if (o.get("services")) |sv| if (sv == .array) for (sv.array.items) |x| {
                if (x == .object) if (str(x.object, "rtype")) |t2| if (std.mem.eql(u8, t2, "light")) {
                    light = true;
                };
            };
            try devices.append(arena, .{ .id = id, .dev = try std.fmt.allocPrint(arena, "hue:{s}", .{id}), .name = metaName(o) orelse "", .room_id = null, .light = light });
        } else if (std.mem.eql(u8, t, "room")) {
            var children: std.ArrayList(Child) = .empty;
            if (o.get("children")) |c| if (c == .array) for (c.array.items) |ch| {
                if (ch != .object) continue;
                try children.append(arena, .{ .rid = str(ch.object, "rid") orelse continue, .rtype = str(ch.object, "rtype") orelse continue });
            };
            try rooms.append(arena, .{ .id = id, .name = metaName(o) orelse "", .children = children.items });
        }
    }
    // The addresses, then the rooms, now that every device is known.
    for (data.array.items) |item| {
        if (item != .object) continue;
        const o = item.object;
        const t = str(o, "type") orelse continue;
        if (!std.mem.eql(u8, t, "zigbee_connectivity")) continue;
        const mac = str(o, "mac_address") orelse continue;
        const owner = o.get("owner") orelse continue;
        if (owner != .object) continue;
        const rid = str(owner.object, "rid") orelse continue;
        for (devices.items) |*d| if (std.mem.eql(u8, d.id, rid)) {
            d.dev = try std.ascii.allocLowerString(arena, mac);
        };
    }
    for (rooms.items) |r| for (r.children) |c| {
        if (!std.mem.eql(u8, c.rtype, "device")) continue;
        for (devices.items) |*d| if (std.mem.eql(u8, d.id, c.rid)) {
            d.room_id = r.id;
        };
    };
    return .{ .devices = devices.items, .rooms = rooms.items };
}

fn metaName(o: std.json.ObjectMap) ?[]const u8 {
    const m = o.get("metadata") orelse return null;
    return if (m == .object) str(m.object, "name") else null;
}

/// The Bridge's limit on a device's or a room's name.
pub const MAX_NAME = 32;

/// Renames a device and leaves the rest of its metadata alone.
pub fn renameBody(arena: Allocator, name: []const u8) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    try aw.writer.writeAll("{\"metadata\":{\"name\":");
    try std.json.Stringify.value(name, .{}, &aw.writer);
    try aw.writer.writeAll("}}");
    return aw.written();
}

/// A room's whole list of children: the Bridge replaces it.
pub fn childrenBody(arena: Allocator, children: []const Child) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    try aw.writer.writeAll("{\"children\":");
    try std.json.Stringify.value(children, .{}, &aw.writer);
    try aw.writer.writeAll("}");
    return aw.written();
}

pub fn setRoom(gpa: Allocator, io: Io, bridge: Credentials, room_id: []const u8, body: []const u8, reply: ?*Reply) !void {
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/clip/v2/resource/room/{s}", .{room_id});
    try tls_http.put(gpa, io, bridge.host, bridge.port, bridge.id, path, bridge.key, body, reply);
}

fn str(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// The whole resource list, for a change that has to start from what's there now.
/// Caller owns the result.
pub fn resources(gpa: Allocator, io: Io, bridge: Credentials) ![]u8 {
    return tls_http.get(gpa, io, bridge.host, bridge.port, bridge.id, "/clip/v2/resource", bridge.key);
}

pub fn flashBody(buf: []u8, duration_ms: u32) ![]const u8 {
    return std.fmt.bufPrint(buf, "{{\"signaling\":{{\"signal\":\"on_off\",\"duration\":{d}}}}}", .{duration_ms});
}

/// The Bridge requires a duration here too, and ignores it.
pub const STOP_FLASH_BODY = "{\"signaling\":{\"signal\":\"no_signal\",\"duration\":1000}}";

pub const PowerUp = struct {
    power_on: PowerOn,
    /// Brightness percent, when it's a set value.
    bri: ?f64 = null,
    bri_previous: bool = false,
    ct_k: ?u32 = null,
};

/// What a light does when power returns, as the Bridge wants it. Returning to the
/// previous state uses its preset, because the Bridge rejects a preset carrying
/// any other property, and that's the setting nearly every light here already has.
pub fn powerUpBody(arena: Allocator, want: PowerUp) ![]const u8 {
    const previous = want.power_on == .previous and want.bri == null and want.ct_k == null;
    if (previous) return "{\"powerup\":{\"preset\":\"powerfail\"}}";

    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("{\"powerup\":{\"preset\":\"custom\",\"on\":");
    switch (want.power_on) {
        .on => try w.writeAll("{\"mode\":\"on\",\"on\":{\"on\":true}}"),
        .off => try w.writeAll("{\"mode\":\"on\",\"on\":{\"on\":false}}"),
        .toggle => try w.writeAll("{\"mode\":\"toggle\"}"),
        .previous => try w.writeAll("{\"mode\":\"previous\"}"),
    }
    if (want.bri) |bri| {
        try w.print(",\"dimming\":{{\"mode\":\"dimming\",\"dimming\":{{\"brightness\":{d}}}}}", .{bri});
    } else if (want.bri_previous) {
        try w.writeAll(",\"dimming\":{\"mode\":\"previous\"}");
    }
    if (want.ct_k) |kelvin| {
        const mirek = (1_000_000 + kelvin / 2) / kelvin;
        try w.print(",\"color\":{{\"mode\":\"color_temperature\",\"color_temperature\":{{\"mirek\":{d}}}}}", .{mirek});
    }
    try w.writeAll("}}");
    return out.written();
}

const testing = std.testing;

test "flashBody is what the Bridge accepted by hand" {
    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings(
        "{\"signaling\":{\"signal\":\"on_off\",\"duration\":60000}}",
        try flashBody(&buf, 60_000),
    );
}

test "powerUpBody uses the preset for returning to the previous state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const preset = "{\"powerup\":{\"preset\":\"powerfail\"}}";
    try testing.expectEqualStrings(preset, try powerUpBody(a, .{ .power_on = .previous, .bri_previous = true }));
    // A plug has no brightness to return to.
    try testing.expectEqualStrings(preset, try powerUpBody(a, .{ .power_on = .previous }));
}

test "powerUpBody spells out anything else as custom" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "{\"powerup\":{\"preset\":\"custom\",\"on\":{\"mode\":\"on\",\"on\":{\"on\":true}}," ++
            "\"dimming\":{\"mode\":\"dimming\",\"dimming\":{\"brightness\":100}}," ++
            "\"color\":{\"mode\":\"color_temperature\",\"color_temperature\":{\"mirek\":366}}}}",
        try powerUpBody(a, .{ .power_on = .on, .bri = 100, .ct_k = 2732 }),
    );
    try testing.expectEqualStrings(
        "{\"powerup\":{\"preset\":\"custom\",\"on\":{\"mode\":\"on\",\"on\":{\"on\":false}}}}",
        try powerUpBody(a, .{ .power_on = .off }),
    );
    try testing.expectEqualStrings(
        "{\"powerup\":{\"preset\":\"custom\",\"on\":{\"mode\":\"previous\"}," ++
            "\"dimming\":{\"mode\":\"dimming\",\"dimming\":{\"brightness\":40}}}}",
        try powerUpBody(a, .{ .power_on = .previous, .bri = 40 }),
    );
}

test "a mistake in the credentials file is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = try parseCredentials(a, "{\"host\":\"10.0.0.1\",\"id\":\"X\",\"key\":\"k\"}");
    try testing.expectEqual(@as(u16, 443), ok.port);
    try testing.expectError(error.UnknownField, parseCredentials(a, "{\"host\":\"h\",\"id\":\"X\",\"key\":\"k\",\"oops\":1}"));
}

test "a device is found by its Zigbee address in any case, or by its own id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list =
        \\{"errors":[],"data":[
        \\ {"id":"dev-1","type":"device"},
        \\ {"id":"z1","type":"zigbee_connectivity","owner":{"rid":"dev-1","rtype":"device"},"mac_address":"00:17:88:01:0B:2C:4D:1E"},
        \\ {"id":"dev-2","type":"device"}]}
    ;
    try std.testing.expectEqualStrings("dev-1", (try deviceFor(a, list, "00:17:88:01:0b:2c:4d:1e")).?);
    try std.testing.expectEqualStrings("dev-2", (try deviceFor(a, list, "hue:dev-2")).?);
    try std.testing.expect(try deviceFor(a, list, "00:17:88:01:00:00:00:00") == null);
    try std.testing.expect(try deviceFor(a, list, "hue:z1") == null);
}

test "the layout names each device by its address and finds its room" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list =
        \\{"errors":[],"data":[
        \\ {"id":"r1","type":"room","metadata":{"name":"Hall","archetype":"hallway"},"children":[{"rid":"dev-1","rtype":"device"}]},
        \\ {"id":"dev-1","type":"device","metadata":{"name":"Ceiling","archetype":"ceiling_round"}},
        \\ {"id":"z1","type":"zigbee_connectivity","owner":{"rid":"dev-1","rtype":"device"},"mac_address":"00:17:88:01:0B:2C:4D:1E"},
        \\ {"id":"dev-2","type":"device","metadata":{"name":"Hue Bridge"}}]}
    ;
    const l = try layout(a, list);
    try std.testing.expectEqual(@as(usize, 2), l.devices.len);
    try std.testing.expectEqualStrings("00:17:88:01:0b:2c:4d:1e", l.devices[0].dev);
    try std.testing.expectEqualStrings("Hall", l.roomById(l.devices[0].room_id.?).?.name);
    try std.testing.expectEqualStrings("hue:dev-2", l.devices[1].dev);
    try std.testing.expect(l.devices[1].room_id == null);
    try std.testing.expectEqualStrings("{\"metadata\":{\"name\":\"Say \\\"hi\\\"\"}}", try renameBody(a, "Say \"hi\""));
    try std.testing.expectEqualStrings("{\"children\":[{\"rid\":\"dev-1\",\"rtype\":\"device\"}]}", try childrenBody(a, l.rooms[0].children));
}
