//! `dmain rooms check | apply [confirm]`: `rooms.json`'s names and rooms to the
//! Bridge. Bare `apply` only shows what would change. hub's half is its own
//! `devices.json`, which the Mac rewrites, so nothing here touches hub.
//!
//! This reads the Bridge directly: a room's children are replaced whole, so a
//! move has to start from what the room holds at that moment.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const bridge_write = @import("bridge_write");
const config = @import("config.zig");
const power_on_cmd = @import("power_on_cmd.zig");

const rf = @import("rooms_file.zig");
const MAX_FILE = 1 << 20;
const PAUSE = Io.Duration.fromMilliseconds(1000);

pub const usage =
    \\  dmain rooms check                  validate rooms.json and show what the Bridge would change
    \\  dmain rooms apply                  show what would change
    \\  dmain rooms apply confirm          rename and move the Bridge's devices to match
    \\  ... check|apply [confirm] -       the same, with rooms.json on stdin
    \\
;

const Rename = struct { id: []const u8, dev: []const u8, from: []const u8, to: []const u8 };
const Move = struct { name: []const u8, from: []const u8, to: []const u8 };
const RoomWrite = struct { room: *const bridge_write.RoomNow, children: []const bridge_write.Child };

const Plan = struct {
    renames: []const Rename,
    moves: []const Move,
    /// Each room whose children change: those gaining a device first, so a device
    /// is never left in no room by a write that fails halfway.
    rooms: []const RoomWrite,
    /// Devices the Bridge has and the file doesn't.
    unlisted: []const bridge_write.Placed,
    /// What the file asks that the Bridge can't do; any one stops the apply.
    refusals: []const []const u8,

    fn changes(self: Plan) usize {
        return self.renames.len + self.moves.len;
    }
};

fn plan(arena: Allocator, wanted: rf.Wanted, l: bridge_write.Layout) !Plan {
    var renames: std.ArrayList(Rename) = .empty;
    var moves: std.ArrayList(Move) = .empty;
    var unlisted: std.ArrayList(bridge_write.Placed) = .empty;
    var refusals: std.ArrayList([]const u8) = .empty;
    // Each room's children as they'll be, and whether a device joins it.
    const after = try arena.alloc(std.ArrayList(bridge_write.Child), l.rooms.len);
    const gains = try arena.alloc(bool, l.rooms.len);
    const loses = try arena.alloc(bool, l.rooms.len);
    for (l.rooms, after, gains, loses) |r, *a, *g, *x| {
        a.* = .empty;
        try a.appendSlice(arena, r.children);
        g.* = false;
        x.* = false;
    }

    for (l.devices) |d| {
        const w = for (wanted.devices) |*e| {
            if (std.mem.eql(u8, e.dev, d.dev)) break e;
        } else {
            try unlisted.append(arena, d);
            continue;
        };
        if (!std.mem.eql(u8, w.name, d.name)) {
            if (w.name.len > bridge_write.MAX_NAME)
                try refusals.append(arena, try std.fmt.allocPrint(arena, "{s} is longer than the Bridge's {d} characters", .{ w.name, bridge_write.MAX_NAME }))
            else
                try renames.append(arena, .{ .id = d.id, .dev = d.dev, .from = d.name, .to = w.name });
        }
        const from: ?usize = if (d.room_id) |id| roomIndex(l, id) else null;
        const to: ?usize = if (w.room) |name| (if (l.roomNamed(name)) |r| roomIndex(l, r.id) else null) else null;
        if (w.room != null and to == null) {
            try refusals.append(arena, try std.fmt.allocPrint(arena, "the Bridge has no room {s}, for {s}: make it in the Hue app", .{ w.room.?, w.name }));
            continue;
        }
        if (std.meta.eql(from, to)) continue;
        try moves.append(arena, .{
            .name = w.name,
            .from = if (from) |i| l.rooms[i].name else "no room",
            .to = if (to) |i| l.rooms[i].name else "no room",
        });
        if (from) |i| {
            const list = &after[i];
            var k: usize = 0;
            while (k < list.items.len) {
                if (std.mem.eql(u8, list.items[k].rid, d.id)) _ = list.orderedRemove(k) else k += 1;
            }
            loses[i] = true;
        }
        if (to) |i| {
            try after[i].append(arena, .{ .rid = d.id, .rtype = "device" });
            gains[i] = true;
        }
    }

    // A room with lights must say what its top button gives. A load's plug is a light
    // to the Bridge, so it doesn't count.
    for (wanted.rooms) |r| {
        if (r.default != null) continue;
        for (l.devices) |d| {
            if (!d.light) continue;
            const w = wanted.device(d.dev) orelse continue;
            if (w.load != null or w.room == null or !std.mem.eql(u8, w.room.?, r.name)) continue;
            try refusals.append(arena, try std.fmt.allocPrint(arena, "{s} has lights, {s} among them, and no default scene", .{ r.name, w.name }));
            break;
        }
    }

    var rooms: std.ArrayList(RoomWrite) = .empty;
    for ([_]bool{ true, false }) |gaining| {
        for (l.rooms, after, gains, loses) |*r, a, g, x| {
            if (gaining and g) try rooms.append(arena, .{ .room = r, .children = a.items });
            if (!gaining and x and !g) try rooms.append(arena, .{ .room = r, .children = a.items });
        }
    }
    return .{ .renames = renames.items, .moves = moves.items, .rooms = rooms.items, .unlisted = unlisted.items, .refusals = refusals.items };
}

fn roomIndex(l: bridge_write.Layout, id: []const u8) ?usize {
    for (l.rooms, 0..) |r, i| if (std.mem.eql(u8, r.id, id)) return i;
    return null;
}

pub fn run(gpa: Allocator, arena: Allocator, io: Io, app: *const config.Config, args: []const []const u8, given: ?[]const u8, out: *Io.Writer) !void {
    const sub = if (args.len > 0) args[0] else "";
    const confirm = args.len == 2 and std.mem.eql(u8, args[1], "confirm");
    const check = std.mem.eql(u8, sub, "check");
    const apply = std.mem.eql(u8, sub, "apply");
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

    const bridge_text = Io.Dir.cwd().readFileAlloc(io, app.bridge_file, arena, .limited(MAX_FILE)) catch |err| {
        try out.print("dmain: cannot read {s} ({t})\n", .{ app.bridge_file, err });
        return err;
    };
    // By name only: this file holds the Bridge's key.
    const bridge = bridge_write.parseCredentials(arena, bridge_text) catch |err| {
        try out.print("dmain: {s} is not right ({t})\n", .{ app.bridge_file, err });
        return err;
    };
    const owned = bridge_write.resources(gpa, io, bridge) catch |err| {
        try out.print("dmain: cannot read the Bridge ({t})\n", .{err});
        return err;
    };
    defer gpa.free(owned);
    const l = bridge_write.layout(arena, owned) catch |err| {
        try out.print("dmain: the Bridge's resource list didn't read ({t})\n", .{err});
        return err;
    };

    const p = try plan(arena, wanted, l);
    try report(p, out);
    if (p.refusals.len > 0) return error.Refused;
    if (!apply or p.changes() == 0) return;
    if (!confirm) {
        try out.writeAll("Nothing written. `dmain rooms apply confirm` writes these to the Bridge.\n");
        return;
    }
    try out.flush();
    try write(gpa, io, bridge, p, arena, out);
}

fn report(p: Plan, out: *Io.Writer) !void {
    try out.print("{d} would change on the Bridge: {d} renames, {d} moves.\n", .{ p.changes(), p.renames.len, p.moves.len });
    // The address too: names repeat, here several rooms' ceilings are just the room.
    for (p.renames) |r| try out.print("  rename \"{s}\" to \"{s}\" ({s})\n", .{ r.from, r.to, r.dev });
    for (p.moves) |m| try out.print("  move {s} from {s} to {s}\n", .{ m.name, m.from, m.to });
    for (p.unlisted) |d| try out.print("  not in rooms.json: {s} ({s})\n", .{ d.name, d.dev });
    for (p.refusals) |r| try out.print("  can't: {s}\n", .{r});
}

fn write(gpa: Allocator, io: Io, bridge: bridge_write.Credentials, p: Plan, arena: Allocator, out: *Io.Writer) !void {
    var accepted: usize = 0;
    var failed: usize = 0;
    for (p.renames) |r| {
        var reply: bridge_write.Reply = .{};
        if (bridge_write.setDevice(gpa, io, bridge, r.id, try bridge_write.renameBody(arena, r.to), &reply)) {
            try out.print("  {s}: renamed\n", .{r.to});
            accepted += 1;
        } else |err| {
            try power_on_cmd.refusedLine(out, r.to, err, &reply);
            failed += 1;
        }
        try out.flush();
        try io.sleep(PAUSE, .awake);
    }
    for (p.rooms) |w| {
        var reply: bridge_write.Reply = .{};
        if (bridge_write.setRoom(gpa, io, bridge, w.room.id, try bridge_write.childrenBody(arena, w.children), &reply)) {
            try out.print("  room {s}: now {d} devices\n", .{ w.room.name, w.children.len });
            accepted += 1;
        } else |err| {
            try power_on_cmd.refusedLine(out, w.room.name, err, &reply);
            failed += 1;
        }
        try out.flush();
        try io.sleep(PAUSE, .awake);
    }
    try out.print("{d} accepted, {d} failed.\n", .{ accepted, failed });
    if (failed > 0) return error.SomeWritesFailed;
}

const testing = std.testing;

test "a plan renames, moves with the gaining room first, and refuses what the Bridge can't do" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = try bridge_write.layout(a,
        \\{"errors":[],"data":[
        \\ {"id":"r1","type":"room","metadata":{"name":"Hall"},"children":[{"rid":"d1","rtype":"device"},{"rid":"d2","rtype":"device"}]},
        \\ {"id":"r2","type":"room","metadata":{"name":"Study"},"children":[]},
        \\ {"id":"d1","type":"device","metadata":{"name":"Ceiling"},"services":[{"rid":"l1","rtype":"light"}]},
        \\ {"id":"z1","type":"zigbee_connectivity","owner":{"rid":"d1","rtype":"device"},"mac_address":"00:00:00:00:00:00:00:01"},
        \\ {"id":"d2","type":"device","metadata":{"name":"Lamp"}},
        \\ {"id":"z2","type":"zigbee_connectivity","owner":{"rid":"d2","rtype":"device"},"mac_address":"00:00:00:00:00:00:00:02"},
        \\ {"id":"d3","type":"device","metadata":{"name":"Stray"}}]}
    );
    const wanted = try rf.parse(a,
        \\{"v":2,"rooms":[{"name":"Hall","default":"Relax"},{"name":"Study"}],"devices":[
        \\ {"dev":"00:00:00:00:00:00:00:01","name":"Hall Ceiling","room":"Hall"},
        \\ {"dev":"00:00:00:00:00:00:00:02","name":"Lamp","room":"Study"}]}
    );
    const p = try plan(a, wanted, l);
    try testing.expectEqual(@as(usize, 2), p.changes());
    try testing.expectEqualStrings("Hall Ceiling", p.renames[0].to);
    try testing.expectEqualStrings("Study", p.moves[0].to);
    try testing.expectEqual(@as(usize, 2), p.rooms.len);
    try testing.expectEqualStrings("Study", p.rooms[0].room.name);
    try testing.expectEqualStrings("d2", p.rooms[0].children[0].rid);
    try testing.expectEqualStrings("Hall", p.rooms[1].room.name);
    try testing.expectEqual(@as(usize, 1), p.rooms[1].children.len);
    try testing.expectEqualStrings("hue:d3", p.unlisted[0].dev);
    try testing.expectEqual(@as(usize, 0), p.refusals.len);

    const bad = try rf.parse(a,
        \\{"v":2,"rooms":[{"name":"Attic"}],"devices":[
        \\ {"dev":"00:00:00:00:00:00:00:01","name":"A name far longer than thirty-two characters","room":"Attic"}]}
    );
    const q = try plan(a, bad, l);
    // Too long, no room Attic on the Bridge, and Attic has a light and no default.
    try testing.expectEqual(@as(usize, 3), q.refusals.len);
    try testing.expect(std.mem.indexOf(u8, q.refusals[2], "Attic has lights") != null);
    try testing.expectEqual(@as(usize, 0), q.moves.len);
}
