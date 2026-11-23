//! `huelog.json` → validated settings. Gitignored: it holds a live Hue
//! application key. `huelog.example.json` is the committed template.
//!
//! A value out of range warns and falls back; a file that does not parse is
//! refused, because there is no bridge to fall back to. **Unknown keys are
//! refused too**: an earlier program once ran a config written for a newer binary, its
//! parser dropped the new key in silence, and every rule lost its gate.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const CONFIG_FILE = "huelog.json";

pub const default_heartbeat_min = 5;
pub const default_silence_limit_min = 10;

const File = struct {
    bridge: struct {
        host: []const u8,
        port: u16 = 443,
        /// Who must answer at `host`: the bridge id its certificate has to
        /// carry. Required, so a file without one can't connect unvalidated.
        id: []const u8,
        key: []const u8,
    },
    /// Holds `raw/` and `house/`, one file per local day in each.
    data_dir: []const u8 = "data",
    heartbeat_min: u32 = default_heartbeat_min,
    /// How long the bridge may send nothing before the connection is assumed
    /// dead. The longest normal silence measured here is 4 minutes, overnight.
    silence_limit_min: u32 = default_silence_limit_min,
};

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    host: []const u8,
    port: u16,
    id: []const u8,
    key: []const u8,
    data_dir: []const u8,
    heartbeat_min: u32,
    silence_limit_min: u32,

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }
};

pub fn load(gpa: Allocator, io: Io, dir: Io.Dir, warn: *Io.Writer) !Config {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const text = dir.readFileAlloc(io, CONFIG_FILE, arena.allocator(), .limited(1 << 16)) catch |err| {
        try warn.print("huelog: cannot read {s} ({t})\n", .{ CONFIG_FILE, err });
        return error.MissingConfig;
    };
    var cfg = try parse(arena.allocator(), text, warn);
    cfg.arena = arena;
    return cfg;
}

fn parse(a: Allocator, text: []const u8, warn: *Io.Writer) !Config {
    const f = std.json.parseFromSliceLeaky(File, a, text, .{ .allocate = .alloc_always }) catch |err| {
        try warn.print("huelog: {s} does not parse ({t}) — see huelog.example.json\n", .{ CONFIG_FILE, err });
        return error.BadConfig;
    };
    // Must divide an hour, so heartbeats land on the same clock times every
    // day and a gap reads the same wherever it falls.
    var heartbeat_min = f.heartbeat_min;
    if (heartbeat_min == 0 or heartbeat_min > 60 or 60 % heartbeat_min != 0) {
        try warn.print("huelog: heartbeat_min {d} does not divide an hour — using {d}\n", .{ heartbeat_min, default_heartbeat_min });
        heartbeat_min = default_heartbeat_min;
    }
    var silence_limit_min = f.silence_limit_min;
    if (silence_limit_min == 0) {
        try warn.print("huelog: silence_limit_min 0 would drop every connection — using {d}\n", .{default_silence_limit_min});
        silence_limit_min = default_silence_limit_min;
    }
    return .{
        .arena = undefined,
        .silence_limit_min = silence_limit_min,
        .host = f.bridge.host,
        .port = f.bridge.port,
        .id = f.bridge.id,
        .key = f.bridge.key,
        .data_dir = f.data_dir,
        .heartbeat_min = heartbeat_min,
    };
}

const testing = std.testing;

test "parse: defaults, a bad interval, an unknown key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var warn: Io.Writer.Allocating = .init(testing.allocator);
    defer warn.deinit();
    const a = arena.allocator();

    const cfg = try parse(a, "{ \"bridge\": { \"host\": \"10.0.0.1\", \"id\": \"001788FFFE000000\", \"key\": \"k\" } }", &warn.writer);
    try testing.expectEqual(@as(u16, 443), cfg.port);
    try testing.expectEqualStrings("data", cfg.data_dir);
    try testing.expectEqual(@as(u32, 5), cfg.heartbeat_min);
    try testing.expectEqual(@as(u32, 10), cfg.silence_limit_min);
    try testing.expectEqual(@as(usize, 0), warn.written().len);

    const zero = try parse(a, "{ \"bridge\": { \"host\": \"h\", \"id\": \"i\", \"key\": \"k\" }, \"silence_limit_min\": 0 }", &warn.writer);
    try testing.expectEqual(@as(u32, 10), zero.silence_limit_min);
    warn.clearRetainingCapacity();

    const odd = try parse(a, "{ \"bridge\": { \"host\": \"h\", \"id\": \"i\", \"key\": \"k\" }, \"heartbeat_min\": 7 }", &warn.writer);
    try testing.expectEqual(@as(u32, 5), odd.heartbeat_min);
    try testing.expect(std.mem.indexOf(u8, warn.written(), "heartbeat_min 7") != null);

    try testing.expectError(error.BadConfig, parse(a, "{ \"bridge\": { \"host\": \"h\", \"id\": \"i\", \"key\": \"k\" }, \"heartbeat\": 5 }", &warn.writer));

    // No bridge id, no connection: there would be nothing to validate against.
    try testing.expectError(error.BadConfig, parse(a, "{ \"bridge\": { \"host\": \"h\", \"key\": \"k\" } }", &warn.writer));
}
