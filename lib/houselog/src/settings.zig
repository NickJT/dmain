//! What a device's settings are now: its model, firmware and power-on behaviour.
//!
//! **A snapshot, not a log.** These aren't events, so each source keeps one file,
//! replaced whole when something changes. No source's protocol reaches it, and
//! `dev` means what it means in the house log, so a reader can treat every source
//! alike and compare a device against what it should be.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const time = @import("time");
const atomic_file = @import("atomic_file");

pub const version = 1;
pub const FILE = "settings.json";

/// What a light does when power returns.
pub const PowerOn = enum { on, off, toggle, previous };

pub const Entry = struct {
    dev: []const u8,
    /// Tells apart several lights in one device, as in the house log.
    ch: u8 = 0,
    name: []const u8,
    model: ?[]const u8 = null,
    firmware: ?[]const u8 = null,
    power_on: ?PowerOn = null,
    /// Brightness percent at power-on, when it's a set value.
    power_on_bri: ?f64 = null,
    power_on_bri_previous: bool = false,
    power_on_ct_k: ?u32 = null,
};

pub const File = struct {
    v: u32 = version,
    src: []const u8,
    t: []const u8,
    devices: []const Entry,
};

fn renderDevices(gpa: Allocator, devices: []const Entry) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, devices, .{ .emit_null_optional_fields = false, .whitespace = .indent_1 });
}

/// The whole file. Strict on the way back in: see `parse`.
pub fn render(gpa: Allocator, src: []const u8, at: Io.Timestamp, devices: []const Entry) ![]u8 {
    var stamp_buf: [32]u8 = undefined;
    var stamp = Io.Writer.fixed(&stamp_buf);
    try time.formatIsoUtcMillis(at, &stamp);
    return std.json.Stringify.valueAlloc(
        gpa,
        File{ .src = src, .t = stamp.buffered(), .devices = devices },
        .{ .emit_null_optional_fields = false, .whitespace = .indent_1 },
    );
}

pub const ParseError = error{ BadFile, UnknownVersion, OutOfMemory };

/// Strings in the result live in `arena`. A field this version doesn't know
/// means a newer writer, so the file is refused rather than guessed at.
pub fn parse(arena: Allocator, text: []const u8) ParseError!File {
    const file = std.json.parseFromSliceLeaky(File, arena, text, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadFile,
    };
    if (file.v != version) return error.UnknownVersion;
    return file;
}

/// Writes a source's file when its contents change, and not otherwise, so `t`
/// says when something last changed.
pub const Publisher = struct {
    gpa: Allocator,
    last: []u8 = &.{},

    pub fn deinit(self: *Publisher) void {
        self.gpa.free(self.last);
        self.last = &.{};
    }

    /// True if the file was written.
    pub fn publish(self: *Publisher, io: Io, dir: Io.Dir, src: []const u8, at: Io.Timestamp, devices: []const Entry) !bool {
        const current = try renderDevices(self.gpa, devices);
        errdefer self.gpa.free(current);
        if (std.mem.eql(u8, current, self.last)) {
            self.gpa.free(current);
            return false;
        }
        const text = try render(self.gpa, src, at, devices);
        defer self.gpa.free(text);
        try atomic_file.write(io, dir, FILE, text);
        self.gpa.free(self.last);
        self.last = current;
        return true;
    }
};

const testing = std.testing;

fn testIo() Io {
    const S = struct {
        var threaded: Io.Threaded = .init_single_threaded;
    };
    return S.threaded.io();
}

test "a file survives its own strict reader" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const at = try time.ISO2Timestamp("2026-11-09T09:20:04.067Z");
    const entries = [_]Entry{
        .{ .dev = "00:17:88:01:0e:7d:d5:ad", .name = "panel", .model = "929003", .firmware = "1.2.3", .power_on = .previous, .power_on_bri_previous = true },
        .{ .dev = "hue:7f1c", .ch = 1, .name = "spot", .power_on = .on, .power_on_bri = 100, .power_on_ct_k = 2732 },
        .{ .dev = "00:12:4b:00:22:d0:f2:c3", .name = "motion2" },
    };
    const text = try render(arena.allocator(), "hub", at, &entries);
    const back = try parse(arena.allocator(), text);
    try testing.expectEqualStrings("hub", back.src);
    try testing.expectEqualStrings("2026-11-09T09:20:04.067Z", back.t);
    try testing.expectEqual(@as(usize, 3), back.devices.len);
    try testing.expectEqual(PowerOn.previous, back.devices[0].power_on.?);
    try testing.expect(back.devices[0].power_on_bri_previous);
    try testing.expectEqual(@as(u32, 2732), back.devices[1].power_on_ct_k.?);
    try testing.expect(back.devices[2].power_on == null);
    try testing.expect(std.mem.indexOf(u8, text, "null") == null);
}

test "a file from another version or with an unknown field is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.UnknownVersion, parse(a, "{\"v\":2,\"src\":\"s\",\"t\":\"x\",\"devices\":[]}"));
    try testing.expectError(error.BadFile, parse(a, "{\"v\":1,\"src\":\"s\",\"t\":\"x\",\"devices\":[],\"extra\":1}"));
    try testing.expectError(error.BadFile, parse(a, "{\"v\":1,\"src\":\"s\",\"t\":\"x\",\"devices\":[{\"dev\":\"d\",\"name\":\"n\",\"power_on\":\"sideways\"}]}"));
}

test "Publisher writes only when the contents change" {
    const io = testIo();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var p: Publisher = .{ .gpa = testing.allocator };
    defer p.deinit();

    const first = [_]Entry{.{ .dev = "d", .name = "n", .power_on = .on }};
    const second = [_]Entry{.{ .dev = "d", .name = "n", .power_on = .previous }};
    const at = try time.ISO2Timestamp("2026-11-09T09:20:04.067Z");
    const later = try time.ISO2Timestamp("2026-11-09T10:00:00.000Z");

    try testing.expect(try p.publish(io, tmp.dir, "hub", at, &first));
    try testing.expect(!try p.publish(io, tmp.dir, "hub", later, &first));
    var buf: [1024]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, try tmp.dir.readFile(io, FILE, &buf), "09:20:04") != null);

    try testing.expect(try p.publish(io, tmp.dir, "hub", later, &second));
    try testing.expect(std.mem.indexOf(u8, try tmp.dir.readFile(io, FILE, &buf), "previous") != null);
}
