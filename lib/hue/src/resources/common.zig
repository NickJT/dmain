//! Shared infrastructure for the resource model: the `ResourceType`
//! enum + `Resource` tagged union (which necessarily references every
//! resource struct from every other file in this directory), the
//! `ResourceIdentifier`/`EventUpdate` types every resource's
//! `fromJson`/`applyUpdate` is built around, and the generic
//! stage-then-commit helpers (`deepFree`, `commitOptionalString`,
//! `validateType`, `validateEntry`) those methods share. Also home to
//! small cross-family value types (`Metadata`, `Position`) that don't
//! belong to any one resource family.
//!
//! This file and every other file in `src/resources/` import each other
//! (family files need `ResourceType`/`EventUpdate`/the helpers here;
//! `Resource` here needs every family's concrete struct types) - Zig
//! resolves circular file `@import`s fine since resolution is
//! declaration-by-declaration, not file-by-file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json_get = @import("json_get").json_get;

const light = @import("light.zig");
const sensors = @import("sensors.zig");
const device = @import("device.zig");
const topology = @import("topology.zig");
const automation = @import("automation_extras.zig");

// ---------------------------------------------------------------------------
// Generic deep-free helper
// ---------------------------------------------------------------------------
//
// Mirrors maps.zig's deepClone, but in reverse: instead of allocating a
// fresh copy of every owned slice/optional, it walks the same shape and
// frees whatever it finds.
//
// Safe on fields that own nothing:
//   - Allocator fields (gpa) contain only single-item pointers (ptr,
//     vtable), which the .pointer branch below leaves untouched since
//     they aren't slices.
//   - Enums, ints, floats, bools fall through to the `else => {}` branch.
//   - std.Io.Timestamp and similar plain-data structs recurse harmlessly
//     into their (non-owning) integer fields.
//
// The one thing this does NOT replace: the errdefer rollback blocks
// inside fromJson/applyUpdate that free *staged* values before they're
// committed to self. Those free local variables that were never part of
// self's shape, so they stay as explicit frees.
pub fn deepFree(allocator: Allocator, value: anytype) void {
    const T = @TypeOf(value);

    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            inline for (info.field_names) |field_name| {
                deepFree(allocator, @field(value, field_name));
            }
        },
        .optional => {
            if (value) |payload| {
                deepFree(allocator, payload);
            }
        },
        .pointer => |info| {
            if (info.size == .slice) {
                // Free what each element owns before freeing the slice
                // itself. For slices of scalars (e.g. []const u8) this
                // loop is a no-op per element — the payload type falls
                // through to `else => {}` below.
                for (value) |item| {
                    deepFree(allocator, item);
                }
                allocator.free(value);
            }
            // Single-item pointers (e.g. Allocator.ptr, Allocator.vtable)
            // aren't owned by the struct that holds them — leave alone.
        },
        else => {},
    }
}

// Collapses the "free the old value, take ownership of the new one" step
//  with a single call. Only ever called in the commit phase, after
// all fallible allocation has already happened — commitOptionalString
// itself cannot fail.
pub fn commitOptionalString(gpa: Allocator, current: *?[]const u8, staged: ?[]const u8) void {
    if (staged) |v| {
        if (current.*) |old| gpa.free(old);
        current.* = v;
    }
}

// ---------------------------------------------------------------------------
// Resource Union Definitions and Helpers
// ---------------------------------------------------------------------------
//
pub const ResourceType = enum {
    // auth_v1,
    behavior_instance,
    behavior_script,
    bridge,
    bridge_home,
    button,
    //camera_motion,
    clip,
    //contact,
    // convenience_area_motion,
    device,
    device_power,
    device_software_update,
    entertainment,
    entertainment_configuration,
    // geofence_client,
    geolocation,
    grouped_light,
    grouped_light_level,
    grouped_motion,
    // homekit,
    light,
    light_level,
    matter,
    // matter_fabric,
    motion,
    motion_area_candidate,
    //  motion_area_configuration,
    public_image,
    relative_rotary,
    room,
    scene,
    // security_area_motion,
    service_group,
    //   smart_scene,
    //  speaker,
    tamper,
    temperature,
    //  wifi_connectivity,
    //  zgp_connectivity,
    zigbee_connectivity,
    zigbee_device_discovery,
    zone,

    pub fn fromString(str: []const u8) ?ResourceType {
        return std.meta.stringToEnum(ResourceType, str);
    }

    pub fn label(self: ResourceType) []const u8 {
        return switch (self) {
            .behavior_instance => "behavior_instance",
            .behavior_script => "behavior_script",
            //.bell_button => "bell_button",
            .bridge => "bridge",
            .bridge_home => "bridge_home",
            .button => "button",
            //  .camera_motion => "camera_motion",
            .clip => "clip",
            //  .contact => "contact",
            //  .convenience_area_motion => "convenience_area_motion",
            .device => "device",
            .device_power => "device_power",
            .device_software_update => "device_software_update",
            .entertainment => "entertainment",
            .entertainment_configuration => "entertainment_configuration",
            //  .geofence_client => "geofence_client",
            .geolocation => "geolocation",
            .grouped_light => "grouped_light",
            .grouped_light_level => "grouped_light_level",
            .grouped_motion => "grouped_motion",
            //  .homekit => "homekit",
            .light => "light",
            .light_level => "light_level",
            .matter => "matter",
            //    .matter_fabric => "matter_fabric",
            .motion => "motion",
            .motion_area_candidate => "motion_area_candidate",
            //  .motion_area_configuration => "motion_area_configuration",
            .public_image => "public_image",
            .relative_rotary => "relative_rotary",
            .room => "room",
            .scene => "scene",
            //   .security_area_motion => "security_area_motion",
            .service_group => "service_group",
            //   .smart_scene => "smart_scene",
            //    .speaker => "speaker",
            .tamper => "tamper",
            .temperature => "temperature",
            //    .wifi_connectivity => "wifi_connectivity",
            //    .zgp_connectivity => "zgp_connectivity",
            .zigbee_connectivity => "zigbee_connectivity",
            .zigbee_device_discovery => "zigbee_device_discovery",
            .zone => "zone",
        };
    }

    pub fn toString(self: ResourceType, allocator: std.mem.Allocator) ![]const u8 {
        return allocator.print("{s}", .{@tagName(self)});
    }
};

pub const Resource = union(ResourceType) {
    //auth_v1,
    behavior_instance: automation.BehaviorInstance,
    behavior_script: automation.BehaviorScript,
    bridge: topology.Bridge,
    bridge_home: topology.BridgeHome,
    button: sensors.Button,
    clip: automation.Clip,
    device: device.Device,
    device_power: sensors.DevicePower,
    device_software_update: device.DeviceSoftwareUpdate,
    entertainment: automation.Entertainment,
    entertainment_configuration: automation.EntertainmentConfiguration,
    geolocation: automation.Geolocation,
    grouped_light: sensors.GroupedLight,
    grouped_light_level: sensors.GroupedLightLevel,
    grouped_motion: sensors.GroupedMotion,
    light: light.Light,
    light_level: sensors.LightLevel,
    matter: automation.Matter,
    motion: sensors.Motion,
    motion_area_candidate: sensors.MotionAreaCandidate,
    public_image: automation.PublicImage,
    relative_rotary: sensors.RelativeRotary,
    room: topology.Room,
    scene: automation.Scene,
    service_group: topology.ServiceGroup,
    tamper: sensors.Tamper,
    temperature: sensors.Temperature,
    zigbee_connectivity: device.ZigbeeConnectivity,
    zigbee_device_discovery: device.ZigbeeDeviceDiscovery,
    zone: topology.Zone,

    pub fn format(self: Resource, writer: *std.Io.Writer) !void {
        switch (self) {
            inline else => |payload| {
                const T = @TypeOf(payload);
                if (comptime @hasDecl(T, "format")) {
                    return payload.format(writer);
                } else {
                    return writer.writeAll("No format available");
                }
            },
        }
    }

    pub fn deinit(self: *Resource) void {
        return switch (self.*) {
            inline else => |*payload| payload.deinit(),
        };
    }

    pub fn Id(self: Resource) []const u8 {
        return switch (self) {
            inline else => |*payload| payload.id,
        };
    }
};

pub const ResourceIdentifier = struct {
    rid: []const u8,
    rtype: ResourceType,

    /// Safely parses a ResourceIdentifier, ensuring it owns its allocated string memory.
    pub fn fromJson(gpa: Allocator, obj: std.json.ObjectMap) !ResourceIdentifier {
        const rtype_str = try json_get.string(obj, "rtype");

        if (ResourceType.fromString(rtype_str)) |typ| {
            const raw_rid = try json_get.string(obj, "rid");
            return .{
                .rid = try gpa.dupe(u8, raw_rid),
                .rtype = typ,
            };
        } else {
            return error.InvalidResourceType;
        }
    }

    /// Parses an array of resource identifiers, cleanly rolling back allocations on error.
    pub fn fromList(gpa: Allocator, object: std.json.Array) !std.ArrayList(ResourceIdentifier) {
        var list = std.ArrayList(ResourceIdentifier).empty;
        errdefer {
            for (list.items) |*item| {
                item.deinit(gpa);
            }
            list.deinit(gpa);
        }

        for (object.items) |item| {
            const rtype_str = try json_get.string(item.object, "rtype");
            if (ResourceType.fromString(rtype_str)) |typ| {
                if (json_get.optionalString(item.object, "rid")) |rid| {
                    try list.append(gpa, .{
                        .rid = try gpa.dupe(u8, rid),
                        .rtype = typ,
                    });
                }
            }
        }
        return list;
    }

    pub fn deinit(self: ResourceIdentifier, gpa: Allocator) void {
        gpa.free(self.rid);
    }
};

pub const EventUpdate = struct {
    id: []const u8,
    timestamp: ?std.Io.Timestamp,
    updateType: ResourceType,
    data: std.json.ObjectMap,
};

/// Ensures the JSON object's own "type" field matches what the caller
/// expects to be parsing (e.g. a `light` fromJson call is fed a `type:
/// "light"` object, not `type: "motion"`).
pub fn validateType(expected_type: ResourceType, obj: std.json.ObjectMap) !void {
    if (!std.mem.eql(u8, expected_type.label(), try json_get.string(obj, "type")))
        return error.UnmatchedTypeField;
}

/// Same as validateType, plus confirms the event's "id" matches the
/// resource being updated - guards against a misrouted event ever being
/// applied to the wrong entry.
pub fn validateEntry(id: []const u8, expected_type: ResourceType, obj: std.json.ObjectMap) !void {
    if (!std.mem.eql(u8, id, try json_get.string(obj, "id"))) {
        return error.UnmatchedIdField;
    }
    try validateType(expected_type, obj);
}

/// Shared "owner" + "id" parse used by every resource whose JSON has an
/// `owner: {rid, rtype}` envelope. Currently unused - every resource
/// struct still inlines this pattern itself in its own fromJson - kept
/// as a documented, ready-to-adopt de-duplication target rather than
/// deleted outright.
fn parseOwnerAndId(gpa: Allocator, obj: std.json.ObjectMap) !struct { id: []const u8, owner_rid: []const u8, owner_rtype: ResourceType } {
    const owner = try ResourceIdentifier.fromJson(gpa, try json_get.object(obj, "owner"));
    errdefer gpa.free(owner.rid);
    const id = try gpa.dupe(u8, try json_get.string(obj, "id"));
    return .{ .id = id, .owner_rid = owner.rid, .owner_rtype = owner.rtype };
}

// ---------------------------------------------------------------------------
// Generic comparators
// ---------------------------------------------------------------------------

pub fn compareByOwnerRid(comptime T: type) fn (void, T, T) bool {
    return struct {
        pub fn compare(_: void, a: T, b: T) bool {
            // Zig performs compile-time Duck Typing here.
            // If T doesn't have an 'id' field, this will fail to compile.
            return std.mem.order(u8, a.owner_rid, b.owner_rid) == .lt;
        }
    }.compare;
}

/// Generic comparator
/// Usage: std.mem.sort(DevicePower, list.items, {}, compareByField(DevicePower, "id"));
pub fn compareByFieldCompTime(comptime T: type, comptime field_name: []const u8) fn (void, T, T) bool {
    return struct {
        pub fn compare(_: void, a: T, b: T) bool {
            // Accesses the struct field dynamically by name at compile time
            return std.mem.order(u8, @field(a, field_name), @field(b, field_name)) == .lt;
        }
    }.compare;
}

/// Generic comparator that also handles nullable fields
pub fn compareByFieldCompTimeNullable(comptime T: type, comptime field_name: []const u8) fn (void, T, T) bool {
    return struct {
        pub fn compare(_: void, a: T, b: T) bool {
            const a_val = @field(a, field_name);
            const b_val = @field(b, field_name);
            const FieldType = @TypeOf(a_val);

            if (@typeInfo(FieldType) == .optional) {
                if (a_val == null and b_val == null) return false;
                if (a_val == null) return true; // nulls sort first
                if (b_val == null) return false;
                return std.mem.order(u8, a_val.?, b_val.?) == .lt;
            } else {
                return std.mem.order(u8, a_val, b_val) == .lt;
            }
        }
    }.compare;
}

// ---------------------------------------------------------------------------
// Small cross-family value types
// ---------------------------------------------------------------------------

/// Generic name+archetype shape. Currently unused - every resource struct
/// parses its own "metadata" object inline rather than through this
/// shared type - kept as a documented candidate for de-duplication.
pub const Metadata = struct {
    name: []const u8,
    archetype: []const u8,
};

pub const Position = struct {
    x: f64,
    y: f64,
    z: f64,

    pub fn fromJson(obj: std.json.ObjectMap) !Position {
        const x_val = obj.get("x") orelse return error.MissingField;
        const y_val = obj.get("y") orelse return error.MissingField;
        const z_val = obj.get("z") orelse return error.MissingField;

        return Position{
            .x = switch (x_val) {
                .float => |f| f,
                .integer => |i| @as(f64, @floatFromInt(i)),
                else => return error.WrongType,
            },
            .y = switch (y_val) {
                .float => |f| f,
                .integer => |i| @as(f64, @floatFromInt(i)),
                else => return error.WrongType,
            },
            .z = switch (z_val) {
                .float => |f| f,
                .integer => |i| @as(f64, @floatFromInt(i)),
                else => return error.WrongType,
            },
        };
    }
};
