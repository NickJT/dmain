//! `dmain schedules`: each load's ons and offs as `rooms.json` says, as the Bridge's
//! `Schedule` automations. Compared by the moments they switch, so an on with an end
//! and an on and an off apart are the same, and a Bridge already doing what the file
//! says is never rewritten. A load whose moments differ has its automations replaced
//! as a set: the new ones made first, then each old one saved and deleted. Bare `apply`
//! only shows what would change.
//!
//! This reads the Bridge directly, as `switches` does.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const bridge_write = @import("bridge_write");
const bridge_switches = @import("bridge_switches");
const bridge_sensors = @import("bridge_sensors");
const bridge_schedules = @import("bridge_schedules");
const config = @import("config.zig");
const power_on_cmd = @import("power_on_cmd.zig");

const layout = @import("schedule_layout.zig");
const rf = @import("rooms_file.zig");
const MAX_FILE = 1 << 20;
/// Each write is one TLS connection and a write to the Bridge's flash.
const PAUSE = Io.Duration.fromMilliseconds(1000);

pub const usage =
    \\  dmain schedules check               show what the Bridge's timed automations would change to match rooms.json
    \\  dmain schedules apply               the same
    \\  dmain schedules apply confirm       make and delete them, saving each old one first
    \\  ... check|apply [confirm] -        the same, with rooms.json on stdin
    \\
;

const Bridge = struct {
    credentials: bridge_write.Credentials,
    found: bridge_schedules.Found,
    groups: []const layout.Group,
    scenes: []const layout.Scene,
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
    return .{ .credentials = credentials, .found = try bridge_schedules.parse(arena, resources), .groups = groups, .scenes = scenes };
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

/// A load whose automations differ: what to make, and what it replaces.
const Change = struct {
    target: layout.Target,
    make: []const bridge_schedules.Entry,
    old: []const bridge_schedules.Schedule,
};

const Plan = struct {
    targets: layout.Targets,
    changes: []const Change,
    /// Automations on groups no load's schedule uses, or turned off: left alone.
    others: []const bridge_schedules.Schedule,

    fn writes(self: Plan) usize {
        var n: usize = 0;
        for (self.changes) |c| n += c.make.len + c.old.len;
        return n;
    }
};

fn fmtTime(buf: []u8, t: layout.Time) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ t.hour, t.minute }) catch unreachable;
}

fn entries(arena: Allocator, t: layout.Target) ![]const bridge_schedules.Entry {
    const out = try arena.alloc(bridge_schedules.Entry, t.entries.len);
    for (t.entries, out) |e, *x| {
        var a: [5]u8 = undefined;
        var b: [5]u8 = undefined;
        const name = if (e.end) |end|
            try std.fmt.allocPrint(arena, "{s} {s}-{s}", .{ t.name, fmtTime(&a, e.start), fmtTime(&b, end) })
        else
            try std.fmt.allocPrint(arena, "{s} {s} {s}", .{ t.name, if (e.on) "on" else "off", fmtTime(&a, e.start) });
        x.* = .{
            .name = name,
            .group_id = t.group.id,
            .group_rtype = t.group.rtype,
            .on = if (e.on) t.on_scene else null,
            .start = .{ .hour = e.start.hour, .minute = e.start.minute },
            .end = if (e.end) |end| .{ .hour = end.hour, .minute = end.minute } else null,
            .days = e.days,
        };
    }
    return out;
}

fn makePlan(arena: Allocator, bridge: Bridge, wanted: rf.Wanted) !Plan {
    const t = try layout.targets(arena, wanted, bridge.groups, bridge.scenes);
    var changes: std.ArrayList(Change) = .empty;
    for (t.targets) |target| {
        var old: std.ArrayList(bridge_schedules.Schedule) = .empty;
        var have: std.ArrayList(bridge_schedules.Point) = .empty;
        var unreadable = false;
        for (bridge.found.schedules) |s| {
            if (!s.enabled) continue;
            const g = s.group_id orelse continue;
            if (!std.mem.eql(u8, g, target.group.id)) continue;
            try old.append(arena, s);
            if (s.points) |p| try have.appendSlice(arena, p) else unreadable = true;
        }
        const make = try entries(arena, target);
        var want: std.ArrayList(bridge_schedules.Point) = .empty;
        for (make) |e| try want.appendSlice(arena, try bridge_schedules.pointsOfEntry(arena, e));
        if (unreadable or !try bridge_schedules.samePoints(arena, have.items, want.items))
            try changes.append(arena, .{ .target = target, .make = make, .old = old.items });
    }
    var others: std.ArrayList(bridge_schedules.Schedule) = .empty;
    for (bridge.found.schedules) |s| {
        const ours = s.enabled and s.group_id != null and for (t.targets) |x| {
            if (std.mem.eql(u8, x.group.id, s.group_id.?)) break true;
        } else false;
        if (!ours) try others.append(arena, s);
    }
    return .{ .targets = t, .changes = changes.items, .others = others.items };
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
    if (bridge.found.script_id == null) {
        try out.writeAll("dmain: the Bridge lists no Schedule script\n");
        return error.NoScript;
    }
    const p = try makePlan(arena, bridge, wanted);
    const refused = try printReport(arena, p, bridge, out);
    if (!apply or p.writes() == 0) return;
    if (refused > 0) {
        try out.print("Nothing written: {d} problem(s) above need fixing first.\n", .{refused});
        return error.BadSchedule;
    }
    if (!confirm) {
        try out.writeAll("Nothing written. `dmain schedules apply confirm` writes these to the Bridge.\n");
        return;
    }
    try applyAll(gpa, arena, io, app, p, bridge, wanted, out);
}

fn dayText(arena: Allocator, days: u7) ![]const u8 {
    if (days == bridge_schedules.EVERY_DAY) return "every day";
    var aw: Io.Writer.Allocating = .init(arena);
    var first = true;
    for (bridge_schedules.DAYS, 0..) |d, i| if (days & (@as(u7, 1) << @intCast(i)) != 0) {
        if (!first) try aw.writer.writeAll(", ");
        try aw.writer.writeAll(d[0..3]);
        first = false;
    };
    return aw.written();
}

fn printReport(arena: Allocator, p: Plan, bridge: Bridge, out: *Io.Writer) !usize {
    var loads: usize = 0;
    for (p.targets.targets) |_| loads += 1;
    try out.print("{d} loads scheduled, {d} would change: {d} automations to make, {d} to delete.\n", .{ loads, p.changes.len, blk: {
        var n: usize = 0;
        for (p.changes) |c| n += c.make.len;
        break :blk n;
    }, blk: {
        var n: usize = 0;
        for (p.changes) |c| n += c.old.len;
        break :blk n;
    } });
    var refused: usize = 0;
    for (p.targets.refusals) |r| {
        try out.print("  can't: {s}: {s}\n", .{ r.name, r.why });
        refused += 1;
    }
    for (p.changes) |c| {
        try out.print("  {s} (in {s}):\n", .{ c.target.name, c.target.group.name });
        for (c.old) |s| try out.print("    delete: {s}{s}\n", .{ s.name, if (s.points == null) ", in a form this can't read" else "" });
        for (c.make) |e| try out.print("    make:   {s}, {s}\n", .{ e.name, try dayText(arena, e.days) });
    }
    _ = bridge;
    for (p.others) |s| try out.print("  left alone: {s}{s}\n", .{ s.name, if (!s.enabled) " (turned off)" else "" });
    return refused;
}

const Saved = struct {
    id: []const u8,
    name: []const u8,
    configuration: std.json.Value,
};

fn saveOld(arena: Allocator, io: Io, app: *const config.Config, s: bridge_schedules.Schedule) ![]const u8 {
    try Io.Dir.cwd().createDirPath(io, app.backups);
    const path = try std.fmt.allocPrint(arena, "{s}/schedule-{s}-{d}.json", .{ app.backups, s.instance, Io.Timestamp.now(io, .real).toSeconds() });
    const text = try std.json.Stringify.valueAlloc(arena, Saved{ .id = s.instance, .name = s.name, .configuration = s.configuration }, .{ .whitespace = .indent_1 });
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
    for (p.changes) |c| {
        // The new ones first, so a failure never leaves a load with nothing.
        var made_all = true;
        for (c.make) |e| {
            var reply: bridge_write.Reply = .{};
            const body = try bridge_schedules.createBody(arena, bridge.found.script_id.?, e);
            if (bridge_write.createBehaviour(gpa, io, bridge.credentials, body, &reply)) {
                try out.print("  made: {s}\n", .{e.name});
                accepted += 1;
            } else |err| {
                try power_on_cmd.refusedLine(out, e.name, err, &reply);
                failed += 1;
                made_all = false;
            }
            try out.flush();
            try io.sleep(PAUSE, .awake);
        }
        if (!made_all) {
            try out.print("  {s}: its old automations kept, as not all the new ones were made\n", .{c.target.name});
            continue;
        }
        for (c.old) |s| {
            // No backup, no delete: this setup may exist nowhere else.
            const saved = saveOld(arena, io, app, s) catch |err| {
                try out.print("  {s}: not deleted, couldn't save it ({t})\n", .{ s.name, err });
                failed += 1;
                continue;
            };
            var reply: bridge_write.Reply = .{};
            if (bridge_write.deleteBehaviour(gpa, io, bridge.credentials, s.instance, &reply)) {
                try out.print("  deleted: {s}. Saved in {s}\n", .{ s.name, saved });
                accepted += 1;
            } else |err| {
                try power_on_cmd.refusedLine(out, s.name, err, &reply);
                failed += 1;
            }
            try out.flush();
            try io.sleep(PAUSE, .awake);
        }
    }
    // What the Bridge now holds, rather than what it said it would do.
    const after = try readWith(arena, gpa, io, bridge.credentials, out);
    const again = try makePlan(arena, after, wanted);
    try out.print("{d} accepted, {d} failed. Read back from the Bridge: {d} still to write.\n", .{ accepted, failed, again.writes() });
    if (failed > 0 or again.writes() > 0) return error.SomeWritesFailed;
}
