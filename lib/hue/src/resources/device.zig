//! Physical device metadata and per-device connectivity/update-status
//! resources: `device`, `device_software_update`, `zigbee_connectivity`,
//! `zigbee_device_discovery`.

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

pub const ProductArchetype = enum {
    bridge_v2,
    bridge_v3,
    unknown_archetype,
    classic_bulb,
    sultan_bulb,
    flood_bulb,
    spot_bulb,
    candle_bulb,
    luster_bulb,
    pendant_round,
    pendant_long,
    ceiling_round,
    ceiling_square,
    floor_shade,
    floor_lantern,
    table_shade,
    recessed_ceiling,
    recessed_floor,
    single_spot,
    double_spot,
    table_wash,
    wall_lantern,
    wall_shade,
    flexible_lamp,
    ground_spot,
    wall_spot,
    plug,
    hue_go,
    hue_lightstrip,
    hue_iris,
    hue_bloom,
    bollard,
    wall_washer,
    hue_play,
    hue_chime,
    vintage_bulb,
    vintage_candle_bulb,
    ellipse_bulb,
    triangle_bulb,
    small_globe_bulb,
    large_globe_bulb,
    edison_bulb,
    christmas_tree,
    string_light,
    hue_centris,
    hue_lightstrip_tv,
    hue_lightstrip_pc,
    hue_tube,
    hue_signe,
    pendant_spot,
    ceiling_horizontal,
    ceiling_tube,
    up_and_down,
    up_and_down_up,
    up_and_down_down,
    hue_floodlight_camera,
    twilight,
    twilight_front,
    twilight_back,
    hue_play_wallwasher,
    hue_omniglow,
    hue_neon,
    string_globe,
    string_permanent,
    hue_go_xxl,
    hue_switch_module,
    rigid_tube,
    flexible_tube,
    panels,
    pendant_tube,
    vertical_tube,
    recessed_ceiling_tube,
    wall_rectangle,
    string_icicle,
    string_grid,
    string_net,
    hue_omniglow_arc,
    hue_flux_arc,

    pub fn fromString(str: []const u8) ?ProductArchetype {
        return std.meta.stringToEnum(ProductArchetype, str);
    }

    pub fn label(self: ProductArchetype) []const u8 {
        return @tagName(self);
    }
};

/// Unused elsewhere - Device parses model_id/manufacturer_name/etc as
/// individual fields inline rather than through this shared shape.
/// Carried forward as-is from the pre-split file.
pub const ProductData = struct {
    model_id: []const u8,
    manufacturer_name: []const u8,
    product_name: []const u8,
    product_archetype: []const u8,
    certified: bool,
    software_version: []const u8,
    hardware_platform_type: ?[]const u8,
};

pub const Device = struct {
    gpa: Allocator,
    id: []const u8,
    timestamp: ?std.Io.Timestamp,
    services: ?[]ResourceIdentifier,
    name: ?[]const u8,
    model_id: ?[]const u8,
    product_archetype: ?ProductArchetype,
    user_archetype: ?ProductArchetype,
    manufacturer_name: ?[]const u8,
    software_version: ?[]const u8,
    product_name: ?[]const u8,
    certified: ?bool,

    pub fn fromJson(gpa: Allocator, obj: std.json.ObjectMap) !Device {
        try validateType(.device, obj);
        var dev = Device{
            .gpa = gpa,
            .id = try gpa.dupe(u8, try json_get.string(obj, "id")),
            .timestamp = null,
            .services = null,
            .name = null,
            .user_archetype = null,
            .model_id = null,
            .product_archetype = null,
            .manufacturer_name = null,
            .software_version = null,
            .product_name = null,
            .certified = null,
        };
        errdefer dev.deinit();

        const event: EventUpdate = .{
            .id = dev.id,
            .timestamp = null,
            .data = obj,
            .updateType = .device,
        };
        try dev.applyUpdate(event);
        return dev;
    }

    pub fn applyUpdate(self: *Device, event: EventUpdate) !void {
        if (!std.mem.eql(u8, event.id, self.id)) return error.InvalidId;
        try validateEntry(event.id, .device, event.data);

        var services_staged: ?[]ResourceIdentifier = null;
        var name_staged: ?[]const u8 = null;
        var model_id_staged: ?[]const u8 = null;
        var manufacturer_name_staged: ?[]const u8 = null;
        var product_name_staged: ?[]const u8 = null;
        var software_version_staged: ?[]const u8 = null;
        var user_arch = self.user_archetype;
        var prod_arch = self.product_archetype;
        var cert = self.certified;

        // Centralised error rollback block handles all staged field properties cleanly
        errdefer {
            if (services_staged) |srvs| {
                for (srvs) |*ri| ri.deinit(self.gpa);
                self.gpa.free(srvs);
            }
            if (name_staged) |nm| self.gpa.free(nm);
            if (model_id_staged) |mid| self.gpa.free(mid);
            if (manufacturer_name_staged) |mfg| self.gpa.free(mfg);
            if (product_name_staged) |pnm| self.gpa.free(pnm);
            if (software_version_staged) |swv| self.gpa.free(swv);
        }

        if (json_get.optionalArray(event.data, "services")) |arr| {
            var list = try ResourceIdentifier.fromList(self.gpa, arr);
            errdefer list.deinit(self.gpa);
            services_staged = try list.toOwnedSlice(self.gpa);
        }

        if (json_get.optionalObject(event.data, "metadata")) |metadataObj| {
            if (json_get.optionalString(metadataObj, "name")) |name| {
                name_staged = try self.gpa.dupe(u8, name);
            }
            if (json_get.optionalString(metadataObj, "archetype")) |archetype| {
                user_arch = ProductArchetype.fromString(archetype);
            }
        }

        if (json_get.optionalObject(event.data, "product_data")) |productObj| {
            if (json_get.optionalString(productObj, "model_id")) |mid| {
                model_id_staged = try self.gpa.dupe(u8, mid);
            }
            if (json_get.optionalString(productObj, "manufacturer_name")) |mname| {
                manufacturer_name_staged = try self.gpa.dupe(u8, mname);
            }
            if (json_get.optionalString(productObj, "product_name")) |pname| {
                product_name_staged = try self.gpa.dupe(u8, pname);
            }
            if (json_get.optionalString(productObj, "product_archetype")) |optVal| {
                prod_arch = ProductArchetype.fromString(optVal);
            }
            if (json_get.optionalBool(productObj, "certified")) |certified| {
                cert = certified;
            }
            if (json_get.optionalString(productObj, "software_version")) |optVal| {
                software_version_staged = try self.gpa.dupe(u8, optVal);
            }
        }

        // Transaction Point (Commit Phase) - Zero chance of failure from here onwards
        if (services_staged) |new_services| {
            if (self.services) |old_services| {
                for (old_services) |*ri| ri.deinit(self.gpa);
                self.gpa.free(old_services);
            }
            self.services = new_services;
        }
        commitOptionalString(self.gpa, &self.name, name_staged);
        commitOptionalString(self.gpa, &self.model_id, model_id_staged);
        commitOptionalString(self.gpa, &self.manufacturer_name, manufacturer_name_staged);
        commitOptionalString(self.gpa, &self.product_name, product_name_staged);
        commitOptionalString(self.gpa, &self.software_version, software_version_staged);
        self.user_archetype = user_arch;
        self.product_archetype = prod_arch;
        self.certified = cert;

        self.timestamp = event.timestamp;
    }

    pub fn deinit(self: *Device) void {
        deepFree(self.gpa, self.*);
    }

    pub fn format(self: Device, writer: *std.Io.Writer) !void {
        var archetype: []const u8 = if (self.product_archetype) |a| a.label() else "unknown";
        if (self.product_name) |fallback| {
            archetype = fallback;
        }
        const label = archetype[0..@min(archetype.len, 25)];
        //const services_count: usize = if (self.services) |s| s.len else 0;
        try writer.print(
            "{s:<25} {?s:<25}", //{?s:<15} {?s:<25} {?s:<10} {d} services",
            .{
                label,
                self.name,
                // self.model_id,
                // self.manufacturer_name,
                // self.software_version,
                // services_count,
            },
        );
    }

    // Prints dev room, name and service details
    pub fn fmtShort(self: Device) struct {
        dev: Device,

        pub fn format(ctx: @This(), writer: anytype) !void {
            var archetype: []const u8 = if (ctx.dev.product_archetype) |a| a.label() else "unknown";

            if (ctx.dev.product_name) |fallback| {
                archetype = fallback;
            }
            const label = archetype[0..@min(archetype.len, 25)];
            try writer.print("{[label]s:<25} {[name]s:<28}", .{
                .label = label,
                .name = ctx.dev.name,
            });
        }
    } {
        return .{ .dev = self };
    }
};

pub const DeviceSoftwareUpdate = struct {
    gpa: Allocator,
    id: []const u8,
    timestamp: ?std.Io.Timestamp,
    owner_rid: []const u8,
    owner_rtype: ResourceType,
    status: ?SoftwareUpdateStatus,

    pub fn fromJson(gpa: Allocator, obj: std.json.ObjectMap) !DeviceSoftwareUpdate {
        try validateType(.device_software_update, obj);
        const owner = try ResourceIdentifier.fromJson(gpa, try json_get.object(obj, "owner"));
        errdefer gpa.free(owner.rid);

        const id = gpa.dupe(u8, try json_get.string(obj, "id")) catch |err| {
            gpa.free(owner.rid);
            return err;
        };

        var dsu = DeviceSoftwareUpdate{
            .gpa = gpa,
            .id = id,
            .timestamp = null,
            .owner_rid = owner.rid,
            .owner_rtype = owner.rtype,
            .status = null,
        };
        errdefer dsu.deinit();

        const event: EventUpdate = .{
            .id = dsu.id,
            .timestamp = null,
            .data = obj,
            .updateType = .device_software_update,
        };
        try dsu.applyUpdate(event);
        return dsu;
    }

    pub fn applyUpdate(self: *DeviceSoftwareUpdate, event: EventUpdate) !void {
        if (!std.mem.eql(u8, event.id, self.id)) return error.InvalidId;
        try validateEntry(event.id, .device_software_update, event.data);

        var staged_status = self.status;

        if (json_get.optionalObject(event.data, "software_update")) |swObj| {
            if (json_get.optionalString(swObj, "status")) |status| {
                staged_status = SoftwareUpdateStatus.fromString(status);
            }
        }

        // Commit Phase
        self.status = staged_status;

        self.timestamp = event.timestamp;
    }

    pub fn deinit(self: *DeviceSoftwareUpdate) void {
        deepFree(self.gpa, self.*);
    }

    pub fn format(self: DeviceSoftwareUpdate, writer: *std.Io.Writer) !void {
        const status: []const u8 = if (self.status) |s| s.label() else "unknown";
        try writer.print("Status: {s}", .{status});
    }
};

pub const ZigbeeConnectivity = struct {
    gpa: Allocator,
    id: []const u8,
    timestamp: ?std.Io.Timestamp,
    owner_rid: []const u8,
    owner_rtype: ResourceType,
    status: ?ZigbeeConnectivityStatus,
    mac_address: ?[]const u8,

    pub fn fromJson(gpa: Allocator, obj: std.json.ObjectMap) !ZigbeeConnectivity {
        try validateType(.zigbee_connectivity, obj);
        const owner = try ResourceIdentifier.fromJson(gpa, try json_get.object(obj, "owner"));
        errdefer gpa.free(owner.rid);

        const id = gpa.dupe(u8, try json_get.string(obj, "id")) catch |err| {
            gpa.free(owner.rid);
            return err;
        };

        var zc = ZigbeeConnectivity{
            .gpa = gpa,
            .id = id,
            .timestamp = null,
            .owner_rid = owner.rid,
            .owner_rtype = owner.rtype,
            .status = null,
            .mac_address = null,
        };
        errdefer zc.deinit();

        const event: EventUpdate = .{
            .id = zc.id,
            .timestamp = null,
            .data = obj,
            .updateType = .zigbee_connectivity,
        };
        try zc.applyUpdate(event);
        return zc;
    }

    pub fn applyUpdate(self: *ZigbeeConnectivity, event: EventUpdate) !void {
        if (!std.mem.eql(u8, event.id, self.id)) return error.InvalidId;
        try validateEntry(event.id, .zigbee_connectivity, event.data);

        var status_staged = self.status;
        var mac_staged: ?[]const u8 = null;

        errdefer {
            if (mac_staged) |m| self.gpa.free(m);
        }

        if (json_get.optionalString(event.data, "status")) |status| {
            status_staged = ZigbeeConnectivityStatus.fromString(status);
        }

        if (json_get.optionalString(event.data, "mac_address")) |mac| {
            mac_staged = try self.gpa.dupe(u8, mac);
        }

        // Commit Phase
        self.status = status_staged;
        commitOptionalString(self.gpa, &self.mac_address, mac_staged);

        self.timestamp = event.timestamp;
    }

    pub fn deinit(self: *ZigbeeConnectivity) void {
        deepFree(self.gpa, self.*);
    }

    pub fn format(self: ZigbeeConnectivity, writer: *std.Io.Writer) !void {
        const status: []const u8 = if (self.status) |s| s.label() else "unknown";
        try writer.print("Status: {s}, MAC: {?s}", .{ status, self.mac_address });
    }
};

pub const ZigbeeDeviceDiscovery = struct {
    gpa: Allocator,
    id: []const u8,
    timestamp: ?std.Io.Timestamp,
    owner_rid: []const u8,
    owner_rtype: ResourceType,
    status: ?ZigbeeDiscoveryStatus,

    pub fn fromJson(gpa: Allocator, obj: std.json.ObjectMap) !ZigbeeDeviceDiscovery {
        try validateType(.zigbee_device_discovery, obj);
        const owner = try ResourceIdentifier.fromJson(gpa, try json_get.object(obj, "owner"));
        errdefer gpa.free(owner.rid);

        const id = gpa.dupe(u8, try json_get.string(obj, "id")) catch |err| {
            gpa.free(owner.rid);
            return err;
        };

        var zdd = ZigbeeDeviceDiscovery{
            .gpa = gpa,
            .id = id,
            .timestamp = null,
            .owner_rid = owner.rid,
            .owner_rtype = owner.rtype,
            .status = null,
        };
        errdefer zdd.deinit();

        const event: EventUpdate = .{
            .id = zdd.id,
            .timestamp = null,
            .data = obj,
            .updateType = .zigbee_device_discovery,
        };
        try zdd.applyUpdate(event);
        return zdd;
    }

    pub fn applyUpdate(self: *ZigbeeDeviceDiscovery, event: EventUpdate) !void {
        if (!std.mem.eql(u8, event.id, self.id)) return error.InvalidId;
        try validateEntry(event.id, .zigbee_device_discovery, event.data);

        var status_staged = self.status;

        if (json_get.optionalObject(event.data, "action")) |action_obj| {
            if (json_get.optionalString(action_obj, "status")) |status| {
                status_staged = ZigbeeDiscoveryStatus.fromString(status);
            }
        }

        // Commit Phase
        self.status = status_staged;

        self.timestamp = event.timestamp;
    }

    pub fn deinit(self: *ZigbeeDeviceDiscovery) void {
        deepFree(self.gpa, self.*);
    }

    pub fn format(self: ZigbeeDeviceDiscovery, writer: *std.Io.Writer) !void {
        const status: []const u8 = if (self.status) |s| s.label() else "unknown";
        try writer.print("Status: {s}", .{status});
    }
};

/// `device_software_update.status`. Values per the Hue CLIP v2 API
/// (hue-sse-events.md: "`status` values: `no_update`, `update_available`,
/// `ready_to_install`, `installing`"). The first variant here used to be
/// spelled `update_pending`, which doesn't match any value the bridge
/// actually sends - that meant the single most common transition ("an
/// update is available") always fell through to `.unknown` instead of
/// ever matching. Renamed to `update_available` to match the documented
/// API (this is a genuine pre-existing bug fix, not a stylistic rename).
pub const SoftwareUpdateStatus = enum {
    update_available,
    no_update,
    ready_to_install,
    installing,
    unknown,

    pub fn fromString(str: []const u8) SoftwareUpdateStatus {
        return std.meta.stringToEnum(SoftwareUpdateStatus, str) orelse .unknown;
    }

    pub fn label(self: SoftwareUpdateStatus) []const u8 {
        return switch (self) {
            .update_available => "update_available",
            .no_update => "no_update",
            .ready_to_install => "ready_to_install",
            .installing => "installing",
            .unknown => "unknown",
        };
    }

    pub fn toString(self: SoftwareUpdateStatus, allocator: std.mem.Allocator) ![]const u8 {
        return allocator.print("{s}", .{@tagName(self)});
    }
};

pub const ZigbeeConnectivityStatus = enum {
    connected,
    disconnected,
    connectivity_issue,
    unidirectional_incoming,
    pending_discovery,
    unknown,

    pub fn fromString(str: []const u8) ZigbeeConnectivityStatus {
        return std.meta.stringToEnum(ZigbeeConnectivityStatus, str) orelse .unknown;
    }

    pub fn label(self: ZigbeeConnectivityStatus) []const u8 {
        return switch (self) {
            .connected => "Connected",
            .disconnected => "Disconnected",
            .connectivity_issue => "Connectivity Issue",
            .unidirectional_incoming => "Unidirectional Incoming",
            .pending_discovery => "Pending Discovery",
            .unknown => "Unknown",
        };
    }

    pub fn toString(self: ZigbeeConnectivityStatus, allocator: std.mem.Allocator) ![]const u8 {
        return allocator.print("{s}", .{@tagName(self)});
    }
};

pub const ZigbeeDiscoveryStatus = enum {
    active,
    ready,
    unknown,

    pub fn fromString(str: []const u8) ZigbeeDiscoveryStatus {
        return std.meta.stringToEnum(ZigbeeDiscoveryStatus, str) orelse .unknown;
    }

    pub fn label(self: ZigbeeDiscoveryStatus) []const u8 {
        return switch (self) {
            .active => "active",
            .ready => "ready",
            .unknown => "unknown",
        };
    }

    pub fn toString(self: ZigbeeDiscoveryStatus, allocator: std.mem.Allocator) ![]const u8 {
        return allocator.print("{s}", .{@tagName(self)});
    }
};
