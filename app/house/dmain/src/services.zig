//! The house's services as systemd has them, for `dmain agent` to report and
//! restart, and their journals to follow.
//!
//! **A restart is queued, not waited for** (`--no-block`): hub takes about 25 s
//! to open its console, and the link stays live meanwhile. The next state says
//! how it went.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const link = @import("link.zig");

pub const Unit = link.Unit;

const PROPS = "Id,ActiveState,SubState,UnitFileState,ActiveEnterTimestamp,NRestarts,ExecStart";

/// One unit's block of `systemctl show`, before its binary is looked at.
pub const Shown = struct {
    service: link.Service,
    /// The unit's program, from ExecStart's `path=`.
    binary: ?[]const u8 = null,
};

/// `systemctl --user show huelog hub dmain --timestamp=unix -p …`: a block of
/// `Key=value` lines per unit, blank lines between. A unit it doesn't name is
/// skipped; one systemd doesn't know reads `inactive`, `dead`, `not-found`.
pub fn parseShow(arena: Allocator, text: []const u8) ![]Shown {
    var out: std.ArrayList(Shown) = .empty;
    var blocks = std.mem.splitSequence(u8, text, "\n\n");
    while (blocks.next()) |block| {
        var unit: ?Unit = null;
        var shown: Shown = .{ .service = .{ .unit = .hub, .active = "", .sub = "", .enabled = "" } };
        var lines = std.mem.splitScalar(u8, block, '\n');
        while (lines.next()) |line| {
            const eq = std.mem.findScalar(u8, line, '=') orelse continue;
            const key = line[0..eq];
            const value = line[eq + 1 ..];
            if (std.mem.eql(u8, key, "Id")) {
                const name = if (std.mem.endsWith(u8, value, ".service")) value[0 .. value.len - ".service".len] else value;
                unit = std.meta.stringToEnum(Unit, name);
            } else if (std.mem.eql(u8, key, "ActiveState")) {
                shown.service.active = try arena.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "SubState")) {
                shown.service.sub = try arena.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "UnitFileState")) {
                shown.service.enabled = try arena.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "ActiveEnterTimestamp")) {
                if (value.len > 1 and value[0] == '@') shown.service.since = std.fmt.parseInt(i64, value[1..], 10) catch null;
            } else if (std.mem.eql(u8, key, "NRestarts")) {
                shown.service.restarts = std.fmt.parseInt(u32, value, 10) catch 0;
            } else if (std.mem.eql(u8, key, "ExecStart")) {
                shown.binary = try execPath(arena, value);
            }
        }
        shown.service.unit = unit orelse continue;
        try out.append(arena, shown);
    }
    return out.items;
}

/// `{ path=/home/house/hub/hub ; argv[]=… }` to the path.
fn execPath(arena: Allocator, value: []const u8) !?[]const u8 {
    const start = (std.mem.find(u8, value, "path=") orelse return null) + "path=".len;
    const end = std.mem.findScalarPos(u8, value, start, ' ') orelse value.len;
    if (end == start) return null;
    return try arena.dupe(u8, value[start..end]);
}

/// Every unit's state, read now. A binary replaced after the unit started is
/// flagged; one that won't stat isn't.
pub fn read(arena: Allocator, io: Io) ![]link.Service {
    const result = try std.process.run(arena, io, .{
        .argv = &.{ "systemctl", "--user", "show", "huelog", "hub", "dmain", "--timestamp=unix", "-p", PROPS },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(4096),
    });
    const shown = try parseShow(arena, result.stdout);
    const out = try arena.alloc(link.Service, shown.len);
    for (shown, out) |s, *o| {
        o.* = s.service;
        const path = s.binary orelse continue;
        const since = s.service.since orelse continue;
        const st = Io.Dir.cwd().statFile(io, path, .{}) catch continue;
        o.newer_binary = st.mtime.toSeconds() > since;
    }
    return out;
}

/// The command that queues a restart.
pub fn restartArgv(buf: *[5][]const u8, unit: Unit) []const []const u8 {
    buf.* = .{ "systemctl", "--user", "--no-block", "restart", @tagName(unit) };
    return buf;
}

/// The command that follows a unit's journal, from its last lines. A user unit's
/// journal is found by this field: `journalctl --user` finds nothing on the server.
pub fn journalArgv(buf: *[8][]const u8, match: []const u8) []const []const u8 {
    buf.* = .{ "journalctl", match, "-n", "200", "-f", "-o", "short-iso", "--no-pager" };
    return buf;
}

pub fn journalMatch(buf: []u8, unit: Unit) []const u8 {
    return std.fmt.bufPrint(buf, "_SYSTEMD_USER_UNIT={t}.service", .{unit}) catch unreachable;
}

const testing = std.testing;

const sample =
    \\MainPID=13266
    \\NRestarts=0
    \\Id=huelog.service
    \\ActiveState=active
    \\SubState=running
    \\UnitFileState=enabled
    \\ExecStart={ path=/home/house/huelog/huelog ; argv[]=/home/house/huelog/huelog ; ignore_errors=no ; start_time=[@1794412548] ; pid=13266 }
    \\ActiveEnterTimestamp=@1794412548
    \\
    \\NRestarts=2
    \\Id=hub.service
    \\ActiveState=failed
    \\SubState=failed
    \\UnitFileState=enabled
    \\ActiveEnterTimestamp=
    \\ExecStart={ path=/home/house/hub/hub ; argv[]=/home/house/hub/hub --port 8081 }
    \\
    \\Id=sshd.service
    \\ActiveState=active
    \\
    \\Id=dmain.service
    \\ActiveState=inactive
    \\SubState=dead
    \\UnitFileState=
    \\NRestarts=0
    \\ActiveEnterTimestamp=@1794413097
    \\
;

test "systemctl show reads as each of the three services, and nothing else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try parseShow(arena.allocator(), sample);
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqual(Unit.huelog, got[0].service.unit);
    try testing.expectEqualStrings("running", got[0].service.sub);
    try testing.expectEqual(@as(?i64, 1794412548), got[0].service.since);
    try testing.expectEqualStrings("/home/house/huelog/huelog", got[0].binary.?);
    try testing.expectEqual(Unit.hub, got[1].service.unit);
    try testing.expectEqualStrings("failed", got[1].service.active);
    try testing.expectEqual(@as(u32, 2), got[1].service.restarts);
    try testing.expect(got[1].service.since == null);
    try testing.expectEqualStrings("/home/house/hub/hub", got[1].binary.?);
    try testing.expectEqual(Unit.dmain, got[2].service.unit);
    try testing.expect(got[2].binary == null);
    try testing.expectEqualStrings("", got[2].service.enabled);
}

test "a restart is queued, and a journal is followed by its user unit" {
    var buf: [5][]const u8 = undefined;
    const r = restartArgv(&buf, .hub);
    try testing.expectEqualStrings("--no-block", r[2]);
    try testing.expectEqualStrings("hub", r[4]);
    var mbuf: [64]u8 = undefined;
    var jbuf: [8][]const u8 = undefined;
    const j = journalArgv(&jbuf, journalMatch(&mbuf, .dmain));
    try testing.expectEqualStrings("_SYSTEMD_USER_UNIT=dmain.service", j[1]);
    try testing.expectEqualStrings("-f", j[4]);
}
