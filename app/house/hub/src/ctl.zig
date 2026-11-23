//! The control socket: the console, for a hub running as a service.
//!
//! A service has no terminal, but `permit`, `setup` and `reload` still need
//! typing. `hub console` connects to a Unix socket in hub's working directory,
//! and the commands it sends are the console's own, through the same dispatcher.
//!
//! **A client can never stall the radio.** That is the design's one hard rule.
//! The engine loop never writes to a socket: a command joins a small queue the
//! loop drains, and its output goes to hub's log as any other line does. Each
//! connection follows that log on its own task, so a stuck client only ever
//! blocks itself.
//!
//! **Who may connect is decided by the file system.** The socket is mode 0600,
//! in a directory the service's user owns. Reaching it from elsewhere takes SSH.

const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const Model = @import("model");

pub const SOCKET_FILE = "hub.sock";

/// Longer than any real command, and hub.sock is a local, trusted peer.
pub const MAX_LINE = 256;

/// One line per engine tick is drained, so this is several seconds of backlog.
pub const MAX_QUEUED = 16;

/// Sent on its own line once a client's command has finished and its output has
/// been written. It's how `hub console reload` knows when to exit.
pub const DONE_MARK: u8 = 0x1E;

const POLL_MS = 150;

/// Why a command can't run over the socket, if it can't. These act on hub's own
/// terminal or lifetime. Under a service, `quit` would only earn a restart.
pub fn remoteRefusal(line: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const cmd = it.next() orelse return null;
    if (std.mem.eql(u8, cmd, "screen") or std.mem.eql(u8, cmd, "terminal"))
        return "the TUI needs hub's own terminal, so it isn't available here";
    if (std.mem.eql(u8, cmd, "quit") or std.mem.eql(u8, cmd, "exit"))
        return "this only leaves the console; to stop hub, use `systemctl --user stop hub`";
    return null;
}

/// Reassembles lines from a byte stream, however the reads happen to split them.
pub const LineSplitter = struct {
    buf: [MAX_LINE]u8 = undefined,
    len: usize = 0,
    /// The current line outgrew `buf`, so it is dropped when it ends.
    overlong: bool = false,

    pub const Line = union(enum) { line: []const u8, overlong };

    /// Feeds bytes until a line completes or they run out. Returns the line, if
    /// one completed, and sets `rest` to what's left to feed.
    pub fn feed(self: *LineSplitter, bytes: []const u8, rest: *[]const u8) ?Line {
        for (bytes, 0..) |b, i| {
            if (b != '\n') {
                if (self.len < self.buf.len) {
                    self.buf[self.len] = b;
                    self.len += 1;
                } else {
                    self.overlong = true;
                }
                continue;
            }
            rest.* = bytes[i + 1 ..];
            const n = self.len;
            const was_overlong = self.overlong;
            self.len = 0;
            self.overlong = false;
            return if (was_overlong) .overlong else .{ .line = std.mem.trim(u8, self.buf[0..n], " \t\r") };
        }
        rest.* = bytes[bytes.len..];
        return null;
    }
};

pub const Request = struct {
    id: u32,
    len: u16,
    bytes: [MAX_LINE]u8,

    pub fn line(self: *const Request) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// The commands waiting for the engine loop, and how far it has got.
pub const Queue = struct {
    mutex: Io.Mutex = .init,
    items: [MAX_QUEUED]Request = undefined,
    head: usize = 0,
    count: usize = 0,
    next_id: u32 = 1,
    /// 32-bit: the Pi has no 64-bit atomics. Ids are compared by wrapping
    /// distance, so wrapping after four billion commands is harmless.
    finished_id: std.atomic.Value(u32) = .init(0),

    /// The new command's id, or null if the queue is full.
    pub fn push(self: *Queue, io: Io, line: []const u8) !?u32 {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        if (self.count == MAX_QUEUED) return null;
        const id = self.next_id;
        self.next_id +%= 1;
        var request: Request = .{ .id = id, .len = @intCast(line.len), .bytes = undefined };
        @memcpy(request.bytes[0..line.len], line);
        self.items[(self.head + self.count) % MAX_QUEUED] = request;
        self.count += 1;
        return id;
    }

    /// For the engine loop. Non-blocking in every way that matters: the lock is
    /// only ever held for a copy.
    pub fn take(self: *Queue, io: Io) !?Request {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        if (self.count == 0) return null;
        const request = self.items[self.head];
        self.head = (self.head + 1) % MAX_QUEUED;
        self.count -= 1;
        return request;
    }

    pub fn finish(self: *Queue, id: u32) void {
        self.finished_id.store(id, .release);
    }

    pub fn isFinished(self: *const Queue, id: u32) bool {
        const distance: i32 = @bitCast(self.finished_id.load(.acquire) -% id);
        return distance >= 0;
    }
};

pub const Server = struct {
    model: *Model.Registry,
    queue: Queue = .{},
    running: std.atomic.Value(bool) = .init(true),
    listener: ?Io.net.Server = null,
    conn_group: Io.Group = .init,

    pub const BindError = error{AlreadyRunning} || Io.net.UnixAddress.ListenError || Io.net.UnixAddress.InitError;

    pub fn init(model: *Model.Registry) Server {
        return .{ .model = model };
    }

    /// Binds now, so a failure reaches the caller. A socket left by a crash has
    /// nothing listening and is replaced; a live one means another hub is here.
    pub fn bind(self: *Server, io: Io) BindError!void {
        const address = try Io.net.UnixAddress.init(SOCKET_FILE);
        if (address.connect(io)) |stream| {
            stream.close(io);
            return error.AlreadyRunning;
        } else |_| {}
        Io.Dir.cwd().deleteFile(io, SOCKET_FILE) catch {};
        self.listener = try address.listen(io, .{});
        Io.Dir.cwd().setFilePermissions(io, SOCKET_FILE, .fromMode(0o600), .{}) catch |err| {
            std.log.warn("{s}: cannot restrict permissions: {t}", .{ SOCKET_FILE, err });
        };
    }

    /// Stops accepting, ends every connection and removes the socket.
    pub fn stop(self: *Server, io: Io) void {
        self.running.store(false, .release);
        self.conn_group.cancel(io);
        Io.Dir.cwd().deleteFile(io, SOCKET_FILE) catch {};
    }

    pub fn listenTask(self: *Server, io: Io) void {
        var listener = self.listener orelse return;
        defer listener.deinit(io);
        while (self.running.load(.acquire)) {
            const stream = listener.accept(io) catch continue;
            // `concurrent`, not `async`: `async` may run a task inline once its
            // limit is reached, and this one loops until the client leaves.
            self.conn_group.concurrent(io, connTask, .{ self, io, stream }) catch {
                stream.close(io);
            };
        }
    }

    fn connTask(self: *Server, io: Io, stream_in: Io.net.Stream) void {
        const stream = stream_in;
        defer stream.close(io);
        self.serve(io, stream) catch {}; // a client leaving is not worth a log line
    }

    fn serve(self: *Server, io: Io, stream: Io.net.Stream) !void {
        var wbuf: [4096]u8 = undefined;
        var writer = stream.writer(io, &wbuf);
        const w = &writer.interface;

        var cursor = try self.model.logPosition(io); // this client wants what's next, not history
        var splitter: LineSplitter = .{};
        var waiting: ?u32 = null;

        while (self.running.load(.acquire)) {
            var pfd = [1]posix.pollfd{.{ .fd = stream.socket.handle, .events = posix.POLL.IN, .revents = 0 }};
            if (try posix.poll(&pfd, POLL_MS) > 0 and pfd[0].revents != 0) {
                var in: [512]u8 = undefined;
                const n = try posix.read(stream.socket.handle, &in);
                if (n == 0) return;
                var bytes: []const u8 = in[0..n];
                while (bytes.len > 0) {
                    const parsed = splitter.feed(bytes, &bytes) orelse break;
                    switch (parsed) {
                        .overlong => try reply(w, "that line is too long"),
                        .line => |line| {
                            if (line.len == 0) {
                                try w.writeByte(DONE_MARK);
                                try w.writeByte('\n');
                            } else if (remoteRefusal(line)) |why| {
                                try reply(w, why);
                            } else if (try self.queue.push(io, line)) |id| {
                                waiting = id;
                            } else {
                                try reply(w, "hub is busy: try again in a moment");
                            }
                        },
                    }
                    try w.flush();
                }
            }

            // Read before the drain: a command seen as finished has all of its
            // lines in the log, so the drain below is certain to include them.
            const finished = if (waiting) |id| self.queue.isFinished(id) else false;
            try self.model.drainTo(io, w, &cursor);
            if (finished) {
                waiting = null;
                try w.writeByte(DONE_MARK);
                try w.writeByte('\n');
                try w.flush();
            }
        }
    }

    fn reply(w: *Io.Writer, text: []const u8) !void {
        try w.print("{s}\n", .{text});
        try w.writeByte(DONE_MARK);
        try w.writeByte('\n');
    }
};

/// `hub console [command...]`. With a command, sends it, prints what follows and
/// exits when it has finished. Without one, stays connected, showing hub's log
/// as it happens and sending each line typed.
pub fn runClient(io: Io, command: []const [:0]const u8, out: *Io.Writer) !u8 {
    const address = try Io.net.UnixAddress.init(SOCKET_FILE);
    const stream = address.connect(io) catch |err| {
        try out.print("hub console: no hub answering here ({s}: {t}). It may still be starting, which takes about 30 s. Run this from hub's directory.\n", .{ SOCKET_FILE, err });
        try out.flush();
        return 1;
    };
    defer stream.close(io);

    var wbuf: [MAX_LINE + 1]u8 = undefined;
    var writer = stream.writer(io, &wbuf);
    const w = &writer.interface;

    const one_shot = command.len > 0;
    if (one_shot) {
        for (command, 0..) |word, i| {
            if (i > 0) try w.writeByte(' ');
            try w.writeAll(word);
        }
        try w.writeByte('\n');
        try w.flush();
    } else {
        try out.writeAll("hub console: connected. `exit` leaves; hub keeps running.\n");
        try out.flush();
    }

    // One command reads nothing from stdin, so stdin isn't polled at all: poll
    // reports a hang-up whatever events were asked for, and over `ssh` stdin has
    // often hung up already, which would end the client before any reply came.
    // A negative fd is how poll is told to skip an entry.
    var pfds = [2]posix.pollfd{
        .{ .fd = stream.socket.handle, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = if (one_shot) -1 else posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
    };
    var splitter: LineSplitter = .{};
    while (true) {
        _ = try posix.poll(&pfds, -1);

        if (pfds[0].revents != 0) {
            var in: [4096]u8 = undefined;
            const n = try posix.read(stream.socket.handle, &in);
            if (n == 0) {
                if (one_shot) {
                    try out.writeAll("hub console: hub went away before the command finished\n");
                    try out.flush();
                    return 1;
                }
                return 0;
            }
            var bytes: []const u8 = in[0..n];
            while (std.mem.indexOfScalar(u8, bytes, DONE_MARK)) |mark| {
                try out.writeAll(bytes[0..mark]);
                try out.flush();
                if (one_shot) return 0;
                // Its newline may arrive in the next read, which prints a blank
                // line at worst.
                bytes = bytes[mark + 1 ..];
                if (bytes.len > 0 and bytes[0] == '\n') bytes = bytes[1..];
            }
            try out.writeAll(bytes);
            try out.flush();
        }

        if (pfds[1].revents != 0) {
            var in: [512]u8 = undefined;
            const n = try posix.read(posix.STDIN_FILENO, &in);
            if (n == 0) return 0;
            var bytes: []const u8 = in[0..n];
            while (bytes.len > 0) {
                const parsed = splitter.feed(bytes, &bytes) orelse break;
                switch (parsed) {
                    .overlong => {
                        try out.writeAll("hub console: that line is too long\n");
                        try out.flush();
                    },
                    .line => |line| {
                        if (std.mem.eql(u8, line, "exit") or std.mem.eql(u8, line, "quit")) return 0;
                        try w.writeAll(line);
                        try w.writeByte('\n');
                        try w.flush();
                    },
                }
            }
        }
    }
}

const testing = std.testing;

fn testIo() Io {
    const S = struct {
        var threaded: Io.Threaded = .init_single_threaded;
    };
    return S.threaded.io();
}

test "remoteRefusal stops only what acts on hub's own terminal or lifetime" {
    try testing.expect(remoteRefusal("screen") != null);
    try testing.expect(remoteRefusal("screen config") != null);
    try testing.expect(remoteRefusal("terminal") != null);
    try testing.expect(remoteRefusal("quit") != null);
    try testing.expect(remoteRefusal("exit") != null);
    try testing.expect(remoteRefusal("reload confirm") == null);
    try testing.expect(remoteRefusal("permit 120") == null);
    try testing.expect(remoteRefusal("quitely") == null);
    try testing.expect(remoteRefusal("") == null);
}

test "LineSplitter joins a line across reads, and splits several in one" {
    var s: LineSplitter = .{};
    var rest: []const u8 = undefined;

    try testing.expect(s.feed("rel", &rest) == null);
    try testing.expectEqual(@as(usize, 0), rest.len);
    try testing.expectEqualStrings("reload", s.feed("oad\nlist\n", &rest).?.line);
    try testing.expectEqualStrings("list\n", rest);
    try testing.expectEqualStrings("list", s.feed(rest, &rest).?.line);
    try testing.expectEqual(@as(usize, 0), rest.len);
}

test "LineSplitter trims a line and passes on an empty one" {
    var s: LineSplitter = .{};
    var rest: []const u8 = undefined;
    try testing.expectEqualStrings("permit 60", s.feed("  permit 60 \r\n", &rest).?.line);
    try testing.expectEqualStrings("", s.feed("\n", &rest).?.line);
}

test "LineSplitter drops an overlong line whole, then recovers" {
    var s: LineSplitter = .{};
    var rest: []const u8 = undefined;
    var long: [MAX_LINE + 10]u8 = undefined;
    @memset(&long, 'x');
    try testing.expect(s.feed(&long, &rest) == null);
    try testing.expect(s.feed("\n", &rest).? == .overlong);
    try testing.expectEqualStrings("list", s.feed("list\n", &rest).?.line);
}

test "Queue runs commands in order and refuses when full" {
    const io = testIo();
    var q: Queue = .{};
    const first = (try q.push(io, "one")).?;
    const second = (try q.push(io, "two")).?;
    try testing.expectEqualStrings("one", (try q.take(io)).?.line());
    try testing.expectEqualStrings("two", (try q.take(io)).?.line());
    try testing.expect(try q.take(io) == null);
    try testing.expect(first != second);

    for (0..MAX_QUEUED) |_| try testing.expect(try q.push(io, "x") != null);
    try testing.expect(try q.push(io, "overflow") == null);
    _ = try q.take(io);
    try testing.expect(try q.push(io, "room again") != null);
}

test "Queue says when a command has finished, across id wrap-around" {
    const io = testIo();
    var q: Queue = .{};
    const id = (try q.push(io, "one")).?;
    const later = (try q.push(io, "two")).?;
    try testing.expect(!q.isFinished(id));
    q.finish(id);
    try testing.expect(q.isFinished(id));
    try testing.expect(!q.isFinished(later));
    q.finish(later);
    try testing.expect(q.isFinished(id));

    q.finished_id.store(std.math.maxInt(u32), .release);
    try testing.expect(!q.isFinished(1)); // just past the wrap, so not reached yet
    q.finish(2);
    try testing.expect(q.isFinished(std.math.maxInt(u32)));
}
