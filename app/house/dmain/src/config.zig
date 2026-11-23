//! `dmain.json`: where the logs are and how to show them.
//!
//! The labels and calibration stay in the file `display_config` names, so there
//! is one copy of them. An unknown key is refused: a silently ignored setting
//! is how a config comes to mean something other than it says.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const FILE = "dmain.json";

const Parsed = struct {
    port: u16 = 8082,
    hue_log: []const u8 = "../huelog/data/house",
    hub_log: []const u8 = "../hub/data/house",
    display_config: []const u8 = "display.json",
    hue_settings: []const u8 = "../huelog/data/settings.json",
    hub_settings: []const u8 = "../hub/data/settings.json",
    /// hub's network as its radio sees it: channel, tables, each device's link.
    hub_network: []const u8 = "../hub/data/network.json",
    bridge_ids: []const u8 = "../huelog/data/bridge-ids.json",
    hue_schedules: []const u8 = "../huelog/data/schedules.json",
    hub_schedules: []const u8 = "../hub/schedule.json",
    /// hub's console, for the admin screens.
    hub_socket: []const u8 = "../hub/hub.sock",
    /// Where the Mac's copy of hub's config waits for hub's `adopt`. Beside
    /// hub's own files, because `adopt` names it from there.
    hub_stage: []const u8 = "../hub/staged",
    /// Holds the Bridge's key, so it stays in the one file that already does.
    bridge_file: []const u8 = "../hub/bridge.json",
    power_on: []const u8 = "power-on.json",
    /// Each switch's setup from before a change, which may exist nowhere else.
    backups: []const u8 = "backups",
    /// The house's rooms, in the order to show them.
    rooms: []const []const u8 = &.{},
};

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    port: u16,
    hue_log: []const u8,
    hub_log: []const u8,
    display_config: []const u8,
    hue_settings: []const u8,
    hub_settings: []const u8,
    hub_network: []const u8,
    bridge_ids: []const u8,
    hue_schedules: []const u8,
    hub_schedules: []const u8,
    hub_socket: []const u8,
    hub_stage: []const u8,
    bridge_file: []const u8,
    power_on: []const u8,
    backups: []const u8,
    rooms: []const []const u8,

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }
};

pub fn parse(a: Allocator, text: []const u8) !Parsed {
    const p = try std.json.parseFromSliceLeaky(Parsed, a, text, .{ .allocate = .alloc_always });
    if (p.port == 0) return error.BadPort;
    return p;
}

pub fn load(gpa: Allocator, io: Io, dir: Io.Dir, out: *Io.Writer) !Config {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const text = dir.readFileAlloc(io, FILE, a, .limited(1 << 16)) catch |err| {
        try out.print("dmain: cannot read {s} ({t})\n", .{ FILE, err });
        return err;
    };
    const p = parse(a, text) catch |err| {
        try out.print("dmain: {s} is not right ({t})\n", .{ FILE, err });
        return err;
    };
    return .{
        .arena = arena,
        .port = p.port,
        .hue_log = p.hue_log,
        .hub_log = p.hub_log,
        .display_config = p.display_config,
        .hue_settings = p.hue_settings,
        .hub_settings = p.hub_settings,
        .hub_network = p.hub_network,
        .bridge_ids = p.bridge_ids,
        .hue_schedules = p.hue_schedules,
        .hub_schedules = p.hub_schedules,
        .hub_socket = p.hub_socket,
        .hub_stage = p.hub_stage,
        .bridge_file = p.bridge_file,
        .power_on = p.power_on,
        .backups = p.backups,
        .rooms = p.rooms,
    };
}

const testing = std.testing;

test "defaults, overrides and refusals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try parse(a, "{}");
    try testing.expectEqual(@as(u16, 8082), d.port);
    try testing.expectEqualStrings("../hub/data/house", d.hub_log);
    const o = try parse(a, "{\"port\":9000,\"rooms\":[\"Kitchen\",\"Hall\"]}");
    try testing.expectEqual(@as(u16, 9000), o.port);
    try testing.expectEqualStrings("Hall", o.rooms[1]);
    try testing.expectError(error.UnknownField, parse(a, "{\"prot\":9000}"));
    try testing.expectError(error.BadPort, parse(a, "{\"port\":0}"));
}
