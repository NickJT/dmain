//! Public surface of the resource model - re-exports every type from
//! `src/resources/*.zig` under its original name, so nothing outside this
//! file needs to know about the split. See `src/resources/common.zig` for
//! the shared `ResourceType`/`Resource` union and generic helpers, and the
//! other files in that directory for each resource family
//! (light/sensors/device/topology/automation_extras).
//!
//! This file replaces what used to be one ~4,200-line monolith. The split
//! is purely organizational - every symbol below has the same name,
//! type, and behavior it always did, except for a handful of fields that
//! were `[]const u8` and are now proper enums (see each family file's
//! doc comments for which, and why). Two pre-existing bugs were fixed
//! along the way (see device.zig's `SoftwareUpdateStatus` and this being
//! the reason `resources.zig` itself is worth reading if you're curious
//! what changed): everything else is a mechanical move.

const std = @import("std");

const common = @import("resources/common.zig");
const light = @import("resources/light.zig");
const sensors = @import("resources/sensors.zig");
const device = @import("resources/device.zig");
const topology = @import("resources/topology.zig");
const automation = @import("resources/automation_extras.zig");

// ── common.zig ──────────────────────────────────────────────────
pub const ResourceType = common.ResourceType;
pub const Resource = common.Resource;
pub const ResourceIdentifier = common.ResourceIdentifier;
pub const EventUpdate = common.EventUpdate;
pub const compareByOwnerRid = common.compareByOwnerRid;
pub const compareByFieldCompTime = common.compareByFieldCompTime;
pub const compareByFieldCompTimeNullable = common.compareByFieldCompTimeNullable;
pub const Metadata = common.Metadata;
pub const Position = common.Position;
// `pub const ContainerView = common.ContainerView;` was here and could never
// compile — `common.zig` has no such declaration, and nothing in the repo used
// it. `zig build` passed regardless because Zig's lazy analysis never reached a
// decl the executable does not reference; `zig build test`, which compiles this
// file as a root, failed on it. Removed 2026-07-25 during a move between
// packages, which is when the test step was first run here.

// ── light.zig ───────────────────────────────────────────────────
pub const Light = light.Light;
pub const LightArchetype = light.LightArchetype;
pub const LightFunction = light.LightFunction;
pub const LightMode = light.LightMode;
pub const GamutType = light.GamutType;
pub const PowerupPreset = light.PowerupPreset;
pub const compareByName = light.compareByName;

// ── sensors.zig ─────────────────────────────────────────────────
pub const Motion = sensors.Motion;
pub const Temperature = sensors.Temperature;
pub const LightLevel = sensors.LightLevel;
pub const DevicePower = sensors.DevicePower;
pub const Button = sensors.Button;
pub const RelativeRotary = sensors.RelativeRotary;
pub const GroupedLight = sensors.GroupedLight;
pub const GroupedLightLevel = sensors.GroupedLightLevel;
pub const GroupedMotion = sensors.GroupedMotion;
pub const Contact = sensors.Contact;
pub const Tamper = sensors.Tamper;
pub const MotionAreaCandidate = sensors.MotionAreaCandidate;
pub const BatteryState = sensors.BatteryState;
pub const ButtonEvent = sensors.ButtonEvent;
pub const MotionStatus = sensors.MotionStatus;
pub const ContactState = sensors.ContactState;

// ── device.zig ──────────────────────────────────────────────────
pub const Device = device.Device;
pub const DeviceSoftwareUpdate = device.DeviceSoftwareUpdate;
pub const ZigbeeConnectivity = device.ZigbeeConnectivity;
pub const ZigbeeDeviceDiscovery = device.ZigbeeDeviceDiscovery;
pub const ProductArchetype = device.ProductArchetype;
pub const ProductData = device.ProductData;
pub const SoftwareUpdateStatus = device.SoftwareUpdateStatus;
pub const ZigbeeConnectivityStatus = device.ZigbeeConnectivityStatus;
pub const ZigbeeDiscoveryStatus = device.ZigbeeDiscoveryStatus;

// ── topology.zig ────────────────────────────────────────────────
pub const Bridge = topology.Bridge;
pub const BridgeHome = topology.BridgeHome;
pub const Room = topology.Room;
pub const Zone = topology.Zone;
pub const ServiceGroup = topology.ServiceGroup;
pub const RoomArchetype = topology.RoomArchetype;

// ── automation_extras.zig ──────────────────────────────────────
pub const BehaviorInstance = automation.BehaviorInstance;
pub const BehaviorScript = automation.BehaviorScript;
pub const Clip = automation.Clip;
pub const Entertainment = automation.Entertainment;
pub const EntertainmentConfiguration = automation.EntertainmentConfiguration;
pub const Geolocation = automation.Geolocation;
pub const Matter = automation.Matter;
pub const PublicImage = automation.PublicImage;
pub const Scene = automation.Scene;
pub const ColorPaletteItem = automation.ColorPaletteItem;
pub const ColorTemperaturePaletteItem = automation.ColorTemperaturePaletteItem;
pub const ConfigurationType = automation.ConfigurationType;
pub const DayType = automation.DayType;
pub const DimmingPaletteItem = automation.DimmingPaletteItem;
pub const EntertainmentChannel = automation.EntertainmentChannel;
pub const EntertainmentSegment = automation.EntertainmentSegment;
pub const EntertainmentSegmentsCapability = automation.EntertainmentSegmentsCapability;
pub const ProxyMode = automation.ProxyMode;
pub const SceneAction = automation.SceneAction;
pub const SceneActionValues = automation.SceneActionValues;
pub const SceneActiveStatus = automation.SceneActiveStatus;
pub const Effect = automation.Effect;
pub const ScenePalette = automation.ScenePalette;
pub const SceneStatus = automation.SceneStatus;
pub const SceneTarget = automation.SceneTarget;
pub const ServiceStatus = automation.ServiceStatus;
pub const SegmentReference = automation.SegmentReference;
pub const ServiceLocation = automation.ServiceLocation;
pub const StreamProxy = automation.StreamProxy;
pub const StreamStatus = automation.StreamStatus;

test "Force Semantic Check" {
    // This built-in function forces the compiler to look at
    // EVERY single struct, function, and variable in this file,
    // completely bypassing lazy analysis during 'zig build test'.
    std.testing.refAllDecls(@This());
}

// COnfirm that each ResourceType can be parsed from JSON and converted to a Resource union.
test "oneOfEach" {
    var arena_block = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_block.deinit();
    const arena = arena_block.allocator();

    var emap = std.EnumMap(ResourceType, []const u8).init(.{});
    const startAt = 8000;
    var d: u32 = startAt;
    inline for (@typeInfo(Resource).@"union".field_names, @typeInfo(Resource).@"union".field_types) |field_name, field_type| {
        const part1: []const u8 = "{\"id\": \"";
        const id_part1 = "956eda8a-7298-413b-";
        const id_part2: []const u8 = "-afd06a92189f";
        const part2: []const u8 = "\", \"owner\": {\"rid\": \"ec7eccea-5d7c-4e6c-8fa3-4bb47af13f17\",\"rtype\": \"room\"}, \"type\": \"";
        const part3: []const u8 = "\"}";
        const id = try arena.print("{s}{d}{s}", .{ id_part1, d, id_part2 });
        const defJ = try arena.print("{s}{s}{s}{s}{s}", .{ part1, id, part2, field_name, part3 });
        const parsed = try std.json.parseFromSlice(std.json.Value, arena, defJ, .{});
        const obj = parsed.value.object;
        const res = @unionInit(Resource, field_name, try field_type.fromJson(arena, obj));
        emap.put(res, id);
        d = d + 1;
    }
    var present = true;
    var it = emap.iterator();
    while (it.next()) |kv| {
        present = present & (kv.value.*.len == 36);
    }
    try std.testing.expect(emap.count() == d - startAt);
    try std.testing.expect(present);
}

// Forces real compilation and execution of every newly added `format()`.
// refAllDecls only takes the address of top-level decls in this file (the
// resource struct *types*), it does not reach inside them to their member
// functions, so an unused format() can compile clean yet still be broken.
test "format new resource types" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const gpa = std.testing.allocator;
    const ts = std.Io.Timestamp.fromNanoseconds(1_700_000_000_000_000_000);

    const device_val = Device{
        .gpa = gpa,
        .id = "dev-1",
        .timestamp = null,
        .services = null,
        .name = "Hallway Light",
        .model_id = "LCT015",
        .product_archetype = .classic_bulb,
        .user_archetype = null,
        .manufacturer_name = "Signify",
        .software_version = "1.88.1",
        .product_name = "Hue color lamp",
        .certified = true,
    };
    try device_val.format(&writer);

    writer = std.Io.Writer.fixed(&buf);
    const dsu = DeviceSoftwareUpdate{
        .gpa = gpa,
        .id = "dsu-1",
        .timestamp = null,
        .owner_rid = "dev-1",
        .owner_rtype = .device,
        .status = .no_update,
    };
    try dsu.format(&writer);

    writer = std.Io.Writer.fixed(&buf);
    const gl = GroupedLight{ .gpa = gpa, .id = "gl-1", .timestamp = null, .on = true, .brightness = 80.0 };
    try gl.format(&writer);

    writer = std.Io.Writer.fixed(&buf);
    const gll = GroupedLightLevel{ .gpa = gpa, .id = "gll-1", .timestamp = null, .light_level = 12000, .changed = ts };
    try gll.format(&writer);

    writer = std.Io.Writer.fixed(&buf);
    const gm = GroupedMotion{ .gpa = gpa, .id = "gm-1", .timestamp = null, .motion = false, .changed = null };
    try gm.format(&writer);

    writer = std.Io.Writer.fixed(&buf);
    const light_val = Light{
        .gpa = gpa,
        .id = "light-1",
        .timestamp = null,
        .owner_rid = "dev-1",
        .owner_rtype = .device,
        .mode = .normal,
        .on = true,
        .name = "Lamp",
        .metaArchetype = .classic_bulb,
        .metaFixedMirek = null,
        .metaFunction = null,
        .pName = null,
        .pArchetype = null,
        .pFunction = null,
        .serviceId = null,
        .brightness = 55.5,
        .min_dim_level = null,
        .mirek = 300,
        .mirek_valid = true,
        .mirek_min = null,
        .mirek_max = null,
        .pu_preset = .safety,
        .pu_configured = true,
        .pu_mode = null,
        .pu_on = null,
        .pu_dimming = null,
        .pu_color = null,
    };
    try light_val.format(&writer);

    writer = std.Io.Writer.fixed(&buf);
    const ll = LightLevel{
        .gpa = gpa,
        .id = "ll-1",
        .timestamp = null,
        .owner_rid = "dev-1",
        .owner_rtype = .device,
        .enabled = true,
        .light_level = 15000,
        .changed = ts,
    };
    try ll.format(&writer);

    writer = std.Io.Writer.fixed(&buf);
    const motion = Motion{
        .gpa = gpa,
        .id = "motion-1",
        .timestamp = null,
        .owner_rid = "dev-1",
        .owner_rtype = .device,
        .enabled = true,
        .motion = true,
        .changed = ts,
    };
    try motion.format(&writer);

    writer = std.Io.Writer.fixed(&buf);
    const rr = RelativeRotary{
        .gpa = gpa,
        .id = "rr-1",
        .timestamp = null,
        .owner_rid = "dev-1",
        .owner_rtype = .device,
        .last_rotation = 1,
        .duration = 400,
    };
    try rr.format(&writer);

    writer = std.Io.Writer.fixed(&buf);
    const room = Room{ .gpa = gpa, .id = "room-1", .timestamp = null, .name = "Kitchen", .services = null, .children = null };
    try room.format(&writer);

    writer = std.Io.Writer.fixed(&buf);
    const temp = Temperature{
        .gpa = gpa,
        .id = "temp-1",
        .timestamp = null,
        .owner_rid = "dev-1",
        .owner_rtype = .device,
        .enabled = true,
        .temperature = 21.5,
        .changed = ts,
    };
    try temp.format(&writer);

    writer = std.Io.Writer.fixed(&buf);
    const zc = ZigbeeConnectivity{
        .gpa = gpa,
        .id = "zc-1",
        .timestamp = null,
        .owner_rid = "dev-1",
        .owner_rtype = .device,
        .status = .connected,
        .mac_address = "00:11:22:33:44:55",
    };
    try zc.format(&writer);

    writer = std.Io.Writer.fixed(&buf);
    const zdd = ZigbeeDeviceDiscovery{
        .gpa = gpa,
        .id = "zdd-1",
        .timestamp = null,
        .owner_rid = "dev-1",
        .owner_rtype = .device,
        .status = .active,
    };
    try zdd.format(&writer);

    writer = std.Io.Writer.fixed(&buf);
    const zone = Zone{ .gpa = gpa, .id = "zone-1", .timestamp = null, .name = "Downstairs", .services = null, .children = null };
    try zone.format(&writer);
}
