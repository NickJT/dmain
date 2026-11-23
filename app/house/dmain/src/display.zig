//! `display.json`: what the phone pages show, and each sensor's calibration.
//!
//! **Sensors are named by IEEE address, with a label of our own**, so a rename
//! in the Hue app neither moves a row nor hides it, and a label can be short
//! ("Bed 2") where the bridge's name is long. Each page shows its own list, in
//! that order, and shows nothing else.
//!
//! No secrets live here.
//!
//! A value out of range warns and falls back; a file that does not parse, or
//! has a key this version does not know, is refused — a silently ignored key
//! once disarmed every rule an earlier program had.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const CONFIG_FILE = "display.json";

pub const Row = struct {
    dev: []const u8,
    label: []const u8,
    /// The outside reference: set apart on the page.
    outside: bool = false,
    /// Added to the sensor's reading wherever it is shown, from a calibration run
    /// (the records are in `calibration/`). The house log stays as reported,
    /// so this can be changed later and every past day follows it.
    correction: f64 = 0,
};

/// A row on the motion page. Its own list, because that page shows the outdoor
/// sensors by name where the temperature page has one "Outside".
pub const MotionRow = struct {
    dev: []const u8,
    label: []const u8,
    /// Set apart on the page.
    outdoor: bool = false,
};

/// More than any of these sensors has ever needed, so it is a typo. A wrong
/// correction would be believed: it looks like a temperature.
const max_correction: f64 = 5;

/// A sensor's correction, or 0 for one not listed.
pub fn correctionFor(display: []const Row, dev: []const u8) f64 {
    for (display) |row| if (std.mem.eql(u8, row.dev, dev)) return row.correction;
    return 0;
}

const File = struct {
    /// A backstop, not the main signal. These sensors report only when the
    /// temperature has moved, so a steady room goes quiet for an hour or
    /// more; a lost Zigbee link is what says a sensor has died.
    stale_min: u32 = 120,
    display: []const Row,
    motion: []const MotionRow = &.{},
};

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    stale_min: u32,
    display: []const Row,
    motion: []const MotionRow,

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }
};

pub fn load(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8, warn: *Io.Writer) !Config {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const text = dir.readFileAlloc(io, path, arena.allocator(), .limited(1 << 16)) catch |err| {
        try warn.print("dmain: cannot read {s} ({t})\n", .{ path, err });
        return error.MissingConfig;
    };
    var cfg = try parse(arena.allocator(), text, warn);
    cfg.arena = arena;
    return cfg;
}

fn parse(a: Allocator, text: []const u8, warn: *Io.Writer) !Config {
    const f = std.json.parseFromSliceLeaky(File, a, text, .{ .allocate = .alloc_always }) catch |err| {
        try warn.print("dmain: {s} does not parse ({t})\n", .{ CONFIG_FILE, err });
        return error.BadConfig;
    };
    if (f.display.len == 0) {
        try warn.print("dmain: {s} lists no sensors to display\n", .{CONFIG_FILE});
        return error.BadConfig;
    }
    for (f.display) |row| if (@abs(row.correction) > max_correction) {
        try warn.print("dmain: {s}: a correction of {d} for {s} cannot be right\n", .{ CONFIG_FILE, row.correction, row.label });
        return error.BadConfig;
    };
    var stale_min = f.stale_min;
    if (stale_min == 0) {
        try warn.print("dmain: stale_min 0 would grey out every reading — using 120\n", .{});
        stale_min = 120;
    }
    return .{
        .arena = undefined,
        .stale_min = stale_min,
        .display = f.display,
        .motion = f.motion,
    };
}

const testing = std.testing;

test "parse: defaults, the display list, and refusals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var warn: Io.Writer.Allocating = .init(testing.allocator);
    defer warn.deinit();
    const a = arena.allocator();

    const cfg = try parse(a,
        \\{ "display": [ { "dev": "00:17:88:01:06:44:35:a4", "label": "Outside" } ] }
    , &warn.writer);
    try testing.expectEqual(@as(u32, 120), cfg.stale_min);
    try testing.expectEqualStrings("Outside", cfg.display[0].label);

    try testing.expectError(error.BadConfig, parse(a, "{ \"display\": [] }", &warn.writer));
    try testing.expectError(error.BadConfig, parse(a, "{ \"display\": [], \"colour\": 1 }", &warn.writer));
}

test "parse: the motion list is its own, and may be absent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var warn: Io.Writer.Allocating = .init(testing.allocator);
    defer warn.deinit();
    const a = arena.allocator();

    const none = try parse(a,
        \\{ "display": [ { "dev": "aa", "label": "A" } ] }
    , &warn.writer);
    try testing.expectEqual(@as(usize, 0), none.motion.len);

    const cfg = try parse(a,
        \\{ "display": [ { "dev": "aa", "label": "A" } ],
        \\  "motion": [ { "dev": "bb", "label": "North Wall", "outdoor": true } ] }
    , &warn.writer);
    try testing.expectEqualStrings("North Wall", cfg.motion[0].label);
    try testing.expect(cfg.motion[0].outdoor);
}

test "corrections: found by address, 0 for a sensor not listed, a typo refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var warn: Io.Writer.Allocating = .init(testing.allocator);
    defer warn.deinit();
    const a = arena.allocator();

    const cfg = try parse(a,
        \\{ "display": [
        \\  { "dev": "aa", "label": "A", "correction": 2.09 },
        \\  { "dev": "bb", "label": "B" } ] }
    , &warn.writer);
    try testing.expectEqual(@as(f64, 2.09), correctionFor(cfg.display, "aa"));
    try testing.expectEqual(@as(f64, 0), correctionFor(cfg.display, "bb"));
    try testing.expectEqual(@as(f64, 0), correctionFor(cfg.display, "cc"));

    try testing.expectError(error.BadConfig, parse(a,
        \\{ "display": [ { "dev": "aa", "label": "A", "correction": 20.9 } ] }
    , &warn.writer));
}
