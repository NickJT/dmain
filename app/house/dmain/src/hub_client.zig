//! hub's console, through `hub.sock`: what `hub console` does, for `dmain agent`
//! to pass over the link and for `dmain admin` on the server to show directly.
//!
//! The socket sends hub's log from the moment of connecting, each command's
//! output among it, and a line holding only `DONE` when a command has finished.
//! A command is one line, and hub refuses what it won't run over the socket.
//!
//! The handler is any pointer type with:
//!
//! ```
//! pub fn hubLine(h, text: []const u8) void
//! pub fn hubDone(h) void
//! pub fn hubUp(h) void
//! pub fn hubDown(h, why: []const u8) void      only on a change, and at the first try
//! ```

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const posix = std.posix;
const link = @import("link.zig");

/// hub.sock's end-of-command mark, on a line of its own.
pub const DONE: u8 = 0x1E;

/// hub's limit on a console line.
pub const MAX_COMMAND = 256;

/// hub takes about 25 s to open its socket after a start.
const RETRY_MS: i64 = 5000;

pub const Client = struct {
    path: []const u8,
    stream: ?Io.net.Stream = null,
    lines: link.Lines = .{},
    /// Whether the last thing reported was up, so a change is reported once.
    reported: ?bool = null,
    last_try_ms: i64 = std.math.minInt(i64) / 2,

    pub fn deinit(self: *Client, gpa: Allocator, io: Io) void {
        if (self.stream) |s| s.close(io);
        self.lines.deinit(gpa);
    }

    /// For a poll set: the socket, or -1, which poll skips.
    pub fn fd(self: *const Client) posix.fd_t {
        return if (self.stream) |s| s.socket.handle else -1;
    }

    /// Connects when it's time to try again.
    pub fn tick(self: *Client, io: Io, handler: anytype) void {
        if (self.stream != null) return;
        const now_ms = Io.Timestamp.now(io, .awake).toMilliseconds();
        if (now_ms - self.last_try_ms < RETRY_MS) return;
        self.last_try_ms = now_ms;
        const address = Io.net.UnixAddress.init(self.path) catch |err| return self.down(handler, @errorName(err));
        self.stream = address.connect(io) catch |err| return self.down(handler, @errorName(err));
        self.reported = true;
        handler.hubUp();
    }

    fn down(self: *Client, handler: anytype, why: []const u8) void {
        if (self.reported == false) return;
        self.reported = false;
        handler.hubDown(why);
    }

    fn lost(self: *Client, gpa: Allocator, io: Io, handler: anytype, why: []const u8) void {
        if (self.stream) |s| s.close(io);
        self.stream = null;
        self.lines.deinit(gpa);
        self.lines = .{};
        self.down(handler, why);
    }

    /// After poll says the socket is ready: whatever hub has sent.
    pub fn readable(self: *Client, gpa: Allocator, io: Io, handler: anytype) void {
        const s = self.stream orelse return;
        var buf: [4096]u8 = undefined;
        const n = posix.read(s.socket.handle, &buf) catch 0;
        if (n == 0) return self.lost(gpa, io, handler, "hub closed its console");
        self.lines.append(gpa, buf[0..n]) catch return self.lost(gpa, io, handler, "hub sent a line too long to keep");
        while (self.lines.next()) |line| {
            if (line.len == 1 and line[0] == DONE) handler.hubDone() else handler.hubLine(line);
        }
    }

    /// One console line. Anything that can't be sent is answered as hub would,
    /// with a line and the end of the command.
    pub fn send(self: *Client, gpa: Allocator, io: Io, command: []const u8, handler: anytype) void {
        if (refusal(command)) |why| {
            handler.hubLine(why);
            return handler.hubDone();
        }
        const s = self.stream orelse {
            handler.hubLine("hub's console isn't answering");
            return handler.hubDone();
        };
        var buf: [MAX_COMMAND + 1]u8 = undefined;
        var w = s.writer(io, &buf);
        w.interface.writeAll(command) catch return self.lost(gpa, io, handler, "hub's console stopped taking commands");
        w.interface.writeByte('\n') catch return self.lost(gpa, io, handler, "hub's console stopped taking commands");
        w.interface.flush() catch return self.lost(gpa, io, handler, "hub's console stopped taking commands");
    }
};

/// What a console line can't be. hub would cut a long one off or split one with
/// a newline into two commands, which isn't what was typed.
pub fn refusal(command: []const u8) ?[]const u8 {
    if (std.mem.trim(u8, command, " ").len == 0) return "nothing to send";
    if (command.len > MAX_COMMAND) return "that's longer than hub takes";
    for (command) |c| if (c < 0x20 or c == 0x7f) return "a console line can't hold control characters";
    return null;
}

const testing = std.testing;

test "only a plain line of hub's length is sent" {
    try testing.expect(refusal("list") == null);
    try testing.expect(refusal("reload confirm") == null);
    try testing.expect(refusal("   ") != null);
    try testing.expect(refusal("list\nreload confirm") != null);
    try testing.expect(refusal("ack\x1e") != null);
    var long: [MAX_COMMAND + 1]u8 = @splat('x');
    try testing.expect(refusal(&long) != null);
    try testing.expect(refusal(long[0..MAX_COMMAND]) == null);
}

const Seen = struct {
    lines: std.ArrayList(u8) = .empty,
    done: usize = 0,
    up: usize = 0,
    down: std.ArrayList(u8) = .empty,

    fn deinit(self: *Seen) void {
        self.lines.deinit(testing.allocator);
        self.down.deinit(testing.allocator);
    }
    pub fn hubLine(self: *Seen, text: []const u8) void {
        self.lines.appendSlice(testing.allocator, text) catch unreachable;
        self.lines.append(testing.allocator, '|') catch unreachable;
    }
    pub fn hubDone(self: *Seen) void {
        self.done += 1;
    }
    pub fn hubUp(self: *Seen) void {
        self.up += 1;
    }
    pub fn hubDown(self: *Seen, why: []const u8) void {
        self.down.appendSlice(testing.allocator, why) catch unreachable;
        self.down.append(testing.allocator, '|') catch unreachable;
    }
};

test "no hub is reported once, and a command to it is answered here" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var seen: Seen = .{};
    defer seen.deinit();
    var client: Client = .{ .path = "/nonexistent-dmain-test/hub.sock" };
    defer client.deinit(testing.allocator, testing.io);

    client.tick(testing.io, &seen);
    client.last_try_ms = std.math.minInt(i64) / 2;
    client.tick(testing.io, &seen);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, seen.down.items, "|"));
    try testing.expectEqual(@as(posix.fd_t, -1), client.fd());

    client.send(testing.allocator, testing.io, "list", &seen);
    client.send(testing.allocator, testing.io, "a\nb", &seen);
    try testing.expectEqualStrings("hub's console isn't answering|a console line can't hold control characters|", seen.lines.items);
    try testing.expectEqual(@as(usize, 2), seen.done);
}

/// Stands in for hub.sock: one client, a log line, then a command's reply and
/// the done mark, then it closes.
fn fakeHub(server: *Io.net.Server, io: Io, got: *[64]u8, got_len: *usize) void {
    const stream = server.accept(io) catch return;
    defer stream.close(io);
    var wbuf: [256]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    w.interface.writeAll("12:00:00 panel: on\n") catch return;
    w.interface.flush() catch return;
    var n: usize = 0;
    while (std.mem.findScalar(u8, got[0..n], '\n') == null) {
        const r = posix.read(stream.socket.handle, got[n..]) catch return;
        if (r == 0) return;
        n += r;
    }
    got_len.* = n;
    w.interface.writeAll("5 devices\n\x1e\n") catch return;
    w.interface.flush() catch return;
}

test "a console line goes to hub, and hub's lines, done mark and going away come back" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [200]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/hub.sock", .{tmp.sub_path});
    const address = try Io.net.UnixAddress.init(path);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    var got: [64]u8 = undefined;
    var got_len: usize = 0;
    const thread = try std.Thread.spawn(.{}, fakeHub, .{ &server, io, &got, &got_len });

    var seen: Seen = .{};
    defer seen.deinit();
    var client: Client = .{ .path = path };
    defer client.deinit(testing.allocator, io);
    client.tick(io, &seen);
    try testing.expectEqual(@as(usize, 1), seen.up);
    client.send(testing.allocator, io, "list", &seen);

    var fds = [_]posix.pollfd{.{ .fd = client.fd(), .events = posix.POLL.IN, .revents = 0 }};
    var rounds: usize = 0;
    while (client.fd() != -1 and rounds < 50) : (rounds += 1) {
        fds[0].fd = client.fd();
        if (try posix.poll(&fds, 100) > 0) client.readable(testing.allocator, io, &seen);
    }
    thread.join();
    try testing.expectEqualStrings("list\n", got[0..got_len]);
    try testing.expectEqualStrings("12:00:00 panel: on|5 devices|", seen.lines.items);
    try testing.expectEqual(@as(usize, 1), seen.done);
    try testing.expectEqualStrings("hub closed its console|", seen.down.items);
}
