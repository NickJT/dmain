//! `rooms.json`: the house's rooms, what every device is called and where it is, what
//! each control acts on, the sensors' timetables, the named actions and the schedules.
//!
//! A room is a place, and every device is in the room where it physically is. A control
//! (a wall dimmer, a sensor, the Dial's ring) acts on one room, not always its own, and
//! names it in `controls`, so moving a dimmer can't change what it switches. A plug
//! drives a light or a `load`; a load is never one of a room's lights.
//!
//! Each entry is one line, so a rename or a move is a one-line diff. A device is its
//! IEEE address on either network. Pure: it reads, writes and checks what it's given,
//! and says nothing about any network.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const version = 2;
pub const FILE = "rooms.json";

pub const Room = struct {
    name: []const u8,
    /// The scene the top button recalls. A room with lights must have one, which only
    /// a dry run against the network can check; Max is generated, never named.
    default: ?[]const u8 = null,
};

/// When a sensor counts the room as dark.
pub const Dark = union(enum) {
    sunset,
    /// A light level read by the sensor itself, on the Bridge's scale.
    below: u32,

    pub fn jsonParse(a: Allocator, source: anytype, options: std.json.ParseOptions) !Dark {
        const v = try std.json.innerParse(std.json.Value, a, source, options);
        return jsonParseFromValue(a, v, options);
    }

    pub fn jsonParseFromValue(_: Allocator, v: std.json.Value, _: std.json.ParseOptions) !Dark {
        switch (v) {
            .string => |t| if (std.mem.eql(u8, t, "sunset")) return .sunset,
            .object => |o| if (o.count() == 1) if (o.get("below")) |n| if (n == .integer and n.integer > 0 and n.integer <= std.math.maxInt(u32))
                return .{ .below = @intCast(n.integer) },
            else => {},
        }
        return error.UnexpectedToken;
    }

    pub fn jsonStringify(self: Dark, jw: anytype) !void {
        switch (self) {
            .sunset => try jw.write("sunset"),
            .below => |n| {
                try jw.beginObject();
                try jw.objectField("below");
                try jw.write(n);
                try jw.endObject();
            },
        }
    }
};

/// From `from` until the next period's start, round the clock.
pub const Period = struct {
    /// "HH:MM", local time.
    from: []const u8,
    /// The room's scene for motion in the dark; null does nothing.
    on: ?[]const u8 = null,
    /// Minutes empty before its lights go off; null leaves them on.
    off_after: ?u32 = null,
    /// Lights already on when motion starts are left as they are: no scene, and no off
    /// afterwards. Hue's own name for it. Written only when true, so there's one spelling.
    do_not_disturb: ?bool = null,
};

pub const Sensor = struct {
    dark: Dark,
    periods: []const Period,
};

pub const Device = struct {
    dev: []const u8,
    name: []const u8,
    room: ?[]const u8 = null,
    /// `fan`, `pump` or `heater` for a plug that doesn't drive a light.
    load: ?[]const u8 = null,
    /// The room a dimmer, sensor or the Dial's ring acts on.
    controls: ?[]const u8 = null,
    /// The fan load a bathroom dimmer's bottom button runs, in place of Max.
    fan: ?[]const u8 = null,
    /// The Dial's buttons, each an action's name or null for none.
    buttons: ?[]const ?[]const u8 = null,
    sensor: ?Sensor = null,
    /// Why it's off on purpose. Still listed, but nothing counts it as wrong.
    parked: ?[]const u8 = null,
};

/// One thing an action or a schedule sets: a room (`*` for every room) to `off`,
/// `default`, `max` or one of its scenes, or a device `on` or `off`.
pub const Step = struct {
    room: ?[]const u8 = null,
    dev: ?[]const u8 = null,
    to: []const u8,
};

/// The same on every press, never a toggle.
pub const Action = struct {
    name: []const u8,
    do: []const Step,
};

pub const Schedule = struct {
    /// "HH:MM", local time.
    at: []const u8,
    /// Null is every day.
    days: ?[]const []const u8 = null,
    do: []const Step,
};

pub const Wanted = struct {
    v: u32 = version,
    rooms: []const Room,
    devices: []const Device,
    actions: []const Action = &.{},
    schedules: []const Schedule = &.{},

    pub fn parkedReason(self: *const Wanted, dev: []const u8) ?[]const u8 {
        const d = self.device(dev) orelse return null;
        return d.parked;
    }

    pub fn device(self: *const Wanted, dev: []const u8) ?*const Device {
        for (self.devices) |*d| if (std.mem.eql(u8, d.dev, dev)) return d;
        return null;
    }

    pub fn room(self: *const Wanted, name: []const u8) ?*const Room {
        return findRoom(self.rooms, name);
    }
};

pub const LOADS = [_][]const u8{ "fan", "pump", "heater" };
const DAYS = [_][]const u8{ "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday" };

/// Strings live in `arena`. A field this version doesn't know means a newer writer,
/// so the file is refused rather than guessed at. `why`, when given, gets a line
/// naming the entry at fault.
pub fn parse(arena: Allocator, text: []const u8) !Wanted {
    return parseWhy(arena, text, null);
}

pub fn parseWhy(arena: Allocator, text: []const u8, why: ?*?[]const u8) !Wanted {
    const w = try std.json.parseFromSliceLeaky(Wanted, arena, text, .{ .allocate = .alloc_always });
    if (w.v != version) return error.UnknownVersion;
    if (try problem(arena, w)) |p| {
        if (why) |out| out.* = p;
        return error.Invalid;
    }
    return w;
}

/// What's wrong with `w` that the file alone shows, or null.
pub fn problem(a: Allocator, w: Wanted) !?[]const u8 {
    for (w.rooms, 0..) |r, i| {
        if (r.name.len == 0) return "a room has no name";
        for (w.rooms[0..i]) |earlier| if (std.mem.eql(u8, earlier.name, r.name)) return try fmt(a, "the room {s} is listed twice", .{r.name});
        if (r.default) |s| if (s.len == 0) return try fmt(a, "{s}'s default is empty", .{r.name});
    }
    for (w.devices, 0..) |d, i| {
        if (d.name.len == 0) return try fmt(a, "{s} has no name", .{d.dev});
        for (w.devices[0..i]) |earlier| if (std.mem.eql(u8, earlier.dev, d.dev)) return try fmt(a, "{s} is listed twice", .{d.dev});
        if (d.parked) |p| if (p.len == 0) return try fmt(a, "{s} is parked with no reason", .{d.name});
        if (d.room) |r| if (findRoom(w.rooms, r) == null) return try fmt(a, "{s} is in {s}, which isn't a room", .{ d.name, r });
        if (d.load) |l| if (!among(&LOADS, l)) return try fmt(a, "{s}'s load {s} isn't fan, pump or heater", .{ d.name, l });
        if (d.controls) |r| if (findRoom(w.rooms, r) == null) return try fmt(a, "{s} controls {s}, which isn't a room", .{ d.name, r });
        if (d.fan) |f| {
            const fan = w.device(f) orelse return try fmt(a, "{s}'s fan {s} isn't listed", .{ d.name, f });
            if (fan.load == null or !std.mem.eql(u8, fan.load.?, "fan")) return try fmt(a, "{s}'s fan {s} isn't a fan load", .{ d.name, fan.name });
            if (d.controls == null) return try fmt(a, "{s} runs a fan but controls no room", .{d.name});
        }
        if (d.buttons) |bs| for (bs) |b| if (b) |name| if (findAction(w.actions, name) == null)
            return try fmt(a, "{s}'s button runs {s}, which isn't an action", .{ d.name, name });
        if (d.sensor) |s| if (try sensorProblem(a, w, d, s)) |p| return p;
    }
    for (w.actions, 0..) |act, i| {
        if (act.name.len == 0) return "an action has no name";
        for (w.actions[0..i]) |earlier| if (std.mem.eql(u8, earlier.name, act.name)) return try fmt(a, "the action {s} is listed twice", .{act.name});
        if (act.do.len == 0) return try fmt(a, "the action {s} does nothing", .{act.name});
        for (act.do) |st| if (try stepProblem(a, w, st, false)) |p| return try fmt(a, "{s}: {s}", .{ act.name, p });
    }
    for (w.schedules) |sc| {
        if (!isTime(sc.at)) return try fmt(a, "a schedule's time {s} isn't HH:MM", .{sc.at});
        if (sc.days) |ds| for (ds) |day| if (!among(&DAYS, day)) return try fmt(a, "the {s} schedule's day {s} isn't a weekday's name", .{ sc.at, day });
        if (sc.do.len == 0) return try fmt(a, "the {s} schedule does nothing", .{sc.at});
        for (sc.do) |st| if (try stepProblem(a, w, st, true)) |p| return try fmt(a, "the {s} schedule: {s}", .{ sc.at, p });
    }
    return null;
}

fn sensorProblem(a: Allocator, w: Wanted, d: Device, s: Sensor) !?[]const u8 {
    const room = d.controls orelse return try fmt(a, "the sensor {s} controls no room", .{d.name});
    if (s.periods.len == 0) return try fmt(a, "the sensor {s} has no periods", .{d.name});
    for (s.periods, 0..) |p, i| {
        if (!isTime(p.from)) return try fmt(a, "the sensor {s}'s period {s} isn't HH:MM", .{ d.name, p.from });
        if (i > 0 and std.mem.order(u8, s.periods[i - 1].from, p.from) != .lt)
            return try fmt(a, "the sensor {s}'s periods aren't in order at {s}", .{ d.name, p.from });
        if (p.off_after) |m| if (m == 0) return try fmt(a, "the sensor {s} turns off after 0 minutes at {s}", .{ d.name, p.from });
        if (p.on) |scene| if (scene.len == 0) return try fmt(a, "the sensor {s}'s scene at {s} is empty", .{ d.name, p.from });
        if (p.do_not_disturb) |b| if (!b) return try fmt(a, "the sensor {s}'s do_not_disturb at {s} is false: leave it out", .{ d.name, p.from });
        // A light left on needs something else that can turn it off.
        if (p.on != null and p.off_after == null and !hasOtherControl(w, d.dev, room))
            return try fmt(a, "the sensor {s} leaves {s} on from {s}, and nothing else there can turn it off", .{ d.name, room, p.from });
    }
    return null;
}

fn hasOtherControl(w: Wanted, sensor: []const u8, room: []const u8) bool {
    for (w.devices) |o| {
        if (std.mem.eql(u8, o.dev, sensor) or o.sensor != null) continue;
        if (o.controls) |c| if (std.mem.eql(u8, c, room)) return true;
    }
    return false;
}

/// Only a schedule may switch a load on, so a stray press never heats or pumps.
fn stepProblem(a: Allocator, w: Wanted, st: Step, schedule: bool) !?[]const u8 {
    if ((st.room == null) == (st.dev == null)) return "each step names a room or a device";
    if (st.room) |r| {
        if (!std.mem.eql(u8, r, "*") and findRoom(w.rooms, r) == null) return try fmt(a, "{s} isn't a room", .{r});
        if (st.to.len == 0) return try fmt(a, "{s} is set to nothing", .{r});
        if (std.mem.eql(u8, r, "*") and !std.mem.eql(u8, st.to, "off")) return "every room can only be set off";
        return null;
    }
    const d = w.device(st.dev.?) orelse return try fmt(a, "{s} isn't listed", .{st.dev.?});
    const on = std.mem.eql(u8, st.to, "on");
    if (!on and !std.mem.eql(u8, st.to, "off")) return try fmt(a, "{s} can only be set on or off", .{d.name});
    if (on and d.load != null and !schedule) return try fmt(a, "{s} is a load, and only a schedule switches a load on", .{d.name});
    return null;
}

fn isTime(t: []const u8) bool {
    if (t.len != 5 or t[2] != ':') return false;
    const h = std.fmt.parseInt(u8, t[0..2], 10) catch return false;
    const m = std.fmt.parseInt(u8, t[3..5], 10) catch return false;
    return h < 24 and m < 60;
}

fn among(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn findAction(actions: []const Action, name: []const u8) ?*const Action {
    for (actions) |*x| if (std.mem.eql(u8, x.name, name)) return x;
    return null;
}

fn fmt(a: Allocator, comptime f: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(a, f, args);
}

fn findRoom(rooms: []const Room, name: []const u8) ?*const Room {
    for (rooms) |*r| if (std.mem.eql(u8, r.name, name)) return r;
    return null;
}

/// One room, device, action or schedule a line, in the file's own order.
pub fn render(w: *Io.Writer, wanted: Wanted) !void {
    try w.print("{{\n  \"v\": {d},\n", .{wanted.v});
    try section(w, "rooms", Room, wanted.rooms, ",");
    try section(w, "devices", Device, wanted.devices, ",");
    try section(w, "actions", Action, wanted.actions, ",");
    try section(w, "schedules", Schedule, wanted.schedules, "");
    try w.writeAll("}\n");
}

fn section(w: *Io.Writer, comptime name: []const u8, comptime T: type, items: []const T, after: []const u8) !void {
    const opts: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
    try w.writeAll("  \"" ++ name ++ "\": [\n");
    for (items, 0..) |x, i| {
        try w.writeAll("    ");
        try std.json.Stringify.value(x, opts, w);
        try w.writeAll(if (i + 1 < items.len) ",\n" else "\n");
    }
    try w.print("  ]{s}\n", .{after});
}

/// A device as a network's inventory has it now.
pub const Current = struct {
    dev: []const u8,
    name: []const u8,
    room: ?[]const u8,
};

/// The file that says the house should stay as it is: rooms and devices by name.
/// Defaults, controls, loads, sensors, actions and schedules are for a person to add.
pub fn generate(arena: Allocator, current: []const Current) !Wanted {
    var room_names: std.ArrayList([]const u8) = .empty;
    for (current) |c| {
        const room = c.room orelse continue;
        for (room_names.items) |n| {
            if (std.mem.eql(u8, n, room)) break;
        } else try room_names.append(arena, room);
    }
    std.mem.sort([]const u8, room_names.items, {}, lessName);
    const rooms = try arena.alloc(Room, room_names.items.len);
    for (room_names.items, rooms) |name, *r| r.* = .{ .name = name };

    const devices = try arena.alloc(Device, current.len);
    for (current, devices) |c, *d| d.* = .{ .dev = c.dev, .name = c.name, .room = c.room };
    sortDevices(devices);
    return .{ .rooms = rooms, .devices = devices };
}

/// By room, then name, with no room last: the file's order, so a device's line
/// is where a reader looks for it.
fn sortDevices(devices: []Device) void {
    std.mem.sort(Device, devices, {}, struct {
        fn lt(_: void, a: Device, b: Device) bool {
            const ra = a.room orelse "\u{10FFFF}";
            const rb = b.room orelse "\u{10FFFF}";
            const order = std.ascii.orderIgnoreCase(ra, rb);
            if (order != .eq) return order == .lt;
            return lessName({}, a.name, b.name);
        }
    }.lt);
}

pub const Edit = union(enum) {
    name: []const u8,
    /// Null for no room.
    room: ?[]const u8,
};

pub const EditError = error{ UnknownDevice, UnknownRoom, EmptyName, Unchanged };

/// `wanted` with one device renamed or moved, in the file's order. Only what's
/// already listed: a device the file lacks is added by its network's inventory.
/// What a network can't take, such as a name too long for the Bridge, its dry
/// run refuses.
pub fn edit(arena: Allocator, wanted: Wanted, dev: []const u8, change: Edit) (EditError || Allocator.Error)!Wanted {
    const devices = try arena.dupe(Device, wanted.devices);
    const d = for (devices) |*d| {
        if (std.mem.eql(u8, d.dev, dev)) break d;
    } else return error.UnknownDevice;
    switch (change) {
        .name => |raw| {
            const name = std.mem.trim(u8, raw, " \t");
            if (name.len == 0) return error.EmptyName;
            if (std.mem.eql(u8, name, d.name)) return error.Unchanged;
            d.name = try arena.dupe(u8, name);
        },
        .room => |room| {
            if (room) |r| if (findRoom(wanted.rooms, r) == null) return error.UnknownRoom;
            if (optEql(room, d.room)) return error.Unchanged;
            d.room = if (room) |r| try arena.dupe(u8, r) else null;
        },
    }
    sortDevices(devices);
    return .{ .v = wanted.v, .rooms = wanted.rooms, .devices = devices, .actions = wanted.actions, .schedules = wanted.schedules };
}

/// What in the file names `dev` besides its own entry: another device's fan, an
/// action's or a schedule's step. Each must go before the device can.
pub fn usesOf(arena: Allocator, wanted: Wanted, dev: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (wanted.devices) |d| if (d.fan) |f| if (std.mem.eql(u8, f, dev))
        try out.append(arena, try std.fmt.allocPrint(arena, "{s}'s fan", .{d.name}));
    for (wanted.actions) |act| for (act.do) |st| if (st.dev) |x| if (std.mem.eql(u8, x, dev))
        try out.append(arena, try std.fmt.allocPrint(arena, "the action {s}", .{act.name}));
    for (wanted.schedules) |sc| for (sc.do) |st| if (st.dev) |x| if (std.mem.eql(u8, x, dev))
        try out.append(arena, try std.fmt.allocPrint(arena, "the {s} schedule", .{sc.at}));
    return out.items;
}

pub const RemoveError = error{ UnknownDevice, InUse };

/// `wanted` without `dev`'s entry. Refused while anything else in it names the
/// device, as `usesOf` says.
pub fn remove(arena: Allocator, wanted: Wanted, dev: []const u8) (RemoveError || Allocator.Error)!Wanted {
    if (wanted.device(dev) == null) return error.UnknownDevice;
    if ((try usesOf(arena, wanted, dev)).len > 0) return error.InUse;
    var devices: std.ArrayList(Device) = .empty;
    for (wanted.devices) |d| if (!std.mem.eql(u8, d.dev, dev)) try devices.append(arena, d);
    return .{ .v = wanted.v, .rooms = wanted.rooms, .devices = devices.items, .actions = wanted.actions, .schedules = wanted.schedules };
}

pub const AddError = error{ AlreadyListed, UnknownRoom, EmptyName };

/// `wanted` with a device it doesn't list yet, named and placed, in the file's
/// order. What a dimmer or sensor controls is added by hand afterwards.
pub fn add(arena: Allocator, wanted: Wanted, dev: []const u8, raw: []const u8, room: ?[]const u8) (AddError || Allocator.Error)!Wanted {
    if (wanted.device(dev) != null) return error.AlreadyListed;
    const name = std.mem.trim(u8, raw, " \t");
    if (name.len == 0) return error.EmptyName;
    if (room) |r| if (findRoom(wanted.rooms, r) == null) return error.UnknownRoom;
    const devices = try arena.alloc(Device, wanted.devices.len + 1);
    @memcpy(devices[0..wanted.devices.len], wanted.devices);
    devices[wanted.devices.len] = .{
        .dev = try arena.dupe(u8, dev),
        .name = try arena.dupe(u8, name),
        .room = if (room) |r| try arena.dupe(u8, r) else null,
    };
    sortDevices(devices);
    return .{ .v = wanted.v, .rooms = wanted.rooms, .devices = devices, .actions = wanted.actions, .schedules = wanted.schedules };
}

pub const DefaultError = error{ UnknownRoom, EmptyName, Unchanged, GeneratedScene };

/// `wanted` with one room's default scene changed. That the room has a scene of
/// that name only the rooms dry run can check, against the Bridge.
pub fn setDefault(arena: Allocator, wanted: Wanted, room: []const u8, raw: []const u8) (DefaultError || Allocator.Error)!Wanted {
    const scene = std.mem.trim(u8, raw, " \t");
    if (scene.len == 0) return error.EmptyName;
    // dmain makes Max for the dimmers; a default never names it.
    if (std.mem.eql(u8, scene, "Max")) return error.GeneratedScene;
    const rooms = try arena.dupe(Room, wanted.rooms);
    const r = for (rooms) |*r| {
        if (std.mem.eql(u8, r.name, room)) break r;
    } else return error.UnknownRoom;
    if (optEql(scene, r.default)) return error.Unchanged;
    r.default = try arena.dupe(u8, scene);
    return .{ .v = wanted.v, .rooms = rooms, .devices = wanted.devices, .actions = wanted.actions, .schedules = wanted.schedules };
}

fn lessName(_: void, a: []const u8, b: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(a, b);
}

/// A device as one network's latest inventory lists it.
pub const Held = struct {
    dev: []const u8,
    name: []const u8,
    room: ?[]const u8,
    /// `hue-bridge` or `hub`, as the house log names its sources.
    network: []const u8,
};

pub const Change = struct {
    /// Who would make it: "the Bridge", "hub", or `rooms.json` itself for a
    /// device the file lists and no network has.
    by: []const u8,
    text: []const u8,
};

pub fn networkName(network: []const u8) []const u8 {
    return if (std.mem.eql(u8, network, "hub")) "hub" else "the Bridge";
}

/// What would change on a network to make it say what `wanted` says: renames and
/// moves, and devices it lists that the file doesn't. A device is matched by its
/// address, so a rename is never mistaken for a new device. A device in the file
/// that `held` lacks isn't one: it may be the other network's.
pub fn changes(arena: Allocator, wanted: Wanted, held: []const Held) ![]const Change {
    var out: std.ArrayList(Change) = .empty;
    for (held) |h| {
        const by = networkName(h.network);
        const w = for (wanted.devices) |*d| {
            if (std.mem.eql(u8, d.dev, h.dev)) break d;
        } else {
            try out.append(arena, .{ .by = by, .text = try std.fmt.allocPrint(arena, "{s} ({s}) isn't in {s}", .{ h.name, h.dev, FILE }) });
            continue;
        };
        if (!std.mem.eql(u8, w.name, h.name))
            try out.append(arena, .{ .by = by, .text = try std.fmt.allocPrint(arena, "rename {s} to {s}", .{ h.name, w.name }) });
        if (!optEql(w.room, h.room))
            try out.append(arena, .{ .by = by, .text = try std.fmt.allocPrint(arena, "move {s} from {s} to {s}", .{ w.name, h.room orelse "no room", w.room orelse "no room" }) });
    }
    return out.items;
}

/// A device as hub's `devices.json` has it; no room is "".
pub const HubEntry = struct {
    name: []const u8,
    ieee: []const u8,
    room: []const u8 = "",
};

const HubFile = struct { devices: []const HubEntry = &.{} };

pub const HUB_FILE = "devices.json";

pub fn parseHub(arena: Allocator, text: []const u8) ![]const HubEntry {
    const f = try std.json.parseFromSliceLeaky(HubFile, arena, text, .{ .allocate = .alloc_always });
    return f.devices;
}

pub fn hubHeld(arena: Allocator, entries: []const HubEntry) ![]const Held {
    const held = try arena.alloc(Held, entries.len);
    for (entries, held) |e, *h| h.* = .{ .dev = e.ieee, .name = e.name, .room = if (e.room.len > 0) e.room else null, .network = "hub" };
    return held;
}

/// Why `wanted` can't be given to hub, or null: its console takes a device's
/// name as one word.
pub fn hubRefusal(arena: Allocator, wanted: Wanted, entries: []const HubEntry) !?[]const u8 {
    for (entries) |e| for (wanted.devices) |d| {
        if (!std.mem.eql(u8, d.dev, e.ieee)) continue;
        if (std.mem.indexOfAny(u8, d.name, " \t") != null)
            return try std.fmt.allocPrint(arena, "hub's console takes a name as one word, and {s} isn't", .{d.name});
    };
    return null;
}

/// `devices.json` with each entry's name and room as `wanted` says, in its own
/// order, one entry a line. An entry the file doesn't list is left as it is.
pub fn renderHub(w: *Io.Writer, wanted: Wanted, entries: []const HubEntry) !void {
    try w.writeAll("{\n  \"devices\": [\n");
    for (entries, 0..) |e, i| {
        var out = e;
        for (wanted.devices) |d| if (std.mem.eql(u8, d.dev, e.ieee)) {
            out.name = d.name;
            out.room = d.room orelse "";
        };
        try w.writeAll("    { \"name\": ");
        try std.json.Stringify.value(out.name, .{}, w);
        try w.writeAll(", \"ieee\": ");
        try std.json.Stringify.value(out.ieee, .{}, w);
        if (out.room.len > 0) {
            try w.writeAll(", \"room\": ");
            try std.json.Stringify.value(out.room, .{}, w);
        }
        try w.writeAll(if (i + 1 < entries.len) " },\n" else " }\n");
    }
    try w.writeAll("  ]\n}\n");
}

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

const testing = std.testing;

test "changes are renames and moves by address" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const wanted = try parse(a,
        \\{"v":2,"rooms":[{"name":"Hall"},{"name":"Lounge"}],"devices":[
        \\ {"dev":"b","name":"Lamp","room":"Lounge"},
        \\ {"dev":"c","name":"Ceiling","room":"Hall"},
        \\ {"dev":"p","name":"power1","parked":"unplugged"},
        \\ {"dev":"g","name":"Gone","room":"Hall"},
        \\ {"dev":"s","name":"Same"}]}
    );
    const held = [_]Held{
        .{ .dev = "b", .name = "Lamp 1", .room = "Lounge", .network = "hue" },
        .{ .dev = "c", .name = "Ceiling", .room = null, .network = "hub" },
        .{ .dev = "s", .name = "Same", .room = null, .network = "hue" },
        .{ .dev = "n", .name = "New", .room = "Hall", .network = "hub" },
    };
    const got = try changes(a, wanted, &held);
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("the Bridge", got[0].by);
    try testing.expectEqualStrings("rename Lamp 1 to Lamp", got[0].text);
    try testing.expectEqualStrings("hub", got[1].by);
    try testing.expectEqualStrings("move Ceiling from no room to Hall", got[1].text);
    try testing.expectEqualStrings("New (n) isn't in rooms.json", got[2].text);

    try testing.expectEqual(@as(usize, 0), (try changes(a, wanted, &.{
        .{ .dev = "b", .name = "Lamp", .room = "Lounge", .network = "hue" },
        .{ .dev = "c", .name = "Ceiling", .room = "Hall", .network = "hub" },
        .{ .dev = "g", .name = "Gone", .room = "Hall", .network = "hub" },
        .{ .dev = "s", .name = "Same", .room = null, .network = "hue" },
    })).len);
}

test "a generated file names each room once and survives its own reader" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const current = [_]Current{
        .{ .dev = "b", .name = "Bulb", .room = "Lounge" },
        .{ .dev = "p", .name = "power1", .room = null },
        .{ .dev = "c", .name = "Ceiling", .room = "Hall" },
        .{ .dev = "d", .name = "Dimmer", .room = "Lounge" },
    };
    const g = try generate(a, &current);
    try testing.expectEqual(@as(usize, 2), g.rooms.len);
    try testing.expectEqualStrings("Hall", g.rooms[0].name);
    // By room, then name, with no room last.
    try testing.expectEqualStrings("Ceiling", g.devices[0].name);
    try testing.expectEqualStrings("Bulb", g.devices[1].name);
    try testing.expectEqualStrings("power1", g.devices[3].name);

    var aw: Io.Writer.Allocating = .init(a);
    try render(&aw.writer, g);
    const text = aw.written();
    try testing.expect(std.mem.indexOf(u8, text, "    {\"dev\":\"b\",\"name\":\"Bulb\",\"room\":\"Lounge\"},\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "{\"dev\":\"p\",\"name\":\"power1\"}\n") != null);
    const back = try parse(a, text);
    try testing.expectEqual(@as(usize, 4), back.devices.len);
}

test "parked says why, and the reader refuses what it can't trust" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good =
        \\{"v":2,"rooms":[{"name":"Bed 2"}],"devices":[
        \\ {"dev":"p","name":"power1","room":"Bed 2","parked":"unplugged on purpose"},
        \\ {"dev":"m","name":"motion2","room":"Bed 2"}]}
    ;
    const w = try parse(a, good);
    try testing.expectEqualStrings("unplugged on purpose", w.parkedReason("p").?);
    try testing.expect(w.parkedReason("m") == null);
    try testing.expect(w.parkedReason("x") == null);

    try expectWhy(a, "power1 is in Nowhere, which isn't a room",
        \\{"v":2,"rooms":[],"devices":[{"dev":"p","name":"power1","room":"Nowhere"}]}
    );
    try expectWhy(a, "p is listed twice",
        \\{"v":2,"rooms":[],"devices":[{"dev":"p","name":"a"},{"dev":"p","name":"b"}]}
    );
    try expectWhy(a, "the room A is listed twice",
        \\{"v":2,"rooms":[{"name":"A"},{"name":"A"}],"devices":[]}
    );
    try expectWhy(a, "a is parked with no reason",
        \\{"v":2,"rooms":[],"devices":[{"dev":"p","name":"a","parked":""}]}
    );
    try testing.expectError(error.UnknownVersion, parse(a,
        \\{"v":1,"rooms":[],"devices":[]}
    ));
    try testing.expectError(error.UnknownField, parse(a,
        \\{"v":2,"rooms":[],"devices":[{"dev":"p","name":"a","zone":"x"}]}
    ));
}

test "devices.json takes its names and rooms from the file, and refuses a name with a space" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = try parseHub(a,
        \\{ "devices": [ { "name": "panel", "ieee": "p", "room" : "Bedroom 2" },
        \\  { "name": "hum1", "ieee": "h", "room": "TV Room" }, { "name": "odd", "ieee": "o" } ] }
    );
    const wanted = try parse(a,
        \\{"v":2,"rooms":[{"name":"Study"},{"name":"TV Room"}],"devices":[
        \\ {"dev":"p","name":"Panel","room":"Study"},{"dev":"h","name":"hum1"}]}
    );
    try testing.expect(try hubRefusal(a, wanted, entries) == null);
    var aw: Io.Writer.Allocating = .init(a);
    try renderHub(&aw.writer, wanted, entries);
    try testing.expectEqualStrings(
        \\{
        \\  "devices": [
        \\    { "name": "Panel", "ieee": "p", "room": "Study" },
        \\    { "name": "hum1", "ieee": "h" },
        \\    { "name": "odd", "ieee": "o" }
        \\  ]
        \\}
        \\
    , aw.written());
    // What it writes, hub reads back, and now matches.
    const back = try parseHub(a, aw.written());
    const left = try changes(a, wanted, try hubHeld(a, back));
    try testing.expectEqual(@as(usize, 1), left.len); // odd isn't in the file
    try testing.expectEqualStrings("odd (o) isn't in rooms.json", left[0].text);

    const spaced = try parse(a,
        \\{"v":2,"rooms":[],"devices":[{"dev":"p","name":"Bed panel"}]}
    );
    try testing.expect(try hubRefusal(a, spaced, entries) != null);
}

test "an edit renames or moves one device, keeps the file's order, and refuses a bad one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = try parse(a,
        \\{"v":2,"rooms":[{"name":"Hall"},{"name":"Study"}],"devices":[
        \\ {"dev":"c","name":"Ceiling","room":"Hall"},
        \\ {"dev":"l","name":"Lamp","room":"Study"},
        \\ {"dev":"x","name":"Annex"}]}
    );
    const moved = try edit(a, w, "x", .{ .room = "Hall" });
    try testing.expectEqualStrings("Annex", moved.devices[0].name);
    try testing.expectEqualStrings("Hall", moved.devices[0].room.?);
    try testing.expect(w.devices[2].room == null); // the original is left alone
    const out = try edit(a, moved, "c", .{ .room = null });
    try testing.expectEqualStrings("Ceiling", out.devices[2].name);
    const renamed = try edit(a, w, "l", .{ .name = "  Desk lamp " });
    try testing.expectEqualStrings("Desk lamp", renamed.devices[1].name);

    try testing.expectError(error.UnknownDevice, edit(a, w, "nope", .{ .name = "X" }));
    try testing.expectError(error.UnknownRoom, edit(a, w, "c", .{ .room = "Attic" }));
    try testing.expectError(error.EmptyName, edit(a, w, "c", .{ .name = " " }));
    try testing.expectError(error.Unchanged, edit(a, w, "c", .{ .room = "Hall" }));
}

test "a new device is added named and placed, in order, and a bad one refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = try parse(a,
        \\{"v":2,"rooms":[{"name":"Hall"},{"name":"Study"}],"devices":[
        \\ {"dev":"c","name":"Ceiling","room":"Hall"},
        \\ {"dev":"l","name":"Lamp","room":"Study"}]}
    );
    const added = try add(a, w, "n", " Bulb ", "Hall");
    try testing.expectEqual(@as(usize, 3), added.devices.len);
    try testing.expectEqualStrings("Bulb", added.devices[0].name);
    try testing.expectEqualStrings("Hall", added.devices[0].room.?);
    try testing.expectEqual(@as(usize, 2), w.devices.len); // the original is left alone
    const loose = try add(a, w, "x", "Annex", null);
    try testing.expectEqualStrings("Annex", loose.devices[2].name);
    try testing.expect(loose.devices[2].room == null);
    // Written and read back as the same file.
    var aw: Io.Writer.Allocating = .init(a);
    try render(&aw.writer, added);
    try testing.expectEqualStrings("Bulb", (try parse(a, aw.written())).devices[0].name);

    try testing.expectError(error.AlreadyListed, add(a, w, "c", "Again", "Hall"));
    try testing.expectError(error.EmptyName, add(a, w, "n", " ", "Hall"));
    try testing.expectError(error.UnknownRoom, add(a, w, "n", "Bulb", "Attic"));
}

test "a device is removed only when nothing else in the file names it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = try parse(a,
        \\{"v":2,"rooms":[{"name":"Bathroom"}],"devices":[
        \\ {"dev":"d","name":"Dimmer","room":"Bathroom","controls":"Bathroom","fan":"f"},
        \\ {"dev":"f","name":"Fan","room":"Bathroom","load":"fan"},
        \\ {"dev":"p","name":"Pump","load":"pump"},
        \\ {"dev":"x","name":"Spare"}],
        \\ "schedules":[{"at":"06:00","do":[{"dev":"p","to":"on"}]}]}
    );
    const gone = try remove(a, w, "x");
    try testing.expectEqual(@as(usize, 3), gone.devices.len);
    for (gone.devices) |d| try testing.expect(!std.mem.eql(u8, d.dev, "x"));
    try testing.expectEqual(@as(usize, 4), w.devices.len); // the original is left alone

    try testing.expectEqualStrings("Dimmer's fan", (try usesOf(a, w, "f"))[0]);
    try testing.expectEqualStrings("the 06:00 schedule", (try usesOf(a, w, "p"))[0]);
    try testing.expectError(error.InUse, remove(a, w, "f"));
    try testing.expectError(error.InUse, remove(a, w, "p"));
    try testing.expectError(error.UnknownDevice, remove(a, w, "nope"));
}

test "a room's default is set by name, and a bad one refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = try parse(a,
        \\{"v":2,"rooms":[{"name":"Hall","default":"Relax"},{"name":"Study"}],"devices":[]}
    );
    const set = try setDefault(a, w, "Study", " Read ");
    try testing.expectEqualStrings("Read", set.rooms[1].default.?);
    try testing.expect(w.rooms[1].default == null); // the original is left alone
    const changed = try setDefault(a, set, "Hall", "Bright");
    try testing.expectEqualStrings("Bright", changed.rooms[0].default.?);
    var aw: Io.Writer.Allocating = .init(a);
    try render(&aw.writer, changed);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "{\"name\":\"Hall\",\"default\":\"Bright\"}") != null);

    try testing.expectError(error.UnknownRoom, setDefault(a, w, "Attic", "Relax"));
    try testing.expectError(error.EmptyName, setDefault(a, w, "Hall", " "));
    try testing.expectError(error.Unchanged, setDefault(a, w, "Hall", "Relax"));
    try testing.expectError(error.GeneratedScene, setDefault(a, w, "Hall", "Max"));
}

fn expectWhy(a: Allocator, want: []const u8, text: []const u8) !void {
    var why: ?[]const u8 = null;
    try testing.expectError(error.Invalid, parseWhy(a, text, &why));
    try testing.expectEqualStrings(want, why.?);
}

const house_v2 =
    \\{
    \\  "v": 2,
    \\  "rooms": [
    \\    {"name":"Bathroom","default":"Bright"},
    \\    {"name":"Bedroom","default":"Lamps only"},
    \\    {"name":"Kitchen","default":"Read"},
    \\    {"name":"Outside","default":"Bright"},
    \\    {"name":"Services"}
    \\  ],
    \\  "devices": [
    \\    {"dev":"d1","name":"Bathroom","room":"Bathroom","controls":"Bathroom","fan":"x1"},
    \\    {"dev":"x1","name":"Bathroom Extractor","room":"Bathroom","load":"fan"},
    \\    {"dev":"l1","name":"Bedside lamp","room":"Bedroom"},
    \\    {"dev":"dial","name":"Dial","room":"Bedroom","controls":"Bedroom","buttons":["Lamp on",null,"Bedtime"]},
    \\    {"dev":"s1","name":"Nightlights","room":"Bedroom","controls":"Bedroom","sensor":{"dark":"sunset","periods":[{"from":"08:00","off_after":10},{"from":"21:00","on":"Footlight","off_after":1}]}},
    \\    {"dev":"d2","name":"Kitchen","room":"Kitchen","controls":"Kitchen"},
    \\    {"dev":"s2","name":"Kitchen","room":"Kitchen","controls":"Kitchen","sensor":{"dark":{"below":18314},"periods":[{"from":"06:30","on":"Bright"},{"from":"23:00","on":"Dimmed","off_after":5,"do_not_disturb":true}]}},
    \\    {"dev":"d3","name":"Outside - Patio","room":"Kitchen","controls":"Outside"},
    \\    {"dev":"p1","name":"Pump","room":"Services","load":"pump"},
    \\    {"dev":"m2","name":"motion2","parked":"flat battery"}
    \\  ],
    \\  "actions": [
    \\    {"name":"Lamp on","do":[{"dev":"l1","to":"on"}]},
    \\    {"name":"Bedtime","do":[{"room":"*","to":"off"},{"dev":"p1","to":"off"}]}
    \\  ],
    \\  "schedules": [
    \\    {"at":"06:00","do":[{"dev":"p1","to":"on"}]},
    \\    {"at":"08:00","days":["saturday","sunday"],"do":[{"dev":"p1","to":"off"}]}
    \\  ]
    \\}
    \\
;

test "version 2 reads back to the same text, a line an entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = try parse(a, house_v2);
    try testing.expectEqual(Dark{ .below = 18314 }, w.device("s2").?.sensor.?.dark);
    try testing.expect(w.device("s1").?.sensor.?.dark == .sunset);
    try testing.expect(w.device("s2").?.sensor.?.periods[1].do_not_disturb.?);
    try testing.expect(w.device("dial").?.buttons.?[1] == null);
    try testing.expectEqualStrings("Lamps only", w.room("Bedroom").?.default.?);
    var aw: Io.Writer.Allocating = .init(a);
    try render(&aw.writer, w);
    try testing.expectEqualStrings(house_v2, aw.written());

    // An edit carries everything else along.
    const moved = try edit(a, w, "d3", .{ .room = "Outside" });
    try testing.expectEqual(@as(usize, 2), moved.actions.len);
    try testing.expectEqualStrings("Outside", moved.device("d3").?.controls.?);
}

fn swap(a: Allocator, from: []const u8, to: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, a, house_v2, from, to);
}

test "version 2 refuses what the model forbids, naming the entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Each fault injected into the good file, so each check is seen to fail.
    try expectWhy(a, "Bedtime: Pump is a load, and only a schedule switches a load on", try swap(a, "{\"dev\":\"p1\",\"to\":\"off\"}]}", "{\"dev\":\"p1\",\"to\":\"on\"}]}"));
    try expectWhy(a, "the sensor Kitchen leaves Kitchen on from 06:30, and nothing else there can turn it off", try swap(a, "\"name\":\"Kitchen\",\"room\":\"Kitchen\",\"controls\":\"Kitchen\"}", "\"name\":\"Kitchen\",\"room\":\"Kitchen\"}"));
    try expectWhy(a, "Bathroom's fan Bedside lamp isn't a fan load", try swap(a, "\"fan\":\"x1\"", "\"fan\":\"l1\""));
    try expectWhy(a, "Pump's load boiler isn't fan, pump or heater", try swap(a, "\"load\":\"pump\"", "\"load\":\"boiler\""));
    try expectWhy(a, "Outside - Patio controls Garden, which isn't a room", try swap(a, "\"controls\":\"Outside\"", "\"controls\":\"Garden\""));
    try expectWhy(a, "Dial's button runs Awake, which isn't an action", try swap(a, "null,\"Bedtime\"", "\"Awake\",\"Bedtime\""));
    try expectWhy(a, "the sensor Nightlights's periods aren't in order at 21:00", try swap(a, "\"from\":\"08:00\",\"off_after\":10", "\"from\":\"22:00\",\"off_after\":10"));
    try expectWhy(a, "the sensor Nightlights's period 8:00 isn't HH:MM", try swap(a, "\"from\":\"08:00\",\"off_after\":10", "\"from\":\"8:00\",\"off_after\":10"));
    try expectWhy(a, "the sensor Kitchen's do_not_disturb at 23:00 is false: leave it out", try swap(a, "\"off_after\":5,\"do_not_disturb\":true", "\"off_after\":5,\"do_not_disturb\":false"));
    try expectWhy(a, "the 08:00 schedule's day sat isn't a weekday's name", try swap(a, "\"saturday\"", "\"sat\""));
    try expectWhy(a, "Bedtime: every room can only be set off", try swap(a, "{\"room\":\"*\",\"to\":\"off\"}", "{\"room\":\"*\",\"to\":\"max\"}"));
    try expectWhy(a, "Bedtime: each step names a room or a device", try swap(a, "{\"room\":\"*\",\"to\":\"off\"}", "{\"to\":\"off\"}"));
    try expectWhy(a, "Lamp on: Bedside lamp can only be set on or off", try swap(a, "{\"dev\":\"l1\",\"to\":\"on\"}", "{\"dev\":\"l1\",\"to\":\"max\"}"));
    try testing.expectError(error.UnexpectedToken, parse(a, try swap(a, "{\"below\":18314}", "\"dusk\"")));
}
