//! A run for `dmain agent`: check, or apply, wanted files sent from the Mac.
//!
//! dmain's own files go to a child `dmain power-on|switches|rooms apply [confirm] -`, with
//! the text on its stdin, so a slow apply (a second a light) never holds up the
//! link. hub's go into a directory beside its own, for `adopt` to read.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const posix = std.posix;
const link = @import("link.zig");

/// The files hub's `adopt` reads, every one of which must be sent: a missing
/// file would read as empty there.
pub const HUB_FILES = [_][]const u8{ "devices.json", "rules.json", "groups.json", "schedule.json" };

/// Why these files can't be run for `target`, or null.
pub fn refusal(target: link.Target, files: []const link.NamedFile) ?[]const u8 {
    switch (target) {
        .power_on, .switches, .sensors, .schedules, .actions => if (files.len != 1) return "dmain's runs take one file",
        // hub's devices.json comes too, so the hash covers both, but it's the
        // Mac's to rewrite.
        .rooms => if (files.len == 0 or !std.mem.eql(u8, files[0].name, "rooms.json")) return "the rooms run takes rooms.json first",
        .hub => {
            if (files.len != HUB_FILES.len) return "hub's run takes devices, rules, groups and schedule.json";
            for (HUB_FILES) |name| {
                var n: usize = 0;
                for (files) |f| {
                    if (std.mem.eql(u8, f.name, name)) n += 1;
                }
                if (n != 1) return "hub's run takes devices, rules, groups and schedule.json, once each";
            }
        },
    }
    return null;
}

/// The command line for a dmain run.
pub fn argv(buf: *[6][]const u8, exe: []const u8, target: link.Target, confirm: bool) []const []const u8 {
    buf[0] = exe;
    buf[1] = switch (target) {
        .power_on => "power-on",
        .switches => "switches",
        .sensors => "sensors",
        .schedules => "schedules",
        .actions => "actions",
        .rooms => "rooms",
        .hub => unreachable,
    };
    buf[2] = "apply";
    var n: usize = 3;
    if (confirm) {
        buf[n] = "confirm";
        n += 1;
    }
    buf[n] = "-";
    return buf[0 .. n + 1];
}

/// A child dmain and what it has printed so far.
pub const Child = struct {
    child: std.process.Child,
    out: link.Lines = .{},
    err: link.Lines = .{},
    out_open: bool = true,
    err_open: bool = true,

    pub fn start(gpa: Allocator, io: Io, target: link.Target, confirm: bool, text: []const u8) !Child {
        const exe = try std.process.executablePathAlloc(io, gpa);
        defer gpa.free(exe);
        var buf: [6][]const u8 = undefined;
        var child = try std.process.spawn(io, .{
            .argv = argv(&buf, exe, target, confirm),
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        // It reads all of stdin before it prints, so this can't wait on its output.
        if (child.stdin) |stdin| {
            stdin.writeStreamingAll(io, text) catch {};
            stdin.close(io);
            child.stdin = null;
        }
        return .{ .child = child };
    }

    /// Any program, its stdout and stderr read as lines, stdin closed.
    pub fn spawn(io: Io, command: []const []const u8) !Child {
        return .{ .child = try std.process.spawn(io, .{ .argv = command, .stdin = .ignore, .stdout = .pipe, .stderr = .pipe }) };
    }

    /// Ends one that won't end by itself, such as a journal being followed.
    pub fn stop(self: *Child, gpa: Allocator, io: Io) void {
        self.child.kill(io);
        self.deinit(gpa);
    }

    pub fn deinit(self: *Child, gpa: Allocator) void {
        self.out.deinit(gpa);
        self.err.deinit(gpa);
    }

    pub fn outFd(self: *const Child) posix.fd_t {
        return if (self.out_open) self.child.stdout.?.handle else -1;
    }

    pub fn errFd(self: *const Child) posix.fd_t {
        return if (self.err_open) self.child.stderr.?.handle else -1;
    }

    /// Reads one of its pipes, handing each complete line to `line`.
    pub fn readable(self: *Child, gpa: Allocator, from_err: bool, sink: anytype) void {
        const fd = if (from_err) self.errFd() else self.outFd();
        if (fd == -1) return;
        const lines = if (from_err) &self.err else &self.out;
        var buf: [4096]u8 = undefined;
        const n = posix.read(fd, &buf) catch 0;
        if (n == 0) {
            if (from_err) self.err_open = false else self.out_open = false;
            // A last line without its newline is still a line.
            lines.append(gpa, "\n") catch {};
        } else {
            lines.append(gpa, buf[0..n]) catch {};
        }
        while (lines.next()) |line| sink.runLine(line);
    }

    /// Once both pipes have closed: whether it succeeded.
    pub fn finish(self: *Child, io: Io) ?bool {
        if (self.out_open or self.err_open) return null;
        const term = self.child.wait(io) catch return false;
        return term.success();
    }
};

/// hub's files, into `dir` beside hub's own.
pub fn stage(io: Io, dir_path: []const u8, files: []const link.NamedFile) !void {
    try Io.Dir.cwd().createDirPath(io, dir_path);
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    for (files) |f| try dir.writeFile(io, .{ .sub_path = f.name, .data = f.text });
}

/// Whether a line of hub's reply to `adopt` says it didn't work.
pub fn hubSaysFailed(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "adopt")) return false;
    for ([_][]const u8{ "refused", "failed", "cannot", "has no", "wasn't copied", "usage" }) |word| {
        if (std.mem.indexOf(u8, line, word) != null) return true;
    }
    return false;
}

const testing = std.testing;

test "hub's run takes its four files exactly, dmain's one" {
    const f = struct {
        fn named(name: []const u8) link.NamedFile {
            return .{ .name = name, .text = "{}" };
        }
    }.named;
    try testing.expect(refusal(.power_on, &.{f("power-on.json")}) == null);
    try testing.expect(refusal(.switches, &.{}) != null);
    try testing.expect(refusal(.hub, &.{ f("devices.json"), f("rules.json"), f("groups.json"), f("schedule.json") }) == null);
    try testing.expect(refusal(.hub, &.{ f("devices.json"), f("rules.json"), f("groups.json") }) != null);
    try testing.expect(refusal(.hub, &.{ f("devices.json"), f("devices.json"), f("groups.json"), f("schedule.json") }) != null);
    try testing.expect(refusal(.hub, &.{ f("devices.json"), f("rules.json"), f("groups.json"), f("../hub.sock") }) != null);
}

test "a dmain run is its apply, with confirm only when asked, reading stdin" {
    var buf: [6][]const u8 = undefined;
    const dry = argv(&buf, "/d", .power_on, false);
    try testing.expectEqual(@as(usize, 4), dry.len);
    try testing.expectEqualStrings("power-on", dry[1]);
    try testing.expectEqualStrings("-", dry[3]);
    const wet = argv(&buf, "/d", .switches, true);
    try testing.expectEqualStrings("switches", wet[1]);
    try testing.expectEqualStrings("confirm", wet[3]);
    try testing.expectEqualStrings("-", wet[4]);
}

test "hub's adopt replies are read for failure, other lines aren't" {
    try testing.expect(hubSaysFailed("adopt refused — keeping the running config"));
    try testing.expect(hubSaysFailed("adopt: staged has no rules.json (FileNotFound) — keeping the running config"));
    try testing.expect(!hubSaysFailed("adopt: 2 change(s) applied"));
    try testing.expect(!hubSaysFailed("adopt: nothing to apply"));
    try testing.expect(!hubSaysFailed("[report] panel: refused"));
}

const Collect = struct {
    text: std.ArrayList(u8) = .empty,
    pub fn runLine(self: *Collect, line: []const u8) void {
        self.text.appendSlice(testing.allocator, line) catch unreachable;
        self.text.append(testing.allocator, '|') catch unreachable;
    }
};

test "a child's output comes back line by line, the last without its newline too" {
    const io = testing.io;
    var child: Child = .{ .child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "cat; echo oops >&2; printf tail" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) };
    defer child.deinit(testing.allocator);
    try child.child.stdin.?.writeStreamingAll(io, "one\ntwo\n");
    child.child.stdin.?.close(io);
    child.child.stdin = null;

    var seen: Collect = .{};
    defer seen.text.deinit(testing.allocator);
    var ok: ?bool = null;
    while (ok == null) {
        var fds = [_]posix.pollfd{
            .{ .fd = child.outFd(), .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = child.errFd(), .events = posix.POLL.IN, .revents = 0 },
        };
        _ = try posix.poll(&fds, 1000);
        if (fds[0].revents != 0) child.readable(testing.allocator, false, &seen);
        if (fds[1].revents != 0) child.readable(testing.allocator, true, &seen);
        ok = child.finish(io);
    }
    try testing.expect(ok.?);
    try testing.expect(std.mem.indexOf(u8, seen.text.items, "one|two|") != null);
    try testing.expect(std.mem.indexOf(u8, seen.text.items, "tail|") != null);
    try testing.expect(std.mem.indexOf(u8, seen.text.items, "oops|") != null);
}
