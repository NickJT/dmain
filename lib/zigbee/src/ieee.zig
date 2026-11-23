//! IEEE-802.15.4 address text conversions, shared by config.zig, model.zig,
//! and engine.zig. Extracted from hub's predecessor (`printHexReversed`,
//! `parseIeeeReversed`), which had already flagged its own duplication
//! (main.zig had a second copy) as "a candidate for a shared util module if
//! a third user appears" — it has now appeared three times over.
//!
//! Zigbee IEEE addresses are conventionally *displayed* MSB-first
//! ("00:17:88:01:08:d1:40:dd") but travel on the wire (and are stored in
//! `Device.ieee` throughout this codebase) LSB-first. These two functions
//! are the only place that reversal happens.
const std = @import("std");
const Io = std.Io;

pub const ParseError = error{InvalidIeee} || std.fmt.ParseIntError;

/// Parses a display-order colon-hex IEEE string ("aa:bb:...:hh") into wire
/// order.
pub fn parseReversed(s: []const u8) ParseError![8]u8 {
    var display: [8]u8 = undefined;
    var it = std.mem.splitScalar(u8, s, ':');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= 8) return error.InvalidIeee;
        display[i] = try std.fmt.parseInt(u8, part, 16);
    }
    if (i != 8) return error.InvalidIeee;

    var wire: [8]u8 = undefined;
    for (0..8) |j| wire[j] = display[7 - j];
    return wire;
}

/// Prints a wire-order IEEE as display-order colon-hex ("aa:bb:...:hh").
pub fn printReversed(writer: *Io.Writer, wire: []const u8) !void {
    var i: usize = wire.len;
    while (i > 0) {
        i -= 1;
        try writer.print("{x:0>2}", .{wire[i]});
        if (i > 0) try writer.writeByte(':');
    }
}

/// Same as `printReversed` but returns an owned display-order string,
/// for callers building a value (e.g. JSON serialization) rather than
/// writing to a stream.
pub fn formatReversedAlloc(allocator: std.mem.Allocator, wire: []const u8) ![]u8 {
    var aw: Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try printReversed(&aw.writer, wire);
    return aw.toOwnedSlice();
}

test "parseReversed/printReversed round-trip" {
    const wire = try parseReversed("00:17:88:01:08:d1:40:dd");
    try std.testing.expectEqualSlices(u8, &.{ 0xdd, 0x40, 0xd1, 0x08, 0x01, 0x88, 0x17, 0x00 }, &wire);

    var buf: [64]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    try printReversed(&w, &wire);
    try std.testing.expectEqualStrings("00:17:88:01:08:d1:40:dd", w.buffered());
}

test "parseReversed rejects malformed input" {
    try std.testing.expectError(error.InvalidIeee, parseReversed("00:17:88"));
    try std.testing.expectError(error.InvalidIeee, parseReversed("00:17:88:01:08:d1:40:dd:ff"));
}

test "formatReversedAlloc matches printReversed" {
    const wire: [8]u8 = .{ 0xdd, 0x40, 0xd1, 0x08, 0x01, 0x88, 0x17, 0x00 };
    const s = try formatReversedAlloc(std.testing.allocator, &wire);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("00:17:88:01:08:d1:40:dd", s);
}

test "Semantic Check" {
    std.testing.refAllDecls(@This());
}
