//! Everything that isn't core lighting/sensor/topology data: Hue Labs
//! automations, scenes, entertainment/streaming, Matter bridging, and
//! bridge-level geolocation/image resources. Candidate bucket to drop
//! entirely if a future app only needs "actually necessary" Hue-hub
//! functions - kept together here specifically so that's easy to do.

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
const Position = common.Position;

pub const BehaviorInstance = struct {
    gpa: Allocator,
    id: []const u8,
    timestamp: ?std.Io.Timestamp,
    script_id: []const u8,
    enabled: ?bool,
    name: ?[]const u8,

    pub fn fromJson(gpa: Allocator, obj: std.json.ObjectMap) !BehaviorInstance {
        try validateType(.behavior_instance, obj);
        const parsed_id = try gpa.dupe(u8, try json_get.string(obj, "id"));
        errdefer gpa.free(parsed_id);

        var instance = BehaviorInstance{
            .gpa = gpa,
            .id = parsed_id,
            .timestamp = null,
            .script_id = &.{},
            .enabled = null,
            .name = null,
        };
        errdefer instance.deinit();

        const event: EventUpdate = .{
            .id = instance.id,
            .timestamp = null,
            .data = obj,
            .updateType = .behavior_instance,
        };
        try instance.applyUpdate(event);
        return instance;
    }

    pub fn applyUpdate(self: *BehaviorInstance, event: EventUpdate) !void {
        if (!std.mem.eql(u8, event.id, self.id)) return error.InvalidId;
        try validateEntry(event.id, .behavior_instance, event.data);

        // 1. Up-front staging fields
        var staged_script_id: ?[]const u8 = null;
        var staged_name: ?[]const u8 = null;

        // Central cleanup trap on failure
        errdefer {
            if (staged_script_id) |s| self.gpa.free(s);
            if (staged_name) |s| self.gpa.free(s);
        }

        // 2. Out-of-band parsing and allocations
        if (json_get.optionalString(event.data, "script_id")) |s| {
            staged_script_id = try self.gpa.dupe(u8, s);
        }

        if (json_get.optionalObject(event.data, "metadata")) |metadataObj| {
            if (json_get.optionalString(metadataObj, "name")) |s| {
                staged_name = try self.gpa.dupe(u8, s);
            }
        }

        // 3. Point of No Return: Atomic Commit Phase
        if (staged_script_id) |new_script_id| {
            self.gpa.free(self.script_id);
            self.script_id = new_script_id;
        }

        if (staged_name) |new_name| {
            if (self.name) |old_name| self.gpa.free(old_name);
            self.name = new_name;
        }

        if (json_get.optionalBool(event.data, "enabled")) |enabled| {
            self.enabled = enabled;
        }

        self.timestamp = event.timestamp orelse null;
    }

    pub fn deinit(self: *BehaviorInstance) void {
        deepFree(self.gpa, self.*);
    }
};

/// `behavior_script.metadata.category` is left as a string - the doc
/// only shows one example value ("automation") and doesn't enumerate the
/// full closed set, so it's flagged rather than guessed at.
pub const BehaviorScript = struct {
    gpa: Allocator,
    id: []const u8,
    timestamp: ?std.Io.Timestamp,
    description: []const u8,
    name: []const u8,
    category: []const u8,

    pub fn fromJson(gpa: Allocator, obj: std.json.ObjectMap) !BehaviorScript {
        try validateType(.behavior_script, obj);
        const parsed_id = try gpa.dupe(u8, try json_get.string(obj, "id"));
        errdefer gpa.free(parsed_id);

        var script = BehaviorScript{
            .gpa = gpa,
            .id = parsed_id,
            .timestamp = null,
            .description = &.{},
            .name = &.{},
            .category = &.{},
        };
        errdefer script.deinit();

        const event: EventUpdate = .{
            .id = script.id,
            .timestamp = null,
            .data = obj,
            .updateType = .behavior_script,
        };
        try script.applyUpdate(event);
        return script;
    }

    pub fn applyUpdate(self: *BehaviorScript, event: EventUpdate) !void {
        if (!std.mem.eql(u8, event.id, self.id)) return error.InvalidId;
        try validateEntry(event.id, .behavior_script, event.data);

        var staged_description: ?[]const u8 = null;
        var staged_name: ?[]const u8 = null;
        var staged_category: ?[]const u8 = null;

        errdefer {
            if (staged_description) |d| self.gpa.free(d);
            if (staged_name) |n| self.gpa.free(n);
            if (staged_category) |c| self.gpa.free(c);
        }

        if (json_get.optionalString(event.data, "description")) |description| {
            staged_description = try self.gpa.dupe(u8, description);
        }

        if (json_get.optionalObject(event.data, "metadata")) |metadataObj| {
            if (json_get.optionalString(metadataObj, "name")) |name| {
                staged_name = try self.gpa.dupe(u8, name);
            }
            if (json_get.optionalString(metadataObj, "category")) |category| {
                staged_category = try self.gpa.dupe(u8, category);
            }
        }

        // Commit Phase
        if (staged_description) |desc| {
            self.gpa.free(self.description);
            self.description = desc;
        }
        if (staged_name) |nm| {
            self.gpa.free(self.name);
            self.name = nm;
        }
        if (staged_category) |cat| {
            self.gpa.free(self.category);
            self.category = cat;
        }

        self.timestamp = event.timestamp;
    }

    pub fn deinit(self: *BehaviorScript) void {
        deepFree(self.gpa, self.*);
    }
};

pub const Clip = struct {
    gpa: Allocator,
    id: []const u8,
    timestamp: ?std.Io.Timestamp,
    resources: ?[][]const u8,

    pub fn fromJson(gpa: Allocator, obj: std.json.ObjectMap) !Clip {
        try validateType(.clip, obj);
        var clip = Clip{
            .gpa = gpa,
            .id = try gpa.dupe(u8, try json_get.string(obj, "id")),
            .timestamp = null,
            .resources = null,
        };
        errdefer clip.deinit();

        const event: EventUpdate = .{
            .id = clip.id,
            .timestamp = null,
            .data = obj,
            .updateType = .clip,
        };
        try clip.applyUpdate(event);
        return clip;
    }

    pub fn applyUpdate(self: *Clip, event: EventUpdate) !void {
        if (!std.mem.eql(u8, event.id, self.id)) return error.InvalidId;
        try validateEntry(event.id, .clip, event.data);

        if (json_get.optionalArray(event.data, "resources")) |resources| {
            var res = std.ArrayList([]const u8).empty;
            defer res.deinit(self.gpa);

            errdefer {
                for (res.items) |item|
                    self.gpa.free(item);
            }

            for (resources.items) |r| {
                const duped = try self.gpa.dupe(u8, r.string);
                errdefer self.gpa.free(duped);
                try res.append(self.gpa, duped);
            }

            const new_resources = try res.toOwnedSlice(self.gpa);
            errdefer {
                for (new_resources) |item|
                    self.gpa.free(item);
                self.gpa.free(new_resources);
            }

            // Transaction Point: old memory is only touched after complete success
            if (self.resources) |old| {
                for (old) |item| self.gpa.free(item);
                self.gpa.free(old);
            }
            self.resources = new_resources;
        }

        self.timestamp = event.timestamp;
    }

    pub fn deinit(self: *Clip) void {
        deepFree(self.gpa, self.*);
    }
};

pub const Entertainment = struct {
    gpa: Allocator,
    id: []const u8,
    timestamp: ?std.Io.Timestamp,
    owner_rid: []const u8,
    owner_rtype: ResourceType,
    renderer: ?bool,
    proxy: ?bool,

    pub fn fromJson(gpa: Allocator, obj: std.json.ObjectMap) !Entertainment {
        try validateType(.entertainment, obj);
        const owner = try ResourceIdentifier.fromJson(gpa, try json_get.object(obj, "owner"));
        errdefer gpa.free(owner.rid);

        const id = gpa.dupe(u8, try json_get.string(obj, "id")) catch |err| {
            gpa.free(owner.rid);
            return err;
        };

        var ent = Entertainment{
            .gpa = gpa,
            .id = id,
            .timestamp = null,
            .owner_rid = owner.rid,
            .owner_rtype = owner.rtype,
            .renderer = null,
            .proxy = null,
        };
        errdefer ent.deinit();

        const event: EventUpdate = .{
            .id = ent.id,
            .timestamp = null,
            .data = obj,
            .updateType = .entertainment,
        };
        try ent.applyUpdate(event);
        return ent;
    }

    pub fn applyUpdate(self: *Entertainment, event: EventUpdate) !void {
        if (!std.mem.eql(u8, event.id, self.id)) return error.InvalidId;
        try validateEntry(event.id, .entertainment, event.data);

        var renderer_staged = self.renderer;
        var proxy_staged = self.proxy;

        if (json_get.optionalBool(event.data, "renderer")) |r| {
            renderer_staged = r;
        }
        if (json_get.optionalBool(event.data, "proxy")) |p| {
            proxy_staged = p;
        }

        // Commit Phase (Infallible primitive mutations)
        self.renderer = renderer_staged;
        self.proxy = proxy_staged;

        self.timestamp = event.timestamp;
    }

    pub fn deinit(self: *Entertainment) void {
        deepFree(self.gpa, self.*);
    }
};

/// `entertainment_configuration.configuration_type`. Only "screen" is
/// confirmed by hue-sse-events.md's example - the other four variants
/// (monitor/music/3dspace/other) come from the pre-existing enum
/// definition (predates this split) rather than being independently
/// doc-verified here.
pub const ConfigurationType = enum {
    screen,
    monitor,
    music,
    @"3dspace",
    other,

    pub fn fromString(str: []const u8) ?ConfigurationType {
        return std.meta.stringToEnum(ConfigurationType, str);
    }

    pub fn label(self: ConfigurationType) []const u8 {
        return @tagName(self);
    }
};

pub const EntertainmentConfiguration = struct {
    gpa: Allocator,
    id: []const u8,
    timestamp: ?std.Io.Timestamp,
    name: ?[]const u8,
    stream_type: ?ConfigurationType,
    locations: ?[]ResourceIdentifier,

    pub fn fromJson(gpa: Allocator, obj: std.json.ObjectMap) !EntertainmentConfiguration {
        try validateType(.entertainment_configuration, obj);
        const id = try gpa.dupe(u8, try json_get.string(obj, "id"));

        var ec = EntertainmentConfiguration{
            .gpa = gpa,
            .id = id,
            .timestamp = null,
            .name = null,
            .stream_type = null,
            .locations = null,
        };
        errdefer ec.deinit();

        const event: EventUpdate = .{
            .id = ec.id,
            .timestamp = null,
            .data = obj,
            .updateType = .entertainment_configuration,
        };
        try ec.applyUpdate(event);
        return ec;
    }

    pub fn applyUpdate(self: *EntertainmentConfiguration, event: EventUpdate) !void {
        if (!std.mem.eql(u8, event.id, self.id)) return error.InvalidId;
        try validateEntry(event.id, .entertainment_configuration, event.data);

        var name_staged: ?[]const u8 = null;
        var stream_type_staged: ?ConfigurationType = null;
        var locations_staged: ?[]ResourceIdentifier = null;

        // Comprehensive roll-back scope for staged assets
        errdefer {
            if (name_staged) |n| self.gpa.free(n);
            if (locations_staged) |slice| {
                for (slice) |*ri| ri.deinit(self.gpa);
                self.gpa.free(slice);
            }
        }

        if (json_get.optionalObject(event.data, "metadata")) |metadataObj| {
            if (json_get.optionalString(metadataObj, "name")) |name| {
                name_staged = try self.gpa.dupe(u8, name);
            }
        }

        if (json_get.optionalString(event.data, "configuration_type")) |c_type| {
            stream_type_staged = ConfigurationType.fromString(c_type);
        }

        if (json_get.optionalArray(event.data, "locations")) |arr| {
            var list = try ResourceIdentifier.fromList(self.gpa, arr);
            errdefer {
                for (list.items) |*ri| ri.deinit(self.gpa);
                list.deinit(self.gpa);
            }
            locations_staged = try list.toOwnedSlice(self.gpa);
        }

        // Commit Phase
        commitOptionalString(self.gpa, &self.name, name_staged);
        if (stream_type_staged) |ct| self.stream_type = ct;
        if (locations_staged) |new_locs| {
            if (self.locations) |old_locs| {
                for (old_locs) |*ri| ri.deinit(self.gpa);
                self.gpa.free(old_locs);
            }
            self.locations = new_locs;
        }

        self.timestamp = event.timestamp;
    }

    pub fn deinit(self: *EntertainmentConfiguration) void {
        deepFree(self.gpa, self.*);
    }
};

pub const Geolocation = struct {
    gpa: Allocator,
    id: []const u8,
    timestamp: ?std.Io.Timestamp,
    is_configured: ?bool,

    pub fn fromJson(gpa: Allocator, obj: std.json.ObjectMap) !Geolocation {
        try validateType(.geolocation, obj);
        const id = try gpa.dupe(u8, try json_get.string(obj, "id"));

        var geo = Geolocation{
            .gpa = gpa,
            .id = id,
            .timestamp = null,
            .is_configured = null,
        };
        errdefer geo.deinit();

        const event: EventUpdate = .{
            .id = geo.id,
            .timestamp = null,
            .data = obj,
            .updateType = .geolocation,
        };
        try geo.applyUpdate(event);
        return geo;
    }

    pub fn applyUpdate(self: *Geolocation, event: EventUpdate) !void {
        if (!std.mem.eql(u8, event.id, self.id)) return error.InvalidId;
        try validateEntry(event.id, .geolocation, event.data);

        var is_configured_staged = self.is_configured;

        if (json_get.optionalBool(event.data, "is_configured")) |cfg| {
            is_configured_staged = cfg;
        }

        // Commit Phase
        self.is_configured = is_configured_staged;

        self.timestamp = event.timestamp;
    }

    pub fn deinit(self: *Geolocation) void {
        deepFree(self.gpa, self.*);
    }
};

pub const Matter = struct {
    gpa: Allocator,
    id: []const u8,
    timestamp: ?std.Io.Timestamp,
    max_fabrics: ?i32,
    has_commissioned_fabric: ?bool,

    pub fn fromJson(gpa: Allocator, obj: std.json.ObjectMap) !Matter {
        try validateType(.matter, obj);
        const id = try gpa.dupe(u8, try json_get.string(obj, "id"));

        var m = Matter{
            .gpa = gpa,
            .id = id,
            .timestamp = null,
            .max_fabrics = null,
            .has_commissioned_fabric = null,
        };
        errdefer m.deinit();

        const event: EventUpdate = .{
            .id = m.id,
            .timestamp = null,
            .data = obj,
            .updateType = .matter,
        };
        try m.applyUpdate(event);
        return m;
    }

    pub fn applyUpdate(self: *Matter, event: EventUpdate) !void {
        if (!std.mem.eql(u8, event.id, self.id)) return error.InvalidId;
        try validateEntry(event.id, .matter, event.data);

        var max_fabrics_staged = self.max_fabrics;
        var fabric_staged = self.has_commissioned_fabric;

        if (json_get.optionalInt(event.data, "max_fabrics")) |mf| {
            max_fabrics_staged = @intCast(mf);
        }
        if (json_get.optionalBool(event.data, "has_commissioned_fabric")) |hcf| {
            fabric_staged = hcf;
        }

        // Commit Phase
        self.max_fabrics = max_fabrics_staged;
        self.has_commissioned_fabric = fabric_staged;

        self.timestamp = event.timestamp;
    }

    pub fn deinit(self: *Matter) void {
        deepFree(self.gpa, self.*);
    }
};

pub const PublicImage = struct {
    gpa: Allocator,
    id: []const u8,
    timestamp: ?std.Io.Timestamp,
    owner_rid: []const u8,
    owner_rtype: ResourceType,
    image_url: ?[]const u8,

    pub fn fromJson(gpa: Allocator, obj: std.json.ObjectMap) !PublicImage {
        try validateType(.public_image, obj);
        const owner = try ResourceIdentifier.fromJson(gpa, try json_get.object(obj, "owner"));
        errdefer gpa.free(owner.rid);

        const id = gpa.dupe(u8, try json_get.string(obj, "id")) catch |err| {
            gpa.free(owner.rid);
            return err;
        };

        var pi = PublicImage{
            .gpa = gpa,
            .id = id,
            .timestamp = null,
            .owner_rid = owner.rid,
            .owner_rtype = owner.rtype,
            .image_url = null,
        };
        errdefer pi.deinit();

        const event: EventUpdate = .{
            .id = pi.id,
            .timestamp = null,
            .data = obj,
            .updateType = .public_image,
        };
        try pi.applyUpdate(event);
        return pi;
    }

    pub fn applyUpdate(self: *PublicImage, event: EventUpdate) !void {
        if (!std.mem.eql(u8, event.id, self.id)) return error.InvalidId;
        try validateEntry(event.id, .public_image, event.data);

        var image_url_staged: ?[]const u8 = null;
        errdefer {
            if (image_url_staged) |url| self.gpa.free(url);
        }

        if (json_get.optionalString(event.data, "image_url")) |url| {
            image_url_staged = try self.gpa.dupe(u8, url);
        }

        // Commit Phase
        commitOptionalString(self.gpa, &self.image_url, image_url_staged);

        self.timestamp = event.timestamp;
    }

    pub fn deinit(self: *PublicImage) void {
        deepFree(self.gpa, self.*);
    }
};

// ---------------------------------------------------------------------------
// Scene value types
// ---------------------------------------------------------------------------

pub const ColorPaletteItem = struct {
    x: f64,
    y: f64,
    brightness: f64,
};
pub const ColorTemperaturePaletteItem = struct {
    mirek: i64,
    brightness: f64,
};
pub const DimmingPaletteItem = struct {
    brightness: f64,
};

/// `scene.status.active`. Values per the Hue CLIP v2 API
/// (hue-sse-events.md: "`status.active` values: `inactive`, `static`,
/// `dynamic_palette`").
pub const SceneActiveStatus = enum {
    inactive,
    static,
    dynamic_palette,

    pub fn fromString(str: []const u8) ?SceneActiveStatus {
        return std.meta.stringToEnum(SceneActiveStatus, str);
    }

    pub fn label(self: SceneActiveStatus) []const u8 {
        return switch (self) {
            .inactive => "inactive",
            .static => "static",
            .dynamic_palette => "dynamic_palette",
        };
    }
};

pub const SceneStatus = struct {
    active: ?SceneActiveStatus,
    last_recall: ?[]const u8,

    pub fn deinit(self: *SceneStatus, gpa: Allocator) void {
        if (self.last_recall) |lr| gpa.free(lr);
    }
};
pub const SceneTarget = struct {
    rid: []const u8,
    rtype: ResourceType,
};

/// `scene.actions[].action.effects_v2.action.effect` (and the same value
/// set the un-modeled `light.effects.effect`/`light.effects_v2` would use,
/// per hue-sse-events.md: `no_effect`, `candle`, `fire`, `prism`,
/// `sparkle`, `opal`, `glisten`). Only `Scene`'s copy of this field is
/// currently parsed anywhere in this codebase.
pub const Effect = enum {
    no_effect,
    candle,
    fire,
    prism,
    sparkle,
    opal,
    glisten,

    pub fn fromString(str: []const u8) ?Effect {
        return std.meta.stringToEnum(Effect, str);
    }

    pub fn label(self: Effect) []const u8 {
        return @tagName(self);
    }
};

pub const SceneActionValues = struct {
    on: ?bool,
    brightness: ?f64,
    mirek: ?i64,
    x: ?f64,
    y: ?f64,
    effect: ?Effect,
    duration: ?i64,
};
pub const SceneAction = struct {
    target: SceneTarget,
    action: SceneActionValues,
};
pub const ScenePalette = struct {
    color: ?[]ColorPaletteItem,
    dimming: ?[]DimmingPaletteItem,
    color_temperature: ?[]ColorTemperaturePaletteItem,
};

pub const Scene = struct {
    gpa: Allocator,
    id: []const u8,
    timestamp: ?std.Io.Timestamp,
    type: []const u8,

    name: ?[]const u8,
    image_rid: ?[]const u8,
    image_rtype: ?ResourceType,
    group_rid: ?[]const u8,
    group_rtype: ?ResourceType,

    speed: ?f64,
    auto_dynamic: ?bool,
    status: SceneStatus,

    actions: ?[]SceneAction,
    palette: ScenePalette,

    pub fn fromJson(gpa: Allocator, obj: std.json.ObjectMap) !Scene {
        try validateType(.scene, obj);

        const id = try gpa.dupe(u8, try json_get.string(obj, "id"));

        const type_str = try gpa.dupe(u8, "scene");
        errdefer gpa.free(type_str);

        var instance = Scene{
            .gpa = gpa,
            .id = id,
            .timestamp = null,
            .type = type_str,
            .name = null,
            .image_rid = null,
            .image_rtype = null,
            .group_rid = null,
            .group_rtype = null,
            .speed = 0.0,
            .auto_dynamic = false,
            .status = .{ .active = .inactive, .last_recall = null },
            .actions = null,
            .palette = .{ .color = null, .dimming = null, .color_temperature = null },
        };
        errdefer instance.deinit();

        const event: EventUpdate = .{
            .id = instance.id,
            .data = obj,
            .timestamp = null,
            .updateType = .scene,
        };

        try instance.applyUpdate(event);
        return instance;
    }

    pub fn applyUpdate(self: *Scene, event: EventUpdate) !void {
        if (!std.mem.eql(u8, event.id, self.id)) return error.InvalidId;
        try validateEntry(event.id, .scene, event.data);

        // --- Staging Variables ---
        var type_staged: ?[]const u8 = null;
        var name_staged: ?[]const u8 = null;
        var image_rid_staged: ?[]const u8 = null;
        var image_rtype_staged: ?ResourceType = null;
        var group_rid_staged: ?[]const u8 = null;
        var group_rtype_staged: ?ResourceType = null;

        // --- Cleanup Handler for Staged Allocations ---
        errdefer {
            if (type_staged) |s| self.gpa.free(s);
            if (name_staged) |s| self.gpa.free(s);
            if (image_rid_staged) |s| self.gpa.free(s);
            if (group_rid_staged) |s| self.gpa.free(s);
        }

        // --- Parsing Logic ---
        if (json_get.optionalString(event.data, "type")) |t| type_staged = try self.gpa.dupe(u8, t);

        if (json_get.optionalObject(event.data, "metadata")) |m| {
            if (json_get.optionalString(m, "name")) |n| name_staged = try self.gpa.dupe(u8, n);
            if (json_get.optionalObject(m, "image")) |img| {
                const ri = try ResourceIdentifier.fromJson(self.gpa, img);
                image_rid_staged = ri.rid;
                image_rtype_staged = ri.rtype;
            }
        }

        if (json_get.optionalObject(event.data, "group")) |g| {
            const ri = try ResourceIdentifier.fromJson(self.gpa, g);
            group_rid_staged = ri.rid;
            group_rtype_staged = ri.rtype;
        }

        // --- Commit Phase (Atomic updates) ---
        if (type_staged) |s| {
            self.gpa.free(self.type);
            self.type = s;
        }
        if (name_staged) |s| {
            if (self.name) |o| self.gpa.free(o);
            self.name = s;
        }
        if (image_rid_staged) |s| {
            if (self.image_rid) |o| self.gpa.free(o);
            self.image_rid = s;
            self.image_rtype = image_rtype_staged;
        }
        if (group_rid_staged) |s| {
            if (self.group_rid) |o| self.gpa.free(o);
            self.group_rid = s;
            self.group_rtype = group_rtype_staged;
        }

        self.speed = json_get.floatOr(event.data, "speed", self.speed orelse 0.0);
        if (json_get.optionalBool(event.data, "auto_dynamic")) |ad| self.auto_dynamic = ad;

        if (json_get.optionalObject(event.data, "status")) |statusObj| {
            if (json_get.optionalString(statusObj, "active")) |act| {
                self.status.active = SceneActiveStatus.fromString(act);
            }
            if (json_get.optionalString(statusObj, "last_recall")) |lr| {
                const new_lr = try self.gpa.dupe(u8, lr);
                if (self.status.last_recall) |old_lr| self.gpa.free(old_lr);
                self.status.last_recall = new_lr;
            }
        }

        if (event.data.get("actions")) |actions_val| {
            if (actions_val == .array) {
                var actions_list = std.ArrayList(SceneAction).empty;
                errdefer {
                    for (actions_list.items) |act| {
                        self.gpa.free(act.target.rid);
                    }
                    actions_list.deinit(self.gpa);
                }

                for (actions_val.array.items) |act_item| {
                    if (act_item != .object) continue;
                    const act_obj = act_item.object;

                    var target = SceneTarget{ .rid = "", .rtype = .grouped_light };
                    if (json_get.optionalObject(act_obj, "target")) |t_obj| {
                        const ri = try ResourceIdentifier.fromJson(self.gpa, t_obj);
                        target.rid = ri.rid; // Transfer pointer ownership safely
                        target.rtype = ri.rtype;
                    } else {
                        target.rid = try self.gpa.dupe(u8, "");
                    }
                    errdefer self.gpa.free(target.rid);

                    var values = SceneActionValues{
                        .on = null,
                        .brightness = null,
                        .mirek = null,
                        .x = null,
                        .y = null,
                        .effect = null,
                        .duration = null,
                    };

                    if (json_get.optionalObject(act_obj, "action")) |a_obj| {
                        if (json_get.optionalObject(a_obj, "on")) |on_obj| {
                            values.on = try json_get.boolean(on_obj, "on");
                        }
                        if (json_get.optionalObject(a_obj, "dimming")) |dim_obj| {
                            values.brightness = json_get.floatOr(dim_obj, "brightness", 0.0);
                        }
                        if (json_get.optionalObject(a_obj, "color_temperature")) |ct_obj| {
                            values.mirek = json_get.optionalInt(ct_obj, "mirek");
                        }
                        if (json_get.optionalObject(a_obj, "color")) |col_obj| {
                            if (json_get.optionalObject(col_obj, "xy")) |xy_obj| {
                                values.x = json_get.optionalFloat(xy_obj, "x");
                                values.y = json_get.optionalFloat(xy_obj, "y");
                            }
                        }
                        if (json_get.optionalObject(a_obj, "effects_v2")) |eff_obj| {
                            if (json_get.optionalObject(eff_obj, "action")) |eff_act| {
                                if (json_get.optionalString(eff_act, "effect")) |eff| {
                                    values.effect = Effect.fromString(eff);
                                }
                            }
                        }
                        if (json_get.optionalObject(a_obj, "dynamics")) |dyn_obj| {
                            values.duration = json_get.optionalInt(dyn_obj, "duration");
                        }
                    }
                    try actions_list.append(self.gpa, .{ .target = target, .action = values });
                }

                const new_actions = try actions_list.toOwnedSlice(self.gpa);
                if (self.actions) |old_actions| {
                    for (old_actions) |act| {
                        self.gpa.free(act.target.rid);
                    }
                    self.gpa.free(old_actions);
                }
                self.actions = new_actions;
            }
        }

        if (json_get.optionalObject(event.data, "palette")) |paletteObj| {
            if (paletteObj.get("color")) |c_val| {
                if (c_val == .array) {
                    var c_list = std.ArrayList(ColorPaletteItem).empty;
                    errdefer c_list.deinit(self.gpa);
                    for (c_val.array.items) |i| {
                        if (i != .object) continue;
                        const io = i.object;
                        var item = ColorPaletteItem{ .x = 0.0, .y = 0.0, .brightness = 0.0 };
                        if (json_get.optionalObject(io, "color")) |c| {
                            if (json_get.optionalObject(c, "xy")) |xy| {
                                item.x = json_get.floatOr(xy, "x", 0.0);
                                item.y = json_get.floatOr(xy, "y", 0.0);
                            }
                        }
                        if (json_get.optionalObject(io, "dimming")) |d| {
                            item.brightness = json_get.floatOr(d, "brightness", 0.0);
                        }
                        try c_list.append(self.gpa, item);
                    }
                    const new_color = try c_list.toOwnedSlice(self.gpa);
                    if (self.palette.color) |c| self.gpa.free(c);
                    self.palette.color = new_color;
                }
            }

            if (paletteObj.get("dimming")) |d_val| {
                if (d_val == .array) {
                    var d_list = std.ArrayList(DimmingPaletteItem).empty;
                    errdefer d_list.deinit(self.gpa);
                    for (d_val.array.items) |i| {
                        if (i != .object) continue;
                        const io = i.object;
                        const b_val = json_get.floatOr(io, "brightness", 0.0);
                        try d_list.append(self.gpa, .{ .brightness = b_val });
                    }
                    const new_dimming = try d_list.toOwnedSlice(self.gpa);
                    if (self.palette.dimming) |d| self.gpa.free(d);
                    self.palette.dimming = new_dimming;
                }
            }

            if (paletteObj.get("color_temperature")) |ct_val| {
                if (ct_val == .array) {
                    var ct_list = std.ArrayList(ColorTemperaturePaletteItem).empty;
                    errdefer ct_list.deinit(self.gpa);
                    for (ct_val.array.items) |i| {
                        if (i != .object) continue;
                        const io = i.object;
                        var mirek: i64 = 0;
                        var brightness: f64 = 0.0;
                        if (json_get.optionalObject(io, "color_temperature")) |ct| {
                            mirek = json_get.optionalInt(ct, "mirek") orelse 0;
                        }
                        if (json_get.optionalObject(io, "dimming")) |d| {
                            brightness = json_get.floatOr(d, "brightness", 0.0);
                        }
                        try ct_list.append(self.gpa, .{ .mirek = mirek, .brightness = brightness });
                    }
                    const new_ct = try ct_list.toOwnedSlice(self.gpa);
                    if (self.palette.color_temperature) |ct| self.gpa.free(ct);
                    self.palette.color_temperature = new_ct;
                }
            }
        }

        self.timestamp = event.timestamp;
    }

    pub fn deinit(self: *Scene) void {
        deepFree(self.gpa, self.*);
    }
};

// ---------------------------------------------------------------------------
// Remaining unused-elsewhere value types, carried forward as-is
// ---------------------------------------------------------------------------

pub const DayType = enum {
    normal_day,
    polar_day,
    polar_night,

    pub fn fromString(s: []const u8) !DayType {
        if (std.mem.eql(u8, s, "normal_day")) return .normal_day;
        if (std.mem.eql(u8, s, "polar_day")) return .polar_day;
        if (std.mem.eql(u8, s, "polar_night")) return .polar_night;
        return error.InvalidDayType;
    }
};
pub const EntertainmentChannel = struct {
    channel_id: i64,
    position: Position,
    members: []SegmentReference,
};
pub const EntertainmentSegment = struct {
    start: i64,
    length: i64,
};
pub const EntertainmentSegmentsCapability = struct {
    configurable: bool,
    max_segments: i64,
    segments: []EntertainmentSegment,

    pub fn fromJson(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !EntertainmentSegmentsCapability {
        const configurable = try json_get.boolean(obj, "configurable");
        const max_seg_val = obj.get("max_segments") orelse return error.MissingField;
        const max_segments = switch (max_seg_val) {
            .integer => |v| v,
            else => return error.WrongType,
        };

        const segs_val = obj.get("segments") orelse return error.MissingField;
        const segs_arr = switch (segs_val) {
            .array => |arr| arr,
            else => return error.WrongType,
        };

        var parsed_segs = try allocator.alloc(EntertainmentSegment, segs_arr.items.len);
        errdefer allocator.free(parsed_segs);

        for (segs_arr.items, 0..) |item, i| {
            const io = switch (item) {
                .object => |o| o,
                else => return error.WrongType,
            };
            const start_val = io.get("start") orelse return error.MissingField;
            const length_val = io.get("length") orelse return error.MissingField;

            parsed_segs[i] = .{
                .start = switch (start_val) {
                    .integer => |v| v,
                    else => return error.WrongType,
                },
                .length = switch (length_val) {
                    .integer => |v| v,
                    else => return error.WrongType,
                },
            };
        }

        return EntertainmentSegmentsCapability{
            .configurable = configurable,
            .max_segments = max_segments,
            .segments = parsed_segs,
        };
    }

    // ADD THIS: Clean up the allocated slice
    pub fn deinit(self: EntertainmentSegmentsCapability, allocator: std.mem.Allocator) void {
        allocator.free(self.segments);
    }
};
pub const ProxyMode = enum {
    auto,
    manual,
};
pub const ServiceStatus = struct {
    device_name: []const u8,
    status_text: []const u8,
};
pub const SegmentReference = struct {
    service: ResourceIdentifier,
    index: i64,
};
pub const ServiceLocation = struct {
    service: ResourceIdentifier,
    positions: []Position, // Correct array layout; ignored old singular 'position' field
    equalization_factor: f64,
};
pub const StreamProxy = struct {
    mode: ProxyMode,
    node: ResourceIdentifier,
};
pub const StreamStatus = enum {
    active,
    inactive,
};
