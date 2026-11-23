//! Topology resources: `bridge`, `bridge_home`, `room`, `zone`,
//! `service_group` - the id/room/device/service tree `maps.zig`'s
//! `Directory` walks.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json_get = @import("json_get").json_get;

const common = @import("common.zig");
const ResourceType = common.ResourceType;
const ResourceIdentifier = common.ResourceIdentifier;
const EventUpdate = common.EventUpdate;
const validateType = common.validateType;
const validateEntry = common.validateEntry;
const commitOptionalString = common.commitOptionalString;
const deepFree = common.deepFree;

/// Unused elsewhere - neither `Room` nor `Zone` below actually parses
/// `metadata.archetype` into this enum (they only capture `name`); this
/// is a missing-field gap, not a wrong-type one, so left unwired rather
/// than guessed at how the caller would want it surfaced.
pub const RoomArchetype = enum {
    living_room,
    kitchen,
    dining,
    bedroom,
    kids_bedroom,
    bathroom,
    nursery,
    recreation,
    office,
    gym,
    hallway,
    toilet,
    front_door,
    garage,
    terrace,
    garden,
    driveway,
    carport,
    home,
    downstairs,
    upstairs,
    top_floor,
    attic,
    guest_room,
    staircase,
    lounge,
    man_cave,
    computer,
    studio,
    music,
    tv,
    reading,
    closet,
    storage,
    laundry_room,
    balcony,
    porch,
    barbecue,
    pool,
    other,
    unknown,

    pub fn fromString(str: []const u8) RoomArchetype {
        return std.meta.stringToEnum(RoomArchetype, str) orelse .unknown;
    }

    pub fn label(self: RoomArchetype) []const u8 {
        return switch (self) {
            .living_room => "living_room",
            .kitchen => "kitchen",
            .dining => "dining",
            .bedroom => "bedroom",
            .kids_bedroom => "kids_bedroom",
            .bathroom => "bathroom",
            .nursery => "nursery",
            .recreation => "recreation",
            .office => "office",
            .gym => "gym",
            .hallway => "hallway",
            .toilet => "toilet",
            .front_door => "front_door",
            .garage => "garage",
            .terrace => "terrace",
            .garden => "garden",
            .driveway => "driveway",
            .carport => "carport",
            .home => "home",
            .downstairs => "downstairs",
            .upstairs => "upstairs",
            .top_floor => "top_floor",
            .attic => "attic",
            .guest_room => "guest_room",
            .staircase => "staircase",
            .lounge => "lounge",
            .man_cave => "man_cave",
            .computer => "computer",
            .studio => "studio",
            .music => "music",
            .tv => "tv",
            .reading => "reading",
            .closet => "closet",
            .storage => "storage",
            .laundry_room => "laundry_room",
            .balcony => "balcony",
            .porch => "porch",
            .barbecue => "barbecue",
            .pool => "pool",
            .other => "other",
            .unknown => "unknown",
        };
    }

    pub fn toString(self: RoomArchetype, allocator: std.mem.Allocator) ![]const u8 {
        return allocator.print("{s}", .{@tagName(self)});
    }
};
pub const Bridge = struct {
    gpa: Allocator,
    id: []const u8,
    timestamp: ?std.Io.Timestamp,
    owner_rid: []const u8,
    owner_rtype: ResourceType,
    bridge_id: []const u8,
    timezone: []const u8,
    origin: ?[]const u8,
    time: ?[]const u8,

    pub fn fromJson(gpa: Allocator, obj: std.json.ObjectMap) !Bridge {
        try validateType(.bridge, obj);
        const owner = try ResourceIdentifier.fromJson(gpa, try json_get.object(obj, "owner"));
        errdefer gpa.free(owner.rid);

        const id = gpa.dupe(u8, try json_get.string(obj, "id")) catch |err| {
            gpa.free(owner.rid);
            return err;
        };

        var bridge = Bridge{
            .gpa = gpa,
            .id = id,
            .timestamp = null,
            .owner_rid = owner.rid,
            .owner_rtype = owner.rtype,
            .bridge_id = &.{},
            .timezone = &.{},
            .origin = null,
            .time = null,
        };
        errdefer bridge.deinit();

        const event: EventUpdate = .{
            .id = bridge.id,
            .timestamp = null,
            .data = obj,
            .updateType = .bridge,
        };
        try bridge.applyUpdate(event);
        return bridge;
    }

    pub fn applyUpdate(self: *Bridge, event: EventUpdate) !void {
        if (!std.mem.eql(u8, event.id, self.id)) return error.InvalidId;
        try validateEntry(event.id, .bridge, event.data);

        var staged_bridge_id: ?[]const u8 = null;
        var staged_timezone: ?[]const u8 = null;
        var staged_origin: ?[]const u8 = null;
        var staged_time: ?[]const u8 = null;

        errdefer {
            if (staged_bridge_id) |bid| self.gpa.free(bid);
            if (staged_timezone) |tz| self.gpa.free(tz);
            if (staged_origin) |org| self.gpa.free(org);
            if (staged_time) |t| self.gpa.free(t);
        }

        if (json_get.optionalString(event.data, "bridge_id")) |bridge_id| {
            staged_bridge_id = try self.gpa.dupe(u8, bridge_id);
        }

        if (json_get.optionalObject(event.data, "time_zone")) |tzObj| {
            if (json_get.optionalString(tzObj, "time_zone")) |tz| {
                staged_timezone = try self.gpa.dupe(u8, tz);
            }
        }

        if (json_get.optionalObject(event.data, "import")) |importObj| {
            if (json_get.optionalString(importObj, "origin")) |o| {
                staged_origin = try self.gpa.dupe(u8, o);
            }
            if (json_get.optionalString(importObj, "time")) |t| {
                staged_time = try self.gpa.dupe(u8, t);
            }
        }

        // Commit Phase
        if (staged_bridge_id) |bid| {
            self.gpa.free(self.bridge_id);
            self.bridge_id = bid;
        }
        if (staged_timezone) |tz| {
            self.gpa.free(self.timezone);
            self.timezone = tz;
        }
        commitOptionalString(self.gpa, &self.origin, staged_origin);
        commitOptionalString(self.gpa, &self.time, staged_time);

        self.timestamp = event.timestamp;
    }

    pub fn deinit(self: *Bridge) void {
        deepFree(self.gpa, self.*);
    }
};
pub const BridgeHome = struct {
    gpa: Allocator,
    id: []const u8,
    timestamp: ?std.Io.Timestamp,
    name: []const u8,
    services: ?[]ResourceIdentifier,
    children: ?[]ResourceIdentifier,

    pub fn fromJson(gpa: Allocator, obj: std.json.ObjectMap) !BridgeHome {
        try validateType(.bridge_home, obj);
        const parsed_id = try gpa.dupe(u8, try json_get.string(obj, "id"));
        errdefer gpa.free(parsed_id);

        var bridgeHome = BridgeHome{
            .gpa = gpa,
            .id = parsed_id,
            .timestamp = null,
            .name = try gpa.dupe(u8, "Hale Farm Cottage"),
            .services = null,
            .children = null,
        };
        errdefer bridgeHome.deinit();

        const event: EventUpdate = .{
            .id = bridgeHome.id,
            .timestamp = null,
            .data = obj,
            .updateType = .bridge_home,
        };
        try bridgeHome.applyUpdate(event);
        return bridgeHome;
    }

    pub fn applyUpdate(self: *BridgeHome, event: EventUpdate) !void {
        if (!std.mem.eql(u8, event.id, self.id)) return error.InvalidId;
        try validateEntry(event.id, .bridge_home, event.data);

        var staged_services: ?[]ResourceIdentifier = null;
        var staged_children: ?[]ResourceIdentifier = null;

        // Central cleanup trap handles slice destruction safely if either step throws midway
        errdefer {
            if (staged_services) |slice| {
                for (slice) |*ri| ri.deinit(self.gpa);
                self.gpa.free(slice);
            }
            if (staged_children) |slice| {
                for (slice) |*ri| ri.deinit(self.gpa);
                self.gpa.free(slice);
            }
        }

        if (json_get.optionalArray(event.data, "services")) |arr| {
            var list = try ResourceIdentifier.fromList(self.gpa, arr);
            errdefer {
                for (list.items) |*ri| ri.deinit(self.gpa);
                list.deinit(self.gpa);
            }
            staged_services = try list.toOwnedSlice(self.gpa);
        }

        if (json_get.optionalArray(event.data, "children")) |arr| {
            var list = try ResourceIdentifier.fromList(self.gpa, arr);
            errdefer {
                for (list.items) |*ri| ri.deinit(self.gpa);
                list.deinit(self.gpa);
            }
            staged_children = try list.toOwnedSlice(self.gpa);
        }

        // Commit Phase - Zero allocation, completely safe from errors
        if (staged_services) |new_services| {
            if (self.services) |old_services| {
                for (old_services) |*ri| ri.deinit(self.gpa);
                self.gpa.free(old_services);
            }
            self.services = new_services;
        }

        if (staged_children) |new_children| {
            if (self.children) |old_children| {
                for (old_children) |*ri| ri.deinit(self.gpa);
                self.gpa.free(old_children);
            }
            self.children = new_children;
        }

        self.timestamp = event.timestamp;
    }

    pub fn deinit(self: *BridgeHome) void {
        deepFree(self.gpa, self.*);
    }
};
pub const Room = struct {
    gpa: Allocator,
    id: []const u8,
    timestamp: ?std.Io.Timestamp,
    name: ?[]const u8,
    services: ?[]ResourceIdentifier,
    children: ?[]ResourceIdentifier,

    pub fn fromJson(gpa: Allocator, obj: std.json.ObjectMap) !Room {
        try validateType(.room, obj);
        const id = try gpa.dupe(u8, try json_get.string(obj, "id"));

        var room = Room{
            .gpa = gpa,
            .id = id,
            .timestamp = null,
            .name = null,
            .services = null,
            .children = null,
        };
        errdefer room.deinit();

        const event: EventUpdate = .{
            .id = room.id,
            .timestamp = null,
            .data = obj,
            .updateType = .room,
        };
        try room.applyUpdate(event);
        return room;
    }

    pub fn applyUpdate(self: *Room, event: EventUpdate) !void {
        if (!std.mem.eql(u8, event.id, self.id)) return error.InvalidId;
        try validateEntry(event.id, .room, event.data);

        var name_staged: ?[]const u8 = null;
        var services_staged: ?[]ResourceIdentifier = null;
        var children_staged: ?[]ResourceIdentifier = null;

        errdefer {
            if (name_staged) |n| self.gpa.free(n);
            if (services_staged) |slice| {
                for (slice) |*ri| ri.deinit(self.gpa);
                self.gpa.free(slice);
            }
            if (children_staged) |slice| {
                for (slice) |*ri| ri.deinit(self.gpa);
                self.gpa.free(slice);
            }
        }

        if (json_get.optionalObject(event.data, "metadata")) |metadataObj| {
            if (json_get.optionalString(metadataObj, "name")) |name| {
                name_staged = try self.gpa.dupe(u8, name);
            }
        }

        if (json_get.optionalArray(event.data, "services")) |arr| {
            var list = try ResourceIdentifier.fromList(self.gpa, arr);
            errdefer {
                for (list.items) |*ri| ri.deinit(self.gpa);
                list.deinit(self.gpa);
            }
            services_staged = try list.toOwnedSlice(self.gpa);
        }

        if (json_get.optionalArray(event.data, "children")) |arr| {
            var list = try ResourceIdentifier.fromList(self.gpa, arr);
            errdefer {
                for (list.items) |*ri| ri.deinit(self.gpa);
                list.deinit(self.gpa);
            }
            children_staged = try list.toOwnedSlice(self.gpa);
        }

        // Commit Phase
        commitOptionalString(self.gpa, &self.name, name_staged);
        if (services_staged) |new_services| {
            if (self.services) |old_services| {
                for (old_services) |*ri| ri.deinit(self.gpa);
                self.gpa.free(old_services);
            }
            self.services = new_services;
        }
        if (children_staged) |new_children| {
            if (self.children) |old_children| {
                for (old_children) |*ri| ri.deinit(self.gpa);
                self.gpa.free(old_children);
            }
            self.children = new_children;
        }

        self.timestamp = event.timestamp;
    }

    pub fn deinit(self: *Room) void {
        deepFree(self.gpa, self.*);
    }

    pub fn format(self: Room, writer: *std.Io.Writer) !void {
        const services_count: usize = if (self.services) |s| s.len else 0;
        const children_count: usize = if (self.children) |c| c.len else 0;
        try writer.print("{?s}, Services: {d}, Children: {d}", .{ self.name, services_count, children_count });
    }
};
pub const ServiceGroup = struct {
    gpa: Allocator,
    id: []const u8,
    timestamp: ?std.Io.Timestamp,
    services: ?[]ResourceIdentifier,

    pub fn fromJson(gpa: Allocator, obj: std.json.ObjectMap) !ServiceGroup {
        try validateType(.service_group, obj);
        const id = try gpa.dupe(u8, try json_get.string(obj, "id"));

        var sg = ServiceGroup{
            .gpa = gpa,
            .id = id,
            .timestamp = null,
            .services = null,
        };
        errdefer sg.deinit();

        const event: EventUpdate = .{
            .id = sg.id,
            .timestamp = null,
            .data = obj,
            .updateType = .service_group,
        };
        try sg.applyUpdate(event);
        return sg;
    }

    pub fn applyUpdate(self: *ServiceGroup, event: EventUpdate) !void {
        if (!std.mem.eql(u8, event.id, self.id)) return error.InvalidId;
        try validateEntry(event.id, .service_group, event.data);

        var services_staged: ?[]ResourceIdentifier = null;

        errdefer {
            if (services_staged) |slice| {
                for (slice) |*ri| ri.deinit(self.gpa);
                self.gpa.free(slice);
            }
        }

        if (json_get.optionalArray(event.data, "services")) |arr| {
            var list = try ResourceIdentifier.fromList(self.gpa, arr);
            errdefer {
                for (list.items) |*ri| ri.deinit(self.gpa);
                list.deinit(self.gpa);
            }
            services_staged = try list.toOwnedSlice(self.gpa);
        }

        // Commit Phase
        if (services_staged) |new_services| {
            if (self.services) |old_services| {
                for (old_services) |*ri| ri.deinit(self.gpa);
                self.gpa.free(old_services);
            }
            self.services = new_services;
        }

        self.timestamp = event.timestamp;
    }

    pub fn deinit(self: *ServiceGroup) void {
        deepFree(self.gpa, self.*);
    }
};
pub const Zone = struct {
    gpa: Allocator,
    id: []const u8,
    timestamp: ?std.Io.Timestamp,
    name: ?[]const u8,
    services: ?[]ResourceIdentifier,
    children: ?[]ResourceIdentifier,

    pub fn fromJson(gpa: Allocator, obj: std.json.ObjectMap) !Zone {
        try validateType(.zone, obj);

        const parsed_id = try gpa.dupe(u8, try json_get.string(obj, "id"));
        errdefer gpa.free(parsed_id);

        var zone = Zone{
            .gpa = gpa,
            .id = parsed_id,
            .timestamp = null,
            .name = null,
            .services = null,
            .children = null,
        };
        errdefer zone.deinit();

        const event: EventUpdate = .{
            .id = zone.id,
            .timestamp = null,
            .data = obj,
            .updateType = .zone,
        };

        try zone.applyUpdate(event);
        return zone;
    }

    pub fn applyUpdate(self: *Zone, event: EventUpdate) !void {
        if (!std.mem.eql(u8, event.id, self.id)) return error.InvalidId;
        try validateEntry(event.id, .zone, event.data);

        // 1. Stage allocations out-of-band to preserve atomicity
        var services_staged: ?[]ResourceIdentifier = null;
        if (json_get.optionalArray(event.data, "services")) |arr| {
            var list = try ResourceIdentifier.fromList(self.gpa, arr);
            errdefer {
                for (list.items) |*ri| ri.deinit(self.gpa);
                list.deinit(self.gpa);
            }
            services_staged = try list.toOwnedSlice(self.gpa);
        }
        // Rollback handler if a subsequent step fails before commit point
        errdefer if (services_staged) |slice| {
            for (slice) |*ri| ri.deinit(self.gpa);
            self.gpa.free(slice);
        };

        var children_staged: ?[]ResourceIdentifier = null;
        if (json_get.optionalArray(event.data, "children")) |arr| {
            var list = try ResourceIdentifier.fromList(self.gpa, arr);
            errdefer {
                for (list.items) |*ri| ri.deinit(self.gpa);
                list.deinit(self.gpa);
            }
            children_staged = try list.toOwnedSlice(self.gpa);
        }
        errdefer if (children_staged) |slice| {
            for (slice) |*ri| ri.deinit(self.gpa);
            self.gpa.free(slice);
        };

        var name_staged: ?[]const u8 = null;
        if (json_get.optionalObject(event.data, "metadata")) |metadataObj| {
            if (json_get.optionalString(metadataObj, "name")) |name| {
                name_staged = try self.gpa.dupe(u8, name);
            }
        }
        errdefer if (name_staged) |n| self.gpa.free(n);

        // 2. Transaction Point: Commit modifications only after all potential errors clear
        if (services_staged) |new_services| {
            if (self.services) |old_services| {
                for (old_services) |*ri| ri.deinit(self.gpa);
                self.gpa.free(old_services);
            }
            self.services = new_services;
        }

        if (children_staged) |new_children| {
            if (self.children) |old_children| {
                for (old_children) |*ri| ri.deinit(self.gpa);
                self.gpa.free(old_children);
            }
            self.children = new_children;
        }

        if (name_staged) |new_name| {
            if (self.name) |old_name| self.gpa.free(old_name);
            self.name = new_name;
        }

        self.timestamp = event.timestamp;
    }

    pub fn deinit(self: *Zone) void {
        deepFree(self.gpa, self.*);
    }

    pub fn format(self: Zone, writer: *std.Io.Writer) !void {
        const services_count: usize = if (self.services) |s| s.len else 0;
        const children_count: usize = if (self.children) |c| c.len else 0;
        try writer.print("Name: {?s}, Services: {d}, Children: {d}", .{ self.name, services_count, children_count });
    }
};
