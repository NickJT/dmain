//! `dmain switches`: each wall dimmer as `rooms.json` says, on the room it controls,
//! top the room's default or off, the middle two dimming, bottom Max. Bare `apply`
//! only shows what would change, and every write saves the switch's whole old
//! configuration first, because a setup like scenes by time of day can't be said in
//! the file. A group's Max scene is made or corrected before any dimmer recalls it.
//!
//! This reads the Bridge directly where the other programs read `huelog`'s files. A
//! change to a configuration has to start from what the switch holds at that moment.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const bridge_write = @import("bridge_write");
const bridge_switches = @import("bridge_switches");
const config = @import("config.zig");
const power_on_cmd = @import("power_on_cmd.zig");

const layout = @import("switch_layout.zig");
const rf = @import("rooms_file.zig");
const MAX_FILE = 1 << 20;
/// A switch's write is one TLS connection and a write to the Bridge's flash, with
/// nothing in a hurry.
const PAUSE = Io.Duration.fromMilliseconds(1000);

pub const usage =
    \\  dmain switches check                show what the dimmers would change to match rooms.json
    \\  dmain switches apply                the same
    \\  dmain switches apply confirm        write Max scenes and the dimmers, saving each old setup first
    \\  ... check|apply [confirm] -        the same, with rooms.json on stdin
    \\  dmain switches restore FILE         show which switch a saved setup belongs to
    \\  dmain switches restore FILE confirm put a saved setup back
    \\
;

const Bridge = struct {
    credentials: bridge_write.Credentials,
    resources: []const u8,
    found: bridge_switches.Found,
    buttons: []const bridge_switches.ButtonIds,
    current: []const layout.Current,
    groups: []const layout.Group,
    light_devs: []const []const u8,
};

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

fn ids(arena: Allocator, where: []const bridge_switches.Group) ![]const []const u8 {
    const out = try arena.alloc([]const u8, where.len);
    for (where, out) |g, *id| id.* = g.id;
    return out;
}

fn readWith(arena: Allocator, gpa: Allocator, io: Io, credentials: bridge_write.Credentials, out: *Io.Writer) !Bridge {
    const owned = bridge_write.resources(gpa, io, credentials) catch |err| {
        try out.print("dmain: cannot read the Bridge ({t})\n", .{err});
        return err;
    };
    defer gpa.free(owned);
    const resources = try arena.dupe(u8, owned);
    const found = try bridge_switches.parse(arena, resources);
    const current = try arena.alloc(layout.Current, found.switches.len);
    for (found.switches, current) |sw, *c| {
        c.* = .{
            .dev = sw.dev,
            .name = sw.name,
            .group = sw.group,
            // Off on the next tap at the top, and staying on at the bottom, are part
            // of the layout, so a scene without that isn't this layout's yet.
            .top = if (sw.top.with_off) sw.top.scene else null,
            .bottom = if (sw.bottom.with_off) null else sw.bottom.scene,
            .dim_tap_or_hold = sw.dim_tap_or_hold,
            .top_text = if (sw.top.scene != null and !sw.top.with_off)
                try std.fmt.allocPrint(arena, "{s}, no off", .{sw.top.text})
            else
                sw.top.text,
            .bottom_text = if (sw.bottom.scene != null and sw.bottom.with_off)
                try std.fmt.allocPrint(arena, "{s}, then off", .{sw.bottom.text})
            else
                sw.bottom.text,
            .dim_text = sw.dim_text,
            .top_where = try ids(arena, sw.top_where),
            .dim_where = try ids(arena, sw.dim_where),
            .bottom_where = try ids(arena, sw.bottom_where),
        };
    }
    const g = try bridge_switches.groups(arena, resources);
    const groups = try arena.alloc(layout.Group, g.groups.len);
    for (g.groups, groups) |x, *y| y.* = .{ .id = x.group.id, .name = x.group.name, .rtype = x.group.rtype, .devs = x.devs };
    return .{
        .credentials = credentials,
        .resources = resources,
        .found = found,
        .buttons = try bridge_switches.buttonIds(arena, resources, found),
        .current = current,
        .groups = groups,
        .light_devs = g.light_devs,
    };
}

fn hueGroup(g: layout.Group) bridge_switches.Group {
    return .{ .id = g.id, .name = g.name, .rtype = g.rtype };
}

/// A group's Max scene that needs writing.
const MaxWrite = struct { group: layout.Group, scene: bridge_switches.MaxScene };

const Plan = struct {
    targets: layout.Targets,
    report: layout.Report,
    max: []const MaxWrite,

    fn writes(self: Plan) usize {
        return self.report.changes.len + self.max.len;
    }
};

fn makePlan(arena: Allocator, bridge: Bridge, wanted: rf.Wanted) !Plan {
    const t = try layout.targets(arena, wanted, bridge.groups, bridge.light_devs);
    const report = try layout.compare(arena, bridge.current, t.targets);
    // Once a group, for every dimmer whose bottom is Max there.
    var max: std.ArrayList(MaxWrite) = .empty;
    for (t.targets, 0..) |target, i| {
        if (target.bottom == null) continue;
        const seen = for (t.targets[0..i]) |e| {
            if (e.bottom != null and std.mem.eql(u8, e.group.id, target.group.id)) break true;
        } else false;
        if (seen) continue;
        const scene = try bridge_switches.maxScene(arena, bridge.resources, hueGroup(target.group));
        if (scene.body != null) try max.append(arena, .{ .group = target.group, .scene = scene });
    }
    return .{ .targets = t, .report = report, .max = max.items };
}

/// `given` is `rooms.json`'s text when it came from elsewhere, such as the Mac's
/// copy through `dmain agent`.
pub fn run(gpa: Allocator, arena: Allocator, io: Io, app: *const config.Config, args: []const []const u8, given: ?[]const u8, out: *Io.Writer) !void {
    const sub = if (args.len > 0) args[0] else "";
    if (std.mem.eql(u8, sub, "restore")) return restore(gpa, arena, io, app, args[1..], out);

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
    const refused = try printReport(p, bridge, out);
    if (!apply or p.writes() == 0) return;
    if (refused > 0) {
        try out.print("Nothing written: {d} problem(s) above need fixing first.\n", .{refused});
        return error.BadScene;
    }
    if (!confirm) {
        try out.writeAll("Nothing written. `dmain switches apply confirm` writes these to the Bridge.\n");
        return;
    }
    try applyAll(gpa, arena, io, app, p, bridge, wanted, out);
}

fn switchFor(bridge: Bridge, dev: []const u8) ?bridge_switches.Switch {
    for (bridge.found.switches) |sw| {
        if (std.mem.eql(u8, sw.dev, dev)) return sw;
    }
    return null;
}

fn names(arena: Allocator, where: []const bridge_switches.Group) ![]const u8 {
    if (where.len == 0) return "nothing";
    var aw: Io.Writer.Allocating = .init(arena);
    for (where, 0..) |g, i| {
        if (i > 0) try aw.writer.writeAll(" and ");
        try aw.writer.writeAll(g.name);
    }
    return aw.written();
}

fn printReport(p: Plan, bridge: Bridge, out: *Io.Writer) !usize {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try out.print("{d} dimmers, {d} would change, and {d} Max scenes to write.\n", .{ bridge.current.len, p.report.changes.len, p.max.len });
    var refused: usize = 0;
    for (p.targets.refusals) |r| {
        try out.print("  can't: {s}: {s}\n", .{ r.name, r.why });
        refused += 1;
    }
    for (p.max) |m| try out.print("  Max in {s}: {s}, {d} lights at full, 4000 K\n", .{ m.group.name, if (m.scene.id == null) "make it" else "correct it", m.scene.lights });
    for (p.report.changes) |c| {
        // The file's name: the Bridge's is its automation's, "Hue dimmer switch 20".
        try out.print("  {s} (now on {s}):\n", .{ c.target.name, c.current.group });
        const sw = switchFor(bridge, c.current.dev).?;
        if (c.where) try out.print("    every button: {s} -> {s}\n", .{ try names(arena, sw.top_where), c.target.group.name });
        for ([_]struct { label: []const u8, name: ?[]const u8, now: []const u8 }{
            .{ .label = "top", .name = c.top, .now = c.current.top_text },
            .{ .label = "bottom", .name = c.bottom, .now = c.current.bottom_text },
        }) |slot| {
            const name = slot.name orelse continue;
            const made = std.mem.eql(u8, name, layout.MAX);
            if (!made) if (bridge_switches.findScene(bridge.found, c.target.group.id, name)) |_| {} else |err| {
                try out.print("    {s}: {s} -> {s} REFUSED: {s}\n", .{ slot.label, slot.now, name, switch (err) {
                    error.AmbiguousScene => try std.fmt.allocPrint(arena, "two scenes of that name in {s}", .{c.target.group.name}),
                    else => try std.fmt.allocPrint(arena, "no such scene in {s}", .{c.target.group.name}),
                } });
                refused += 1;
                continue;
            };
            try out.print("    {s}: {s} -> {s}\n", .{ slot.label, slot.now, name });
        }
        if (c.dim_tap_or_hold) try out.print("    dim: {s} -> tap or hold\n", .{c.current.dim_text});
    }
    for (p.report.unknown) |t| try out.print("  not a Bridge dimmer, left alone: {s}\n", .{t.name});
    for (p.report.unlisted) |c| try out.print("  on the Bridge but controlling nothing in rooms.json, left alone: {s} ({s})\n", .{ c.name, c.dev });
    return refused;
}

fn saveOld(arena: Allocator, io: Io, app: *const config.Config, sw: bridge_switches.Switch) ![]const u8 {
    try Io.Dir.cwd().createDirPath(io, app.backups);
    const dev = try arena.dupe(u8, sw.dev);
    std.mem.replaceScalar(u8, dev, ':', '-');
    const path = try std.fmt.allocPrint(arena, "{s}/switch-{s}-{d}.json", .{ app.backups, dev, Io.Timestamp.now(io, .real).toSeconds() });
    const text = try std.json.Stringify.valueAlloc(arena, Saved{ .id = sw.instance, .name = sw.name, .configuration = sw.configuration }, .{ .whitespace = .indent_1 });
    var file = try Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll(text);
    try w.interface.flush();
    return path;
}

const Saved = struct {
    id: []const u8,
    name: []const u8,
    configuration: std.json.Value,
};

fn applyAll(gpa: Allocator, arena: Allocator, io: Io, app: *const config.Config, p: Plan, bridge: Bridge, wanted: rf.Wanted, out: *Io.Writer) !void {
    var accepted: usize = 0;
    var failed: usize = 0;
    // The scenes first: a dimmer can only recall one that's there.
    for (p.max) |m| {
        var reply: bridge_write.Reply = .{};
        const label = try std.fmt.allocPrint(arena, "Max in {s}", .{m.group.name});
        const done = if (m.scene.id) |id|
            bridge_write.setScene(gpa, io, bridge.credentials, id, m.scene.body.?, &reply)
        else
            bridge_write.createScene(gpa, io, bridge.credentials, m.scene.body.?, &reply);
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
    const now = if (p.max.len > 0) try readWith(arena, gpa, io, bridge.credentials, out) else bridge;
    for (p.report.changes) |c| {
        const sw = switchFor(now, c.current.dev) orelse continue;
        const body = bridge_switches.layoutBody(arena, now.found, sw, now.buttons, .{
            .top = c.top,
            .bottom = c.bottom,
            .dim_tap_or_hold = c.dim_tap_or_hold,
            .where = if (c.where) hueGroup(c.target.group) else null,
        }) catch |err| {
            try out.print("  {s}: not written ({t})\n", .{ c.target.name, err });
            failed += 1;
            continue;
        };
        // No backup, no write: this setup may exist nowhere else.
        const saved = saveOld(arena, io, app, sw) catch |err| {
            try out.print("  {s}: not written, couldn't save its old setup ({t})\n", .{ c.target.name, err });
            failed += 1;
            continue;
        };
        var reply: bridge_write.Reply = .{};
        if (bridge_write.setBehaviour(gpa, io, bridge.credentials, sw.instance, body, &reply)) {
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
    const again = try makePlan(arena, after, wanted);
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
        try out.print("dmain: {s} isn't a saved switch setup ({t})\n", .{ args[0], err });
        return err;
    };
    if (!confirm) {
        try out.print("{s} is the setup of {s}. Nothing written. Add `confirm` to put it back.\n", .{ args[0], saved.name });
        return;
    }
    const bridge = try readBridge(arena, gpa, io, app, out);
    var known = false;
    for (bridge.found.switches) |sw| {
        if (std.mem.eql(u8, sw.instance, saved.id)) known = true;
    }
    if (!known) {
        try out.print("dmain: the Bridge has no such switch now: {s}\n", .{saved.name});
        return error.UnknownSwitch;
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
    try out.print("  {s}: the Bridge accepted it. `dmain switches check` shows it as it now differs from the file.\n", .{saved.name});
}
