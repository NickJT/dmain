//! event_stream — the bridge's event stream, followed for as long as it is wanted.
//!
//! The loop every consumer of the bridge needs: fetch `/clip/v2/resource` into
//! a registry, open `/eventstream/clip/v2`, reassemble SSE messages from the
//! chunked body, parse each into `EventUpdate`s, and reconnect when the bridge
//! drops the connection.
//!
//! **What an event means is the caller's business.** The handler is told about
//! each stage and decides; nothing here logs, filters or applies an event to
//! the registry. A consumer that wants the registry kept current calls
//! `registry.handleEvent` itself.
//!
//! ## The handler
//!
//! `handler` is a pointer to any type with these methods:
//!
//! ```
//! fn snapshot(h, registry: *Registry, raw: []const u8) void
//!     The resource list, fetched afresh on every (re)connect, parsed and as
//!     the bridge sent it. Names live only here, so this is where services are
//!     bound to whatever the caller calls them — and a rename in the Hue app
//!     takes effect on the next reconnect. `raw` is valid only for the call.
//! fn connected(h) void
//!     The stream's response head was 200; events follow.
//! fn message(h, registry: *Registry, payload: []const u8, events: []const EventUpdate) void
//!     One complete SSE message. `payload` is the bridge's JSON verbatim and
//!     `events` its parse; both are valid only for the duration of the call.
//! fn unparseable(h, payload: []const u8, err: anyerror) void
//!     A message that would not parse. The stream carries on.
//! fn ended(h, err: anyerror) void
//!     The connection is gone; `follow` sleeps and reconnects after this.
//! fn resync(h) bool
//!     Asked after every line the stream delivers, keepalives included, and
//!     before that line is used. True drops this connection and reconnects at
//!     once, with no backoff and no `ended` — the way to re-read the resource
//!     list, because the stream carries only `update` messages: a device
//!     added, removed or renamed is otherwise seen only after a fault.
//! ```
//!
//! The registry passed to `snapshot` and `message` lives for one connection.
//! Do not keep the pointer past `ended`.
//!
//! ## A connection can die without saying so
//!
//! The stream only listens. If the network drops for long enough that the
//! bridge gives up, its goodbye is lost, and nothing is ever sent that could
//! bring back an error: the socket stays ESTABLISHED and the read blocks for
//! ever. `resync` cannot help, being asked only when a line arrives. A receive
//! timeout is not an option, because `EAGAIN` reaches `Io.Threaded` as a
//! programmer bug and panics.
//!
//! So a caller passes a `Liveness` and watches it from another task: `silentMs`
//! says how long since the bridge last sent anything, keepalives included, and
//! `cut` shuts the socket down, which wakes the read. How long is too long is
//! the caller's choice.

const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const Allocator = std.mem.Allocator;

const tls_http = @import("tls_http");
const sse_events = @import("sse_events");
const Registry = @import("maps").ResourceRegistry;
const EventUpdate = @import("resources").EventUpdate;

pub const Bridge = struct {
    /// An IP literal: there is no resolver, deliberately.
    host: []const u8,
    port: u16 = 443,
    /// Who must answer at `host`: the common name its certificate must carry.
    id: []const u8,
    key: []const u8,
};

/// What a watcher needs to notice a silent stream and end it. Shared between the
/// task following the stream and the one watching it.
pub const Liveness = struct {
    mutex: Io.Mutex = .init,
    /// The stream being read; null between connections and once cut.
    socket: ?posix.socket_t = null,
    /// Under the mutex, not atomic: a 32-bit target has no 64-bit atomics, and a
    /// 64-bit host build will not reveal that.
    last_ms: i64 = 0,
    stalled: std.atomic.Value(bool) = .init(false),

    /// The stream, or an attempt to reach it, has just made progress.
    pub fn touch(self: *Liveness, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.last_ms = nowMs(io);
    }

    /// How long since `touch`.
    pub fn silentMs(self: *Liveness, io: Io) i64 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return nowMs(io) - self.last_ms;
    }

    /// Shut the stream's socket down, waking its blocked read, so that
    /// `followOnce` returns `error.StreamStalled`. Nothing is closed here: the
    /// follower owns the socket, and closing it under a blocked read is a race.
    /// Returns whether there was a connection to cut.
    pub fn cut(self: *Liveness, io: Io) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const fd = self.socket orelse return false;
        self.socket = null;
        self.stalled.store(true, .release);
        _ = posix.system.shutdown(fd, posix.SHUT.RDWR);
        return true;
    }

    fn attach(self: *Liveness, io: Io, fd: posix.socket_t) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.socket = fd;
        self.stalled.store(false, .release);
    }

    fn detach(self: *Liveness, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.socket = null;
    }

    /// Monotonic: an interval, which a clock step must not stretch into a stall.
    fn nowMs(io: Io) i64 {
        return @intCast(Io.Timestamp.now(io, .awake).toMilliseconds());
    }
};

/// Longest SSE line accepted. A bridge message carrying several services'
/// full state runs to a few KB; this is generous rather than tight.
pub const max_line = 128 * 1024;

/// Follow the stream until `running` goes false, reconnecting after `backoff`
/// whenever it ends. Never returns an error: a watcher that gives up because
/// the bridge rebooted is not a watcher. `liveness`, if given, is kept current
/// for a watcher in another task; without one, a silent death goes unnoticed.
pub fn follow(
    gpa: Allocator,
    io: Io,
    bridge: Bridge,
    handler: anytype,
    running: *const std.atomic.Value(bool),
    backoff: Io.Duration,
    liveness: ?*Liveness,
) void {
    while (running.load(.acquire)) {
        followOnce(gpa, io, bridge, handler, running, liveness) catch |err| {
            if (!running.load(.acquire)) return;
            if (err == error.Resync) continue;
            handler.ended(err);
        };
        if (!running.load(.acquire)) return;
        Io.sleep(io, backoff, Io.Clock.real) catch return;
    }
}

/// One connection: snapshot, stream, until the bridge, `running` or the
/// handler's `resync` ends it. Returns `error.StreamClosed` on a clean close by
/// the bridge — a stream that ends is always a fault from the caller's point of
/// view — `error.Resync` when the handler asked, and `error.StreamStalled` when
/// a watcher cut it.
pub fn followOnce(
    gpa: Allocator,
    io: Io,
    bridge: Bridge,
    handler: anytype,
    running: *const std.atomic.Value(bool),
    liveness: ?*Liveness,
) !void {
    if (liveness) |l| l.touch(io);
    const all_json = try tls_http.get(gpa, io, bridge.host, bridge.port, bridge.id, "/clip/v2/resource", bridge.key);
    defer gpa.free(all_json);

    var registry = Registry.init(gpa);
    defer registry.deinit();
    try registry.populate(all_json);
    handler.snapshot(&registry, all_json);

    const conn = try tls_http.connect(gpa, io, bridge.host, bridge.port, bridge.id);
    defer conn.close();
    if (liveness) |l| {
        l.touch(io);
        l.attach(io, conn.stream.socket.handle);
    }
    defer if (liveness) |l| l.detach(io); // before the close above: the watcher must not reach a closed socket
    try tls_http.writeRequest(conn, "GET", "/eventstream/clip/v2", bridge.host, bridge.key, "text/event-stream");

    var reader = tls_http.TlsReader.init(conn);
    var head_buf: [4096]u8 = undefined;
    const head = try reader.readResponseHead(&head_buf);
    if (!head.status_ok) return error.BridgeRejectedUs;
    handler.connected();

    const line_buf = try gpa.alloc(u8, max_line);
    defer gpa.free(line_buf);

    var messages: Assembler = .{};
    defer messages.deinit(gpa);

    while (running.load(.acquire)) {
        const n = reader.readLine(line_buf) catch |err| {
            if (liveness) |l| if (l.stalled.load(.acquire)) return error.StreamStalled;
            return err;
        };
        if (n == 0) {
            if (liveness) |l| if (l.stalled.load(.acquire)) return error.StreamStalled;
            return error.StreamClosed;
        }
        if (liveness) |l| l.touch(io);
        if (handler.resync()) return error.Resync;
        const payload = try messages.feed(gpa, line_buf[0..n]) orelse continue;
        deliver(gpa, &registry, payload, handler);
        messages.clear();
    }
}

fn deliver(gpa: Allocator, registry: *Registry, payload: []const u8, handler: anytype) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const events = sse_events.parseMessage(arena.allocator(), payload) catch |err| {
        handler.unparseable(payload, err);
        return;
    };
    handler.message(registry, payload, events.items);
}

/// SSE lines in, complete `data:` payloads out.
///
/// A message is its `data:` lines joined, terminated by a blank line. `id:`
/// lines and `: hi` keepalives carry nothing a consumer needs and are dropped.
/// Pure, so the framing is tested without a bridge.
pub const Assembler = struct {
    payload: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Assembler, gpa: Allocator) void {
        self.payload.deinit(gpa);
    }

    /// Feed one line, with or without its line ending. Returns the finished
    /// payload when this line completed a message; it stays valid until
    /// `clear` or the next `feed`.
    pub fn feed(self: *Assembler, gpa: Allocator, raw: []const u8) !?[]const u8 {
        const line = std.mem.trimEnd(u8, raw, "\r\n");
        if (line.len == 0) {
            if (self.payload.items.len == 0) return null;
            return self.payload.items;
        }
        if (std.mem.startsWith(u8, line, "data:")) {
            try self.payload.appendSlice(gpa, std.mem.trimStart(u8, line["data:".len..], " "));
        }
        return null;
    }

    pub fn clear(self: *Assembler) void {
        self.payload.clearRetainingCapacity();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Liveness: cut wakes a read that nothing else would ever wake" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var addr: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(18099) };
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    var client = try addr.connect(io, .{ .mode = .stream });
    defer client.close(io);
    var server = try listener.accept(io);
    defer server.close(io);

    var live: Liveness = .{};
    live.touch(io);
    try testing.expect(live.silentMs(io) < 1000);
    try testing.expect(!live.cut(io)); // nothing attached yet
    live.attach(io, client.socket.handle);

    // The peer stays open and silent, as a dead connection does.
    const Reader = struct {
        fn run(s: Io.net.Stream, i: Io, done: *std.atomic.Value(bool)) void {
            var buf: [64]u8 = undefined;
            var r = s.reader(i, &buf);
            _ = r.interface.peekByte() catch {};
            done.store(true, .release);
        }
    };
    var done: std.atomic.Value(bool) = .init(false);
    const thread = try std.Thread.spawn(.{}, Reader.run, .{ client, io, &done });
    try Io.sleep(io, Io.Duration.fromMilliseconds(100), .real);
    try testing.expect(!done.load(.acquire)); // it really is blocked

    try testing.expect(live.cut(io));
    thread.join();
    try testing.expect(done.load(.acquire));
    try testing.expect(live.stalled.load(.acquire));
    try testing.expect(!live.cut(io)); // once only
}

test "Assembler: one message per blank line, keepalives and ids dropped" {
    var a: Assembler = .{};
    defer a.deinit(testing.allocator);

    try testing.expectEqual(@as(?[]const u8, null), try a.feed(testing.allocator, ": hi\n"));
    try testing.expectEqual(@as(?[]const u8, null), try a.feed(testing.allocator, "\n"));
    try testing.expectEqual(@as(?[]const u8, null), try a.feed(testing.allocator, "id: 1:0\n"));
    try testing.expectEqual(@as(?[]const u8, null), try a.feed(testing.allocator, "data: [{\"a\":1}]\r\n"));
    try testing.expectEqualStrings("[{\"a\":1}]", (try a.feed(testing.allocator, "\r\n")).?);
    a.clear();

    // A keepalive's blank line after a cleared message yields nothing.
    try testing.expectEqual(@as(?[]const u8, null), try a.feed(testing.allocator, "\n"));
}

test "Assembler: multi-line data joins without separators" {
    var a: Assembler = .{};
    defer a.deinit(testing.allocator);

    _ = try a.feed(testing.allocator, "data: [{\"a\":");
    _ = try a.feed(testing.allocator, "data:1}]");
    try testing.expectEqualStrings("[{\"a\":1}]", (try a.feed(testing.allocator, "")).?);
}
