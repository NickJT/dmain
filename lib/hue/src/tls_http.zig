//! The transport: a TLS connection to a Hue bridge, and just enough HTTP to
//! use it — a request writer, a response-head consumer, and a line reader that
//! understands chunked transfer-encoding.
//!
//! Depends on `tls_client` and `std`. It knows nothing about resources, events
//! or rules, and must stay that way: `sse_events` is pure precisely so that a
//! caller can test parsing without a socket.
//!
//! ## Why a bridge needs its own TLS client
//!
//! A Hue bridge accepts **exactly one** cipher suite,
//! `ECDHE-ECDSA-AES128-GCM-SHA256`, with an ECDSA P-256 certificate. Stock
//! `std.crypto.tls.Client` never offers that suite, so the handshake fails with
//! `handshake_failure` before any HTTP happens. The `tls_client` module is std's
//! client with the ECDSA suites added at build time — see `tools/patch-tls`.
//!
//! ## A bridge proves who it is before it is sent anything
//!
//! `connect` completes only if the certificate chains to one of Signify's two
//! private roots (`hue-roots.pem`, as Hue publishes them) and its common name is
//! the id the caller configured. Neither fact comes from the bridge, and a
//! request can only be written to a connection `connect` has returned, so the
//! application key never reaches anything else that answers at that address.
//!
//! **The id is the name, not the address.** The certificate carries no address,
//! so `host` says where to connect and the id says who must be there. The id
//! can't be derived from the bridge's MAC. Its `GET /api/config` reports it
//! unauthenticated, so read that once and keep it: fetching it on each connect
//! would ask an impostor who it is.
//!
//! **A chain of any length works.** A bridge is signed directly by the root
//! today, and Hue expects intermediates later. Each one must be a CA; see
//! `cert_issuer`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Certificate = std.crypto.Certificate;
const net = std.Io.net;
const TlsClient = @import("tls_client");

/// Signify's roots, current then secondary. A root that std can't parse is
/// dropped without a word, so a test holds this to two.
const hue_roots_pem = @embedFile("hue-roots.pem");

/// A live TLS session plus everything whose address the session captured.
///
/// Heap-allocated as one unit because `TlsClient` holds pointers *into*
/// `stream_reader`/`stream_writer`: moving or copying this struct after
/// `connect` would leave the client reading through dangling interfaces. That
/// is also why `connect` returns a pointer rather than a value.
pub const Connection = struct {
    gpa: Allocator,
    io: std.Io,
    stream: net.Stream,
    stream_reader: net.Stream.Reader,
    stream_writer: net.Stream.Writer,
    tls: TlsClient,
    buffers: [4][]u8,

    pub fn close(self: *Connection) void {
        self.stream.close(self.io);
        for (self.buffers) |b| self.gpa.free(b);
        const gpa = self.gpa;
        gpa.destroy(self);
    }
};

/// How much decrypted body to keep buffered. One SSE message from a busy
/// bridge runs to a few kilobytes; 128 KB is slack, and it is the read buffer
/// rather than a per-message limit.
const plaintext_buffer_len = 128 * 1024;

pub const ConnectError = error{
    /// `host` was not an IP literal. There is no resolver here on purpose —
    /// a bridge is configured by address, and a DNS dependency in an
    /// always-on appliance is a failure mode with nothing to gain.
    BadAddress,
    /// `bridge_id` was not sixteen hex digits. Refused here rather than left to
    /// the name check, whose wildcard rule should never meet a configured value.
    BadBridgeId,
    OutOfMemory,
} || std.Io.Cancelable;

/// A bridge id: sixteen hex digits, in either case.
pub fn isBridgeId(id: []const u8) bool {
    if (id.len != 16) return false;
    for (id) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// PEM to a bundle std can check against. Caller owns it.
fn loadRoots(gpa: Allocator, pem: []const u8, now_sec: i64) !Certificate.Bundle {
    const begin = "-----BEGIN CERTIFICATE-----";
    const end = "-----END CERTIFICATE-----";
    const decoder = std.base64.standard.decoderWithIgnore(" \t\r\n");

    var bundle: Certificate.Bundle = .empty;
    errdefer bundle.deinit(gpa);

    var at: usize = 0;
    while (std.mem.findPos(u8, pem, at, begin)) |found| {
        const start = found + begin.len;
        const stop = std.mem.findPos(u8, pem, start, end) orelse return error.BadRoots;
        at = stop + end.len;

        const encoded = pem[start..stop];
        try bundle.bytes.ensureUnusedCapacity(gpa, decoder.calcSizeUpperBound(encoded.len));
        const decoded_start: u32 = @intCast(bundle.bytes.items.len);
        bundle.bytes.items.len += try decoder.decode(bundle.bytes.unusedCapacitySlice(), encoded);
        try bundle.parseCert(gpa, decoded_start, now_sec);
    }
    return bundle;
}

/// The handshake, over whatever carries it, so that tests can drive the real
/// client from scripted bytes. Fails unless the server proves it is `bridge_id`
/// under `roots_pem`.
fn handshake(
    gpa: Allocator,
    io: std.Io,
    input: *std.Io.Reader,
    output: *std.Io.Writer,
    read_buffer: []u8,
    write_buffer: []u8,
    bridge_id: []const u8,
    roots_pem: []const u8,
    now: std.Io.Timestamp,
) !TlsClient {
    // Only read during the handshake, so one per connection costs nothing that
    // matters and leaves nothing shared between them.
    var roots = try loadRoots(gpa, roots_pem, now.toSeconds());
    defer roots.deinit(gpa);
    var roots_lock: std.Io.RwLock = .init;

    var entropy: [TlsClient.Options.entropy_len]u8 = undefined;
    io.random(&entropy);

    return TlsClient.init(input, output, .{
        .host = .{ .explicit = bridge_id },
        .ca = .{ .bundle = .{ .gpa = gpa, .io = io, .lock = &roots_lock, .bundle = &roots } },
        .read_buffer = read_buffer,
        .write_buffer = write_buffer,
        .entropy = &entropy,
        .realtime_now = now,
        // The event stream has no Content-Length and never ends normally, so a
        // truncation check has nothing to check against; framing is the chunk
        // layer's job.
        .allow_truncation_attacks = true,
    });
}

/// Open a TCP connection to `host`:`port` and complete a TLS handshake with the
/// bridge whose id is `bridge_id`, refusing anything else that answers there.
/// Caller owns the result and must `close()` it.
pub fn connect(gpa: Allocator, io: std.Io, host: []const u8, port: u16, bridge_id: []const u8) !*Connection {
    const addr = net.IpAddress.parse(host, port) catch return error.BadAddress;
    if (!isBridgeId(bridge_id)) return error.BadBridgeId;

    const conn = try gpa.create(Connection);
    errdefer gpa.destroy(conn);

    // Sized as std.http.Client sizes them: the socket side must hold a whole
    // ciphertext record, and the TLS read buffer holds that plus room for
    // decrypted bytes the caller has not consumed yet.
    var buffers: [4][]u8 = undefined;
    var allocated: usize = 0;
    errdefer for (buffers[0..allocated]) |b| gpa.free(b);
    for ([_]usize{
        TlsClient.min_buffer_len,
        TlsClient.min_buffer_len,
        TlsClient.min_buffer_len + plaintext_buffer_len,
        TlsClient.min_buffer_len,
    }, 0..) |len, i| {
        buffers[i] = try gpa.alloc(u8, len);
        allocated += 1;
    }

    const stream = try addr.connect(io, .{ .mode = .stream });
    errdefer stream.close(io);

    conn.* = .{
        .gpa = gpa,
        .io = io,
        .stream = stream,
        .stream_reader = stream.reader(io, buffers[0]),
        .stream_writer = stream.writer(io, buffers[1]),
        .tls = undefined,
        .buffers = buffers,
    };

    conn.tls = try handshake(
        gpa,
        io,
        &conn.stream_reader.interface,
        &conn.stream_writer.interface,
        buffers[2],
        buffers[3],
        bridge_id,
        hue_roots_pem,
        std.Io.Timestamp.now(io, .real),
    );
    return conn;
}

/// Write an HTTP request with the headers a bridge expects.
///
/// **Both writers are flushed, and both are needed.** `tls.writer` encrypts
/// into the socket writer's buffer; without the second flush the request sits
/// in memory and the connection looks alive but silent — which is exactly how
/// it presents, and it costs an afternoon to find.
pub fn writeRequest(
    conn: *Connection,
    method: []const u8,
    path: []const u8,
    host: []const u8,
    key: []const u8,
    accept: []const u8,
) !void {
    try conn.tls.writer.print(
        "{s} {s} HTTP/1.1\r\n" ++
            "Host: {s}\r\n" ++
            "hue-application-key: {s}\r\n" ++
            "Accept: {s}\r\n" ++
            "Cache-Control: no-cache\r\n" ++
            "Connection: keep-alive\r\n\r\n",
        .{ method, path, host, key, accept },
    );
    try conn.tls.writer.flush();
    try conn.stream_writer.interface.flush();
}

/// Result of consuming an HTTP response's status line + headers.
pub const ResponseHead = struct {
    status_ok: bool,
    chunked: bool,
    /// The status line's code, or 0 if it didn't read as one.
    status: u16 = 0,
};

/// What the Bridge said when it refused a request, kept so a caller can say why
/// rather than only that it failed.
pub const Reply = struct {
    status: u16 = 0,
    buf: [1024]u8 = undefined,
    len: usize = 0,

    pub fn body(self: *const Reply) []const u8 {
        return self.buf[0..self.len];
    }

    /// "HTTP 400: …", with each CLIP v2 error's `description` joined by "; ",
    /// or the start of the body when it isn't that shape.
    pub fn describe(self: *const Reply, w: *std.Io.Writer) !void {
        try w.print("HTTP {d}", .{self.status});
        var fba_buf: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
        const Errors = struct { errors: []const struct { description: []const u8 } = &.{} };
        if (std.json.parseFromSliceLeaky(Errors, fba.allocator(), self.body(), .{ .ignore_unknown_fields = true })) |parsed| {
            for (parsed.errors, 0..) |e, i| try w.print("{s}{s}", .{ if (i == 0) ": " else "; ", e.description });
            if (parsed.errors.len > 0) return;
        } else |_| {}
        const text = std.mem.trim(u8, self.body(), " \r\n");
        if (text.len > 0) try w.print(": {s}", .{text[0..@min(text.len, 200)]});
    }
};

/// Seam between the chunk-decoding logic and its byte source. Defaults to the
/// live TLS session; tests substitute a fake over an in-memory buffer so the
/// state machine can be exercised with no socket. Returns bytes read, or 0 on
/// graceful EOF.
pub const RawReadFn = *const fn (ctx: ?*anyopaque, buf: []u8) anyerror!usize;

fn defaultTlsRead(ctx: ?*anyopaque, buf: []u8) !usize {
    const conn: *Connection = @ptrCast(@alignCast(ctx.?));
    // `peekGreedy(1)` rather than `readSliceShort`: the latter blocks until it
    // has filled `buf` or hit end-of-stream, which on an event stream means
    // waiting for 8 KB of events before returning the first one. This asks for
    // one byte and takes whatever arrived with it.
    const avail = conn.tls.reader.peekGreedy(1) catch |err| switch (err) {
        error.EndOfStream => return 0,
        else => return err,
    };
    const n = @min(avail.len, buf.len);
    @memcpy(buf[0..n], avail[0..n]);
    conn.tls.reader.toss(n);
    return n;
}

/// Buffered, stateful reader over a TLS connection. Strips HTTP chunked
/// transfer-encoding framing when `chunked` is set.
///
/// **The bridge's event stream is chunked**, which is not obvious from the
/// name `text/event-stream`: keepalives arrive as `6\r\n: hi\n\n\r\n` and
/// payloads as `197\r\nid: …\ndata: […]\n\n\r\n`. A reader that treats the
/// stream as raw lines sees chunk-length digits as content and never finds a
/// `data:` line.
///
/// Ported from an earlier Hue monitor's `tls_http.zig` — the logic and its tests came across
/// unchanged; only the byte source below it differs.
pub const TlsReader = struct {
    conn: *Connection,
    read_raw: RawReadFn = defaultTlsRead,
    buf: [8192]u8 = undefined,
    pos: usize = 0,
    end: usize = 0,

    chunked: bool = false,
    chunk_remaining: usize = 0,
    chunk_state: enum { chunk_header, chunk_body, chunk_cr, chunk_lf } = .chunk_header,

    /// Opaque context handed to `read_raw`. Split out so tests can point the
    /// seam at their own buffer without constructing a Connection.
    ctx: ?*anyopaque = null,

    pub fn init(conn: *Connection) TlsReader {
        return .{ .conn = conn, .ctx = conn };
    }

    fn readRawByte(self: *TlsReader) !?u8 {
        if (self.pos >= self.end) {
            const n = try self.read_raw(self.ctx, &self.buf);
            if (n == 0) return null;
            self.pos = 0;
            self.end = n;
        }
        const b = self.buf[self.pos];
        self.pos += 1;
        return b;
    }

    /// One logical byte, with chunk boundaries removed on the fly.
    fn readByte(self: *TlsReader) !?u8 {
        if (!self.chunked) return try self.readRawByte();

        while (true) {
            switch (self.chunk_state) {
                .chunk_header => {
                    var hex_val: usize = 0;
                    var reading_ext = false;
                    while (true) {
                        const b = (try self.readRawByte()) orelse return null;
                        if (b == '\r') continue;
                        if (b == '\n') break;
                        if (reading_ext) continue; // skip extension text
                        const digit: usize = switch (b) {
                            '0'...'9' => b - '0',
                            'a'...'f' => b - 'a' + 10,
                            'A'...'F' => b - 'A' + 10,
                            ';', ' ' => {
                                reading_ext = true;
                                continue;
                            },
                            else => return error.MalformedChunkHeader,
                        };
                        hex_val = (hex_val << 4) | digit;
                    }
                    if (hex_val == 0) return null; // terminal chunk
                    self.chunk_remaining = hex_val;
                    self.chunk_state = .chunk_body;
                },
                .chunk_body => {
                    if (self.chunk_remaining == 0) {
                        self.chunk_state = .chunk_cr;
                        continue;
                    }
                    const b = (try self.readRawByte()) orelse return error.UnexpectedEof;
                    self.chunk_remaining -= 1;
                    return b;
                },
                .chunk_cr => {
                    const b = (try self.readRawByte()) orelse return error.UnexpectedEof;
                    if (b != '\r') return error.ExpectedChunkCr;
                    self.chunk_state = .chunk_lf;
                },
                .chunk_lf => {
                    const b = (try self.readRawByte()) orelse return error.UnexpectedEof;
                    if (b != '\n') return error.ExpectedChunkLf;
                    self.chunk_state = .chunk_header;
                },
            }
        }
    }

    /// One line including its '\n', into `out`. Returns length; 0 means EOF.
    pub fn readLine(self: *TlsReader, out: []u8) !usize {
        var i: usize = 0;
        while (i < out.len) {
            const b = try self.readByte() orelse return i;
            out[i] = b;
            i += 1;
            if (b == '\n') return i;
        }
        return error.LineTooLong;
    }

    /// Everything remaining, until EOF or the terminal chunk. Caller owns it.
    pub fn readToEnd(self: *TlsReader, gpa: Allocator) ![]u8 {
        var body: std.ArrayList(u8) = .empty;
        errdefer body.deinit(gpa);

        if (self.chunked) {
            while (try self.readByte()) |b| try body.append(gpa, b);
        } else {
            if (self.pos < self.end) {
                try body.appendSlice(gpa, self.buf[self.pos..self.end]);
                self.pos = self.end;
            }
            while (true) {
                const n = try self.read_raw(self.ctx, &self.buf);
                if (n == 0) break;
                try body.appendSlice(gpa, self.buf[0..n]);
            }
        }
        return try body.toOwnedSlice(gpa);
    }

    /// Consume the status line and header block, setting `chunked` from
    /// Transfer-Encoding.
    ///
    /// Reports `status_ok = false` rather than erroring on a non-200, so the
    /// caller can name the failure in its own terms. A socket that closes
    /// before the blank line *is* an error — that is a transport failure, not
    /// an HTTP answer.
    pub fn readResponseHead(self: *TlsReader, line_buf: []u8) !ResponseHead {
        var saw_200 = false;
        var chunked = false;
        var status: u16 = 0;

        while (true) {
            const n = try self.readLine(line_buf);
            if (n == 0) return error.ConnectionClosed;

            const line = std.mem.trimEnd(u8, line_buf[0..n], "\r\n");
            if (line.len == 0) break;

            if (std.mem.startsWith(u8, line, "HTTP/1.1 200") or
                std.mem.startsWith(u8, line, "HTTP/1.0 200"))
            {
                saw_200 = true;
            }
            if (status == 0 and std.mem.startsWith(u8, line, "HTTP/") and line.len >= 12)
                status = std.fmt.parseInt(u16, line[9..12], 10) catch 0;
            if (isChunkedTransfer(line)) chunked = true;
        }

        self.chunked = chunked;
        return .{ .status_ok = saw_200, .chunked = chunked, .status = status };
    }
};

/// Case-insensitive `Transfer-Encoding: chunked`. Header names are
/// case-insensitive per RFC 7230 and a bridge is not the only thing that will
/// ever answer this code.
fn isChunkedTransfer(line: []const u8) bool {
    const name = "transfer-encoding:";
    if (line.len < name.len) return false;
    for (line[0..name.len], name) |c, want| {
        if (std.ascii.toLower(c) != want) return false;
    }
    var it = std.mem.tokenizeAny(u8, line[name.len..], " ,\t");
    while (it.next()) |tok| {
        if (std.ascii.eqlIgnoreCase(tok, "chunked")) return true;
    }
    return false;
}

/// One GET, returning the whole body. Caller owns the result.
///
/// Used for the initial `/clip/v2/resource` snapshot; the event stream uses
/// `connect` + `writeRequest` + `TlsReader` directly, because it never ends.
pub fn get(
    gpa: Allocator,
    io: std.Io,
    host: []const u8,
    port: u16,
    bridge_id: []const u8,
    path: []const u8,
    key: []const u8,
) ![]u8 {
    const conn = try connect(gpa, io, host, port, bridge_id);
    defer conn.close();

    try writeRequest(conn, "GET", path, host, key, "application/json");

    var reader = TlsReader.init(conn);
    var line_buf: [1024]u8 = undefined;
    const head = try reader.readResponseHead(&line_buf);
    if (!head.status_ok) return error.HttpError;

    return try reader.readToEnd(gpa);
}

/// The request `put` sends. Separate so the framing can be tested without a bridge.
fn writePut(w: *std.Io.Writer, path: []const u8, host: []const u8, key: []const u8, body: []const u8) !void {
    return writeWithBody(w, "PUT", path, host, key, body);
}

fn writeWithBody(w: *std.Io.Writer, method: []const u8, path: []const u8, host: []const u8, key: []const u8, body: []const u8) !void {
    try w.print(
        "{s} {s} HTTP/1.1\r\n" ++
            "Host: {s}\r\n" ++
            "hue-application-key: {s}\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n\r\n" ++
            "{s}",
        .{ method, path, host, key, body.len, body },
    );
}

/// One PUT with a JSON body, on a connection of its own. Anything but a 200 is
/// `error.HttpError`, including a 207, which updated the resource and still
/// failed part of the request; `reply`, if given, then holds what the Bridge
/// said. It blocks on the network, so a caller with a deadline runs it on its
/// own task.
pub fn put(
    gpa: Allocator,
    io: std.Io,
    host: []const u8,
    port: u16,
    bridge_id: []const u8,
    path: []const u8,
    key: []const u8,
    body: []const u8,
    reply: ?*Reply,
) !void {
    return send(gpa, io, "PUT", host, port, bridge_id, path, key, body, reply);
}

/// One POST, which creates a resource: a 201 is the success, otherwise as `put`.
pub fn post(
    gpa: Allocator,
    io: std.Io,
    host: []const u8,
    port: u16,
    bridge_id: []const u8,
    path: []const u8,
    key: []const u8,
    body: []const u8,
    reply: ?*Reply,
) !void {
    return send(gpa, io, "POST", host, port, bridge_id, path, key, body, reply);
}

/// One DELETE, which removes a resource; otherwise as `put`.
pub fn delete(
    gpa: Allocator,
    io: std.Io,
    host: []const u8,
    port: u16,
    bridge_id: []const u8,
    path: []const u8,
    key: []const u8,
    reply: ?*Reply,
) !void {
    return send(gpa, io, "DELETE", host, port, bridge_id, path, key, "", reply);
}

fn send(
    gpa: Allocator,
    io: std.Io,
    method: []const u8,
    host: []const u8,
    port: u16,
    bridge_id: []const u8,
    path: []const u8,
    key: []const u8,
    body: []const u8,
    reply: ?*Reply,
) !void {
    const conn = try connect(gpa, io, host, port, bridge_id);
    defer conn.close();

    try writeWithBody(&conn.tls.writer, method, path, host, key, body);
    try conn.tls.writer.flush();
    try conn.stream_writer.interface.flush();

    var reader = TlsReader.init(conn);
    var line_buf: [1024]u8 = undefined;
    const head = try reader.readResponseHead(&line_buf);
    if (head.status_ok or (std.mem.eql(u8, method, "POST") and head.status == 201)) return;
    if (reply) |r| {
        r.status = head.status;
        r.len = 0;
        // The reason is worth having but not worth failing over.
        if (reader.readToEnd(gpa)) |text| {
            defer gpa.free(text);
            r.len = @min(text.len, r.buf.len);
            @memcpy(r.buf[0..r.len], text[0..r.len]);
        } else |_| {}
    }
    return error.HttpError;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
// The chunk state machine is the part worth testing and the part that has no
// business needing a bridge to exercise: `read_raw` is pointed at a literal
// buffer and the decoded output is asserted directly.

const testing = std.testing;

test "writePut frames its body with the right length" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writePut(&w, "/clip/v2/resource/light/x", "10.0.0.1", "abc", "{\"a\":1}");
    try testing.expectEqualStrings(
        "PUT /clip/v2/resource/light/x HTTP/1.1\r\n" ++
            "Host: 10.0.0.1\r\n" ++
            "hue-application-key: abc\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: 7\r\n" ++
            "Connection: close\r\n\r\n" ++
            "{\"a\":1}",
        w.buffered(),
    );
}

/// A fake byte source over a fixed slice, handing out `drip` bytes at a time.
/// The drip matters: a state machine that only ever sees whole chunks in one
/// read is not being tested at its boundaries, and the boundaries are where
/// framing bugs live.
const FakeSource = struct {
    data: []const u8,
    pos: usize = 0,
    drip: usize,

    fn read(ctx: ?*anyopaque, buf: []u8) anyerror!usize {
        const self: *FakeSource = @ptrCast(@alignCast(ctx.?));
        const remaining = self.data.len - self.pos;
        if (remaining == 0) return 0;
        const n = @min(@min(buf.len, self.drip), remaining);
        @memcpy(buf[0..n], self.data[self.pos..][0..n]);
        self.pos += n;
        return n;
    }
};

fn readerOver(src: *FakeSource, chunked: bool) TlsReader {
    return .{
        .conn = undefined, // never touched: read_raw is replaced below
        .read_raw = FakeSource.read,
        .ctx = src,
        .chunked = chunked,
    };
}

test "chunked: strips framing and yields the payload lines" {
    // Byte-for-byte what the bridge sent during the 2026-08-18 bring-up: a
    // keepalive comment chunk, then a real event chunk.
    const wire =
        "6\r\n: hi\n\n\r\n" ++
        "22\r\nid: 1787034207:0\ndata: [{\"x\":1}]\n\n\r\n" ++
        "0\r\n\r\n";

    for ([_]usize{ 1, 3, 8192 }) |drip| {
        var src = FakeSource{ .data = wire, .drip = drip };
        var r = readerOver(&src, true);

        var buf: [256]u8 = undefined;
        var lines: std.ArrayList([]const u8) = .empty;
        // Both defers registered before anything is appended: a failure inside
        // the read loop must still free what was collected, or a genuine
        // framing bug is reported as a leak as well and the two obscure
        // each other.
        defer lines.deinit(testing.allocator);
        defer for (lines.items) |l| testing.allocator.free(l);
        while (true) {
            const n = try r.readLine(&buf);
            if (n == 0) break;
            try lines.append(testing.allocator, try testing.allocator.dupe(u8, buf[0..n]));
        }

        try testing.expectEqual(@as(usize, 5), lines.items.len);
        try testing.expectEqualStrings(": hi\n", lines.items[0]);
        try testing.expectEqualStrings("\n", lines.items[1]);
        try testing.expectEqualStrings("id: 1787034207:0\n", lines.items[2]);
        try testing.expectEqualStrings("data: [{\"x\":1}]\n", lines.items[3]);
        try testing.expectEqualStrings("\n", lines.items[4]);
    }
}

test "chunked: a chunk boundary mid-line is invisible to the caller" {
    // The failure this guards: one logical line split across two chunks. A
    // reader that resynchronised on chunk boundaries would emit two lines.
    const wire = "5\r\ndata:\r\n7\r\n [1,2]\n\r\n0\r\n\r\n";
    var src = FakeSource{ .data = wire, .drip = 2 };
    var r = readerOver(&src, true);

    var buf: [256]u8 = undefined;
    const n = try r.readLine(&buf);
    try testing.expectEqualStrings("data: [1,2]\n", buf[0..n]);
    try testing.expectEqual(@as(usize, 0), try r.readLine(&buf));
}

test "chunked: extensions after the length are skipped" {
    const wire = "5;foo=bar\r\nhello\r\n0\r\n\r\n";
    var src = FakeSource{ .data = wire, .drip = 4 };
    var r = readerOver(&src, true);

    var buf: [64]u8 = undefined;
    const n = try r.readLine(&buf);
    try testing.expectEqualStrings("hello", buf[0..n]);
}

test "unchunked: bytes pass through untouched" {
    var src = FakeSource{ .data = "one\ntwo\n", .drip = 3 };
    var r = readerOver(&src, false);

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("one\n", buf[0..try r.readLine(&buf)]);
    try testing.expectEqualStrings("two\n", buf[0..try r.readLine(&buf)]);
    try testing.expectEqual(@as(usize, 0), try r.readLine(&buf));
}

test "readResponseHead: reads status and Transfer-Encoding" {
    const wire =
        "HTTP/1.1 200 OK\r\n" ++
        "Server: nginx\r\n" ++
        "Content-Type: text/event-stream; charset=utf-8\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "\r\n";
    var src = FakeSource{ .data = wire, .drip = 5 };
    var r = readerOver(&src, false);

    var line_buf: [512]u8 = undefined;
    const head = try r.readResponseHead(&line_buf);
    try testing.expect(head.status_ok);
    try testing.expect(head.chunked);
    // The flag must be armed for subsequent reads, not merely reported.
    try testing.expect(r.chunked);
}

test "readResponseHead: a non-200 is reported, not thrown" {
    const wire = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n";
    var src = FakeSource{ .data = wire, .drip = 7 };
    var r = readerOver(&src, false);

    var line_buf: [512]u8 = undefined;
    const head = try r.readResponseHead(&line_buf);
    try testing.expect(!head.status_ok);
    try testing.expect(!head.chunked);
}

test "readResponseHead: keeps the status code" {
    const wire = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n";
    var src = FakeSource{ .data = wire, .drip = 9 };
    var r = readerOver(&src, false);
    var line_buf: [512]u8 = undefined;
    try testing.expectEqual(@as(u16, 400), (try r.readResponseHead(&line_buf)).status);
}

test "a refusal is described by its CLIP errors, or by its body" {
    var reply: Reply = .{ .status = 400 };
    const json =
        \\{"errors":[{"description":"invalid value for configuration","error_code":"client_error"},{"description":"second"}],"data":[]}
    ;
    @memcpy(reply.buf[0..json.len], json);
    reply.len = json.len;
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try reply.describe(&w);
    try testing.expectEqualStrings("HTTP 400: invalid value for configuration; second", w.buffered());

    reply = .{ .status = 503 };
    const html = "<html>busy</html>\n";
    @memcpy(reply.buf[0..html.len], html);
    reply.len = html.len;
    w = .fixed(&buf);
    try reply.describe(&w);
    try testing.expectEqualStrings("HTTP 503: <html>busy</html>", w.buffered());
}

test "readResponseHead: a socket closing mid-headers is an error" {
    var src = FakeSource{ .data = "HTTP/1.1 200 OK\r\nServer: ngin", .drip = 6 };
    var r = readerOver(&src, false);

    var line_buf: [512]u8 = undefined;
    try testing.expectError(error.ConnectionClosed, r.readResponseHead(&line_buf));
}

// ---------------------------------------------------------------------------
// Certificate validation
// ---------------------------------------------------------------------------
// The real client, fed what a server would send: a ServerHello, a Certificate,
// and a ServerKeyExchange whose signature is nonsense.
//
// That last message is what tells accept from refuse. The client asks for a
// trusted chain before it reads the signature, so `error.SignatureVerificationFailed`
// means the chain and the name both passed, and only possession of the key stood
// between this server and the application key. Which is itself the refusal a
// replayed certificate gets: `bridge-leaf.der` is public, and it isn't enough.

const chain_trusted = error.SignatureVerificationFailed;

/// 2026-11-09. Inside every fixture's dates and the real Bridge's.
const test_now_sec: i64 = 1_794_182_400;
const test_id = "AABBCCDDEEFF0011";
const real_id = "C42996FFFEC5CBE6";
const test_roots = @embedFile("testdata/test-root.pem");

const bridge_leaf = @embedFile("testdata/bridge-leaf.der");
const leaf = @embedFile("testdata/leaf.der");
const leaf_via_intermediate = @embedFile("testdata/leaf-via-intermediate.der");
const intermediate = @embedFile("testdata/intermediate.der");
const leaf_via_not_a_ca = @embedFile("testdata/leaf-via-not-a-ca.der");
const not_a_ca = @embedFile("testdata/not-a-ca.der");
const self_signed = @embedFile("testdata/self-signed.der");
const forged_leaf = @embedFile("testdata/forged-leaf.der");

fn appendRecord(out: *std.ArrayList(u8), message_type: u8, body: []const u8) !void {
    const gpa = testing.allocator;
    const message_len: u32 = @intCast(body.len);
    const record_len: u16 = @intCast(body.len + 4);
    try out.appendSlice(gpa, &.{ 0x16, 0x03, 0x03, @truncate(record_len >> 8), @truncate(record_len) });
    try out.appendSlice(gpa, &.{ message_type, @truncate(message_len >> 16), @truncate(message_len >> 8), @truncate(message_len) });
    try out.appendSlice(gpa, body);
}

/// What a bridge would say, with the chain given. `null` leaves the Certificate
/// message out altogether.
fn serverScript(chain: ?[]const []const u8) !std.ArrayList(u8) {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    // ServerHello: TLS 1.2, the only suite a bridge has.
    const random: [32]u8 = @splat(0x42);
    const hello = [_]u8{ 0x03, 0x03 } ++ random ++ [_]u8{ 0x00, 0xC0, 0x2B, 0x00 };
    try appendRecord(&out, 2, &hello);

    if (chain) |certs| {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(gpa);
        var total: u32 = 0;
        for (certs) |c| total += @intCast(c.len + 3);
        try list.appendSlice(gpa, &.{ @truncate(total >> 16), @truncate(total >> 8), @truncate(total) });
        for (certs) |c| {
            const n: u32 = @intCast(c.len);
            try list.appendSlice(gpa, &.{ @truncate(n >> 16), @truncate(n >> 8), @truncate(n) });
            try list.appendSlice(gpa, c);
        }
        try appendRecord(&out, 11, list.items);
    }

    // ServerKeyExchange: secp256r1, an empty point, ecdsa_secp256r1_sha256, and
    // the well-formed signature r=1, s=1.
    try appendRecord(&out, 12, &.{
        0x03, 0x00, 0x17, 0x00,
        0x04, 0x03, 0x00, 0x08,
        0x30, 0x06, 0x02, 0x01,
        0x01, 0x02, 0x01, 0x01,
    });
    return out;
}

/// The handshake against that script. Never succeeds: the signature is nonsense.
fn attemptAt(id: []const u8, roots: []const u8, chain: ?[]const []const u8, at_sec: i64) !void {
    const gpa = testing.allocator;
    var script = try serverScript(chain);
    defer script.deinit(gpa);

    // The client insists on a whole record's worth of input buffer.
    const input_buf = try gpa.alloc(u8, @max(TlsClient.min_buffer_len, script.items.len));
    defer gpa.free(input_buf);
    @memcpy(input_buf[0..script.items.len], script.items);
    var input: std.Io.Reader = .fixed(input_buf);
    input.end = script.items.len;

    var discard_buf: [TlsClient.min_buffer_len]u8 = undefined;
    var output: std.Io.Writer.Discarding = .init(&discard_buf);
    const read_buffer = try gpa.alloc(u8, TlsClient.min_buffer_len);
    defer gpa.free(read_buffer);
    const write_buffer = try gpa.alloc(u8, TlsClient.min_buffer_len);
    defer gpa.free(write_buffer);

    _ = try handshake(
        gpa,
        testing.io,
        &input,
        &output.writer,
        read_buffer,
        write_buffer,
        id,
        roots,
        .{ .nanoseconds = @as(i96, at_sec) * std.time.ns_per_s },
    );
}

fn attempt(id: []const u8, roots: []const u8, chain: ?[]const []const u8) !void {
    return attemptAt(id, roots, chain, test_now_sec);
}

test "the real roots: both load" {
    var roots = try loadRoots(testing.allocator, hue_roots_pem, test_now_sec);
    defer roots.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2), roots.map.count());
}

test "a real Bridge's certificate passes, in either case of its id" {
    try testing.expectError(chain_trusted, attempt(real_id, hue_roots_pem, &.{bridge_leaf}));
    try testing.expectError(chain_trusted, attempt("c42996fffec5cbe6", hue_roots_pem, &.{bridge_leaf}));
}

test "a real Bridge's certificate is refused under any other id" {
    try testing.expectError(error.CertificateHostMismatch, attempt("C42996FFFEC5CBE7", hue_roots_pem, &.{bridge_leaf}));
}

test "a real Bridge's certificate is refused without its root" {
    try testing.expectError(error.TlsCertificateNotVerified, attempt(real_id, test_roots, &.{bridge_leaf}));
}

test "an invented chain does not pass the real roots" {
    try testing.expectError(error.TlsCertificateNotVerified, attempt(test_id, hue_roots_pem, &.{leaf}));
}

test "directly under a root: the shape a Bridge has today" {
    try testing.expectError(chain_trusted, attempt(test_id, test_roots, &.{leaf}));
}

test "through an intermediate: the shape Hue expects next" {
    try testing.expectError(chain_trusted, attempt(test_id, test_roots, &.{ leaf_via_intermediate, intermediate }));
}

test "an intermediate that was not sent leaves the chain unproven" {
    try testing.expectError(error.TlsCertificateNotVerified, attempt(test_id, test_roots, &.{leaf_via_intermediate}));
}

test "a device certificate cannot stand in for an intermediate" {
    // Signed all the way up to the root, and the signatures are all good. Only
    // the signer's basicConstraints says it had no right to sign.
    try testing.expectError(error.TlsCertificateNotVerified, attempt(test_id, test_roots, &.{ leaf_via_not_a_ca, not_a_ca }));
}

test "the right name, signed by nobody trusted" {
    try testing.expectError(error.TlsCertificateNotVerified, attempt(test_id, test_roots, &.{self_signed}));
}

test "a fake root with the real root's name" {
    try testing.expectError(error.CertificateSignatureInvalid, attempt(test_id, test_roots, &.{forged_leaf}));
}

test "no certificate at all, sent empty or skipped" {
    try testing.expectError(error.TlsCertificateNotVerified, attempt(test_id, test_roots, &.{}));
    try testing.expectError(error.TlsCertificateNotVerified, attempt(test_id, test_roots, null));
}

test "outside its dates" {
    const before: i64 = 1_577_836_800; // 2020
    const after: i64 = 2_556_144_000; // 2051: past the leaf, not the test root
    try testing.expectError(error.CertificateNotYetValid, attemptAt(test_id, test_roots, &.{leaf}, before));
    try testing.expectError(error.CertificateExpired, attemptAt(test_id, test_roots, &.{leaf}, after));
}

test "isBridgeId" {
    try testing.expect(isBridgeId(real_id));
    try testing.expect(isBridgeId("c42996fffec5cbe6"));
    try testing.expect(!isBridgeId(""));
    try testing.expect(!isBridgeId("192.168.86.36"));
    try testing.expect(!isBridgeId("C42996FFFEC5CBE"));
    try testing.expect(!isBridgeId("C42996FFFEC5CBE67"));
    try testing.expect(!isBridgeId("*.42996FFFEC5CBE"));
    try testing.expect(!isBridgeId("G42996FFFEC5CBE6"));
}

test "isChunkedTransfer: case-insensitive, and not fooled by a lookalike" {
    try testing.expect(isChunkedTransfer("Transfer-Encoding: chunked"));
    try testing.expect(isChunkedTransfer("transfer-encoding: chunked"));
    try testing.expect(isChunkedTransfer("TRANSFER-ENCODING: gzip, chunked"));
    try testing.expect(!isChunkedTransfer("Transfer-Encoding: gzip"));
    try testing.expect(!isChunkedTransfer("X-Transfer-Encoding: chunked"));
    try testing.expect(!isChunkedTransfer("Content-Type: text/chunked"));
}
