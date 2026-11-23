//! A Zigbee network as its coordinator sees it now: channel, PAN id, how full the
//! radio's tables are, whether joining is open, and each device's short address and
//! the quality of the last hop it was heard over.
//!
//! **A snapshot, not a log**, like `settings`: replaced whole, read whole. When a
//! device was last heard is the house log's to say, not this file's. Link quality
//! is the last hop's, so for a device that reaches the coordinator through a
//! router it describes that router's link, not the device's own.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const time = @import("time");
const atomic_file = @import("atomic_file");

pub const version = 1;
pub const FILE = "network.json";

/// A table's entries in use against its size; null where the radio didn't say.
pub const Use = struct {
    used: ?u16 = null,
    size: ?u16 = null,
};

pub const Device = struct {
    dev: []const u8,
    /// The short address, as `0x1a2b`.
    nwk: []const u8,
    /// Last hop's link quality, 0 to 255, and signal in dBm, from the latest frame.
    lqi: ?u8 = null,
    rssi: ?i8 = null,
};

pub const File = struct {
    v: u32 = version,
    src: []const u8,
    t: []const u8,
    /// Whether the radio has a network up.
    up: bool,
    channel: ?u8 = null,
    /// As `0x1a2b`.
    pan: ?[]const u8 = null,
    children: Use = .{},
    neighbours: Use = .{},
    /// When joining closes, unix ms, while it's open.
    permit_until_ms: ?i64 = null,
    devices: []const Device = &.{},
};

/// The whole file, `t` and `src` filled in.
pub fn render(gpa: Allocator, src: []const u8, at: Io.Timestamp, file: File) ![]u8 {
    var stamp_buf: [32]u8 = undefined;
    var stamp = Io.Writer.fixed(&stamp_buf);
    try time.formatIsoUtcMillis(at, &stamp);
    var out = file;
    out.src = src;
    out.t = stamp.buffered();
    return std.json.Stringify.valueAlloc(gpa, out, .{ .emit_null_optional_fields = false, .whitespace = .indent_1 });
}

pub fn write(gpa: Allocator, io: Io, dir: Io.Dir, src: []const u8, at: Io.Timestamp, file: File) !void {
    const text = try render(gpa, src, at, file);
    defer gpa.free(text);
    try atomic_file.write(io, dir, FILE, text);
}

pub const ParseError = error{ BadFile, UnknownVersion, OutOfMemory };

/// Strings in the result live in `arena`. A field this version doesn't know means
/// a newer writer, so the file is refused rather than guessed at.
pub fn parse(arena: Allocator, text: []const u8) ParseError!File {
    const file = std.json.parseFromSliceLeaky(File, arena, text, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadFile,
    };
    if (file.v != version) return error.UnknownVersion;
    return file;
}

const testing = std.testing;

test "a network renders and reads back, and a newer version is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try render(a, "hub", .{ .nanoseconds = 0 }, .{
        .src = "",
        .t = "",
        .up = true,
        .channel = 15,
        .pan = "0xcb2c",
        .children = .{ .used = 3, .size = 32 },
        .neighbours = .{ .used = 2 },
        .devices = &.{
            .{ .dev = "8c:73:da:ff:fe:29:38:57", .nwk = "0x1a2b", .lqi = 180, .rssi = -61 },
            .{ .dev = "00:17:88:01:0b:2c:4d:1e", .nwk = "0x0002" },
        },
    });
    const back = try parse(a, text);
    try testing.expectEqualStrings("hub", back.src);
    try testing.expectEqualStrings("1970-01-01T00:00:00.000Z", back.t);
    try testing.expectEqual(@as(?u8, 15), back.channel);
    try testing.expectEqual(@as(?u16, 32), back.children.size);
    try testing.expect(back.neighbours.size == null);
    try testing.expectEqual(@as(?i8, -61), back.devices[0].rssi);
    try testing.expect(back.devices[1].lqi == null);
    try testing.expect(back.permit_until_ms == null);

    try testing.expectError(error.UnknownVersion, parse(a, "{\"v\":2,\"src\":\"hub\",\"t\":\"x\",\"up\":true}"));
    try testing.expectError(error.BadFile, parse(a, "{\"v\":1,\"src\":\"hub\",\"t\":\"x\",\"up\":true,\"extra\":1}"));
}
