//! `dmain sensors`: each motion sensor as `rooms.json` says, a timetable of its room's
//! scenes on the lights they light. Bare `apply` only shows what would change, and
//! every write saves the sensor's whole old configuration first. A zone's copies of
//! the room's scenes are made or corrected before any sensor recalls them.
//!
//! This reads the Bridge directly, as `switches` does: a change to a configuration has
//! to start from what the sensor holds at that moment.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const bridge_write = @import("bridge_write");
const bridge_switches = @import("bridge_switches");
const bridge_sensors = @import("bridge_sensors");
const config = @import("config.zig");
const power_on_cmd = @import("power_on_cmd.zig");

const layout = @import("sensor_layout.zig");
const rf = @import("rooms_file.zig");
const MAX_FILE = 1 << 20;
/// Each write is one TLS connection and a write to the Bridge's flash.
const PAUSE = Io.Duration.fromMilliseconds(1000);

pub const usage =
    \\  dmain sensors check                 show what the motion sensors would change to match rooms.json
    \\  dmain sensors apply                 the same
    \\  dmain sensors apply confirm         write zone scenes and the sensors, saving each old setup first
    \\  dmain sensors apply [confirm] NAME   the same for the one sensor rooms.json calls NAME
    \\  ... check|apply [confirm] -        the same, with rooms.json on stdin
    \\  dmain sensors restore FILE confirm  put a saved setup back
    \\
;

const Bridge = struct {
    credentials: bridge_write.Credentials,
    resources: []const u8,
    sensors: []const bridge_sensors.Sensor,
    scenes: []const layout.Scene,
    groups: []const layout.Group,
};

fn readWith(arena: Allocator, gpa: Allocator, io: Io, credentials: bridge_write.Credentials, out: *Io.Writer) !Bridge {
    const owned = bridge_write.resources(gpa, io, credentials) catch |err| {
        try out.print("dmain: cannot read the Bridge ({t})\n", .{err});
        return err;
    };
    defer gpa.free(owned);
    const resources = try arena.dupe(u8, owned);
    const sc = try bridge_sensors.scenes(arena, resources);
    const scenes = try arena.alloc(layout.Scene, sc.len);
    for (sc, scenes) |x, *y| y.* = .{ .id = x.id, .group_id = x.group_id, .name = x.name, .lit = x.lit };
    const g = try bridge_switches.groups(arena, resources);
    const groups = try arena.alloc(layout.Group, g.groups.len);
    for (g.groups, groups) |x, *y| y.* = .{ .id = x.group.id, .name = x.group.name, .rtype = x.group.rtype, .devs = x.devs };
    return .{
        .credentials = credentials,
        .resources = resources,
        .sensors = try bridge_sensors.parse(arena, resources),
        .scenes = scenes,
        .groups = groups,
    };
}

fn readBridge(arena: Allocator, gpa: Allocator, io: Io, app: *const config.Config, out: *Io.Writer) !Bridge {
    const text = Io.Dir.cwd().readFileAlloc(io, app.bridge_file, arena, .limited(MAX_FILE)) catch |err| {
        try out.print("dmain: cannot read {s} ({t})\n", .{ app.bridge_file, err });
        return err;
    };
    // By name only: this file holds the Bridge's key.
    const credentials = bridge_write.parseCredentials(arena, text) catch |err| {
        try out.print("dmain: {s} is not right ({t})\n", .{ app.bridge_file, err });
        return err;
    };
    return readWith(arena, gpa, io, credentials, out);
}

/// A zone scene that needs writing.
const CopyWrite = struct { zone: layout.Group, name: []const u8, copy: bridge_sensors.Copy };

/// One sensor that differs from the file. `want`'s scene ids are null for a copy not
/// made yet; the write resolves them after the copies.
const Change = struct {
    target: layout.Target,
    sensor: bridge_sensors.Sensor,
    want: bridge_sensors.Want,
    /// A scene the write needs that isn't on the Bridge yet.
    pending: bool,
};

const Plan = struct {
    targets: layout.Targets,
    copies: []const CopyWrite,
    changes: []const Change,
    /// In the file but with no sensor behaviour on the Bridge.
    missing: []const layout.Target,
    /// On the Bridge but in no timetable of the file.
    unlisted: []const bridge_sensors.Sensor,

    fn writes(self: Plan) usize {
        return self.copies.len + self.changes.len;
    }
};

fn sensorFor(bridge: Bridge, dev: []const u8) ?bridge_sensors.Sensor {
    for (bridge.sensors) |s| if (std.mem.eql(u8, s.dev, dev)) return s;
    return null;
}

fn want(arena: Allocator, bridge: Bridge, t: layout.Target) !struct { want: bridge_sensors.Want, pending: bool } {
    var pending = false;
    const slots = try arena.alloc(bridge_sensors.Slot, t.periods.len);
    for (t.periods, slots) |p, *s| {
        var id: ?[]const u8 = null;
        if (p.scene) |name| {
            if (layout.sceneIn(bridge.scenes, t.group.id, name)) |sc| id = sc.id else |_| {
                pending = true;
                id = "(to make)";
            }
        }
        s.* = .{ .hour = p.hour, .minute = p.minute, .scene = id, .off_after = p.off_after, .do_not_disturb = p.do_not_disturb };
    }
    const dark: bridge_sensors.Dark = switch (t.dark) {
        .sunset => .sunset,
        .below => |n| .{ .below = n },
    };
    return .{ .want = .{ .group_id = t.group.id, .group_rtype = t.group.rtype, .dark = dark, .slots = slots }, .pending = pending };
}

/// `only` keeps the one sensor of that name, and leaves the rest unreported.
fn makePlan(arena: Allocator, bridge: Bridge, wanted: rf.Wanted, only: ?[]const u8) !Plan {
    var t = try layout.targets(arena, wanted, bridge.groups, bridge.scenes);
    if (only) |name| {
        var kept: std.ArrayList(layout.Target) = .empty;
        for (t.targets) |x| if (std.mem.eql(u8, x.name, name)) try kept.append(arena, x);
        var refused: std.ArrayList(layout.Refusal) = .empty;
        for (t.refusals) |r| if (std.mem.eql(u8, r.name, name)) try refused.append(arena, r);
        t = .{ .targets = kept.items, .refusals = refused.items };
    }
    var copies: std.ArrayList(CopyWrite) = .empty;
    var changes: std.ArrayList(Change) = .empty;
    var missing: std.ArrayList(layout.Target) = .empty;
    for (t.targets) |target| {
        for (target.copies) |c| {
            const seen = for (copies.items) |e| {
                if (std.mem.eql(u8, e.zone.id, target.group.id) and std.mem.eql(u8, e.name, c.name)) break true;
            } else false;
            if (seen) continue;
            const copy = try bridge_sensors.copyScene(arena, bridge.resources, c.from, target.group.id, c.name);
            if (copy.body != null) try copies.append(arena, .{ .zone = target.group, .name = c.name, .copy = copy });
        }
        const s = sensorFor(bridge, target.dev) orelse {
            try missing.append(arena, target);
            continue;
        };
        const w = try want(arena, bridge, target);
        if (w.pending or !bridge_sensors.matches(s, w.want)) try changes.append(arena, .{ .target = target, .sensor = s, .want = w.want, .pending = w.pending });
    }
    var unlisted: std.ArrayList(bridge_sensors.Sensor) = .empty;
    if (only == null) for (bridge.sensors) |s| {
        const listed = for (t.targets) |x| {
            if (std.mem.eql(u8, x.dev, s.dev)) break true;
        } else for (t.refusals) |r| {
            const d = wanted.device(s.dev) orelse continue;
            if (std.mem.eql(u8, d.name, r.name)) break true;
        } else false;
        if (!listed) try unlisted.append(arena, s);
    };
    return .{ .targets = t, .copies = copies.items, .changes = changes.items, .missing = missing.items, .unlisted = unlisted.items };
}

/// `given` is `rooms.json`'s text when it came from elsewhere, such as the Mac's
/// copy through `dmain agent`.
pub fn run(gpa: Allocator, arena: Allocator, io: Io, app: *const config.Config, args: []const []const u8, given: ?[]const u8, out: *Io.Writer) !void {
    const sub = if (args.len > 0) args[0] else "";
    if (std.mem.eql(u8, sub, "restore")) return restore(gpa, arena, io, app, args[1..], out);

    const check = std.mem.eql(u8, sub, "check");
    const apply = std.mem.eql(u8, sub, "apply");
    const confirm = args.len >= 2 and std.mem.eql(u8, args[1], "confirm");
    // apply NAME, or apply confirm NAME: one sensor.
    const only: ?[]const u8 = if (apply and args.len == 3 and confirm) args[2] else if (apply and args.len == 2 and !confirm) args[1] else null;
    if (!(check or apply) or args.len > 3 or (check and args.len != 1) or (args.len == 3 and !confirm)) {
        try out.writeAll(usage);
        return error.BadUsage;
    }
    const text = given orelse Io.Dir.cwd().readFileAlloc(io, rf.FILE, arena, .limited(MAX_FILE)) catch |err| {
        try out.print("dmain: cannot read {s} ({t})\n", .{ rf.FILE, err });
        return err;
    };
    var why: ?[]const u8 = null;
    const wanted = rf.parseWhy(arena, text, &why) catch |err| {
        try out.print("dmain: {s} is not right ({s})\n", .{ rf.FILE, why orelse @errorName(err) });
        return err;
    };
    const bridge = try readBridge(arena, gpa, io, app, out);
    const p = try makePlan(arena, bridge, wanted, only);
    if (only) |name| if (p.targets.targets.len == 0 and p.targets.refusals.len == 0) {
        try out.print("dmain: rooms.json has no sensor timetable called {s}\n", .{name});
        return error.BadUsage;
    };
    const refused = try printReport(arena, p, bridge, out);
    if (!apply or p.writes() == 0) return;
    if (refused > 0) {
        try out.print("Nothing written: {d} problem(s) above need fixing first.\n", .{refused});
        return error.BadScene;
    }
    if (!confirm) {
        try out.writeAll("Nothing written. `dmain sensors apply confirm` writes these to the Bridge.\n");
        return;
    }
    try applyAll(gpa, arena, io, app, p, bridge, wanted, only, out);
}

fn groupName(bridge: Bridge, id: []const u8) []const u8 {
    for (bridge.groups) |g| if (std.mem.eql(u8, g.id, id)) return g.name;
    return id;
}

fn sceneName(bridge: Bridge, id: []const u8) []const u8 {
    for (bridge.scenes) |s| if (std.mem.eql(u8, s.id, id)) return s.name;
    return id;
}

fn darkText(arena: Allocator, d: ?bridge_sensors.Dark) ![]const u8 {
    const x = d orelse return "something else";
    return switch (x) {
        .sunset => "after sunset",
        .below => |n| try std.fmt.allocPrint(arena, "below {d}", .{n}),
    };
}

fn slotText(arena: Allocator, bridge: Bridge, s: bridge_sensors.Slot, name: ?[]const u8) ![]const u8 {
    const scene = if (s.scene) |id| name orelse sceneName(bridge, id) else "nothing";
    const off = if (s.off_after) |m| try std.fmt.allocPrint(arena, "off after {d} min", .{m}) else "stays on";
    return std.fmt.allocPrint(arena, "{d:0>2}:{d:0>2} {s}, {s}{s}", .{ s.hour, s.minute, scene, off, if (s.do_not_disturb) ", lit lights left alone" else "" });
}

fn printReport(arena: Allocator, p: Plan, bridge: Bridge, out: *Io.Writer) !usize {
    try out.print("{d} sensors, {d} would change, and {d} zone scenes to write.\n", .{ bridge.sensors.len, p.changes.len, p.copies.len });
    var refused: usize = 0;
    for (p.targets.refusals) |r| {
        try out.print("  can't: {s}: {s}\n", .{ r.name, r.why });
        refused += 1;
    }
    for (p.copies) |c| try out.print("  {s} in the zone {s}: {s}, {d} lights from the room's {s}\n", .{ c.name, c.zone.name, if (c.copy.id == null) "make it" else "correct it", c.copy.lights, c.name });
    for (p.changes) |c| {
        try out.print("  {s}:\n", .{c.target.name});
        const now_where = if (c.sensor.where.len == 1) groupName(bridge, c.sensor.where[0]) else "several";
        if (c.sensor.where.len != 1 or !std.mem.eql(u8, c.sensor.where[0], c.want.group_id))
            try out.print("    acts on: {s} -> {s} ({s})\n", .{ now_where, c.target.group.name, c.target.group.rtype });
        const dark = c.sensor.dark;
        if (dark == null or !dark.?.eql(c.want.dark)) try out.print("    dark: {s} -> {s}\n", .{ try darkText(arena, dark), try darkText(arena, c.want.dark) });
        const now = c.sensor.slots orelse &.{};
        const same = c.sensor.slots != null and now.len == c.want.slots.len and for (now, c.want.slots) |a, b| {
            if (!a.eql(b)) break false;
        } else true;
        if (!same) {
            if (c.sensor.slots == null) try out.writeAll("    now: a timetable this can't read\n");
            for (now) |s| try out.print("    now:  {s}\n", .{try slotText(arena, bridge, s, null)});
            for (c.want.slots, c.target.periods) |s, per| try out.print("    want: {s}\n", .{try slotText(arena, bridge, s, per.scene)});
        }
    }
    for (p.missing) |t| try out.print("  not a Bridge sensor, left alone: {s}\n", .{t.name});
    for (p.unlisted) |s| try out.print("  on the Bridge but with no timetable in rooms.json, left alone: {s} ({s})\n", .{ s.name, s.dev });
    return refused;
}

const Saved = struct {
    id: []const u8,
    name: []const u8,
    configuration: std.json.Value,
};

fn saveOld(arena: Allocator, io: Io, app: *const config.Config, s: bridge_sensors.Sensor) ![]const u8 {
    try Io.Dir.cwd().createDirPath(io, app.backups);
    const dev = try arena.dupe(u8, s.dev);
    std.mem.replaceScalar(u8, dev, ':', '-');
    const path = try std.fmt.allocPrint(arena, "{s}/sensor-{s}-{d}.json", .{ app.backups, dev, Io.Timestamp.now(io, .real).toSeconds() });
    const text = try std.json.Stringify.valueAlloc(arena, Saved{ .id = s.instance, .name = s.name, .configuration = s.configuration }, .{ .whitespace = .indent_1 });
    var file = try Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll(text);
    try w.interface.flush();
    return path;
}

fn applyAll(gpa: Allocator, arena: Allocator, io: Io, app: *const config.Config, p: Plan, bridge: Bridge, wanted: rf.Wanted, only: ?[]const u8, out: *Io.Writer) !void {
    var accepted: usize = 0;
    var failed: usize = 0;
    // The scenes first: a sensor can only recall one that's there.
    for (p.copies) |c| {
        var reply: bridge_write.Reply = .{};
        const label = try std.fmt.allocPrint(arena, "{s} in {s}", .{ c.name, c.zone.name });
        const done = if (c.copy.id) |id|
            bridge_write.setScene(gpa, io, bridge.credentials, id, c.copy.body.?, &reply)
        else
            bridge_write.createScene(gpa, io, bridge.credentials, c.copy.body.?, &reply);
        if (done) {
            try out.print("  {s}: the Bridge accepted it\n", .{label});
            accepted += 1;
        } else |err| {
            try power_on_cmd.refusedLine(out, label, err, &reply);
            failed += 1;
        }
        try out.flush();
        try io.sleep(PAUSE, .awake);
    }
    // Read again, for the new scenes' ids.
    const now = if (p.copies.len > 0) try readWith(arena, gpa, io, bridge.credentials, out) else bridge;
    for (p.changes) |c| {
        const s = sensorFor(now, c.target.dev) orelse continue;
        const w = try want(arena, now, c.target);
        if (w.pending) {
            try out.print("  {s}: not written, a scene it needs isn't on the Bridge\n", .{c.target.name});
            failed += 1;
            continue;
        }
        const body = bridge_sensors.body(arena, s, w.want) catch |err| {
            try out.print("  {s}: not written ({t})\n", .{ c.target.name, err });
            failed += 1;
            continue;
        };
        // No backup, no write: this setup may exist nowhere else.
        const saved = saveOld(arena, io, app, s) catch |err| {
            try out.print("  {s}: not written, couldn't save its old setup ({t})\n", .{ c.target.name, err });
            failed += 1;
            continue;
        };
        var reply: bridge_write.Reply = .{};
        if (bridge_write.setBehaviour(gpa, io, bridge.credentials, s.instance, body, &reply)) {
            try out.print("  {s}: the Bridge accepted it. Old setup in {s}\n", .{ c.target.name, saved });
            accepted += 1;
        } else |err| {
            try power_on_cmd.refusedLine(out, c.target.name, err, &reply);
            failed += 1;
        }
        try out.flush();
        try io.sleep(PAUSE, .awake);
    }
    // What the Bridge now holds, rather than what it said it would do.
    const after = try readWith(arena, gpa, io, bridge.credentials, out);
    const again = try makePlan(arena, after, wanted, only);
    try out.print("{d} accepted, {d} failed. Read back from the Bridge: {d} still to write.\n", .{ accepted, failed, again.writes() });
    if (failed > 0 or again.writes() > 0) return error.SomeWritesFailed;
}

fn restore(gpa: Allocator, arena: Allocator, io: Io, app: *const config.Config, args: []const []const u8, out: *Io.Writer) !void {
    const confirm = args.len == 2 and std.mem.eql(u8, args[1], "confirm");
    if (args.len != 1 and !confirm) {
        try out.writeAll(usage);
        return error.BadUsage;
    }
    const text = Io.Dir.cwd().readFileAlloc(io, args[0], arena, .limited(MAX_FILE)) catch |err| {
        try out.print("dmain: cannot read {s} ({t})\n", .{ args[0], err });
        return err;
    };
    const saved = std.json.parseFromSliceLeaky(Saved, arena, text, .{ .allocate = .alloc_always }) catch |err| {
        try out.print("dmain: {s} isn't a saved sensor setup ({t})\n", .{ args[0], err });
        return err;
    };
    if (!confirm) {
        try out.print("{s} is the setup of {s}. Nothing written. Add `confirm` to put it back.\n", .{ args[0], saved.name });
        return;
    }
    const bridge = try readBridge(arena, gpa, io, app, out);
    const known = for (bridge.sensors) |s| {
        if (std.mem.eql(u8, s.instance, saved.id)) break true;
    } else false;
    if (!known) {
        try out.print("dmain: the Bridge has no such sensor now: {s}\n", .{saved.name});
        return error.UnknownSensor;
    }
    var body: Io.Writer.Allocating = .init(arena);
    try body.writer.writeAll("{\"configuration\":");
    try std.json.Stringify.value(saved.configuration, .{}, &body.writer);
    try body.writer.writeByte('}');
    var reply: bridge_write.Reply = .{};
    bridge_write.setBehaviour(gpa, io, bridge.credentials, saved.id, body.written(), &reply) catch |err| {
        try power_on_cmd.refusedLine(out, saved.name, err, &reply);
        return err;
    };
    try out.print("  {s}: the Bridge accepted it. `dmain sensors check` shows it as it now differs from the file.\n", .{saved.name});
}
