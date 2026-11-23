//! `dmain actions`: the controls that run `rooms.json`'s actions, the Dial today, each
//! button its action and the ring raising its room's default lights. Bare `apply` only
//! shows what would change, and every write saves the control's whole old
//! configuration first. A zone's copies of a room's scenes are made or corrected before
//! a press recalls them.
//!
//! This reads the Bridge directly, as `switches` does.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const sensor_layout = @import("sensor_layout.zig");
const bridge_write = @import("bridge_write");
const bridge_switches = @import("bridge_switches");
const bridge_sensors = @import("bridge_sensors");
const bridge_dial = @import("bridge_dial");
const config = @import("config.zig");
const power_on_cmd = @import("power_on_cmd.zig");

const layout = @import("action_layout.zig");
const rf = @import("rooms_file.zig");
const MAX_FILE = 1 << 20;
/// Each write is one TLS connection and a write to the Bridge's flash.
const PAUSE = Io.Duration.fromMilliseconds(1000);

pub const usage =
    \\  dmain actions check                 show what the Dial would change to match rooms.json's actions
    \\  dmain actions apply                 the same
    \\  dmain actions apply confirm         write zone scenes and the Dial, saving its old setup first
    \\  ... check|apply [confirm] -        the same, with rooms.json on stdin
    \\
;

const Bridge = struct {
    credentials: bridge_write.Credentials,
    resources: []const u8,
    dials: []const bridge_dial.Dial,
    groups: []const layout.Group,
    scenes: []const layout.Scene,
    home: ?layout.Group,
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
    const home: ?layout.Group = if (try bridge_dial.homeId(arena, resources)) |id| .{ .id = id, .name = "the whole house", .rtype = layout.HOME_RTYPE, .devs = &.{} } else null;
    return .{ .credentials = credentials, .resources = resources, .dials = try bridge_dial.parse(arena, resources), .groups = groups, .scenes = scenes, .home = home };
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

const CopyWrite = struct { zone: layout.Group, name: []const u8, copy: bridge_sensors.Copy };

const Change = struct { target: layout.Target, dial: bridge_dial.Dial };

const Plan = struct {
    targets: layout.Targets,
    copies: []const CopyWrite,
    changes: []const Change,
    missing: []const layout.Target,

    fn writes(self: Plan) usize {
        return self.copies.len + self.changes.len;
    }
};

fn dialFor(bridge: Bridge, dev: []const u8) ?bridge_dial.Dial {
    for (bridge.dials) |d| if (std.mem.eql(u8, d.dev, dev)) return d;
    return null;
}

fn sceneId(bridge: Bridge, group: layout.Group, s: layout.SceneRef) ?[]const u8 {
    if (!s.copied) return s.from;
    const found = sensor_layout.sceneIn(bridge.scenes, group.id, s.name) catch return null;
    return found.id;
}

fn ref(g: layout.Group) bridge_dial.GroupRef {
    return .{ .id = g.id, .rtype = g.rtype };
}

/// The Dial as wanted, by scene id; null when a copy it needs isn't made yet.
fn want(arena: Allocator, bridge: Bridge, t: layout.Target) !?bridge_dial.Want {
    var w: bridge_dial.Want = .{ .presses = @splat(null), .ring = null };
    for (t.presses, &w.presses) |p, *slot| {
        const press = p orelse continue;
        const where = try arena.alloc(bridge_dial.GroupRef, press.entries.len);
        for (press.entries, where) |e, *g| g.* = ref(e.group);
        if (press.off) {
            slot.* = .{ .where = where, .scenes = &.{} };
            continue;
        }
        const scenes = try arena.alloc([]const u8, press.entries.len);
        for (press.entries, scenes) |e, *s| s.* = sceneId(bridge, e.group, e.scene.?) orelse return null;
        slot.* = .{ .where = where, .scenes = scenes };
    }
    if (t.ring) |r| w.ring = .{ .group = ref(r.group), .scene = sceneId(bridge, r.group, r.scene) orelse return null };
    return w;
}

fn addCopy(arena: Allocator, list: *std.ArrayList(CopyWrite), bridge: Bridge, group: layout.Group, s: layout.SceneRef) !void {
    if (!s.copied) return;
    for (list.items) |c| if (std.mem.eql(u8, c.zone.id, group.id) and std.mem.eql(u8, c.name, s.name)) return;
    const copy = try bridge_sensors.copyScene(arena, bridge.resources, s.from, group.id, s.name);
    if (copy.body != null) try list.append(arena, .{ .zone = group, .name = s.name, .copy = copy });
}

fn makePlan(arena: Allocator, bridge: Bridge, wanted: rf.Wanted) !Plan {
    const t = try layout.targets(arena, wanted, bridge.groups, bridge.scenes, bridge.home);
    var copies: std.ArrayList(CopyWrite) = .empty;
    var changes: std.ArrayList(Change) = .empty;
    var missing: std.ArrayList(layout.Target) = .empty;
    for (t.targets) |target| {
        for (target.presses) |p| if (p) |press| for (press.entries) |e| if (e.scene) |s| try addCopy(arena, &copies, bridge, e.group, s);
        if (target.ring) |r| try addCopy(arena, &copies, bridge, r.group, r.scene);
        const dial = dialFor(bridge, target.dev) orelse {
            try missing.append(arena, target);
            continue;
        };
        const w = try want(arena, bridge, target);
        if (w == null or !bridge_dial.matches(dial, w.?)) try changes.append(arena, .{ .target = target, .dial = dial });
    }
    return .{ .targets = t, .copies = copies.items, .changes = changes.items, .missing = missing.items };
}

pub fn run(gpa: Allocator, arena: Allocator, io: Io, app: *const config.Config, args: []const []const u8, given: ?[]const u8, out: *Io.Writer) !void {
    const sub = if (args.len > 0) args[0] else "";
    const check = std.mem.eql(u8, sub, "check");
    const apply = std.mem.eql(u8, sub, "apply");
    const confirm = args.len == 2 and std.mem.eql(u8, args[1], "confirm");
    if (!(check or apply) or (args.len != 1 and !(apply and confirm))) {
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
    const p = try makePlan(arena, bridge, wanted);
    const refused = try printReport(arena, p, bridge, out);
    if (!apply or p.writes() == 0) return;
    if (refused > 0) {
        try out.print("Nothing written: {d} problem(s) above need fixing first.\n", .{refused});
        return error.BadAction;
    }
    if (!confirm) {
        try out.writeAll("Nothing written. `dmain actions apply confirm` writes these to the Bridge.\n");
        return;
    }
    try applyAll(gpa, arena, io, app, p, bridge, wanted, out);
}

fn groupName(bridge: Bridge, id: []const u8) []const u8 {
    for (bridge.groups) |g| if (std.mem.eql(u8, g.id, id)) return g.name;
    if (bridge.home) |h| if (std.mem.eql(u8, h.id, id)) return h.name;
    return id;
}

fn sceneName(bridge: Bridge, id: []const u8) []const u8 {
    for (bridge.scenes) |s| if (std.mem.eql(u8, s.id, id)) return s.name;
    return "a scene that's gone";
}

fn pressText(arena: Allocator, bridge: Bridge, p: ?bridge_dial.Press) ![]const u8 {
    const press = p orelse return "something else";
    var aw: Io.Writer.Allocating = .init(arena);
    for (press.where, 0..) |g, i| {
        if (i > 0) try aw.writer.writeAll(" and ");
        if (press.scenes.len == 0) try aw.writer.print("{s} off", .{groupName(bridge, g.id)}) else try aw.writer.print("{s} {s}", .{ groupName(bridge, g.id), sceneName(bridge, press.scenes[i]) });
    }
    return aw.written();
}

fn wantText(arena: Allocator, p: layout.Press) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    try aw.writer.print("{s}: ", .{p.action});
    for (p.entries, 0..) |e, i| {
        if (i > 0) try aw.writer.writeAll(" and ");
        if (e.scene) |s| try aw.writer.print("{s} {s}", .{ e.group.name, s.name }) else try aw.writer.print("{s} off", .{e.group.name});
    }
    return aw.written();
}

fn printReport(arena: Allocator, p: Plan, bridge: Bridge, out: *Io.Writer) !usize {
    try out.print("{d} controls run actions, {d} would change, and {d} zone scenes to write.\n", .{ p.targets.targets.len + p.targets.refusals.len, p.changes.len, p.copies.len });
    var refused: usize = 0;
    for (p.targets.refusals) |r| {
        try out.print("  can't: {s}: {s}\n", .{ r.name, r.why });
        refused += 1;
    }
    for (p.copies) |c| try out.print("  {s} in the zone {s}: {s}, {d} lights from the room's {s}\n", .{ c.name, c.zone.name, if (c.copy.id == null) "make it" else "correct it", c.copy.lights, c.name });
    for (p.changes) |c| {
        try out.print("  {s}:\n", .{c.target.name});
        const w = try want(arena, bridge, c.target);
        for (c.target.presses, 0..) |tp, i| {
            const press = tp orelse continue;
            const same = if (w) |x| (if (c.dial.presses[i]) |h| h.eql(x.presses[i].?) else false) else false;
            if (same) continue;
            try out.print("    button {d}: {s} -> {s}\n", .{ i + 1, try pressText(arena, bridge, c.dial.presses[i]), try wantText(arena, press) });
        }
        if (c.target.ring) |r| {
            const same = if (w) |x| (if (c.dial.ring) |h| h.eql(x.ring.?) else false) else false;
            if (!same) {
                const now = if (c.dial.ring) |h| try std.fmt.allocPrint(arena, "{s} {s}", .{ groupName(bridge, h.group.id), sceneName(bridge, h.scene) }) else "something else";
                try out.print("    ring brings up: {s} -> {s} {s}\n", .{ now, r.group.name, r.scene.name });
            }
        }
    }
    for (p.missing) |t| try out.print("  not a Bridge tap dial, left alone: {s}\n", .{t.name});
    return refused;
}

const Saved = struct {
    id: []const u8,
    name: []const u8,
    configuration: std.json.Value,
};

fn saveOld(arena: Allocator, io: Io, app: *const config.Config, d: bridge_dial.Dial) ![]const u8 {
    try Io.Dir.cwd().createDirPath(io, app.backups);
    const dev = try arena.dupe(u8, d.dev);
    std.mem.replaceScalar(u8, dev, ':', '-');
    const path = try std.fmt.allocPrint(arena, "{s}/dial-{s}-{d}.json", .{ app.backups, dev, Io.Timestamp.now(io, .real).toSeconds() });
    const text = try std.json.Stringify.valueAlloc(arena, Saved{ .id = d.instance, .name = d.name, .configuration = d.configuration }, .{ .whitespace = .indent_1 });
    var file = try Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll(text);
    try w.interface.flush();
    return path;
}

fn applyAll(gpa: Allocator, arena: Allocator, io: Io, app: *const config.Config, p: Plan, bridge: Bridge, wanted: rf.Wanted, out: *Io.Writer) !void {
    var accepted: usize = 0;
    var failed: usize = 0;
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
    const now = if (p.copies.len > 0) try readWith(arena, gpa, io, bridge.credentials, out) else bridge;
    for (p.changes) |c| {
        const dial = dialFor(now, c.target.dev) orelse continue;
        const w = (try want(arena, now, c.target)) orelse {
            try out.print("  {s}: not written, a scene it needs isn't on the Bridge\n", .{c.target.name});
            failed += 1;
            continue;
        };
        const body = bridge_dial.body(arena, dial, w) catch |err| {
            try out.print("  {s}: not written ({t})\n", .{ c.target.name, err });
            failed += 1;
            continue;
        };
        // No backup, no write: this setup may exist nowhere else.
        const saved = saveOld(arena, io, app, dial) catch |err| {
            try out.print("  {s}: not written, couldn't save its old setup ({t})\n", .{ c.target.name, err });
            failed += 1;
            continue;
        };
        var reply: bridge_write.Reply = .{};
        if (bridge_write.setBehaviour(gpa, io, bridge.credentials, dial.instance, body, &reply)) {
            try out.print("  {s}: the Bridge accepted it. Old setup in {s}\n", .{ c.target.name, saved });
            accepted += 1;
        } else |err| {
            try power_on_cmd.refusedLine(out, c.target.name, err, &reply);
            failed += 1;
        }
        try out.flush();
        try io.sleep(PAUSE, .awake);
    }
    const after = try readWith(arena, gpa, io, bridge.credentials, out);
    const again = try makePlan(arena, after, wanted);
    try out.print("{d} accepted, {d} failed. Read back from the Bridge: {d} still to write.\n", .{ accepted, failed, again.writes() });
    if (failed > 0 or again.writes() > 0) return error.SomeWritesFailed;
}
