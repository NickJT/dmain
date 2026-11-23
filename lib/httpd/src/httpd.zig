//! A small HTTP/1.1 server for a LAN page: one request per connection, a
//! handler that routes it, and the hard-won parts that make it survive real
//! browsers.
//!
//! **Why hand-rolled.** `std.Io` has no HTTP server, and the scope — a page and
//! a few JSON endpoints, polled by a handful of phones and laptops — does not
//! need one: no keep-alive, no chunking, no TLS.
//!
//! **What this owns, and what it does not.** The accept loop, one task per
//! connection, the preconnect timeout, request-head parsing and response
//! framing are here. Routing, bodies and policy are the handler's — including
//! who may connect: `Options.allow` is a predicate the application chooses,
//! and `isPrivate` is one it may choose.
//!
//! The handler is a pointer to any type with:
//!
//! ```
//! fn handle(h, io: Io, arena: Allocator, req: Request, rd: *Io.Reader, wr: *Io.Writer) !void
//!     One request. Write the whole response with `respond` (or by hand), and
//!     read any body from `rd` — `req.content_length` says how much. `arena`
//!     lives until the connection closes.
//! ```

const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const Allocator = std.mem.Allocator;

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    content_length: usize,
    peer: Io.net.IpAddress,
};

pub const Options = struct {
    port: u16,
    /// Who may connect. Null admits everyone; a connection refused here is
    /// closed without a word, so a scan learns nothing.
    allow: ?*const fn (Io.net.IpAddress) bool = null,
};

pub fn Server(comptime Handler: type) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        handler: *Handler,
        options: Options,
        running: std.atomic.Value(bool) = .init(true),
        listener: ?Io.net.Server = null,
        // Per-connection tasks are fire-and-forget: a `Group` reclaims each
        // finished task on its own, so only the group needs one cancel at
        // shutdown — a `Future` per connection would need an await each.
        conn_group: Io.Group = .init,

        pub fn init(gpa: Allocator, handler: *Handler, options: Options) Self {
            return .{ .gpa = gpa, .handler = handler, .options = options };
        }

        /// Stop accepting and cancel every open connection.
        pub fn stop(self: *Self, io: Io) void {
            self.running.store(false, .release);
            self.conn_group.cancel(io);
        }

        /// Takes the port, so a caller can know it has it before saying so:
        /// `listenTask` runs later, in its own task, with nobody left to tell.
        /// `error.AddressInUse` means another server is on it.
        pub fn bind(self: *Self, io: Io) !void {
            if (!portIsFree(self.options.port)) return error.AddressInUse;
            var addr: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.unspecified(self.options.port) };
            self.listener = try addr.listen(io, .{ .reuse_address = true });
        }

        /// Accepts on `0.0.0.0:port` until `stop`, binding first if `bind` has
        /// not. Meant to run as its own `io.async` task.
        pub fn listenTask(self: *Self, io: Io) void {
            if (self.listener == null) self.bind(io) catch |err| {
                std.log.err("httpd: listen on :{d} failed: {t}", .{ self.options.port, err });
                return;
            };
            var listener = self.listener.?;
            defer listener.deinit(io);
            while (self.running.load(.acquire)) {
                const stream = listener.accept(io) catch continue;
                if (self.options.allow) |allow| if (!allow(stream.socket.address)) {
                    stream.close(io);
                    continue;
                };
                self.conn_group.async(io, connTask, .{ self, io, stream });
            }
        }

        fn connTask(self: *Self, io: Io, stream_in: Io.net.Stream) void {
            var stream = stream_in;
            defer stream.close(io);
            // Silent on purpose: a browser with the page open preconnects
            // every few seconds and sends nothing on most of those sockets.
            // That is normal, and logging it fills the log.
            if (!waitForRequest(stream)) return;
            if (!looksLikeHttp(stream)) return;
            var rbuf: [4096]u8 = undefined;
            var wbuf: [4096]u8 = undefined;
            var rd = stream.reader(io, &rbuf);
            var wr = stream.writer(io, &wbuf);

            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();

            const head = parseRequestHead(&rd.interface) catch {
                respond(&wr.interface, 400, "text/plain", "bad request\n") catch {};
                return;
            };
            const req: Request = .{
                .method = head.method,
                .path = head.path,
                .content_length = head.content_length,
                .peer = stream.socket.address,
            };
            self.handler.handle(io, arena.allocator(), req, &rd.interface, &wr.interface) catch |err| {
                std.log.debug("httpd: request failed: {t}", .{err});
            };
        }
    };
}

/// Whether another server is already listening on `port`.
///
/// **`Io`'s `reuse_address` cannot say.** It is needed, because without it a
/// restart cannot rebind while old connections wind down. But it sets
/// `SO_REUSEPORT` as well, so a second server run by the same user binds without
/// error and the kernel splits connections between the two: a browser gets one
/// server's page or the other's, and nothing reports a fault. A socket with
/// `SO_REUSEADDR` alone gets past the winding-down connections and still collides
/// with a listener, so it is tried first. A failure other than a collision is
/// left for the real bind to report.
fn portIsFree(port: u16) bool {
    const fd = posix.system.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    if (posix.errno(fd) != .SUCCESS) return true;
    const sock: posix.fd_t = @intCast(fd);
    defer _ = posix.system.close(sock);
    const on: c_int = 1;
    _ = posix.system.setsockopt(sock, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&on), @sizeOf(c_int));
    const addr: posix.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = 0 };
    const rc = posix.system.bind(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));
    return posix.errno(rc) != .ADDRINUSE;
}

/// How long a connection may say nothing before we hang up.
///
/// **This is a liveness fix, not politeness.** Once `Io`'s task pool is busy,
/// `Io.async` runs the task immediately on the caller's thread — here the
/// accept loop. A connection that opens and sends nothing used to hold a slot
/// forever, and once the slots were gone the accept loop itself ran one inline
/// and **stopped accepting for good**. Any browser that preconnects
/// speculatively (Chrome does) could wedge the server just by looking at it;
/// reproduced on hub's rig with three silent sockets.
///
/// **It bounds the damage; it does not remove the cause.** More silent sockets
/// than pool slots still stall the accept loop for this long, each. The full
/// fix is architectural — a dedicated pool, or one poll loop — and is not
/// bolted on here.
///
/// 2 s: about ten times any LAN round trip (a browser sends its request in the
/// same burst as the handshake), and short enough that a speculative socket
/// frees its slot quickly.
pub const request_head_timeout_ms = 2_000;

/// **A raw `posix.poll`, deliberately, and NOT `SO_RCVTIMEO`.** A receive
/// timeout makes `read` return `EAGAIN`, which `Io.Threaded` treats as a
/// programmer bug and **panics** on — strictly worse than the wedge. `poll`
/// only observes readiness and changes nothing about the socket.
fn waitForRequest(stream: Io.net.Stream) bool {
    var pfd = [1]posix.pollfd{.{ .fd = stream.socket.handle, .events = posix.POLL.IN, .revents = 0 }};
    const ready = posix.poll(&pfd, request_head_timeout_ms) catch return true; // cannot poll: try anyway
    return ready > 0;
}

/// Is the first byte one an HTTP request can start with?
///
/// **A TLS greeting on the plain port wedged the server without this.** A
/// greeting is binary and need not contain a newline, so `parseRequestHead`
/// waited on it for ever, holding a pool slot each time. Four at once stopped
/// the server answering anything, reproduced against the Pi on 2026-11-04
/// with a scripted client. Any browser or scanner that tries `https://` on
/// this port can send one.
///
/// Every method starts with a capital letter and TLS starts with 0x16, so one
/// byte, peeked rather than read, settles it. The connection is closed at once.
fn looksLikeHttp(stream: Io.net.Stream) bool {
    var first: [1]u8 = undefined;
    const rc = posix.system.recvfrom(stream.socket.handle, &first, 1, posix.MSG.PEEK, null, null);
    if (posix.errno(rc) != .SUCCESS) return true; // cannot tell: let the parser decide
    if (rc == 0) return false; // closed already
    return first[0] >= 'A' and first[0] <= 'Z';
}

pub const Head = struct {
    method: []const u8,
    path: []const u8,
    content_length: usize,
};

pub const HeadError = error{ BadRequest, ReadFailed, EndOfStream, StreamTooLong };

/// The request line and headers up to the blank line, keeping only method,
/// path and `Content-Length`.
pub fn parseRequestHead(rd: *Io.Reader) HeadError!Head {
    const request_line = try readLine(rd);
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = parts.next() orelse return error.BadRequest;
    const path = parts.next() orelse return error.BadRequest;
    if (method.len == 0 or path.len == 0) return error.BadRequest;

    var content_length: usize = 0;
    while (true) {
        const line = try readLine(rd);
        if (line.len == 0) break; // the blank line that ends the headers
        if (headerValue(line, "content-length")) |v| {
            content_length = std.fmt.parseInt(usize, v, 10) catch 0;
        }
    }
    return .{ .method = method, .path = path, .content_length = content_length };
}

fn headerValue(line: []const u8, want: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    if (!std.ascii.eqlIgnoreCase(line[0..colon], want)) return null;
    return std.mem.trim(u8, line[colon + 1 ..], " \t");
}

/// One CRLF-terminated line, delimiter stripped. `takeDelimiterExclusive`
/// leaves the delimiter unconsumed, so it is tossed here — or every later call
/// re-finds the same '\n' and returns an empty line forever.
fn readLine(rd: *Io.Reader) HeadError![]const u8 {
    const line = try rd.takeDelimiterExclusive('\n');
    if (rd.bufferedLen() > 0) rd.toss(1);
    return std.mem.trimEnd(u8, line, "\r");
}

/// A whole response, flushed.
///
/// `Connection: close` always: one request per connection keeps a connection
/// task a straight line. `Cache-Control: no-store` always: without it a
/// browser's heuristic cache was found serving an old page and old JSON
/// indefinitely, since nothing here carries an ETag to prompt revalidation.
pub fn respond(wr: *Io.Writer, status: u16, content_type: []const u8, body: []const u8) !void {
    try wr.print("HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", .{ status, reason(status), content_type, body.len });
    try wr.writeAll(body);
    try wr.flush();
}

/// `{"error":message}` with `status`.
pub fn respondJsonError(arena: Allocator, wr: *Io.Writer, status: u16, message: []const u8) !void {
    var aw: Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(.{ .@"error" = message }, .{}, &aw.writer);
    try respond(wr, status, "application/json", aw.writer.buffered());
}

fn reason(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        500 => "Internal Server Error",
        else => "Status",
    };
}

/// Loopback, link-local and the private ranges: RFC 1918 for IPv4, unique
/// local (fc00::/7) for IPv6. One `allow` an application may choose for a page
/// meant only for its own LAN — defence in depth behind a router that forwards
/// nothing.
pub fn isPrivate(addr: Io.net.IpAddress) bool {
    return switch (addr) {
        .ip4 => |a| privateIp4(a.bytes),
        .ip6 => |a| blk: {
            const b = a.bytes;
            // IPv4-mapped (::ffff:a.b.c.d): judge the IPv4 address.
            if (std.mem.allEqual(u8, b[0..10], 0) and b[10] == 0xff and b[11] == 0xff) break :blk privateIp4(b[12..16].*);
            if (std.mem.allEqual(u8, b[0..15], 0) and b[15] == 1) break :blk true; // ::1
            break :blk (b[0] & 0xfe) == 0xfc or (b[0] == 0xfe and (b[1] & 0xc0) == 0x80);
        },
    };
}

fn privateIp4(b: [4]u8) bool {
    return b[0] == 10 or b[0] == 127 or
        (b[0] == 172 and b[1] >= 16 and b[1] <= 31) or
        (b[0] == 192 and b[1] == 168) or
        (b[0] == 169 and b[1] == 254);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseRequestHead: GET with no headers" {
    var rd = Io.Reader.fixed("GET /api/status HTTP/1.1\r\n\r\n");
    const head = try parseRequestHead(&rd);
    try testing.expectEqualStrings("GET", head.method);
    try testing.expectEqualStrings("/api/status", head.path);
    try testing.expectEqual(@as(usize, 0), head.content_length);
}

test "parseRequestHead: Content-Length is found case-insensitively" {
    var rd = Io.Reader.fixed("POST /api/action HTTP/1.1\r\nHost: hub.local\r\ncontent-LENGTH: 42\r\n\r\nbody-not-read-here");
    const head = try parseRequestHead(&rd);
    try testing.expectEqualStrings("POST", head.method);
    try testing.expectEqual(@as(usize, 42), head.content_length);
}

test "parseRequestHead: a missing path is a bad request" {
    var rd = Io.Reader.fixed("GET\r\n\r\n");
    try testing.expectError(error.BadRequest, parseRequestHead(&rd));
}

test "isPrivate: the LAN ranges, and nothing outside them" {
    const v4 = struct {
        fn a(b0: u8, b1: u8, b2: u8, b3: u8) Io.net.IpAddress {
            return .{ .ip4 = .{ .bytes = .{ b0, b1, b2, b3 }, .port = 0 } };
        }
    }.a;
    try testing.expect(isPrivate(v4(192, 168, 86, 20)));
    try testing.expect(isPrivate(v4(10, 1, 2, 3)));
    try testing.expect(isPrivate(v4(172, 16, 0, 1)));
    try testing.expect(isPrivate(v4(127, 0, 0, 1)));
    try testing.expect(!isPrivate(v4(172, 32, 0, 1)));
    try testing.expect(!isPrivate(v4(8, 8, 8, 8)));

    var ula: [16]u8 = @splat(0);
    ula[0] = 0xfd;
    try testing.expect(isPrivate(.{ .ip6 = .{ .bytes = ula, .port = 0 } }));
    var mapped: [16]u8 = @splat(0);
    mapped[10] = 0xff;
    mapped[11] = 0xff;
    mapped[12] = 8;
    mapped[13] = 8;
    mapped[14] = 8;
    mapped[15] = 8;
    try testing.expect(!isPrivate(.{ .ip6 = .{ .bytes = mapped, .port = 0 } }));
    var global: [16]u8 = @splat(0);
    global[0] = 0x20;
    try testing.expect(!isPrivate(.{ .ip6 = .{ .bytes = global, .port = 0 } }));
}

test "Server: a TLS greeting is closed at once and cannot wedge the server" {
    const port: u16 = 18097;
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const H = struct {
        pub fn handle(_: *@This(), _: Io, _: Allocator, _: Request, _: *Io.Reader, wr: *Io.Writer) !void {
            return respond(wr, 200, "text/plain", "ok\n");
        }
    };
    var h: H = .{};
    var server = Server(H).init(gpa, &h, .{ .port = port });
    var listen_task = io.async(Server(H).listenTask, .{ &server, io });
    defer {
        server.stop(io);
        _ = listen_task.cancel(io);
    }
    const addr: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(port) };

    // A TLS ClientHello's shape: a handshake record header, then bytes with no
    // newline. More of them than any pool has slots.
    var hello: [600]u8 = @splat(0x42);
    hello[0..5].* = .{ 0x16, 0x03, 0x01, 0x02, 0x53 };
    var tls: [8]Io.net.Stream = undefined;
    for (&tls) |*t| {
        var tries: u8 = 0;
        t.* = while (tries < 50) : (tries += 1) {
            break addr.connect(io, .{ .mode = .stream }) catch {
                Io.sleep(io, Io.Duration.fromMilliseconds(10), .real) catch {};
                continue;
            };
        } else return error.ServerNeverCameUp;
        var wbuf: [64]u8 = undefined;
        var wr = t.writer(io, &wbuf);
        try wr.interface.writeAll(&hello);
        try wr.interface.flush();
    }
    defer for (&tls) |*t| t.close(io);

    // Each is closed by the server rather than left hanging. Closing with
    // the greeting unread sends a reset, which the client reads as a failure;
    // an empty end of stream is as good.
    for (&tls) |*t| {
        var rbuf: [64]u8 = undefined;
        var rd = t.reader(io, &rbuf);
        const got = rd.interface.allocRemaining(gpa, .limited(64)) catch |err| switch (err) {
            error.ReadFailed => continue,
            else => return err,
        };
        defer gpa.free(got);
        try testing.expectEqual(@as(usize, 0), got.len);
    }

    // And plain HTTP is still served.
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var wbuf: [128]u8 = undefined;
    var wr = stream.writer(io, &wbuf);
    try wr.interface.writeAll("GET / HTTP/1.1\r\n\r\n");
    try wr.interface.flush();
    var rbuf: [256]u8 = undefined;
    var rd = stream.reader(io, &rbuf);
    const resp = try rd.interface.allocRemaining(gpa, .limited(256));
    defer gpa.free(resp);
    try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
}

test "Server: bind reports a port already taken, and the holder keeps serving" {
    const port: u16 = 18096;
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const H = struct {
        pub fn handle(_: *@This(), _: Io, _: Allocator, _: Request, _: *Io.Reader, wr: *Io.Writer) !void {
            return respond(wr, 200, "text/plain", "first\n");
        }
    };
    var h: H = .{};
    var first = Server(H).init(gpa, &h, .{ .port = port });
    try first.bind(io);
    var task = io.async(Server(H).listenTask, .{ &first, io });
    defer {
        first.stop(io);
        _ = task.cancel(io);
    }

    var second = Server(H).init(gpa, &h, .{ .port = port });
    try testing.expectError(error.AddressInUse, second.bind(io));

    const addr: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(port) };
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var wbuf: [64]u8 = undefined;
    var wr = stream.writer(io, &wbuf);
    try wr.interface.writeAll("GET / HTTP/1.1\r\n\r\n");
    try wr.interface.flush();
    var rbuf: [256]u8 = undefined;
    var rd = stream.reader(io, &rbuf);
    const resp = try rd.interface.allocRemaining(gpa, .limited(256));
    defer gpa.free(resp);
    try testing.expect(std.mem.endsWith(u8, resp, "first\n"));
}

test "Server: a real loopback request reaches the handler with its peer" {
    // A real `Threaded` Io: `init_single_threaded` has no async machinery, so
    // the accept loop would never run beside this test's own client.
    const port: u16 = 18098;
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const H = struct {
        loopback_seen: std.atomic.Value(bool) = .init(false),
        pub fn handle(h: *@This(), _: Io, _: Allocator, req: Request, _: *Io.Reader, wr: *Io.Writer) !void {
            if (req.peer == .ip4 and req.peer.ip4.bytes[0] == 127) h.loopback_seen.store(true, .release);
            if (std.mem.eql(u8, req.path, "/hello")) return respond(wr, 200, "text/plain", "hi\n");
            return respond(wr, 404, "text/plain", "no\n");
        }
    };
    var h: H = .{};
    var server = Server(H).init(gpa, &h, .{ .port = port, .allow = isPrivate });
    var listen_task = io.async(Server(H).listenTask, .{ &server, io });
    defer {
        server.stop(io);
        _ = listen_task.cancel(io);
    }

    const addr: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(port) };
    var tries: u8 = 0;
    var stream: Io.net.Stream = while (tries < 50) : (tries += 1) {
        break addr.connect(io, .{ .mode = .stream }) catch {
            Io.sleep(io, Io.Duration.fromMilliseconds(10), .real) catch {};
            continue;
        };
    } else return error.ServerNeverCameUp;
    defer stream.close(io);

    var wbuf: [256]u8 = undefined;
    var wr = stream.writer(io, &wbuf);
    try wr.interface.writeAll("GET /hello HTTP/1.1\r\nHost: x\r\n\r\n");
    try wr.interface.flush();
    var rbuf: [1024]u8 = undefined;
    var rd = stream.reader(io, &rbuf);
    const resp = try rd.interface.allocRemaining(gpa, .limited(1024));
    defer gpa.free(resp);
    try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.endsWith(u8, resp, "hi\n"));
    try testing.expect(h.loopback_seen.load(.acquire));
}
