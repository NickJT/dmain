//! Loads devices.json (physical device names/rooms) and rules.json
//! (switch/sensor → light automation). devices.json replaces the predecessor's
//! compiled-in `Hardware` registry, which required a source-code edit +
//! recompile to add a device. rules.json is carried over from the predecessor
//! essentially unchanged — that mapping was already JSON there; only the
//! device *identity* registry needed to move out of source.
//!
//! The startup loaders share one discipline: an absent file or malformed JSON
//! logs a warning and leaves that part of the config empty rather than refusing
//! to start. `Config.loadChecked` is the opposite on purpose, for a live reload.
const std = @import("std");
const Io = std.Io;
const Ieee = @import("ieee");
const LightIds = @import("light_ids");

pub const DeviceEntry = struct {
    name: []const u8,
    /// Display-order colon-hex ("00:17:88:01:08:d1:40:dd"), as a user would
    /// copy it from a `list`/`discover` command.
    ieee: []const u8,
    room: []const u8 = "",
};

const DevicesFile = struct {
    devices: []DeviceEntry = &.{},
};

pub const DEVICES_FILE = "devices.json";

/// The things a rule can do to a target. On/Off/Toggle ride the On/Off
/// cluster; the level actions are gesture-aware — see `engine.zig`'s
/// `Phase`/`executeAction`.
pub const Action = enum { on, off, toggle, level_up, level_down };

pub fn parseAction(s: []const u8) ?Action {
    return std.meta.stringToEnum(Action, s);
}

fn onOrOff(action: []const u8) bool {
    const a = parseAction(action) orelse return true; // reported as unknown instead
    return a == .on or a == .off;
}

/// One rules.json entry: when `controller` (a devices.json name) emits
/// `event`, perform `action` on `target` (a devices.json name). Flat and
/// explicit — one row per button/event, so any button can drive any light
/// with any action.
pub const RuleEntry = struct {
    controller: []const u8,
    event: []const u8, // button1..button4, dial_left, dial_right, occupied, clear, alarm, humid, dry
    action: []const u8, // on, off, toggle, level_up, level_down
    target: []const u8,
    // Optional default colour for the target: "#RRGGBB".
    // Applied (as a Move to Color) only when this rule's action is `on`;
    // omitted → no colour command at all (the bulb's own power-on
    // default). A target without a Color Control cluster ignores it. Kept
    // as the raw string here; `colourXy` does the parse/convert so a
    // malformed value warns once at load rather than failing.
    colour: ?[]const u8 = null,
};

/// A CIE 1931 xy colour point, each a u16 (fraction × 65536), ready for
/// `Zcl.buildMoveToColor`. What `RuleEntry.colour` resolves to.
pub const ColourXy = struct { x: u16, y: u16 };

/// Parses a "#RRGGBB" (or "RRGGBB") hex colour and converts sRGB → CIE
/// 1931 xy, the colour space Hue bulbs speak. Returns null for anything
/// malformed (caught once by `validateRules`, never a hard failure).
///
/// The conversion is the standard one Philips documents: undo sRGB gamma,
/// apply the Wide-RGB-D65 matrix to linear RGB, normalise X/(X+Y+Z). A
/// pure function of the string — no allocation, no IO — so it's unit-
/// tested against known values.
pub fn parseColourXy(hex: []const u8) ?ColourXy {
    const h = if (hex.len > 0 and hex[0] == '#') hex[1..] else hex;
    if (h.len != 6) return null;
    const r8 = std.fmt.parseInt(u8, h[0..2], 16) catch return null;
    const g8 = std.fmt.parseInt(u8, h[2..4], 16) catch return null;
    const b8 = std.fmt.parseInt(u8, h[4..6], 16) catch return null;

    const rl = gammaExpand(@as(f64, @floatFromInt(r8)) / 255.0);
    const gl = gammaExpand(@as(f64, @floatFromInt(g8)) / 255.0);
    const bl = gammaExpand(@as(f64, @floatFromInt(b8)) / 255.0);

    // Philips' Wide RGB D65 matrix (the one the Hue apps use).
    const X = rl * 0.664511 + gl * 0.154324 + bl * 0.162028;
    const Y = rl * 0.283881 + gl * 0.668433 + bl * 0.047685;
    const Z = rl * 0.000088 + gl * 0.072310 + bl * 0.986039;
    const sum = X + Y + Z;
    if (sum <= 0) return null; // pure black → no meaningful hue; leave default
    const xf = X / sum;
    const yf = Y / sum;
    // Scale to u16, clamped to the spec's 0xFEFF max.
    return .{ .x = xyToU16(xf), .y = xyToU16(yf) };
}

fn gammaExpand(c: f64) f64 {
    return if (c > 0.04045) std.math.pow(f64, (c + 0.055) / 1.055, 2.4) else c / 12.92;
}

fn xyToU16(f: f64) u16 {
    const scaled = f * 65536.0;
    const clamped = @max(0.0, @min(scaled, 65279.0)); // 0xFEFF
    return @intFromFloat(clamped);
}

const RulesFile = struct {
    rules: []RuleEntry = &.{},
};

pub const RULES_FILE = "rules.json";

const KNOWN_EVENTS = [_][]const u8{ "button1", "button2", "button3", "button4", "dial_left", "dial_right", "occupied", "clear", "alarm", "humid", "dry" };

/// One groups.json entry: a named collection of `members` (devices.json
/// names) that all join Zigbee group `group_id` (via `engine.zig`'s
/// `setupGroup`/`Zcl.buildAddGroup`) so a single group-addressed send
/// reaches every member simultaneously, instead of a coordinator-side
/// unicast fan-out that would visibly stagger. Once grouped, a group's
/// control semantics are identical to a single device's — the requirement
/// is grouping, not scenes, so there's no separate "group state"
/// beyond membership: on/off/toggle/level_up/level_down all apply.
pub const GroupEntry = struct {
    name: []const u8,
    group_id: u16,
    members: []const []const u8,
};

const GroupsFile = struct {
    groups: []GroupEntry = &.{},
};

pub const GROUPS_FILE = "groups.json";

/// What a rules.json `target` (or a future TUI/web command) resolved to:
/// a single device or a whole group. `engine.zig`'s `fireEvent`/
/// `executeAction` branch on this so the same action code path (on/off/
/// toggle/level_up/level_down) works for either — matching the
/// "same control semantics as a single bulb" requirement.
pub const Target = union(enum) {
    device: [8]u8,
    group: u16,
    /// A light the Hue Bridge holds, by its wire-order IEEE: hub writes to it
    /// through the Bridge, not the radio. On and off only, as hub can't read
    /// its state.
    bridge: [8]u8,
};

/// huelog's map from the house's addresses to the Bridge's light ids, from hub's
/// working directory: both run from their own folders in one home.
pub const BRIDGE_IDS_PATH = "../huelog/data/" ++ LightIds.FILE;

/// One schedule.json entry: at local wall-clock `time` ("HH:MM", 24h),
/// once per day, perform `action` on `target` (a devices.json or
/// groups.json name — the same `resolveTargetName` rules.json targets
/// use). Deliberately just time-of-day, not day-of-week or date ranges —
/// the requirement is "simple schedules", and `sched.zig`'s `Scheduler`
/// fires this the same way a rule fires: through the engine's existing
/// `PendingAction` queue, with `Phase.tick` (a schedule is a one-shot
/// trigger, not a gesture — the same phase dial detents/motion use).
pub const ScheduleEntry = struct {
    name: []const u8,
    time: []const u8, // "HH:MM", 24-hour, local time
    action: []const u8, // on, off, toggle, level_up, level_down
    target: []const u8,
};

const SchedulesFile = struct {
    schedules: []ScheduleEntry = &.{},
};

pub const SCHEDULES_FILE = "schedule.json";

/// Parses "HH:MM" (24-hour). Returns null for anything else — malformed
/// entries are caught once by `validateSchedules` at load, not on every
/// `sched.zig` tick.
pub fn parseHHMM(s: []const u8) ?struct { hour: u8, minute: u8 } {
    if (s.len != 5 or s[2] != ':') return null;
    const hour = std.fmt.parseInt(u8, s[0..2], 10) catch return null;
    const minute = std.fmt.parseInt(u8, s[3..5], 10) catch return null;
    if (hour > 23 or minute > 59) return null;
    return .{ .hour = hour, .minute = minute };
}

/// Largest config file either path accepts. Startup and `loadChecked` share it,
/// so a file a reload accepts cannot then fail at the next restart.
pub const MAX_CONFIG_FILE = 1 << 20;

/// The most schedules `sched.zig` tracks. Past this, an entry silently never fires.
pub const MAX_SCHEDULES = 32;

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    devices: []DeviceEntry = &.{},
    rules: []RuleEntry = &.{},
    groups: []GroupEntry = &.{},
    schedules: []ScheduleEntry = &.{},
    /// The Bridge's lights, for a target given as an address. Empty when huelog's
    /// file is absent or won't read, with why in `bridge_ids_err`.
    bridge_lights: []const LightIds.Light = &.{},
    bridge_ids_err: ?anyerror = null,

    pub fn init(gpa: std.mem.Allocator) Config {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }

    /// One file's text, in the arena. Absent is the normal "not configured"
    /// case and stays quiet; any other failure is worth a warning.
    fn readOptional(self: *Config, io: Io, dir: Io.Dir, name: []const u8) ?[]const u8 {
        return dir.readFileAlloc(io, name, self.arena.allocator(), .limited(MAX_CONFIG_FILE)) catch |err| {
            if (err != error.FileNotFound) std.log.warn("{s}: cannot read: {t}", .{ name, err });
            return null;
        };
    }

    /// Loads `devices.json` from `dir`. `.alloc_always` copies every string
    /// into the arena.
    pub fn load(self: *Config, io: Io, dir: Io.Dir) void {
        const text = self.readOptional(io, dir, DEVICES_FILE) orelse return; // no file yet is fine
        const parsed = std.json.parseFromSliceLeaky(DevicesFile, self.arena.allocator(), text, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| {
            std.log.warn("{s} parse failed: {t} — running with no configured devices", .{ DEVICES_FILE, err });
            return;
        };
        self.devices = parsed.devices;
        for (self.devices) |d| {
            _ = Ieee.parseReversed(d.ieee) catch {
                std.log.warn("{s}: device '{s}' has an invalid ieee '{s}' — it will never match", .{ DEVICES_FILE, d.name, d.ieee });
            };
        }
    }

    /// Loads `rules.json` from `dir`. Absent file means no automation, not
    /// an error.
    pub fn loadRules(self: *Config, io: Io, dir: Io.Dir) void {
        const text = self.readOptional(io, dir, RULES_FILE) orelse return;
        const parsed = std.json.parseFromSliceLeaky(RulesFile, self.arena.allocator(), text, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| {
            std.log.warn("{s} parse failed: {t} — running with no automation rules", .{ RULES_FILE, err });
            return;
        };
        self.rules = parsed.rules;
    }

    /// Loads `groups.json` from `dir`. Absent file means no groups, not
    /// an error.
    pub fn loadGroups(self: *Config, io: Io, dir: Io.Dir) void {
        const text = self.readOptional(io, dir, GROUPS_FILE) orelse return;
        const parsed = std.json.parseFromSliceLeaky(GroupsFile, self.arena.allocator(), text, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| {
            std.log.warn("{s} parse failed: {t} — running with no groups", .{ GROUPS_FILE, err });
            return;
        };
        self.groups = parsed.groups;
    }

    /// Loads huelog's Bridge ids from `path` under `dir`. Absent means hub has no
    /// Bridge targets; a rule naming one is then an unknown target.
    pub fn loadBridgeIds(self: *Config, io: Io, dir: Io.Dir, path: []const u8) void {
        const text = dir.readFileAlloc(io, path, self.arena.allocator(), .limited(MAX_CONFIG_FILE)) catch |err| {
            self.bridge_ids_err = err;
            return;
        };
        const file = LightIds.parse(self.arena.allocator(), text) catch |err| {
            self.bridge_ids_err = err;
            return;
        };
        self.bridge_lights = file.lights;
    }

    /// The Bridge's id for a light, by its wire-order IEEE.
    pub fn bridgeLightFor(self: *const Config, wire: [8]u8) ?[]const u8 {
        for (self.bridge_lights) |light| {
            const w = Ieee.parseReversed(light.dev) catch continue;
            if (light.ch == 0 and std.mem.eql(u8, &w, &wire)) return light.id;
        }
        return null;
    }

    fn unknownTarget(self: *const Config, out: *Io.Writer, file: []const u8, what: []const u8, target: []const u8) !void {
        try out.print("{s} warning: '{s}' has unknown target '{s}' (not a devices.json or groups.json name, nor an address hub or the Bridge holds", .{ file, what, target });
        if (self.bridge_ids_err) |err| try out.print("; {s}: {t}", .{ BRIDGE_IDS_PATH, err });
        try out.writeAll(")\n");
    }

    fn bridgeAction(out: *Io.Writer, file: []const u8, target: []const u8, action: []const u8) !void {
        try out.print("{s} warning: '{s}' is on the Bridge, which hub can only switch on or off, not '{s}'\n", .{ file, target, action });
    }

    /// Warns (does not reject) about devices that could never be addressed: a
    /// bad IEEE, a name or IEEE used twice, a name the console cannot type
    /// because it splits on spaces, or a group sharing a device's name, where
    /// the device always wins.
    pub fn validateDevices(self: *const Config, out: *Io.Writer) !void {
        for (self.devices, 0..) |device, i| {
            const wire = Ieee.parseReversed(device.ieee) catch null;
            if (wire == null)
                try out.print("{s} warning: device '{s}' has an invalid ieee '{s}'\n", .{ DEVICES_FILE, device.name, device.ieee });
            if (device.name.len == 0 or std.mem.indexOfAny(u8, device.name, " \t") != null)
                try out.print("{s} warning: device name '{s}' can't be typed at the console: no spaces\n", .{ DEVICES_FILE, device.name });
            for (self.devices[i + 1 ..]) |other| {
                if (std.mem.eql(u8, device.name, other.name))
                    try out.print("{s} warning: two devices are named '{s}'\n", .{ DEVICES_FILE, device.name });
                const other_wire = Ieee.parseReversed(other.ieee) catch null;
                if (wire != null and other_wire != null and std.mem.eql(u8, &wire.?, &other_wire.?))
                    try out.print("{s} warning: '{s}' and '{s}' have the same ieee\n", .{ DEVICES_FILE, device.name, other.name });
            }
        }
        for (self.groups) |group| {
            if (self.ieeeFor(group.name) != null)
                try out.print("{s} warning: group '{s}' shares a device's name; the device wins\n", .{ GROUPS_FILE, group.name });
        }
        try out.flush();
    }

    /// Warns (does not reject) about groups referencing unconfigured
    /// member names or reusing a group_id already claimed by another
    /// group — a typo otherwise silently means a member never joins, or
    /// two groups collide on the wire and both control each other's
    /// members. Call once at load, same discipline as `validateRules`.
    pub fn validateGroups(self: *const Config, out: *Io.Writer) !void {
        for (self.groups, 0..) |group, i| {
            for (self.groups[i + 1 ..]) |other| {
                if (group.group_id == other.group_id)
                    try out.print("{s} warning: '{s}' and '{s}' both use group_id {d}\n", .{ GROUPS_FILE, group.name, other.name, group.group_id });
            }
            for (group.members) |member| {
                if (self.ieeeFor(member) == null)
                    try out.print("{s} warning: group '{s}' has unknown member '{s}'\n", .{ GROUPS_FILE, group.name, member });
            }
        }
        try out.flush();
    }

    /// Loads `schedule.json` from `dir`. Absent file means no schedules,
    /// not an error.
    pub fn loadSchedules(self: *Config, io: Io, dir: Io.Dir) void {
        const text = self.readOptional(io, dir, SCHEDULES_FILE) orelse return;
        const parsed = std.json.parseFromSliceLeaky(SchedulesFile, self.arena.allocator(), text, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| {
            std.log.warn("{s} parse failed: {t} — running with no schedules", .{ SCHEDULES_FILE, err });
            return;
        };
        self.schedules = parsed.schedules;
    }

    /// Warns (does not reject) about schedules with a malformed `time`,
    /// an unknown action, or a target that resolves to neither a device
    /// nor a group — same discipline as `validateRules`/`validateGroups`.
    pub fn validateSchedules(self: *const Config, out: *Io.Writer) !void {
        for (self.schedules) |sched| {
            if (parseHHMM(sched.time) == null)
                try out.print("{s} warning: schedule '{s}' has an invalid time '{s}' (want \"HH:MM\", 24h)\n", .{ SCHEDULES_FILE, sched.name, sched.time });
            const target = self.resolveTargetName(sched.target);
            if (target == null)
                try self.unknownTarget(out, SCHEDULES_FILE, sched.name, sched.target);
            if (target != null and target.? == .bridge and !onOrOff(sched.action))
                try bridgeAction(out, SCHEDULES_FILE, sched.target, sched.action);
            if (parseAction(sched.action) == null)
                try out.print("{s} warning: schedule '{s}' has unknown action '{s}'\n", .{ SCHEDULES_FILE, sched.name, sched.action });
        }
        try out.flush();
    }

    /// Warns (does not reject) about rules referencing an unconfigured
    /// controller, or a target that resolves to neither a device nor a
    /// group, unknown actions, or unknown events — a typo otherwise
    /// silently never fires. Call once at load so the problem surfaces
    /// immediately, not after a baffling no-op button press.
    pub fn validateRules(self: *const Config, out: *Io.Writer) !void {
        for (self.rules) |rule| {
            if (self.ieeeFor(rule.controller) == null)
                try out.print("{s} warning: unknown controller '{s}'\n", .{ RULES_FILE, rule.controller });
            const target = self.resolveTargetName(rule.target);
            if (target == null)
                try self.unknownTarget(out, RULES_FILE, rule.controller, rule.target);
            if (target != null and target.? == .bridge and !onOrOff(rule.action))
                try bridgeAction(out, RULES_FILE, rule.target, rule.action);
            if (parseAction(rule.action) == null)
                try out.print("{s} warning: unknown action '{s}' (use on/off/toggle/level_up/level_down)\n", .{ RULES_FILE, rule.action });
            const event_ok = for (KNOWN_EVENTS) |e| {
                if (std.mem.eql(u8, e, rule.event)) break true;
            } else false;
            if (!event_ok)
                try out.print("{s} warning: unknown event '{s}'\n", .{ RULES_FILE, rule.event });
            if (rule.colour) |c| {
                if (parseColourXy(c) == null)
                    try out.print("{s} warning: rule for '{s}' has malformed colour '{s}' (want \"#RRGGBB\") — ignored\n", .{ RULES_FILE, rule.target, c });
                if (!std.mem.eql(u8, rule.action, "on"))
                    try out.print("{s} warning: rule for '{s}' has a colour but action '{s}' — colour only applies to 'on'\n", .{ RULES_FILE, rule.target, rule.action });
            }
        }
        try out.flush();
    }

    /// Loads every config file for a live reload, the strict twin of the
    /// startup loaders. Startup degrades and carries on, because a house must
    /// not stay dark over a typo. A reload is a person asking for a change, and
    /// the running config still works, so any problem refuses the whole set:
    /// an unknown field is an error here, and so is every validator warning.
    ///
    /// Returns a heap-allocated Config, or null with the reasons in `problems`.
    /// `bridge_dir` holds huelog's Bridge ids at `BRIDGE_IDS_PATH`: hub's own
    /// directory, whichever `dir` the files come from.
    pub fn loadChecked(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, bridge_dir: Io.Dir, problems: *Io.Writer) !?*Config {
        const self = try gpa.create(Config);
        errdefer gpa.destroy(self);
        self.* = Config.init(gpa);
        errdefer self.deinit();

        var aw: Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        const w = &aw.writer;

        if (try self.parseChecked(DevicesFile, io, dir, DEVICES_FILE, w)) |f| self.devices = f.devices;
        if (try self.parseChecked(RulesFile, io, dir, RULES_FILE, w)) |f| self.rules = f.rules;
        if (try self.parseChecked(GroupsFile, io, dir, GROUPS_FILE, w)) |f| self.groups = f.groups;
        if (try self.parseChecked(SchedulesFile, io, dir, SCHEDULES_FILE, w)) |f| self.schedules = f.schedules;
        self.loadBridgeIds(io, bridge_dir, BRIDGE_IDS_PATH);

        // Only over files that all parsed: checking rules against an unreadable
        // devices.json would bury the one real error under a false one per rule.
        if (w.buffered().len == 0) {
            try self.validateDevices(w);
            try self.validateRules(w);
            try self.validateGroups(w);
            try self.validateSchedules(w);
            if (self.schedules.len > MAX_SCHEDULES)
                try w.print("{s}: {d} schedules, and only the first {d} would ever fire\n", .{ SCHEDULES_FILE, self.schedules.len, MAX_SCHEDULES });
        }
        if (w.buffered().len == 0) return self;

        try problems.writeAll(w.buffered());
        self.deinit();
        gpa.destroy(self);
        return null;
    }

    /// Null when the file is absent or failed, with a failure described in `w`.
    fn parseChecked(self: *Config, comptime T: type, io: Io, dir: Io.Dir, name: []const u8, w: *Io.Writer) !?T {
        const arena = self.arena.allocator();
        const text = dir.readFileAlloc(io, name, arena, .limited(MAX_CONFIG_FILE)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => {
                try w.print("{s}: cannot read: {t}\n", .{ name, err });
                return null;
            },
        };
        var scanner = std.json.Scanner.initCompleteInput(arena, text);
        var diagnostics: std.json.Diagnostics = .{};
        scanner.enableDiagnostics(&diagnostics);
        return std.json.parseFromTokenSourceLeaky(T, arena, &scanner, .{ .allocate = .alloc_always }) catch |err| {
            try w.print("{s}: line {d}, column {d}: {t}\n", .{ name, diagnostics.getLine(), diagnostics.getColumn(), err });
            return null;
        };
    }

    /// Registry name for a wire-order IEEE, if configured.
    pub fn nameFor(self: *const Config, ieee_wire: [8]u8) ?[]const u8 {
        for (self.devices) |d| {
            const wire = Ieee.parseReversed(d.ieee) catch continue;
            if (std.mem.eql(u8, &wire, &ieee_wire)) return d.name;
        }
        return null;
    }

    /// Wire-order IEEE for a configured device name.
    pub fn ieeeFor(self: *const Config, name: []const u8) ?[8]u8 {
        for (self.devices) |d| {
            if (std.mem.eql(u8, d.name, name)) return Ieee.parseReversed(d.ieee) catch null;
        }
        return null;
    }

    /// Room a configured device belongs to, "" if none or unconfigured.
    pub fn roomFor(self: *const Config, ieee_wire: [8]u8) []const u8 {
        for (self.devices) |d| {
            const wire = Ieee.parseReversed(d.ieee) catch continue;
            if (std.mem.eql(u8, &wire, &ieee_wire)) return d.room;
        }
        return "";
    }

    /// Zigbee group_id for a configured group name.
    pub fn groupIdFor(self: *const Config, name: []const u8) ?u16 {
        for (self.groups) |g| {
            if (std.mem.eql(u8, g.name, name)) return g.group_id;
        }
        return null;
    }

    /// Configured group name for a group_id, if any.
    pub fn groupNameFor(self: *const Config, group_id: u16) ?[]const u8 {
        for (self.groups) |g| {
            if (g.group_id == group_id) return g.name;
        }
        return null;
    }

    /// Group definition by name, if any — for `engine.zig`'s `setupGroup`
    /// (needs the member list, not just the group_id).
    pub fn groupByName(self: *const Config, name: []const u8) ?GroupEntry {
        for (self.groups) |g| {
            if (std.mem.eql(u8, g.name, name)) return g;
        }
        return null;
    }

    /// Resolves a rules.json `target` (or any user-facing name) against
    /// devices first, then groups — a device name always wins if both
    /// happen to collide, which `validateGroups`/loading order can't
    /// prevent but is cheap to avoid by just not reusing names.
    /// An address is looked up in hub's devices, then the Bridge's, so a rule
    /// naming one keeps working when the device moves between them.
    pub fn resolveTargetName(self: *const Config, name: []const u8) ?Target {
        if (self.ieeeFor(name)) |ieee| return .{ .device = ieee };
        if (self.groupIdFor(name)) |gid| return .{ .group = gid };
        const wire = Ieee.parseReversed(name) catch return null;
        if (self.nameFor(wire) != null) return .{ .device = wire };
        if (self.bridgeLightFor(wire) != null) return .{ .bridge = wire };
        return null;
    }
};

/// Publishes the running config to readers on other tasks. A reload swaps the
/// whole object through this one pointer, so a reader sees all of the old config
/// or all of the new, never a mixture.
///
/// **A replaced Config stays in memory until shutdown.** Queued actions, log lines
/// and in-flight web requests can all hold strings from it, and nothing can say
/// when the last has gone. A reload is a rare human act and a config is small.
pub const Live = struct {
    current: std.atomic.Value(*const Config),

    pub fn init(config: *const Config) Live {
        return .{ .current = .init(config) };
    }

    pub fn get(self: *const Live) *const Config {
        return self.current.load(.acquire);
    }

    pub fn set(self: *Live, config: *const Config) void {
        self.current.store(config, .release);
    }
};

/// Writes what `new` would change from `old`, one line each, returning the
/// number of changes that take effect on a reload.
pub fn writeChanges(old: *const Config, new: *const Config, out: *Io.Writer) !usize {
    var count: usize = 0;

    for (new.devices) |d| {
        const was = deviceNamed(old, d.name) orelse {
            try out.print("device added: {s} {s}\n", .{ d.name, d.ieee });
            count += 1;
            continue;
        };
        if (!std.mem.eql(u8, was.ieee, d.ieee) or !std.mem.eql(u8, was.room, d.room)) {
            try out.print("device changed: {s} {s} '{s}' -> {s} '{s}'\n", .{ d.name, was.ieee, was.room, d.ieee, d.room });
            count += 1;
        }
    }
    for (old.devices) |d| {
        if (deviceNamed(new, d.name) == null) {
            try out.print("device removed: {s}\n", .{d.name});
            count += 1;
        }
    }

    for (new.rules) |r| {
        if (!hasRule(old, r)) {
            try out.print("rule added: {s} {s} -> {s} {s}\n", .{ r.controller, r.event, r.action, r.target });
            count += 1;
        }
    }
    for (old.rules) |r| {
        if (!hasRule(new, r)) {
            try out.print("rule removed: {s} {s} -> {s} {s}\n", .{ r.controller, r.event, r.action, r.target });
            count += 1;
        }
    }

    // Group membership lives in the lights, so a config change alone reaches
    // none of them, and the startup auto-setup won't run on a reload.
    for (new.groups) |g| {
        const was = old.groupByName(g.name) orelse {
            try out.print("group added: {s} (run `group {s}` to join its members)\n", .{ g.name, g.name });
            count += 1;
            continue;
        };
        if (was.group_id != g.group_id or !sameNames(was.members, g.members)) {
            try out.print("group changed: {s} (run `group {s}` to join its members)\n", .{ g.name, g.name });
            count += 1;
        }
    }
    for (old.groups) |g| {
        if (new.groupByName(g.name) == null) {
            try out.print("group removed: {s} (its lights keep the membership until reset)\n", .{g.name});
            count += 1;
        }
    }

    for (new.schedules) |s| {
        const was = scheduleNamed(old, s.name) orelse {
            try out.print("schedule added: {s} {s} -> {s} {s}\n", .{ s.name, s.time, s.action, s.target });
            count += 1;
            continue;
        };
        if (!std.mem.eql(u8, was.time, s.time) or !std.mem.eql(u8, was.action, s.action) or !std.mem.eql(u8, was.target, s.target)) {
            try out.print("schedule changed: {s} {s} -> {s} {s}\n", .{ s.name, s.time, s.action, s.target });
            count += 1;
        }
    }
    for (old.schedules) |s| {
        if (scheduleNamed(new, s.name) == null) {
            try out.print("schedule removed: {s}\n", .{s.name});
            count += 1;
        }
    }

    return count;
}

fn deviceNamed(config: *const Config, name: []const u8) ?DeviceEntry {
    for (config.devices) |d| {
        if (std.mem.eql(u8, d.name, name)) return d;
    }
    return null;
}

fn scheduleNamed(config: *const Config, name: []const u8) ?ScheduleEntry {
    for (config.schedules) |s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

fn hasRule(config: *const Config, rule: RuleEntry) bool {
    for (config.rules) |r| {
        if (std.mem.eql(u8, r.controller, rule.controller) and std.mem.eql(u8, r.event, rule.event) and
            std.mem.eql(u8, r.action, rule.action) and std.mem.eql(u8, r.target, rule.target) and
            std.mem.eql(u8, r.colour orelse "", rule.colour orelse "")) return true;
    }
    return false;
}

fn sameNames(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

test "load parses a devices.json fixture from an in-memory dir" {
    // Io.Dir has no fixed/in-memory backend in this Zig version, so this
    // exercises the parse path directly the same way the file-based load
    // would after readFile succeeds.
    const gpa = std.testing.allocator;
    var cfg = Config.init(gpa);
    defer cfg.deinit();

    const text =
        \\{"devices":[
        \\  {"name":"bulb1","ieee":"00:17:88:01:08:d1:40:dd","room":"kitchen"},
        \\  {"name":"dimmer","ieee":"00:17:88:01:0e:dd:d8:34"}
        \\]}
    ;
    const parsed = try std.json.parseFromSliceLeaky(DevicesFile, cfg.arena.allocator(), text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    cfg.devices = parsed.devices;

    try std.testing.expectEqual(@as(usize, 2), cfg.devices.len);
    const bulb1_ieee = try Ieee.parseReversed("00:17:88:01:08:d1:40:dd");
    try std.testing.expectEqualStrings("bulb1", cfg.nameFor(bulb1_ieee).?);
    try std.testing.expectEqualStrings("kitchen", cfg.roomFor(bulb1_ieee));
    try std.testing.expectEqualSlices(u8, &bulb1_ieee, &cfg.ieeeFor("bulb1").?);
    try std.testing.expectEqualStrings("", cfg.roomFor(try Ieee.parseReversed("00:17:88:01:0e:dd:d8:34")));
    try std.testing.expect(cfg.nameFor(.{ 0, 1, 2, 3, 4, 5, 6, 7 }) == null);
    try std.testing.expect(cfg.ieeeFor("toaster") == null);
}

test "parseAction accepts the five known actions and rejects garbage" {
    try std.testing.expectEqual(Action.on, parseAction("on").?);
    try std.testing.expectEqual(Action.level_up, parseAction("level_up").?);
    try std.testing.expect(parseAction("dim") == null);
}

test "validateRules warns on unconfigured names, unknown action, unknown event" {
    const gpa = std.testing.allocator;
    var cfg = Config.init(gpa);
    defer cfg.deinit();

    const devices_text =
        \\{"devices":[{"name":"dimmer","ieee":"00:17:88:01:0e:dd:d8:34"},{"name":"bulb1","ieee":"00:17:88:01:08:d1:40:dd"}]}
    ;
    cfg.devices = (try std.json.parseFromSliceLeaky(DevicesFile, cfg.arena.allocator(), devices_text, .{ .allocate = .alloc_always })).devices;

    const rules_text =
        \\{"rules":[
        \\  {"controller":"dimmer","event":"button1","action":"on","target":"bulb1"},
        \\  {"controller":"ghost","event":"button1","action":"on","target":"bulb1"},
        \\  {"controller":"dimmer","event":"button1","action":"explode","target":"bulb1"},
        \\  {"controller":"dimmer","event":"not_a_real_event","action":"on","target":"bulb1"}
        \\]}
    ;
    cfg.rules = (try std.json.parseFromSliceLeaky(RulesFile, cfg.arena.allocator(), rules_text, .{ .allocate = .alloc_always })).rules;

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try cfg.validateRules(&aw.writer);
    const warnings = aw.writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, warnings, "unknown controller 'ghost'") != null);
    try std.testing.expect(std.mem.indexOf(u8, warnings, "unknown action 'explode'") != null);
    try std.testing.expect(std.mem.indexOf(u8, warnings, "unknown event 'not_a_real_event'") != null);
    // The first, fully-valid rule must not have produced any warning text
    // naming it — a crude but effective check: "unknown target 'bulb1'"
    // (the one wrong-direction mistake this test would catch) never appears.
    try std.testing.expect(std.mem.indexOf(u8, warnings, "unknown target 'bulb1'") == null);
}

test "resolveTargetName: device wins, then group, then neither" {
    const gpa = std.testing.allocator;
    var cfg = Config.init(gpa);
    defer cfg.deinit();

    const devices = [_]DeviceEntry{.{ .name = "bulb1", .ieee = "00:17:88:01:08:d1:40:dd" }};
    cfg.devices = @constCast(&devices);
    const members = [_][]const u8{"bulb1"};
    const groups = [_]GroupEntry{.{ .name = "landing", .group_id = 7, .members = &members }};
    cfg.groups = @constCast(&groups);

    const bulb1_ieee = try Ieee.parseReversed("00:17:88:01:08:d1:40:dd");
    try std.testing.expectEqualSlices(u8, &bulb1_ieee, &cfg.resolveTargetName("bulb1").?.device);
    try std.testing.expectEqual(@as(u16, 7), cfg.resolveTargetName("landing").?.group);
    try std.testing.expect(cfg.resolveTargetName("nothing") == null);
    try std.testing.expectEqualStrings("landing", cfg.groupNameFor(7).?);
    try std.testing.expect(cfg.groupNameFor(99) == null);
}

test "validateGroups warns on unknown member and duplicate group_id" {
    const gpa = std.testing.allocator;
    var cfg = Config.init(gpa);
    defer cfg.deinit();

    const devices = [_]DeviceEntry{.{ .name = "bulb1", .ieee = "00:17:88:01:08:d1:40:dd" }};
    cfg.devices = @constCast(&devices);
    const members_a = [_][]const u8{ "bulb1", "ghost" };
    const members_b = [_][]const u8{"bulb1"};
    const groups = [_]GroupEntry{
        .{ .name = "landing", .group_id = 7, .members = &members_a },
        .{ .name = "hallway", .group_id = 7, .members = &members_b },
    };
    cfg.groups = @constCast(&groups);

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try cfg.validateGroups(&aw.writer);
    const warnings = aw.writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, warnings, "unknown member 'ghost'") != null);
    try std.testing.expect(std.mem.indexOf(u8, warnings, "both use group_id 7") != null);
}

test "parseHHMM accepts valid times and rejects malformed ones" {
    try std.testing.expectEqual(@as(u8, 18), parseHHMM("18:00").?.hour);
    try std.testing.expectEqual(@as(u8, 30), parseHHMM("23:30").?.minute);
    try std.testing.expectEqual(@as(u8, 0), parseHHMM("00:00").?.hour);
    try std.testing.expect(parseHHMM("24:00") == null); // hour out of range
    try std.testing.expect(parseHHMM("12:60") == null); // minute out of range
    try std.testing.expect(parseHHMM("1830") == null); // missing colon
    try std.testing.expect(parseHHMM("6:00") == null); // wrong length
}

test "validateSchedules warns on bad time, unknown target, unknown action" {
    const gpa = std.testing.allocator;
    var cfg = Config.init(gpa);
    defer cfg.deinit();

    const devices = [_]DeviceEntry{.{ .name = "bulb1", .ieee = "00:17:88:01:08:d1:40:dd" }};
    cfg.devices = @constCast(&devices);
    const scheds = [_]ScheduleEntry{
        .{ .name = "good", .time = "18:00", .action = "on", .target = "bulb1" },
        .{ .name = "bad-time", .time = "25:99", .action = "on", .target = "bulb1" },
        .{ .name = "bad-target", .time = "18:00", .action = "on", .target = "ghost" },
        .{ .name = "bad-action", .time = "18:00", .action = "explode", .target = "bulb1" },
    };
    cfg.schedules = @constCast(&scheds);

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try cfg.validateSchedules(&aw.writer);
    const warnings = aw.writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, warnings, "'bad-time' has an invalid time") != null);
    try std.testing.expect(std.mem.indexOf(u8, warnings, "'bad-target' has unknown target 'ghost'") != null);
    try std.testing.expect(std.mem.indexOf(u8, warnings, "'bad-action' has unknown action 'explode'") != null);
    try std.testing.expect(std.mem.indexOf(u8, warnings, "'good'") == null);
}

test "parseColourXy converts sRGB hex to CIE xy near Philips' gamut points" {
    // Red sits near (0.70, 0.30) in CIE 1931 — the classic Hue red corner.
    // Compare on the xy fraction (u16 / 65536) to a couple of decimals, not
    // the raw u16, so the check reads as colour rather than magic numbers.
    const red = parseColourXy("#FF0000").?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.70), @as(f64, @floatFromInt(red.x)) / 65536.0, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 0.30), @as(f64, @floatFromInt(red.y)) / 65536.0, 0.01);

    // White lands near D65 (~0.313, 0.329) — the '#' prefix optional.
    const white = parseColourXy("FFFFFF").?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.32), @as(f64, @floatFromInt(white.x)) / 65536.0, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 0.33), @as(f64, @floatFromInt(white.y)) / 65536.0, 0.01);

    // Malformed → null (never a hard failure), and pure black too (no hue).
    try std.testing.expectEqual(@as(?ColourXy, null), parseColourXy("#GGGGGG"));
    try std.testing.expectEqual(@as(?ColourXy, null), parseColourXy("#FFF"));
    try std.testing.expectEqual(@as(?ColourXy, null), parseColourXy("nope"));
    try std.testing.expectEqual(@as(?ColourXy, null), parseColourXy("#000000"));
}

/// A temp dir holding the given config files, for the checked loader's tests.
fn writeConfigDir(tmp: *std.testing.TmpDir, io: Io, files: []const [2][]const u8) !void {
    for (files) |f| try tmp.dir.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
}

const test_devices =
    \\{"devices":[{"name":"dimmer","ieee":"00:17:88:01:0e:dd:d8:34"},{"name":"bulb1","ieee":"00:17:88:01:08:d1:40:dd"}]}
;

fn testIo() Io {
    const S = struct {
        var threaded: Io.Threaded = .init_single_threaded;
    };
    return S.threaded.io();
}

fn freeChecked(gpa: std.mem.Allocator, config: *Config) void {
    config.deinit();
    gpa.destroy(config);
}

test "loadChecked accepts a good set, and absent files mean none" {
    const gpa = std.testing.allocator;
    const io = testIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeConfigDir(&tmp, io, &.{
        .{ DEVICES_FILE, test_devices },
        .{
            RULES_FILE,
            \\{"rules":[{"controller":"dimmer","event":"button1","action":"on","target":"bulb1"}]}
        },
    });

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const config = (try Config.loadChecked(gpa, io, tmp.dir, tmp.dir, &aw.writer)).?;
    defer freeChecked(gpa, config);

    try std.testing.expectEqual(@as(usize, 2), config.devices.len);
    try std.testing.expectEqual(@as(usize, 1), config.rules.len);
    try std.testing.expectEqual(@as(usize, 0), config.groups.len);
    try std.testing.expectEqualStrings("", aw.writer.buffered());
}

test "loadChecked refuses a misspelt field, naming the file and line" {
    const gpa = std.testing.allocator;
    const io = testIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeConfigDir(&tmp, io, &.{.{
        DEVICES_FILE,
        \\{"devices":[
        \\  {"name":"bulb1","ieee":"00:17:88:01:08:d1:40:dd","rooom":"kitchen"}
        \\]}
    }});

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.testing.expect(try Config.loadChecked(gpa, io, tmp.dir, tmp.dir, &aw.writer) == null);
    const problems = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, problems, "devices.json: line 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, problems, "UnknownField") != null);
}

test "loadChecked refuses broken JSON and doesn't pile on false rule errors" {
    const gpa = std.testing.allocator;
    const io = testIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeConfigDir(&tmp, io, &.{
        .{ DEVICES_FILE, "{\"devices\":[" },
        .{
            RULES_FILE,
            \\{"rules":[{"controller":"dimmer","event":"button1","action":"on","target":"bulb1"}]}
        },
    });

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.testing.expect(try Config.loadChecked(gpa, io, tmp.dir, tmp.dir, &aw.writer) == null);
    const problems = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, problems, "devices.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, problems, "unknown controller") == null);
}

test "loadChecked refuses what validators only warn about at startup" {
    const gpa = std.testing.allocator;
    const io = testIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeConfigDir(&tmp, io, &.{
        .{ DEVICES_FILE, test_devices },
        .{
            RULES_FILE,
            \\{"rules":[{"controller":"ghost","event":"button1","action":"on","target":"bulb1"}]}
        },
    });

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.testing.expect(try Config.loadChecked(gpa, io, tmp.dir, tmp.dir, &aw.writer) == null);
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "unknown controller 'ghost'") != null);
}

test "validateDevices catches names and addresses nothing could reach" {
    const gpa = std.testing.allocator;
    var cfg = Config.init(gpa);
    defer cfg.deinit();
    const devices = [_]DeviceEntry{
        .{ .name = "Power 1", .ieee = "00:12:4b:00:24:c0:1d:a3" },
        .{ .name = "bulb1", .ieee = "not-an-ieee" },
        .{ .name = "bulb1", .ieee = "00:17:88:01:08:d1:40:dd" },
        .{ .name = "twin", .ieee = "00:17:88:01:08:d1:40:dd" },
    };
    cfg.devices = @constCast(&devices);
    const groups = [_]GroupEntry{.{ .name = "twin", .group_id = 1, .members = &.{} }};
    cfg.groups = @constCast(&groups);

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try cfg.validateDevices(&aw.writer);
    const warnings = aw.writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, warnings, "'Power 1' can't be typed") != null);
    try std.testing.expect(std.mem.indexOf(u8, warnings, "invalid ieee 'not-an-ieee'") != null);
    try std.testing.expect(std.mem.indexOf(u8, warnings, "two devices are named 'bulb1'") != null);
    try std.testing.expect(std.mem.indexOf(u8, warnings, "'bulb1' and 'twin' have the same ieee") != null);
    try std.testing.expect(std.mem.indexOf(u8, warnings, "group 'twin' shares a device's name") != null);
}

test "writeChanges reports nothing for the same config" {
    const gpa = std.testing.allocator;
    var cfg = Config.init(gpa);
    defer cfg.deinit();
    const devices = [_]DeviceEntry{.{ .name = "bulb1", .ieee = "00:17:88:01:08:d1:40:dd" }};
    cfg.devices = @constCast(&devices);

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.testing.expectEqual(@as(usize, 0), try writeChanges(&cfg, &cfg, &aw.writer));
    try std.testing.expectEqualStrings("", aw.writer.buffered());
}

test "writeChanges names every kind of change, and flags what a reload can't do" {
    const gpa = std.testing.allocator;
    var old = Config.init(gpa);
    defer old.deinit();
    var new = Config.init(gpa);
    defer new.deinit();

    const old_devices = [_]DeviceEntry{
        .{ .name = "bulb1", .ieee = "00:17:88:01:08:d1:40:dd", .room = "Office" },
        .{ .name = "gone", .ieee = "00:17:88:01:0e:dd:d8:34" },
    };
    old.devices = @constCast(&old_devices);
    const new_devices = [_]DeviceEntry{
        .{ .name = "bulb1", .ieee = "00:17:88:01:08:d1:40:dd", .room = "Hall" },
        .{ .name = "fresh", .ieee = "00:12:4b:00:24:c0:1d:a3" },
    };
    new.devices = @constCast(&new_devices);

    const old_rules = [_]RuleEntry{.{ .controller = "gone", .event = "button1", .action = "on", .target = "bulb1" }};
    old.rules = @constCast(&old_rules);
    const new_rules = [_]RuleEntry{.{ .controller = "fresh", .event = "button1", .action = "toggle", .target = "bulb1" }};
    new.rules = @constCast(&new_rules);

    const members = [_][]const u8{"bulb1"};
    const new_groups = [_]GroupEntry{.{ .name = "landing", .group_id = 1, .members = &members }};
    new.groups = @constCast(&new_groups);

    const old_scheds = [_]ScheduleEntry{.{ .name = "night", .time = "23:00", .action = "off", .target = "bulb1" }};
    old.schedules = @constCast(&old_scheds);
    const new_scheds = [_]ScheduleEntry{.{ .name = "night", .time = "22:30", .action = "off", .target = "bulb1" }};
    new.schedules = @constCast(&new_scheds);

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const count = try writeChanges(&old, &new, &aw.writer);
    const text = aw.writer.buffered();

    // 3 device + 2 rule + 1 group + 1 schedule.
    try std.testing.expectEqual(@as(usize, 7), count);
    try std.testing.expect(std.mem.indexOf(u8, text, "device changed: bulb1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "device added: fresh") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "device removed: gone") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "rule added: fresh button1 -> toggle bulb1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "rule removed: gone button1 -> on bulb1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "run `group landing`") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "schedule changed: night 22:30") != null);
}

test "Live hands out whichever config was set last" {
    const gpa = std.testing.allocator;
    var a = Config.init(gpa);
    defer a.deinit();
    var b = Config.init(gpa);
    defer b.deinit();
    var live = Live.init(&a);
    try std.testing.expectEqual(@as(*const Config, &a), live.get());
    live.set(&b);
    try std.testing.expectEqual(@as(*const Config, &b), live.get());
}

test "Semantic Check" {
    std.testing.refAllDecls(@This());
}

const test_bridge_ids =
    \\{"v":1,"lights":[{"dev":"00:17:88:01:0f:09:8a:e0","ch":0,"id":"0123456789abcdef0123456789abcdef0123"}]}
;

/// hub's directory beside huelog's, as on the server, for `BRIDGE_IDS_PATH`.
fn bridgeTestDirs(tmp: *std.testing.TmpDir, io: Io, rules: []const u8) !Io.Dir {
    try tmp.dir.createDirPath(io, "hub");
    try tmp.dir.createDirPath(io, "huelog/data");
    try tmp.dir.writeFile(io, .{ .sub_path = "huelog/data/" ++ LightIds.FILE, .data = test_bridge_ids });
    try tmp.dir.writeFile(io, .{ .sub_path = "hub/" ++ DEVICES_FILE, .data = test_devices });
    try tmp.dir.writeFile(io, .{ .sub_path = "hub/" ++ RULES_FILE, .data = rules });
    return tmp.dir.openDir(io, "hub", .{});
}

test "a rule may name a Bridge light by address, to switch on or off" {
    const gpa = std.testing.allocator;
    const io = testIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var hub = try bridgeTestDirs(&tmp, io,
        \\{"rules":[
        \\ {"controller":"dimmer","event":"humid","action":"on","target":"00:17:88:01:0f:09:8a:e0"},
        \\ {"controller":"dimmer","event":"dry","action":"off","target":"00:17:88:01:0f:09:8a:e0"},
        \\ {"controller":"dimmer","event":"button1","action":"on","target":"00:17:88:01:08:d1:40:dd"}
        \\]}
    );
    defer hub.close(io);

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const config = (try Config.loadChecked(gpa, io, hub, hub, &aw.writer)) orelse {
        std.debug.print("{s}", .{aw.writer.buffered()});
        return error.Refused;
    };
    defer freeChecked(gpa, config);

    const fan = try Ieee.parseReversed("00:17:88:01:0f:09:8a:e0");
    try std.testing.expectEqualSlices(u8, &fan, &config.resolveTargetName(config.rules[0].target).?.bridge);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef0123", config.bridgeLightFor(fan).?);
    // hub's own device by address is hub's, not the Bridge's.
    try std.testing.expect(config.resolveTargetName(config.rules[2].target).? == .device);
}

test "a Bridge target refuses toggle, and an address nobody holds is unknown" {
    const gpa = std.testing.allocator;
    const io = testIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var hub = try bridgeTestDirs(&tmp, io,
        \\{"rules":[
        \\ {"controller":"dimmer","event":"button1","action":"toggle","target":"00:17:88:01:0f:09:8a:e0"},
        \\ {"controller":"dimmer","event":"button2","action":"on","target":"00:17:88:01:0f:09:8a:e1"}
        \\]}
    );
    defer hub.close(io);

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.testing.expect(try Config.loadChecked(gpa, io, hub, hub, &aw.writer) == null);
    const problems = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, problems, "only switch on or off, not 'toggle'") != null);
    try std.testing.expect(std.mem.indexOf(u8, problems, "unknown target '00:17:88:01:0f:09:8a:e1'") != null);
}

test "without huelog's file, the unknown target says why" {
    const gpa = std.testing.allocator;
    const io = testIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeConfigDir(&tmp, io, &.{
        .{ DEVICES_FILE, test_devices },
        .{
            RULES_FILE,
            \\{"rules":[{"controller":"dimmer","event":"humid","action":"on","target":"00:17:88:01:0f:09:8a:e0"}]}
        },
    });
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.testing.expect(try Config.loadChecked(gpa, io, tmp.dir, tmp.dir, &aw.writer) == null);
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "FileNotFound") != null);
}
