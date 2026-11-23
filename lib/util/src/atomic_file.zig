//! Replaces a file whole: written beside itself, then renamed over it.
//!
//! A reader sees the old contents or the complete new ones, never half, and a
//! crash mid-write leaves the old file intact.

const std = @import("std");
const Io = std.Io;

pub fn write(io: Io, dir: Io.Dir, sub_path: []const u8, data: []const u8) !void {
    return writeWith(io, dir, sub_path, data, .default_file);
}

/// `write`, with the permissions the new file is created with. The rename
/// replaces the file, so they hold whatever the old file had.
pub fn writeWith(io: Io, dir: Io.Dir, sub_path: []const u8, data: []const u8, permissions: Io.File.Permissions) !void {
    var tmp_buf: [256]u8 = undefined;
    const suffix = ".tmp";
    if (sub_path.len + suffix.len > tmp_buf.len) return error.NameTooLong;
    @memcpy(tmp_buf[0..sub_path.len], sub_path);
    @memcpy(tmp_buf[sub_path.len..][0..suffix.len], suffix);
    const tmp_path = tmp_buf[0 .. sub_path.len + suffix.len];

    // A temporary left by a crash would keep its own permissions, because
    // creating over an existing file doesn't change them.
    dir.deleteFile(io, tmp_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try dir.writeFile(io, .{ .sub_path = tmp_path, .data = data, .flags = .{ .permissions = permissions } });
    // Don't leave litter behind if the rename fails: a failed write should
    // change nothing observable.
    errdefer dir.deleteFile(io, tmp_path) catch {};
    try dir.rename(tmp_path, dir, sub_path, io);
}

test "correct content, no .tmp left behind, and an overwrite works" {
    const S = struct {
        var threaded: Io.Threaded = .init_single_threaded;
    };
    const io = S.threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try write(io, tmp.dir, "thing.json", "first");
    try write(io, tmp.dir, "thing.json", "second");

    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("second", try tmp.dir.readFile(io, "thing.json", &buf));
    try std.testing.expectError(error.FileNotFound, tmp.dir.readFile(io, "thing.json.tmp", &buf));
}

test "writeWith sets the permissions, even over a wider file and a stale temporary" {
    if (Io.File.Permissions == u0 or @import("builtin").os.tag == .windows) return error.SkipZigTest;
    const S = struct {
        var threaded: Io.Threaded = .init_single_threaded;
    };
    const io = S.threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const open: Io.File.Permissions = .fromMode(0o666);
    try tmp.dir.writeFile(io, .{ .sub_path = "key.json", .data = "old", .flags = .{ .permissions = open } });
    try tmp.dir.writeFile(io, .{ .sub_path = "key.json.tmp", .data = "stale", .flags = .{ .permissions = open } });

    try writeWith(io, tmp.dir, "key.json", "new", .fromMode(0o600));

    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("new", try tmp.dir.readFile(io, "key.json", &buf));
    const st = try tmp.dir.statFile(io, "key.json", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);
}
