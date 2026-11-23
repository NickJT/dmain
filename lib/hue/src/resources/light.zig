//! The `light` resource and its value types.

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

const device = @import("device.zig");
const ProductArchetype = device.ProductArchetype;

pub const GamutType = enum {
    A,
    B,
    C,
    other,
    unknown,

    pub fn fromString(str: []const u8) GamutType {
        return std.meta.stringToEnum(GamutType, str) orelse .unknown;
    }

    pub fn label(self: GamutType) []const u8 {
        return switch (self) {
            .A => "A",
            .B => "B",
            .C => "C",
            .other => "other",
            .unknown => "unknown",
        };
    }
};

pub const LightArchetype = enum {
    bollard,
    bridge_v2,
    bridge_v3,
    candle_bulb,
    ceiling_horizontal,
    ceiling_round,
    ceiling_square,
    ceiling_tube,
    christmas_tree,
    classic_bulb,
    double_spot,
    edison_bulb,
    ellipse_bulb,
    flexible_lamp,
    flood_bulb,
    floor_lantern,
    floor_shade,
    ground_spot,
    hue_bloom,
    hue_centris,
    hue_chime,
    hue_floodlight_camera,
    hue_go,
    hue_iris,
    hue_lightstrip,
    hue_lightstrip_pc,
    hue_lightstrip_tv,
    hue_neon,
    hue_omniglow,
    hue_play,
    hue_play_wallwasher,
    hue_signe,
    hue_tube,
    large_globe_bulb,
    luster_bulb,
    pendant_long,
    pendant_round,
    pendant_spot,
    plug,
    recessed_ceiling,
    recessed_floor,
    single_spot,
    small_globe_bulb,
    spot_bulb,
    string_globe,
    string_light,
    string_permanent,
    sultan_bulb,
    table_shade,
    table_wash,
    triangle_bulb,
    twilight,
    twilight_back,
    twilight_front,
    up_and_down,
    up_and_down_down,
    up_and_down_up,
    vintage_bulb,
    vintage_candle_bulb,
    wall_lantern,
    wall_shade,
    wall_spot,
    wall_washer,

    pub fn fromString(str: []const u8) ?LightArchetype {
        return std.meta.stringToEnum(LightArchetype, str);
    }

    pub fn label(self: LightArchetype) []const u8 {
        return switch (self) {
            .bollard => "bollard",
            .bridge_v2 => "bridge_v2",
            .bridge_v3 => "bridge_v3",
            .candle_bulb => "candle_bulb",
            .ceiling_horizontal => "ceiling_horizontal",
            .ceiling_round => "ceiling_round",
            .ceiling_square => "ceiling_square",
            .ceiling_tube => "ceiling_tube",
            .christmas_tree => "christmas_tree",
            .classic_bulb => "classic_bulb",
            .double_spot => "double_spot",
            .edison_bulb => "edison_bulb",
            .ellipse_bulb => "ellipse_bulb",
            .flexible_lamp => "flexible_lamp",
            .flood_bulb => "flood_bulb",
            .floor_lantern => "floor_lantern",
            .floor_shade => "floor_shade",
            .ground_spot => "ground_spot",
            .hue_bloom => "hue_bloom",
            .hue_centris => "hue_centris",
            .hue_chime => "hue_chime",
            .hue_floodlight_camera => "hue_floodlight_camera",
            .hue_go => "hue_go",
            .hue_iris => "hue_iris",
            .hue_lightstrip => "hue_lightstrip",
            .hue_lightstrip_pc => "hue_lightstrip_pc",
            .hue_lightstrip_tv => "hue_lightstrip_tv",
            .hue_neon => "hue_neon",
            .hue_omniglow => "hue_omniglow",
            .hue_play => "hue_play",
            .hue_play_wallwasher => "hue_play_wallwasher",
            .hue_signe => "hue_signe",
            .hue_tube => "hue_tube",
            .large_globe_bulb => "large_globe_bulb",
            .luster_bulb => "luster_bulb",
            .pendant_long => "pendant_long",
            .pendant_round => "pendant_round",
            .pendant_spot => "pendant_spot",
            .plug => "plug",
            .recessed_ceiling => "recessed_ceiling",
            .recessed_floor => "recessed_floor",
            .single_spot => "single_spot",
            .small_globe_bulb => "small_globe_bulb",
            .spot_bulb => "spot_bulb",
            .string_globe => "string_globe",
            .string_light => "string_light",
            .string_permanent => "string_permanent",
            .sultan_bulb => "sultan_bulb",
            .table_shade => "table_shade",
            .table_wash => "table_wash",
            .triangle_bulb => "triangle_bulb",
            .twilight => "twilight",
            .twilight_back => "twilight_back",
            .twilight_front => "twilight_front",
            .up_and_down => "up_and_down",
            .up_and_down_down => "up_and_down_down",
            .up_and_down_up => "up_and_down_up",
            .vintage_bulb => "vintage_bulb",
            .vintage_candle_bulb => "vintage_candle_bulb",
            .wall_lantern => "wall_lantern",
            .wall_shade => "wall_shade",
            .wall_spot => "wall_spot",
            .wall_washer => "wall_washer",
        };
    }
};

pub const LightFunction = enum {
    functional,
    decorative,
    mixed,
    unknown,

    pub fn fromString(str: []const u8) LightFunction {
        return std.meta.stringToEnum(LightFunction, str) orelse .unknown;
    }

    pub fn label(self: LightFunction) []const u8 {
        return switch (self) {
            .functional => "functional",
            .decorative => "decorative",
            .mixed => "mixed",
            .unknown => "unknown",
        };
    }
};

pub const LightMode = enum {
    normal,
    streaming,
    unknown,

    pub fn fromString(str: []const u8) LightMode {
        return std.meta.stringToEnum(LightMode, str) orelse .unknown;
    }

    pub fn label(self: LightMode) []const u8 {
        return switch (self) {
            .normal => "normal",
            .streaming => "streaming",
            .unknown => "unknown",
        };
    }
};

/// `light.powerup.preset` - what a light should do the moment power is
/// restored after an outage. Values per the Hue CLIP v2 API (corroborated
/// by this codebase's own `screens.zig` power-fail legend: "safety = Full
/// on, last_on = On/last brightness" / "powerfail = stay off or turn back
/// on", and by the pre-split `test "format new resource types"` literal
/// `.pu_preset = "safety"`).
pub const PowerupPreset = enum {
    safety,
    powerfail,
    last_on_state,
    custom,

    pub fn fromString(str: []const u8) ?PowerupPreset {
        return std.meta.stringToEnum(PowerupPreset, str);
    }

    pub fn label(self: PowerupPreset) []const u8 {
        return switch (self) {
            .safety => "safety",
            .powerfail => "powerfail",
            .last_on_state => "last_on_state",
            .custom => "custom",
        };
    }
};

pub const Light = struct {
    gpa: Allocator,
    id: []const u8,
    timestamp: ?std.Io.Timestamp,
    owner_rid: []const u8,
    owner_rtype: ResourceType,
    mode: ?LightMode,
    on: ?bool,

    // Metadata
    name: ?[]const u8,
    metaArchetype: ?ProductArchetype,
    metaFixedMirek: ?i64,
    metaFunction: ?LightFunction,

    pName: ?[]const u8,
    pArchetype: ?LightArchetype,
    pFunction: ?LightFunction,

    serviceId: ?i64,

    // Dimming
    brightness: ?f64,
    min_dim_level: ?f64,

    // Colour temperature
    mirek: ?i64,
    mirek_valid: ?bool,
    mirek_min: ?i64,
    mirek_max: ?i64,

    pu_preset: ?PowerupPreset,
    pu_configured: ?bool,
    // pu_mode (powerup.on.mode), pu_dimming (powerup.dimming.mode):
    // likely closed sets (on/toggle/previous, dimming/previous per the
    // Hue API) but not corroborated anywhere in this codebase the way
    // pu_preset is - left as strings rather than guessed enums. See the
    // resources.zig split summary for the full flagged list.
    pu_mode: ?[]const u8,
    pu_on: ?bool,
    pu_dimming: ?[]const u8,
    pu_color: ?[]const u8,
    /// powerup.dimming.dimming.brightness, when the mode sets one.
    pu_brightness: ?f64 = null,
    /// powerup.color.color_temperature.mirek, when the mode sets one.
    pu_mirek: ?i64 = null,

    pub fn fromJson(gpa: Allocator, obj: std.json.ObjectMap) !Light {
        try validateType(.light, obj);

        // 1. Safe parsing of the ResourceIdentifier (allocates owner.rid)
        const owner = try ResourceIdentifier.fromJson(gpa, try json_get.object(obj, "owner"));
        errdefer gpa.free(owner.rid);

        // 2. Safe duplication of identity string
        const id = try gpa.dupe(u8, try json_get.string(obj, "id"));
        errdefer gpa.free(id);

        // 3. Setup core struct instance with structural defaults
        var instance = Light{
            .gpa = gpa,
            .id = id,
            .timestamp = null,
            .owner_rid = owner.rid,
            .owner_rtype = owner.rtype,
            .on = false,
            .mode = .unknown,
            .name = null,
            .metaArchetype = null,
            .metaFixedMirek = null,
            .metaFunction = null,
            .pName = null,
            .pArchetype = null,
            .pFunction = null,
            .serviceId = null,
            .brightness = null,
            .min_dim_level = null,
            .mirek = null,
            .mirek_valid = null,
            .mirek_min = null,
            .mirek_max = null,
            .pu_preset = null,
            .pu_configured = false,
            .pu_mode = null,
            .pu_on = null,
            .pu_dimming = null,
            .pu_color = null,
        };
        // Once instance is instantiated, instance.deinit() safely cleans up on failure
        errdefer instance.deinit();

        // 4. Transform payload to event stream update format and parse properties
        const event: EventUpdate = .{
            .id = instance.id,
            .data = obj,
            .timestamp = null,
            .updateType = .light,
        };

        try instance.applyUpdate(event);
        return instance;
    }

    pub fn applyUpdate(self: *Light, event: EventUpdate) !void {
        if (!std.mem.eql(u8, event.id, self.id)) return error.InvalidId;
        try validateEntry(event.id, .light, event.data);

        // --- Value types: Direct assignment ---
        if (json_get.optionalObject(event.data, "on")) |o| {
            self.on = try json_get.boolean(o, "on");
        }

        if (json_get.optionalObject(event.data, "color_temperature")) |ct| {
            self.mirek_valid = try json_get.boolean(ct, "mirek_valid");
            if (self.mirek_valid orelse false) {
                self.mirek = json_get.optionalInt(ct, "mirek");
            }
            if (json_get.optionalObject(ct, "mirek_schema")) |schema| {
                self.mirek_min = json_get.optionalInt(schema, "mirek_minimum");
                self.mirek_max = json_get.optionalInt(schema, "mirek_maximum");
            }
        }

        if (json_get.optionalString(event.data, "mode")) |m| self.mode = LightMode.fromString(m);
        if (json_get.optionalInt(event.data, "service_id")) |serviceId| self.serviceId = serviceId;

        // --- Metadata: Swap-on-Success for strings ---
        if (json_get.optionalObject(event.data, "metadata")) |m| {
            if (json_get.optionalString(m, "name")) |val| {
                commitOptionalString(self.gpa, &self.name, try self.gpa.dupe(u8, val));
            }
            if (json_get.optionalString(m, "archetype")) |val| {
                self.metaArchetype = ProductArchetype.fromString(val);
            }
            if (json_get.optionalInt(m, "fixed_mirek")) |fm| self.metaFixedMirek = fm;
        }

        // --- Product Data: Swap-on-Success for strings ---
        if (json_get.optionalObject(event.data, "product_data")) |pd| {
            if (json_get.optionalString(pd, "name")) |val| {
                commitOptionalString(self.gpa, &self.pName, try self.gpa.dupe(u8, val));
            }
            if (json_get.optionalString(pd, "archetype")) |a| self.pArchetype = LightArchetype.fromString(a);
            if (json_get.optionalString(pd, "function")) |f| self.pFunction = LightFunction.fromString(f);
        }

        // --- Dimming ---
        if (json_get.optionalObject(event.data, "dimming")) |d| {
            self.brightness = json_get.floatOr(d, "brightness", 0.0);
            self.min_dim_level = json_get.optionalFloat(d, "min_dim_level");
        }

        // --- Powerup: Swap-on-Success for all nested strings ---
        if (json_get.optionalObject(event.data, "powerup")) |pu| {
            if (json_get.optionalString(pu, "preset")) |val| {
                self.pu_preset = PowerupPreset.fromString(val);
            }
            if (json_get.optionalBool(pu, "configured")) |v| self.pu_configured = v;

            // Nested: powerup.on
            if (json_get.optionalObject(pu, "on")) |o| {
                if (json_get.optionalString(o, "mode")) |val| {
                    commitOptionalString(self.gpa, &self.pu_mode, try self.gpa.dupe(u8, val));
                }
                if (json_get.optionalObject(o, "on")) |on_obj| {
                    if (json_get.optionalBool(on_obj, "on")) |b| {
                        self.pu_on = b;
                    }
                }
            }

            // Nested: powerup.dimming
            if (json_get.optionalObject(pu, "dimming")) |d| {
                if (json_get.optionalString(d, "mode")) |val| {
                    commitOptionalString(self.gpa, &self.pu_dimming, try self.gpa.dupe(u8, val));
                }
                if (json_get.optionalObject(d, "dimming")) |v| {
                    self.pu_brightness = json_get.optionalFloat(v, "brightness");
                } else {
                    self.pu_brightness = null;
                }
            }

            // Nested: powerup.color
            if (json_get.optionalObject(pu, "color")) |c| {
                if (json_get.optionalString(c, "mode")) |val| {
                    commitOptionalString(self.gpa, &self.pu_color, try self.gpa.dupe(u8, val));
                }
                if (json_get.optionalObject(c, "color_temperature")) |v| {
                    self.pu_mirek = json_get.optionalInt(v, "mirek");
                } else {
                    self.pu_mirek = null;
                }
            }
        }

        self.timestamp = event.timestamp;
    }

    pub fn deinit(self: *Light) void {
        deepFree(self.gpa, self.*);
    }

    fn miredToKelvin(mirek: i64) i64 {
        return @divTrunc(1_000_000, mirek);
    }

    pub fn format(self: Light, writer: *std.Io.Writer) !void {
        const archetype: []const u8 = if (self.metaArchetype) |a| a.label() else "unknown";
        const mode: []const u8 = if (self.mode) |m| m.label() else "unknown";
        const mirek: ?i64 = if (self.mirek_valid orelse false) self.mirek else null;
        const preset: []const u8 = if (self.pu_preset) |p| p.label() else "unknown";

        try writer.print(
            "{?s}, Type: {s}, Svc id: {?d}, Configured: {?any}, Preset: {s}, On: {?any}, Brightness: {?d:.1}%, Mirek: {?d}, Mode: {s}",
            .{
                self.name,
                archetype,
                self.serviceId,
                self.pu_configured,
                preset,
                self.on,
                self.brightness,
                mirek,
                mode,
            },
        );
    }
};

pub fn compareByName(_: void, a: Light, b: Light) bool {
    const a_name = a.name orelse "none";
    const b_name = b.name orelse "none";
    return std.mem.order(u8, a_name, b_name) == .lt;
}

test "Light powerup parsing" {
    const json_text =
        \\{
        \\  "id": "light-test-1",
        \\  "type": "light",
        \\  "owner": { "rid": "dev-test-1", "rtype": "device" },
        \\  "powerup": {
        \\    "preset": "safety",
        \\    "configured": true,
        \\    "on": { "mode": "on", "on": { "on": true } },
        \\    "dimming": { "mode": "dimming" },
        \\    "color": { "mode": "color_temperature" }
        \\  }
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_text, .{});
    defer parsed.deinit();

    var light = try Light.fromJson(std.testing.allocator, parsed.value.object);
    defer light.deinit();

    try std.testing.expectEqual(true, light.pu_on);
    try std.testing.expectEqualStrings("on", light.pu_mode.?);
    try std.testing.expectEqualStrings("color_temperature", light.pu_color.?);
    try std.testing.expectEqualStrings("dimming", light.pu_dimming.?);
}
