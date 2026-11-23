//! Sensor and per-device-service resources: motion/temperature/light-level
//! readings, battery state, button/rotary input, grouped (room/zone
//! aggregate) sensor readings, and door/window contact + tamper sensors.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json_get = @import("json_get").json_get;
const Time = @import("time");

const common = @import("common.zig");
const ResourceType = common.ResourceType;
const ResourceIdentifier = common.ResourceIdentifier;
const EventUpdate = common.EventUpdate;
const validateType = common.validateType;
const validateEntry = common.validateEntry;
const commitOptionalString = common.commitOptionalString;
const deepFree = common.deepFree;

pub const BatteryState = enum {
    normal,
    low,
    critical,

    pub fn fromString(str: []const u8) ?BatteryState {
        return std.meta.stringToEnum(BatteryState, str);
    }

    pub fn label(self: BatteryState) []const u8 {
        return switch (self) {
            .normal => "normal",
            .low => "low",
            .critical => "critical",
        };
    }
};

pub const ButtonEvent = enum {
    initial_press,
    repeat,
    short_release,
    long_release,
    double_short_release,
    long_press,
    unknown,

    pub fn fromString(str: []const u8) ButtonEvent {
        return std.meta.stringToEnum(ButtonEvent, str) orelse .unknown;
    }

    pub fn label(self: ButtonEvent) []const u8 {
        return switch (self) {
            .initial_press => "initial_press",
            .repeat => "repeat",
            .short_release => "short_release",
            .long_release => "long_release",
            .double_short_release => "double_short_release",
            .long_press => "long_press",
            .unknown => "unknown",
        };
    }
};

/// Unused elsewhere in the codebase - no resource struct currently
/// references it. Carried forward as-is from the pre-split file.
pub const MotionStatus = enum {
    set,
    changing,
    unknown,

    pub fn fromString(s: []const u8) MotionStatus {
        if (std.mem.eql(u8, s, "set")) return .set;
        if (std.mem.eql(u8, s, "changing")) return .changing;
        return .unknown;
    }

    pub fn label(state: MotionStatus) []const u8 {
        return switch (state) {
            .set => "set",
            .changing => "changing",
            else => "unknown",
        };
    }
};

/// `contact.contact_report.state` - door/window sensor open/closed.
/// Values per the Hue CLIP v2 API (hue-sse-events.md: "`state` values:
/// `contact` (closed), `no_contact` (open)").
pub const ContactState = enum {
    contact,
    no_contact,

    pub fn fromString(str: []const u8) ?ContactState {
        return std.meta.stringToEnum(ContactState, str);
    }

    pub fn label(self: ContactState) []const u8 {
        return switch (self) {
            .contact => "contact",
            .no_contact => "no_contact",
        };
    }
};

pub const Button = struct {
    gpa: Allocator,
    id: []const u8,
    timestamp: ?std.Io.Timestamp,
    owner_rid: []const u8,
    owner_rtype: ResourceType,
    enabled: ?bool,
    changed: ?std.Io.Timestamp,
    last_event: ?ButtonEvent,

    pub fn fromJson(gpa: Allocator, obj: std.json.ObjectMap) !Button {
        try validateType(.button, obj);
        const owner = try ResourceIdentifier.fromJson(gpa, try json_get.object(obj, "owner"));

        const id = gpa.dupe(u8, try json_get.string(obj, "id")) catch |err| {
            gpa.free(owner.rid);
            return err;
        };

        var button = Button{
            .gpa = gpa,
            .id = id,
            .timestamp = null,
            .owner_rid = owner.rid,
            .owner_rtype = owner.rtype,
            .enabled = null,
            .changed = null,
            .last_event = null,
        };
        errdefer button.deinit();

        const event: EventUpdate = .{
            .id = button.id,
            .timestamp = null,
            .data = obj,
            .updateType = .button,
        };
        try button.applyUpdate(event);
        return button;
    }

    pub fn applyUpdate(self: *Button, event: EventUpdate) !void {
        if (!std.mem.eql(u8, event.id, self.id)) return error.InvalidId;
        try validateEntry(event.id, .button, event.data);

        var enabled_staged = self.enabled;
        var changed_staged = self.changed;
        var last_event_staged = self.last_event;

        if (json_get.optionalBool(event.data, "enabled")) |en| {
            enabled_staged = en;
        }

        if (json_get.optionalObject(event.data, "button")) |btn| {
            if (json_get.optionalObject(btn, "button_report")) |report| {
                if (json_get.optionalString(report, "event")) |ev| {
                    last_event_staged = ButtonEvent.fromString(ev);
                }
                if (json_get.optionalString(report, "changed")) |newVal| {
                    changed_staged = try Time.ISO2Timestamp(newVal);
                }
            }
        }

        // Transaction Point: Commit changes only after all throwing calls succeed
        self.last_event = last_event_staged;
        self.enabled = enabled_staged;
        self.changed = changed_staged;

        self.timestamp = event.timestamp;
    }

    pub fn format(self: Button, writer: *std.Io.Writer) !void {
        const event: []const u8 = if (self.last_event) |e| e.label() else "none";

        try writer.print(
            "Event {[event]s:<[w0]}",
            .{
                .event = event,
                .w0 = 20,
            },
        );
        if (self.changed) |ts| {
            try Time.formatTimestamp(ts, writer);
        } else {
            try writer.print("unknown", .{});
        }
    }

    pub fn deinit(self: *Button) void {
        deepFree(self.gpa, self.*);
    }
};

/// Not currently wired into `ResourceType`/`Resource` (see the
/// commented-out `//contact,` entries there) - kept here, type fixed up
/// anyway, ready for whenever contact sensors are enabled.
pub const Contact = struct {
    gpa: Allocator,
    id: []const u8,
    timestamp: ?std.Io.Timestamp,
    owner_rid: []const u8,
    owner_rtype: ResourceType,
    enabled: ?bool,
    changed: ?std.Io.Timestamp,
    state: ?ContactState,

    pub fn fromJson(gpa: Allocator, obj: std.json.ObjectMap) !Contact {
        try validateType(.contact, obj);
        const owner = try ResourceIdentifier.fromJson(gpa, try json_get.object(obj, "owner"));

        var contact = Contact{
            .gpa = gpa,
            .id = try gpa.dupe(u8, try json_get.string(obj, "id")),
            .timestamp = null,
            .owner_rid = owner.rid,
            .owner_rtype = owner.rtype,
            .enabled = null,
            .changed = null,
            .state = null,
        };
        errdefer contact.deinit();

        const event: EventUpdate = .{
            .id = contact.id,
            .timestamp = null,
            .data = obj,
            .updateType = .contact,
        };
        try contact.applyUpdate(event);
        return contact;
    }

    pub fn applyUpdate(self: *Contact, event: EventUpdate) !void {
        if (!std.mem.eql(u8, event.id, self.id)) return error.InvalidId;
        try validateEntry(event.id, .contact, event.data);

        var enabled_staged = self.enabled;
        var changed_staged = self.changed;
        var state_staged = self.state;

        if (json_get.optionalBool(event.data, "enabled")) |en| {
            enabled_staged = en;
        }

        if (json_get.optionalObject(event.data, "contact")) |cont| {
            if (json_get.optionalObject(cont, "contact_report")) |report| {
                if (json_get.optionalString(report, "state")) |st| {
                    state_staged = ContactState.fromString(st);
                }
                if (json_get.optionalString(report, "changed")) |newVal| {
                    changed_staged = try Time.ISO2Timestamp(newVal);
                }
            }
        }

        // Transaction Point: commit updates safely
        self.state = state_staged;
        self.enabled = enabled_staged;
        self.changed = changed_staged;

        self.timestamp = event.timestamp;
    }

    pub fn deinit(self: *Contact) void {
        deepFree(self.gpa, self.*);
    }

    pub fn format(self: Contact, writer: anytype) !void {
        const enabled_str = if (self.enabled) |e| (if (e) "enabled" else "disabled") else "null";
        const state_str = if (self.state) |s| s.label() else "null";

        try writer.print("{s} ", .{enabled_str});
        if (self.changed) |ts| {
            try writer.print("{}", .{ts});
        } else {
            try writer.print("null", .{});
        }
        try writer.print("  {s}", .{state_str});
    }
};

pub const DevicePower = struct {
    gpa: Allocator,
    id: []const u8,
    timestamp: ?std.Io.Timestamp,
    owner_rid: []const u8,
    owner_rtype: ResourceType,
    battery_state: ?BatteryState,
    battery_level: ?i32,

    pub fn fromJson(gpa: Allocator, obj: std.json.ObjectMap) !DevicePower {
        try validateType(.device_power, obj);
        const owner = try ResourceIdentifier.fromJson(gpa, try json_get.object(obj, "owner"));
        errdefer gpa.free(owner.rid);

        const id = gpa.dupe(u8, try json_get.string(obj, "id")) catch |err| {
            gpa.free(owner.rid);
            return err;
        };

        var dp = DevicePower{
            .gpa = gpa,
            .id = id,
            .timestamp = null,
            .owner_rid = owner.rid,
            .owner_rtype = owner.rtype,
            .battery_state = null,
            .battery_level = null,
        };
        errdefer dp.deinit();

        const event: EventUpdate = .{
            .id = dp.id,
            .timestamp = null,
            .data = obj,
            .updateType = .device_power,
        };
        try dp.applyUpdate(event);
        return dp;
    }

    pub fn applyUpdate(self: *DevicePower, event: EventUpdate) !void {
        if (!std.mem.eql(u8, event.id, self.id)) return error.InvalidId;
        try validateEntry(event.id, .device_power, event.data);

        var staged_battery_state = self.battery_state;
        var staged_battery_level = self.battery_level;

        if (json_get.optionalObject(event.data, "power_state")) |powerObj| {
            if (json_get.optionalString(powerObj, "battery_state")) |state| {
                staged_battery_state = BatteryState.fromString(state);
            }
            if (json_get.optionalInt(powerObj, "battery_level")) |level| {
                staged_battery_level = @intCast(level);
            }
        }

        // Commit Phase - completely exception-safe
        self.battery_state = staged_battery_state;
        self.battery_level = staged_battery_level;

        self.timestamp = event.timestamp;
    }

    pub fn deinit(self: *DevicePower) void {
        deepFree(self.gpa, self.*);
    }

    pub fn format(self: DevicePower, writer: *std.Io.Writer) !void {
        const state: []const u8 = if (self.battery_state) |state| state.label() else "unknown";
        const level: i32 = self.battery_level orelse 0;

        try writer.print(
            "Battery {[state]s:<[w0]} {[level]d:<[w1]}",
            .{
                .state = state,
                .level = level,
                .w0 = 20,
                .w1 = 5,
            },
        );
    }
};

pub const GroupedLight = struct {
    gpa: Allocator,
    id: []const u8,
    timestamp: ?std.Io.Timestamp,
    on: ?bool,
    brightness: ?f64,

    pub fn fromJson(gpa: Allocator, obj: std.json.ObjectMap) !GroupedLight {
        try validateType(.grouped_light, obj);
        const id = try gpa.dupe(u8, try json_get.string(obj, "id"));

        var gl = GroupedLight{
            .gpa = gpa,
            .id = id,
            .timestamp = null,
            .on = null,
            .brightness = null,
        };
        errdefer gl.deinit();

        const event: EventUpdate = .{
            .id = gl.id,
            .timestamp = null,
            .data = obj,
            .updateType = .grouped_light,
        };
        try gl.applyUpdate(event);
        return gl;
    }

    pub fn applyUpdate(self: *GroupedLight, event: EventUpdate) !void {
        if (!std.mem.eql(u8, event.id, self.id)) return error.InvalidId;
        try validateEntry(event.id, .grouped_light, event.data);

        var on_staged = self.on;
        var brightness_staged = self.brightness;

        if (json_get.optionalObject(event.data, "on")) |on_obj| {
            if (json_get.optionalBool(on_obj, "on")) |o| {
                on_staged = o;
            }
        }

        if (json_get.optionalObject(event.data, "dimming")) |dim_obj| {
            if (json_get.optionalFloat(dim_obj, "brightness")) |b| {
                brightness_staged = b;
            }
        }

        // Commit Phase
        self.on = on_staged;
        self.brightness = brightness_staged;

        self.timestamp = event.timestamp;
    }

    pub fn deinit(self: *GroupedLight) void {
        deepFree(self.gpa, self.*);
    }

    pub fn format(self: GroupedLight, writer: *std.Io.Writer) !void {
        try writer.print("On: {?any}, Brightness: {?d:.1}%", .{ self.on, self.brightness });
    }
};
pub const GroupedLightLevel = struct {
    gpa: Allocator,
    id: []const u8,
    timestamp: ?std.Io.Timestamp,
    light_level: ?i32,
    changed: ?std.Io.Timestamp,

    pub fn fromJson(gpa: Allocator, obj: std.json.ObjectMap) !GroupedLightLevel {
        try validateType(.grouped_light_level, obj);
        const id = try gpa.dupe(u8, try json_get.string(obj, "id"));

        var gll = GroupedLightLevel{
            .gpa = gpa,
            .id = id,
            .timestamp = null,
            .light_level = null,
            .changed = null,
        };
        errdefer gll.deinit();

        const event: EventUpdate = .{
            .id = gll.id,
            .timestamp = null,
            .data = obj,
            .updateType = .grouped_light_level,
        };
        try gll.applyUpdate(event);
        return gll;
    }

    pub fn applyUpdate(self: *GroupedLightLevel, event: EventUpdate) !void {
        if (!std.mem.eql(u8, event.id, self.id)) return error.InvalidId;
        try validateEntry(event.id, .grouped_light_level, event.data);

        var light_level_staged = self.light_level;
        var changed_staged = self.changed;

        if (json_get.optionalObject(event.data, "light")) |light_obj| {
            if (json_get.optionalObject(light_obj, "light_level_report")) |report| {
                if (json_get.optionalInt(report, "light_level")) |ll| {
                    light_level_staged = @intCast(ll);
                }
                if (json_get.optionalString(report, "changed")) |newVal| {
                    // If parsing the timestamp fails, structural state remains entirely unmutated
                    changed_staged = try Time.ISO2Timestamp(newVal);
                }
            }
        }

        // Commit Phase
        self.light_level = light_level_staged;
        self.changed = changed_staged;

        self.timestamp = event.timestamp;
    }

    pub fn deinit(self: *GroupedLightLevel) void {
        deepFree(self.gpa, self.*);
    }

    pub fn format(self: GroupedLightLevel, writer: *std.Io.Writer) !void {
        try writer.print("Level: {?d}, Changed: ", .{self.light_level});
        if (self.changed) |ts| {
            try Time.formatTimestamp(ts, writer);
        } else {
            try writer.print("unknown", .{});
        }
    }
};
pub const GroupedMotion = struct {
    gpa: Allocator,
    id: []const u8,
    timestamp: ?std.Io.Timestamp,
    motion: ?bool,
    changed: ?std.Io.Timestamp,

    pub fn fromJson(gpa: Allocator, obj: std.json.ObjectMap) !GroupedMotion {
        try validateType(.grouped_motion, obj);
        const id = try gpa.dupe(u8, try json_get.string(obj, "id"));

        var gm = GroupedMotion{
            .gpa = gpa,
            .id = id,
            .timestamp = null,
            .motion = null,
            .changed = null,
        };
        errdefer gm.deinit();

        const event: EventUpdate = .{
            .id = gm.id,
            .timestamp = null,
            .data = obj,
            .updateType = .grouped_motion,
        };
        try gm.applyUpdate(event);
        return gm;
    }

    pub fn applyUpdate(self: *GroupedMotion, event: EventUpdate) !void {
        if (!std.mem.eql(u8, event.id, self.id)) return error.InvalidId;
        try validateEntry(event.id, .grouped_motion, event.data);

        var motion_staged = self.motion;
        var changed_staged = self.changed;

        if (json_get.optionalObject(event.data, "motion")) |motion_obj| {
            if (json_get.optionalObject(motion_obj, "motion_report")) |report| {
                if (json_get.optionalBool(report, "motion")) |m| {
                    motion_staged = m;
                }
                if (json_get.optionalString(report, "changed")) |newVal| {
                    changed_staged = try Time.ISO2Timestamp(newVal);
                }
            }
        }

        // Commit Phase
        self.motion = motion_staged;
        self.changed = changed_staged;

        self.timestamp = event.timestamp;
    }

    pub fn deinit(self: *GroupedMotion) void {
        deepFree(self.gpa, self.*);
    }

    pub fn format(self: GroupedMotion, writer: *std.Io.Writer) !void {
        try writer.print("Motion: {?any}, Changed: ", .{self.motion});
        if (self.changed) |ts| {
            try Time.formatTimestamp(ts, writer);
        } else {
            try writer.print("unknown", .{});
        }
    }
};
pub const LightLevel = struct {
    gpa: Allocator,
    id: []const u8,
    timestamp: ?std.Io.Timestamp,
    owner_rid: []const u8,
    owner_rtype: ResourceType,
    enabled: ?bool,
    light_level: ?i32,
    changed: ?std.Io.Timestamp,

    pub fn fromJson(gpa: Allocator, obj: std.json.ObjectMap) !LightLevel {
        try validateType(.light_level, obj);
        const owner = try ResourceIdentifier.fromJson(gpa, try json_get.object(obj, "owner"));
        errdefer gpa.free(owner.rid);

        const id = gpa.dupe(u8, try json_get.string(obj, "id")) catch |err| {
            gpa.free(owner.rid);
            return err;
        };

        var ll = LightLevel{
            .gpa = gpa,
            .id = id,
            .timestamp = null,
            .owner_rid = owner.rid,
            .owner_rtype = owner.rtype,
            .enabled = null,
            .light_level = null,
            .changed = null,
        };
        errdefer ll.deinit();

        const event: EventUpdate = .{
            .id = ll.id,
            .timestamp = null,
            .data = obj,
            .updateType = .light_level,
        };
        try ll.applyUpdate(event);
        return ll;
    }

    pub fn applyUpdate(self: *LightLevel, event: EventUpdate) !void {
        if (!std.mem.eql(u8, event.id, self.id)) return error.InvalidId;
        try validateEntry(event.id, .light_level, event.data);

        var enabled_staged = self.enabled;
        var light_level_staged = self.light_level;
        var changed_staged = self.changed;

        if (json_get.optionalBool(event.data, "enabled")) |en| {
            enabled_staged = en;
        }

        if (json_get.optionalObject(event.data, "light")) |light_obj| {
            if (json_get.optionalObject(light_obj, "light_level_report")) |report| {
                if (json_get.optionalInt(report, "light_level")) |lvl| {
                    light_level_staged = @intCast(lvl);
                }
                if (json_get.optionalString(report, "changed")) |newVal| {
                    // Any structural error in time-parsing leaves existing state pristine
                    changed_staged = try Time.ISO2Timestamp(newVal);
                }
            }
        }

        // Commit Phase
        self.enabled = enabled_staged;
        self.light_level = light_level_staged;
        self.changed = changed_staged;

        self.timestamp = event.timestamp;
    }

    pub fn deinit(self: *LightLevel) void {
        deepFree(self.gpa, self.*);
    }

    pub fn format(self: LightLevel, writer: *std.Io.Writer) !void {
        try writer.print("Enabled: {?any}, Level: {?d}, Changed: ", .{ self.enabled, self.light_level });
        if (self.changed) |ts| {
            try Time.formatTimestamp(ts, writer);
        } else {
            try writer.print("unknown", .{});
        }
    }
};
pub const Motion = struct {
    gpa: Allocator,
    id: []const u8,
    timestamp: ?std.Io.Timestamp,
    owner_rid: []const u8,
    owner_rtype: ResourceType,
    enabled: ?bool,
    motion: ?bool,
    changed: ?std.Io.Timestamp,

    pub fn fromJson(gpa: Allocator, obj: std.json.ObjectMap) !Motion {
        try validateType(.motion, obj);
        const owner = try ResourceIdentifier.fromJson(gpa, try json_get.object(obj, "owner"));
        errdefer gpa.free(owner.rid);

        const id = gpa.dupe(u8, try json_get.string(obj, "id")) catch |err| {
            gpa.free(owner.rid);
            return err;
        };

        var m = Motion{
            .gpa = gpa,
            .id = id,
            .timestamp = null,
            .owner_rid = owner.rid,
            .owner_rtype = owner.rtype,
            .enabled = null,
            .motion = null,
            .changed = null,
        };
        errdefer m.deinit();

        const event: EventUpdate = .{
            .id = m.id,
            .timestamp = null,
            .data = obj,
            .updateType = .motion,
        };
        try m.applyUpdate(event);
        return m;
    }

    pub fn applyUpdate(self: *Motion, event: EventUpdate) !void {
        if (!std.mem.eql(u8, event.id, self.id)) return error.InvalidId;
        try validateEntry(event.id, .motion, event.data);

        var enabled_staged = self.enabled;
        var motion_staged = self.motion;
        var changed_staged = self.changed;

        if (json_get.optionalBool(event.data, "enabled")) |en| {
            enabled_staged = en;
        }

        if (json_get.optionalObject(event.data, "motion")) |motion_obj| {
            if (json_get.optionalObject(motion_obj, "motion_report")) |report| {
                if (json_get.optionalBool(report, "motion")) |mot| {
                    motion_staged = mot;
                }
                if (json_get.optionalString(report, "changed")) |newVal| {
                    changed_staged = try Time.ISO2Timestamp(newVal);
                }
            }
        }

        // Commit Phase
        self.enabled = enabled_staged;
        self.motion = motion_staged;
        self.changed = changed_staged;

        self.timestamp = event.timestamp;
    }

    pub fn deinit(self: *Motion) void {
        deepFree(self.gpa, self.*);
    }

    pub fn format(self: Motion, writer: *std.Io.Writer) !void {
        try writer.print("Enabled: {?any}, Motion: {?any}, Changed: ", .{ self.enabled, self.motion });
        if (self.changed) |ts| {
            try Time.formatTimestamp(ts, writer);
        } else {
            try writer.print("unknown", .{});
        }
    }
};
pub const MotionAreaCandidate = struct {
    gpa: Allocator,
    id: []const u8,
    timestamp: ?std.Io.Timestamp,
    owner_rid: []const u8,
    owner_rtype: ResourceType,
    enabled: ?bool,

    pub fn fromJson(gpa: Allocator, obj: std.json.ObjectMap) !MotionAreaCandidate {
        try validateType(.motion_area_candidate, obj);
        const owner = try ResourceIdentifier.fromJson(gpa, try json_get.object(obj, "owner"));
        errdefer gpa.free(owner.rid);

        const id = gpa.dupe(u8, try json_get.string(obj, "id")) catch |err| {
            gpa.free(owner.rid);
            return err;
        };

        var mac = MotionAreaCandidate{
            .gpa = gpa,
            .id = id,
            .timestamp = null,
            .owner_rid = owner.rid,
            .owner_rtype = owner.rtype,
            .enabled = null,
        };
        errdefer mac.deinit();

        const event: EventUpdate = .{
            .id = mac.id,
            .timestamp = null,
            .data = obj,
            .updateType = .motion_area_candidate,
        };
        try mac.applyUpdate(event);
        return mac;
    }

    pub fn applyUpdate(self: *MotionAreaCandidate, event: EventUpdate) !void {
        if (!std.mem.eql(u8, event.id, self.id)) return error.InvalidId;
        try validateEntry(event.id, .motion_area_candidate, event.data);

        var enabled_staged = self.enabled;

        if (json_get.optionalBool(event.data, "enabled")) |en| {
            enabled_staged = en;
        }

        // Commit Phase
        self.enabled = enabled_staged;

        self.timestamp = event.timestamp;
    }

    pub fn deinit(self: *MotionAreaCandidate) void {
        deepFree(self.gpa, self.*);
    }
};
/// **Flagged, not fixed**: `last_rotation` reads `rotation.direction`
/// (a string enum - `clock_work`/`counter_clock_work` per the Hue API)
/// through `json_get.optionalInt`, which only ever matches a JSON
/// `.integer` value - so this field is always null in practice. The
/// actual numeric rotation amount (`rotation.steps`) isn't read at all.
/// Left exactly as before the split; would need both a type change
/// (`?RotaryDirection` enum for direction) and a new field (`steps`)
/// to actually fix, which is beyond a field-type-only pass.
pub const RelativeRotary = struct {
    gpa: Allocator,
    id: []const u8,
    timestamp: ?std.Io.Timestamp,
    owner_rid: []const u8,
    owner_rtype: ResourceType,
    last_rotation: ?i32,
    duration: ?i32,

    pub fn fromJson(gpa: Allocator, obj: std.json.ObjectMap) !RelativeRotary {
        try validateType(.relative_rotary, obj);
        const owner = try ResourceIdentifier.fromJson(gpa, try json_get.object(obj, "owner"));
        errdefer gpa.free(owner.rid);

        const id = gpa.dupe(u8, try json_get.string(obj, "id")) catch |err| {
            gpa.free(owner.rid);
            return err;
        };

        var rr = RelativeRotary{
            .gpa = gpa,
            .id = id,
            .timestamp = null,
            .owner_rid = owner.rid,
            .owner_rtype = owner.rtype,
            .last_rotation = null,
            .duration = null,
        };
        errdefer rr.deinit();

        const event: EventUpdate = .{
            .id = rr.id,
            .timestamp = null,
            .data = obj,
            .updateType = .relative_rotary,
        };
        try rr.applyUpdate(event);
        return rr;
    }

    pub fn applyUpdate(self: *RelativeRotary, event: EventUpdate) !void {
        if (!std.mem.eql(u8, event.id, self.id)) return error.InvalidId;
        try validateEntry(event.id, .relative_rotary, event.data);

        var rotation_staged = self.last_rotation;
        var duration_staged = self.duration;

        if (json_get.optionalObject(event.data, "relative_rotary")) |rot_obj| {
            const rot_inner = json_get.optionalObject(rot_obj, "rotary_report") orelse
                (json_get.optionalObject(rot_obj, "last_event") orelse rot_obj);
            if (json_get.optionalObject(rot_inner, "rotation")) |report| {
                if (json_get.optionalInt(report, "steps")) |st| {
                    var s: i32 = @intCast(st);
                    if (json_get.optionalString(report, "direction")) |dir| {
                        if (std.mem.eql(u8, dir, "counter_clock_wise")) {
                            s = -s;
                        }
                    }
                    rotation_staged = s;
                } else if (json_get.optionalInt(report, "direction")) |dir| {
                    rotation_staged = @intCast(dir);
                }
                if (json_get.optionalInt(report, "duration")) |dur| {
                    duration_staged = @intCast(dur);
                }
            }
        }

        // Commit Phase
        self.last_rotation = rotation_staged;
        self.duration = duration_staged;

        self.timestamp = event.timestamp;
    }

    pub fn deinit(self: *RelativeRotary) void {
        deepFree(self.gpa, self.*);
    }

    pub fn format(self: RelativeRotary, writer: *std.Io.Writer) !void {
        try writer.print("Last rotation: {?d}, Duration: {?d}ms", .{ self.last_rotation, self.duration });
    }
};
/// **Flagged, not fixed**: this struct's shape doesn't match the
/// documented API at all. hue-sse-events.md shows `tamper_reports: [{
/// changed, source, state }]` (an array of reports, `state` a string
/// enum `tampered`/`not_tampered`), but this parses a flat
/// `tamper.tampered: bool` that isn't in the documented schema. Whether
/// this reflects an older API version or was simply never finished is
/// unclear - left exactly as before the split rather than guessed at.
pub const Tamper = struct {
    gpa: Allocator,
    id: []const u8,
    timestamp: ?std.Io.Timestamp,
    owner_rid: []const u8,
    owner_rtype: ResourceType,
    tampered: ?bool,
    changed: ?std.Io.Timestamp,

    pub fn fromJson(gpa: Allocator, obj: std.json.ObjectMap) !Tamper {
        try validateType(.tamper, obj);
        const owner = try ResourceIdentifier.fromJson(gpa, try json_get.object(obj, "owner"));
        errdefer gpa.free(owner.rid);

        const id = try gpa.dupe(u8, try json_get.string(obj, "id"));

        var tamper = Tamper{
            .gpa = gpa,
            .id = id,
            .timestamp = null,
            .owner_rid = owner.rid,
            .owner_rtype = owner.rtype,
            .tampered = null,
            .changed = null,
        };
        errdefer tamper.deinit();

        const event: EventUpdate = .{
            .id = tamper.id,
            .timestamp = null,
            .data = obj,
            .updateType = .tamper,
        };
        try tamper.applyUpdate(event);
        return tamper;
    }

    pub fn applyUpdate(self: *Tamper, event: EventUpdate) !void {
        if (!std.mem.eql(u8, event.id, self.id)) return error.InvalidId;
        try validateEntry(event.id, .tamper, event.data);

        var tampered_staged = self.tampered;
        var changed_staged = self.changed;

        if (json_get.optionalArray(event.data, "tamper_reports")) |reports| {
            if (reports.items.len > 0) {
                const last = reports.items[reports.items.len - 1];
                if (last == .object) {
                    const rep = last.object;
                    if (json_get.optionalString(rep, "state")) |st| {
                        tampered_staged = std.mem.eql(u8, st, "tampered");
                    }
                    if (json_get.optionalString(rep, "changed")) |newVal| {
                        changed_staged = try Time.ISO2Timestamp(newVal);
                    }
                }
            }
        } else if (json_get.optionalObject(event.data, "tamper")) |t_obj| {
            if (json_get.optionalBool(t_obj, "tampered")) |t| {
                tampered_staged = t;
            }
            if (json_get.optionalString(t_obj, "changed")) |newVal| {
                changed_staged = try Time.ISO2Timestamp(newVal);
            }
        }

        // Commit Phase
        self.tampered = tampered_staged;
        self.changed = changed_staged;

        self.timestamp = event.timestamp;
    }

    pub fn deinit(self: *Tamper) void {
        deepFree(self.gpa, self.*);
    }
};
pub const Temperature = struct {
    gpa: Allocator,
    id: []const u8,
    timestamp: ?std.Io.Timestamp,
    owner_rid: []const u8,
    owner_rtype: ResourceType,
    enabled: ?bool,
    temperature: ?f64,
    changed: ?std.Io.Timestamp,

    pub fn fromJson(gpa: Allocator, obj: std.json.ObjectMap) !Temperature {
        try validateType(.temperature, obj);
        const owner = try ResourceIdentifier.fromJson(gpa, try json_get.object(obj, "owner"));
        errdefer gpa.free(owner.rid);

        const id = gpa.dupe(u8, try json_get.string(obj, "id")) catch |err| {
            gpa.free(owner.rid);
            return err;
        };

        var temp = Temperature{
            .gpa = gpa,
            .id = id,
            .timestamp = null,
            .owner_rid = owner.rid,
            .owner_rtype = owner.rtype,
            .enabled = null,
            .temperature = null,
            .changed = null,
        };
        errdefer temp.deinit();

        const event: EventUpdate = .{
            .id = temp.id,
            .timestamp = null,
            .data = obj,
            .updateType = .temperature,
        };
        try temp.applyUpdate(event);
        return temp;
    }

    pub fn applyUpdate(self: *Temperature, event: EventUpdate) !void {
        if (!std.mem.eql(u8, event.id, self.id)) return error.InvalidId;
        try validateEntry(event.id, .temperature, event.data);

        var enabled_staged = self.enabled;
        var temp_staged = self.temperature;
        var changed_staged = self.changed;

        if (json_get.optionalBool(event.data, "enabled")) |en| {
            enabled_staged = en;
        }

        if (json_get.optionalObject(event.data, "temperature")) |t_obj| {
            if (json_get.optionalObject(t_obj, "temperature_report")) |report| {
                if (json_get.optionalFloat(report, "temperature")) |t| {
                    temp_staged = t;
                }
                if (json_get.optionalString(report, "changed")) |newVal| {
                    changed_staged = try Time.ISO2Timestamp(newVal);
                }
            }
        }

        // Commit Phase
        self.enabled = enabled_staged;
        self.temperature = temp_staged;
        self.changed = changed_staged;

        self.timestamp = event.timestamp;
    }

    pub fn deinit(self: *Temperature) void {
        deepFree(self.gpa, self.*);
    }

    pub fn format(self: Temperature, writer: *std.Io.Writer) !void {
        try writer.print("Enabled: {?any}, Temperature: {?d:.1}°C, Changed: ", .{ self.enabled, self.temperature });
        if (self.changed) |ts| {
            try Time.formatTimestamp(ts, writer);
        } else {
            try writer.print("unknown", .{});
        }
    }
};

test "RelativeRotary parsing" {
    const json_text =
        \\{
        \\  "id": "rr-test-1",
        \\  "type": "relative_rotary",
        \\  "owner": { "rid": "dev-test-1", "rtype": "device" },
        \\  "relative_rotary": {
        \\    "rotary_report": {
        \\      "rotation": {
        \\        "direction": "counter_clock_wise",
        \\        "steps": 12,
        \\        "duration": 200
        \\      }
        \\    }
        \\  }
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_text, .{});
    defer parsed.deinit();

    var rr = try RelativeRotary.fromJson(std.testing.allocator, parsed.value.object);
    defer rr.deinit();

    try std.testing.expectEqual(@as(i32, -12), rr.last_rotation.?);
    try std.testing.expectEqual(@as(i32, 200), rr.duration.?);
}

test "Tamper reports parsing" {
    const json_text =
        \\{
        \\  "id": "tamper-test-1",
        \\  "type": "tamper",
        \\  "owner": { "rid": "dev-test-1", "rtype": "device" },
        \\  "tamper_reports": [
        \\    {
        \\      "changed": "2024-01-01T12:00:00.000Z",
        \\      "source": "physical",
        \\      "state": "tampered"
        \\    }
        \\  ]
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_text, .{});
    defer parsed.deinit();

    var tamper = try Tamper.fromJson(std.testing.allocator, parsed.value.object);
    defer tamper.deinit();

    try std.testing.expectEqual(true, tamper.tampered.?);
    try std.testing.expect(tamper.changed != null);
}
