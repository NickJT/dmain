const std = @import("std");
const Io = std.Io;

// ASH (Asynchronous Serial Host) protocol framing, per Silicon Labs UG101 and
// cross-checked against the bellows reference implementation
// (https://github.com/zigpy/bellows/blob/dev/bellows/ash.py).

const FLAG: u8 = 0x7E;
const ESCAPE: u8 = 0x7D;
const XON: u8 = 0x11;
const XOFF: u8 = 0x13;
const SUBSTITUTE: u8 = 0x18;
const CANCEL: u8 = 0x1A;

const CONTROL_RST: u8 = 0xC0;
const CONTROL_RSTACK: u8 = 0xC1;
const CONTROL_ERROR: u8 = 0xC2;

// Max EZSP payload we support inside a DATA frame. Generous for the
// getEui64/getNodeId/getNetworkParameters/getKey responses this tool needs.
const MAX_EZSP_PAYLOAD = 140;
// control(1) + payload + crc(2)
const MAX_CONTENT = 1 + MAX_EZSP_PAYLOAD + 2;
// Worst case every content byte gets escaped, plus trailing flag.
const MAX_WIRE = MAX_CONTENT * 2 + 1;

fn isReserved(b: u8) bool {
    return switch (b) {
        FLAG, ESCAPE, XON, XOFF, SUBSTITUTE, CANCEL => true,
        else => false,
    };
}

/// CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, MSB-first, no reflect/xorout).
/// Equivalent to Python's `binascii.crc_hqx(data, 0xFFFF)`, which is what ASH specifies.
fn crc16(data: []const u8) u16 {
    var crc: u16 = 0xFFFF;
    for (data) |byte| {
        crc ^= @as(u16, byte) << 8;
        var i: u8 = 0;
        while (i < 8) : (i += 1) {
            if (crc & 0x8000 != 0) {
                crc = (crc << 1) ^ 0x1021;
            } else {
                crc = crc << 1;
            }
        }
    }
    return crc;
}

fn stuff(data: []const u8, out: []u8) !usize {
    var n: usize = 0;
    for (data) |b| {
        if (isReserved(b)) {
            if (n + 2 > out.len) {
                std.log.warn("BufferTooSmall@ash.stuff/escaped: n={d} out={d} data={d}", .{ n, out.len, data.len });
                return error.BufferTooSmall;
            }
            out[n] = ESCAPE;
            out[n + 1] = b ^ 0x20;
            n += 2;
        } else {
            if (n + 1 > out.len) {
                std.log.warn("BufferTooSmall@ash.stuff/plain: n={d} out={d} data={d}", .{ n, out.len, data.len });
                return error.BufferTooSmall;
            }
            out[n] = b;
            n += 1;
        }
    }
    return n;
}

fn unstuff(data: []const u8, out: []u8) !usize {
    var n: usize = 0;
    var escaped = false;
    for (data) |b| {
        if (escaped) {
            const byte = b ^ 0x20;
            if (!isReserved(byte)) return error.InvalidEscape;
            if (n >= out.len) {
                std.log.warn("BufferTooSmall@ash.unstuff/escaped: n={d} out={d} data={d}", .{ n, out.len, data.len });
                return error.BufferTooSmall;
            }
            out[n] = byte;
            n += 1;
            escaped = false;
        } else if (b == ESCAPE) {
            escaped = true;
        } else {
            if (n >= out.len) {
                std.log.warn("BufferTooSmall@ash.unstuff/plain: n={d} out={d} data={d}", .{ n, out.len, data.len });
                return error.BufferTooSmall;
            }
            out[n] = b;
            n += 1;
        }
    }
    return n;
}

/// XORs `data` in place with the ASH PRBS byte sequence (seed 0x42, LFSR
/// tap 0xB8), applied fresh from the start of the sequence every call. Self
/// inverse, so the same function (de)randomizes DATA frame EZSP payloads.
fn randomizeInPlace(data: []u8) void {
    var rand: u8 = 0x42;
    for (data) |*b| {
        b.* ^= rand;
        if (rand & 1 == 0) {
            rand >>= 1;
        } else {
            rand = (rand >> 1) ^ 0xB8;
        }
    }
}

/// Builds a stuffed, CRC'd, flag-terminated frame from `content` (control byte
/// plus any payload, CRC-less, already randomized if applicable) into `out`.
/// Returns the full wire slice.
fn buildFrame(content: []const u8, out: []u8) ![]const u8 {
    var raw: [MAX_CONTENT]u8 = undefined;
    if (content.len + 2 > raw.len) {
        std.log.warn("BufferTooSmall@ash.buildFrame/raw: content={d} raw={d}", .{ content.len, raw.len });
        return error.BufferTooSmall;
    }
    std.mem.copyForwards(u8, raw[0..content.len], content);
    const crc = crc16(content);
    raw[content.len] = @truncate(crc >> 8);
    raw[content.len + 1] = @truncate(crc & 0xFF);

    const n = try stuff(raw[0 .. content.len + 2], out);
    if (n + 1 > out.len) {
        std.log.warn("BufferTooSmall@ash.buildFrame/flag: n={d} out={d}", .{ n, out.len });
        return error.BufferTooSmall;
    }
    out[n] = FLAG;
    return out[0 .. n + 1];
}

pub fn buildRst(out: []u8) ![]const u8 {
    return buildFrame(&.{CONTROL_RST}, out);
}

fn dataControlByte(frm_num: u3, re_tx: bool, ack_num: u3) u8 {
    return (@as(u8, frm_num) << 4) | (@as(u8, @intFromBool(re_tx)) << 3) | @as(u8, ack_num);
}

fn ackControlByte(ack_num: u3) u8 {
    return 0x80 | @as(u8, ack_num);
}

fn nakControlByte(ack_num: u3) u8 {
    return 0xA0 | @as(u8, ack_num);
}

fn isDataControl(c: u8) bool {
    return c & 0x80 == 0;
}
fn isAckControl(c: u8) bool {
    return c & 0xE0 == 0x80;
}
fn isNakControl(c: u8) bool {
    return c & 0xE0 == 0xA0;
}

/// Builds a DATA frame carrying `ezsp_payload`, randomized per the ASH spec.
/// `scratch` is working space (must hold 1 + ezsp_payload.len bytes).
fn buildDataFrame(frm_num: u3, re_tx: bool, ack_num: u3, ezsp_payload: []const u8, scratch: []u8, out: []u8) ![]const u8 {
    if (1 + ezsp_payload.len > scratch.len) {
        std.log.warn("BufferTooSmall@ash.buildDataFrame: payload={d} scratch={d}", .{ ezsp_payload.len, scratch.len });
        return error.BufferTooSmall;
    }
    scratch[0] = dataControlByte(frm_num, re_tx, ack_num);
    std.mem.copyForwards(u8, scratch[1 .. 1 + ezsp_payload.len], ezsp_payload);
    randomizeInPlace(scratch[1 .. 1 + ezsp_payload.len]);
    return buildFrame(scratch[0 .. 1 + ezsp_payload.len], out);
}

const ReadFrameResult = struct {
    control: u8,
    payload_len: usize,
};

/// Scans raw bytes for ASH frame boundaries. ALL scan state is *fields*,
/// not locals of `readFrame`, on purpose — two separate real bugs came from
/// state living inside a single call:
/// 1. `raw`/`raw_len`/`discarding` (the frame accumulator): a frame can
///    straddle two separate reads; a call-local accumulator silently
///    discarded the first half when the call returned empty-handed, and the
///    next call started misaligned with the frame boundary.
/// 2. `chunk`/`chunk_len`/`chunk_pos` (the unprocessed read tail): when a
///    frame completed mid-chunk, returning it from inside a loop over a
///    call-local chunk threw away every byte after the FLAG — which, under
///    bursty traffic, is the NEXT frame's head. The next call then started
///    mid-frame and failed CRC. Invisible under light traffic (one frame
///    per read), devastating during joins/discovery: the log filled with
///    "CRC mismatch" warnings that looked like wire noise but were us
///    discarding our own buffered bytes, and the resulting ASH
///    retransmissions added more traffic and more loss.
const FrameReader = struct {
    reader: *Io.Reader,
    raw: [MAX_WIRE]u8 = undefined,
    raw_len: usize = 0,
    discarding: bool = false,
    chunk: [256]u8 = undefined,
    chunk_len: usize = 0,
    chunk_pos: usize = 0,

    fn init(reader: *Io.Reader) FrameReader {
        return .{ .reader = reader };
    }

    /// Reads raw bytes looking for one complete ASH frame, handling CANCEL
    /// (discard in-progress frame), SUBSTITUTE (discard until next flag),
    /// and XON/XOFF (ignored) per the ASH framing spec. Drains greedily:
    /// only an EMPTY read (the ~1s VTIME timeout with no data) counts
    /// against `max_polls` — at 460800 baud the NCP streams ~46 bytes/ms,
    /// so pacing reads would let the OS serial buffer overflow during
    /// callback bursts. Returns null if no frame completes within
    /// `max_polls` empty reads; any bytes accumulated so far (and any
    /// unprocessed chunk tail) remain buffered for the next call. On
    /// success, copies the frame's payload (control byte stripped, CRC
    /// stripped, still randomized if it's a DATA frame) into `payload_out`.
    fn readFrame(self: *FrameReader, payload_out: []u8, max_polls: u8) !?ReadFrameResult {
        var poll: u8 = 0;
        while (poll < max_polls) {
            if (self.chunk_pos >= self.chunk_len) {
                const n = try self.reader.readSliceShort(&self.chunk);
                if (n == 0) {
                    poll += 1;
                    continue;
                }
                self.chunk_len = n;
                self.chunk_pos = 0;
            }
            while (self.chunk_pos < self.chunk_len) {
                const b = self.chunk[self.chunk_pos];
                self.chunk_pos += 1;
                switch (b) {
                    CANCEL => {
                        self.raw_len = 0;
                        self.discarding = false;
                    },
                    SUBSTITUTE => {
                        self.raw_len = 0;
                        self.discarding = true;
                    },
                    XON, XOFF => {},
                    FLAG => {
                        if (self.discarding) {
                            self.discarding = false;
                            continue;
                        }
                        if (self.raw_len == 0) continue; // idle flag byte between frames

                        var content: [MAX_CONTENT]u8 = undefined;
                        const clen = unstuff(self.raw[0..self.raw_len], &content) catch {
                            // Malformed escape sequence — almost certainly wire
                            // noise, not a protocol bug. Discard and keep
                            // listening rather than treating one bad frame as fatal.
                            std.log.warn("readFrame: discarding frame with invalid byte-stuffing", .{});
                            self.raw_len = 0;
                            continue;
                        };
                        self.raw_len = 0;
                        if (clen < 3) {
                            std.log.warn("readFrame: discarding frame too short after unstuffing ({d} bytes)", .{clen});
                            continue;
                        }

                        const body = content[0 .. clen - 2];
                        const recv_crc = (@as(u16, content[clen - 2]) << 8) | content[clen - 1];
                        if (crc16(body) != recv_crc) {
                            std.log.warn("readFrame: discarding frame with CRC mismatch", .{});
                            continue;
                        }

                        const payload_len = body.len - 1;
                        if (payload_len > payload_out.len) {
                            std.log.warn("BufferTooSmall@ash.readFrame: payload_len={d} payload_out={d} control=0x{x:0>2}", .{ payload_len, payload_out.len, body[0] });
                            return error.BufferTooSmall;
                        }
                        std.mem.copyForwards(u8, payload_out[0..payload_len], body[1..]);
                        return .{ .control = body[0], .payload_len = payload_len };
                    },
                    else => {
                        if (!self.discarding) {
                            if (self.raw_len >= self.raw.len) {
                                std.log.warn("readFrame: discarding oversized in-progress frame (no flag seen in {d} bytes)", .{self.raw.len});
                                self.raw_len = 0;
                            } else {
                                self.raw[self.raw_len] = b;
                                self.raw_len += 1;
                            }
                        }
                    },
                }
            }
        }
        return null;
    }
};

/// NCP reset/error codes carried in RSTACK and ERROR frames. Values from
/// bellows' `NcpResetCode`; non-exhaustive since the NCP can report values
/// this list doesn't enumerate.
pub const ResetCode = enum(u8) {
    unknown_reason = 0x00,
    external = 0x01,
    power_on = 0x02,
    watchdog = 0x03,
    assert_reset = 0x06,
    bootloader = 0x09,
    software = 0x0B,
    exceeded_max_ack_timeout = 0x51,
    unknown_em3xx_error = 0x80,
    _,

    pub fn name(self: ResetCode) []const u8 {
        return switch (self) {
            .unknown_reason => "unknown reason",
            .external => "external reset",
            .power_on => "power-on reset",
            .watchdog => "watchdog reset",
            .assert_reset => "assert",
            .bootloader => "bootloader",
            .software => "software reset",
            .exceeded_max_ack_timeout => "exceeded max ACK timeout",
            .unknown_em3xx_error => "unknown EM3xx error",
            else => "unrecognized",
        };
    }
};

pub const HandshakeResult = struct {
    version: u8,
    reset_code: ResetCode,
    is_error_frame: bool,
};

/// Sends RST and waits for RSTACK (or ERROR), resending on timeout up to 5
/// attempts. `reader`/`writer` should wrap a serial port already configured
/// for raw byte I/O with a bounded per-read timeout (see serial.zig).
pub fn handshake(reader: *Io.Reader, writer: *Io.Writer) !HandshakeResult {
    var fr = FrameReader.init(reader);
    var attempt: u8 = 0;
    while (attempt < 5) : (attempt += 1) {
        var rst_buf: [16]u8 = undefined;
        const rst = try buildRst(&rst_buf);
        try writer.writeAll(rst);
        try writer.flush();

        var payload: [2]u8 = undefined;
        if (try fr.readFrame(&payload, 3)) |result| {
            switch (result.control) {
                CONTROL_RSTACK => return .{ .version = payload[0], .reset_code = @fromBackingInt(@intCast(payload[1])), .is_error_frame = false },
                CONTROL_ERROR => return .{ .version = payload[0], .reset_code = @fromBackingInt(@intCast(payload[1])), .is_error_frame = true },
                // Stray leftover frame (e.g. from a prior session) — ignore and retry rather than aborting outright.
                else => {},
            }
        }
    }
    return error.HandshakeTimeout;
}

/// Reliable request/response transport for EZSP frames over ASH DATA frames.
/// ASH's sliding window (TX_K) is 1 for this protocol, so at most one
/// unacknowledged frame is ever outstanding — this keeps the state machine
/// to a simple send-and-wait rather than full pipelining.
pub const Transport = struct {
    frame_reader: FrameReader,
    writer: *Io.Writer,
    tx_seq: u3 = 0,
    rx_seq: u3 = 0,
    /// ASH "reject condition" (UG101): set after NAKing an out-of-sequence
    /// frame, cleared when the expected in-sequence frame finally arrives.
    /// While set, further out-of-sequence frames are dropped WITHOUT
    /// re-NAKing — one NAK per loss event. Without this, a retransmission
    /// burst of N frames triggers N NAKs, each restarting the NCP's
    /// retransmission from scratch: a feedback storm we hit for real.
    rejecting: bool = false,

    pub fn init(reader: *Io.Reader, writer: *Io.Writer) Transport {
        return .{ .frame_reader = FrameReader.init(reader), .writer = writer };
    }

    /// Waits for and consumes the next incoming DATA frame — sending its
    /// ACK and advancing rx_seq — regardless of what EZSP command it
    /// carries. Bare ACKs are absorbed (and tx_seq advanced) without being
    /// returned; a NAK or a poll timeout both yield null so the caller can
    /// decide how to react. Shared by `exchange` (waiting for a specific
    /// command's reply) and `receiveCallback` (waiting for an unsolicited
    /// NCP callback frame, e.g. stackStatusHandler).
    fn receiveData(self: *Transport, out: []u8, max_polls: u8) !?usize {
        var poll_attempt: u8 = 0;
        while (poll_attempt < 3) : (poll_attempt += 1) {
            var payload_buf: [MAX_EZSP_PAYLOAD]u8 = undefined;
            const result = (try self.frame_reader.readFrame(&payload_buf, max_polls)) orelse return null;

            if (isAckControl(result.control) or isDataControl(result.control)) {
                const acked: u3 = @intCast(result.control & 0x07);
                if (acked == self.tx_seq +% 1) self.tx_seq +%= 1;
            }

            if (isAckControl(result.control)) continue; // bare ack; keep polling for the DATA response
            if (isNakControl(result.control)) return null; // rejected; caller decides how to react

            if (isDataControl(result.control)) {
                const frm: u3 = @intCast((result.control >> 4) & 0x07);
                // Classify in 3-bit circular space: `behind` = how far frm
                // trails rx_seq. ASH's sliding window is at most 5 (K=5),
                // so 1..5 behind can only be a duplicate retransmission of
                // frames we already delivered and ACKed — the NCP's ~800ms
                // ACK timer fired while a burst sat in our buffer waiting
                // for the caller's next poll. Re-ACK so it stops resending,
                // but don't redeliver. (Originally only `behind == 1` was
                // treated as a duplicate; a multi-frame duplicate burst got
                // misread as "lost frames ahead" and NAKed, triggering a
                // pointless retransmission ping-pong that delayed or
                // starved real traffic — observed for real as ZCL Default
                // Responses never arriving under load, then again at
                // exactly behind=5 once the window was widened only to 4.)
                const behind = self.rx_seq -% frm;
                if (behind >= 1 and behind <= 5) {
                    var ack_scratch: [8]u8 = undefined;
                    const ack = try buildFrame(&.{ackControlByte(self.rx_seq)}, &ack_scratch);
                    try self.writer.writeAll(ack);
                    try self.writer.flush();
                    continue;
                }
                if (frm != self.rx_seq) {
                    // Out-of-sequence frame: a frame we expected was LOST
                    // (usually CRC-corrupted on the wire — the discard shows
                    // up as a "CRC mismatch" warning just before this). The
                    // old behavior here resynced rx_seq forward and carried
                    // on, but ASH ACKs are cumulative, so that silently
                    // acknowledged the lost frame — the NCP never resent it,
                    // and if it carried a command response or a ZDO reply,
                    // that data was gone for good (real symptom: sendUnicast
                    // responses vanishing under bursty traffic, crashing
                    // discovery with UnexpectedResponse). Correct ASH
                    // behavior (and what bellows does): reject with a NAK
                    // carrying the sequence we actually need, making the
                    // NCP retransmit from there — but only ONE NAK per loss
                    // event (see `rejecting`), or the NAKs themselves storm.
                    // Don't deliver this frame — the retransmission will
                    // include it again in order.
                    if (!self.rejecting) {
                        std.log.warn("receiveData: out-of-sequence frame frm={d} (expected {d}) — NAKing for retransmission of the lost frame", .{ frm, self.rx_seq });
                        self.rejecting = true;
                        var nak_scratch: [8]u8 = undefined;
                        const nak = try buildFrame(&.{nakControlByte(self.rx_seq)}, &nak_scratch);
                        try self.writer.writeAll(nak);
                        try self.writer.flush();
                    }
                    continue;
                }
                self.rejecting = false; // in-sequence frame ends any reject condition

                randomizeInPlace(payload_buf[0..result.payload_len]);
                self.rx_seq +%= 1;

                var ack_scratch: [8]u8 = undefined;
                const ack = try buildFrame(&.{ackControlByte(self.rx_seq)}, &ack_scratch);
                try self.writer.writeAll(ack);
                try self.writer.flush();

                if (result.payload_len > out.len) {
                    std.log.warn("BufferTooSmall@ash.receiveData: payload_len={d} out={d} control=0x{x:0>2}", .{ result.payload_len, out.len, result.control });
                    return error.BufferTooSmall;
                }
                std.mem.copyForwards(u8, out[0..result.payload_len], payload_buf[0..result.payload_len]);
                return result.payload_len;
            }

            return error.UnexpectedFrame;
        }
        return null;
    }

    /// Sends `ezsp_cmd` in a DATA frame and returns the NCP's EZSP response
    /// payload (de-randomized), copied into `out`.
    pub fn exchange(self: *Transport, ezsp_cmd: []const u8, out: []u8) ![]const u8 {
        var re_tx = false;
        var attempt: u8 = 0;
        while (attempt < 5) : (attempt += 1) {
            var scratch: [1 + MAX_EZSP_PAYLOAD]u8 = undefined;
            var wire: [MAX_WIRE]u8 = undefined;
            const frame = try buildDataFrame(self.tx_seq, re_tx, self.rx_seq, ezsp_cmd, &scratch, &wire);
            try self.writer.writeAll(frame);
            try self.writer.flush();
            re_tx = true; // if we loop back around to resend, mark it as a retransmit

            if (try self.receiveData(out, 3)) |len| return out[0..len];
        }
        return error.ExchangeTimeout;
    }

    /// Waits for the next incoming DATA frame without having just sent a
    /// request — for asynchronous NCP callbacks (e.g. stackStatusHandler
    /// after formNetwork). `max_rounds` bounds how many poll cycles (each
    /// up to ~3s: receiveData's internal 3 ACK-skip attempts × a single
    /// ~1s readFrame poll) to try.
    pub fn receiveCallback(self: *Transport, out: []u8, max_rounds: u8) ![]const u8 {
        var round: u8 = 0;
        while (round < max_rounds) : (round += 1) {
            if (try self.receiveData(out, 1)) |len| return out[0..len];
        }
        return error.CallbackTimeout;
    }
};

test "crc16 matches the CRC-16/CCITT-FALSE known-answer test vector" {
    try std.testing.expectEqual(@as(u16, 0x29B1), crc16("123456789"));
}

test "stuff/unstuff round-trips data containing every reserved byte" {
    const data = [_]u8{ 0x00, FLAG, ESCAPE, XON, XOFF, SUBSTITUTE, CANCEL, 0xFF };
    var stuffed: [32]u8 = undefined;
    const slen = try stuff(&data, &stuffed);

    for (stuffed[0..slen]) |b| {
        if (b != ESCAPE) try std.testing.expect(!isReserved(b) or b == ESCAPE);
    }

    var back: [32]u8 = undefined;
    const ulen = try unstuff(stuffed[0..slen], &back);
    try std.testing.expectEqualSlices(u8, &data, back[0..ulen]);
}

test "randomizeInPlace is self-inverse" {
    const original = [_]u8{ 0x00, 0x00, 0xFF, 0x11, 0x22, 0x33, 0x00, 0x00 };
    var data = original;
    randomizeInPlace(&data);
    try std.testing.expect(!std.mem.eql(u8, &data, &original));
    randomizeInPlace(&data);
    try std.testing.expectEqualSlices(u8, &original, &data);
}

test "buildRst produces a frame that readFrame parses back to control 0xC0" {
    var buf: [16]u8 = undefined;
    const rst = try buildRst(&buf);
    try std.testing.expectEqual(CONTROL_RST, rst[0]);
    try std.testing.expectEqual(FLAG, rst[rst.len - 1]);

    var r = Io.Reader.fixed(rst);
    var fr = FrameReader.init(&r);
    var payload: [4]u8 = undefined;
    const result = (try fr.readFrame(&payload, 1)).?;
    try std.testing.expectEqual(CONTROL_RST, result.control);
    try std.testing.expectEqual(@as(usize, 0), result.payload_len);
}

test "handshake parses a canned RSTACK response (power-on reset)" {
    var frame_buf: [16]u8 = undefined;
    const rstack = try buildFrame(&.{ CONTROL_RSTACK, 0x02, @backingInt(ResetCode.power_on) }, &frame_buf);

    var r = Io.Reader.fixed(rstack);
    var discard: [64]u8 = undefined;
    var w = Io.Writer.fixed(&discard);

    const result = try handshake(&r, &w);
    try std.testing.expectEqual(@as(u8, 2), result.version);
    try std.testing.expectEqual(ResetCode.power_on, result.reset_code);
    try std.testing.expect(!result.is_error_frame);
}

test "readFrame recovers after a CANCEL byte discards a partial frame" {
    var buf: [16]u8 = undefined;
    const rst = try buildRst(&buf);

    var garbage_then_rst: [24]u8 = undefined;
    garbage_then_rst[0] = 0x01;
    garbage_then_rst[1] = 0x02;
    garbage_then_rst[2] = CANCEL;
    std.mem.copyForwards(u8, garbage_then_rst[3..], rst);

    var r = Io.Reader.fixed(garbage_then_rst[0 .. 3 + rst.len]);
    var fr = FrameReader.init(&r);
    var payload: [4]u8 = undefined;
    const result = (try fr.readFrame(&payload, 1)).?;
    try std.testing.expectEqual(CONTROL_RST, result.control);
}

test "readFrame discards a CRC-corrupted frame and recovers the next valid one" {
    var good: [16]u8 = undefined;
    const rst = try buildRst(&good);

    // A well-formed-looking but corrupted frame (bad CRC bytes), followed by
    // a real one. Simulates real-world wire noise, which is expected to
    // happen occasionally on a live serial link and must not be fatal.
    var corrupted_then_rst: [32]u8 = undefined;
    corrupted_then_rst[0] = CONTROL_RST;
    corrupted_then_rst[1] = 0xDE;
    corrupted_then_rst[2] = 0xAD;
    corrupted_then_rst[3] = FLAG;
    std.mem.copyForwards(u8, corrupted_then_rst[4..], rst);

    var r = Io.Reader.fixed(corrupted_then_rst[0 .. 4 + rst.len]);
    var fr = FrameReader.init(&r);
    var payload: [4]u8 = undefined;
    const result = (try fr.readFrame(&payload, 1)).?;
    try std.testing.expectEqual(CONTROL_RST, result.control);
}

test "FrameReader reassembles a frame split across two separate reads" {
    var buf: [16]u8 = undefined;
    const rst = try buildRst(&buf);
    try std.testing.expect(rst.len > 3); // sanity: enough bytes to split before the trailing flag

    // Split well before the trailing FLAG, simulating a frame arriving in
    // two separate underlying reads (e.g. two different poll cycles).
    const split = 2;
    var r1 = Io.Reader.fixed(rst[0..split]);
    var fr = FrameReader.init(&r1);

    var payload: [4]u8 = undefined;
    // First read call sees no FLAG at all — must return null, not lose the bytes.
    try std.testing.expectEqual(@as(?ReadFrameResult, null), try fr.readFrame(&payload, 1));

    var r2 = Io.Reader.fixed(rst[split..]);
    fr.reader = &r2; // simulates the next poll's underlying read

    // Second call must complete using the bytes buffered from the first.
    const result = (try fr.readFrame(&payload, 1)).?;
    try std.testing.expectEqual(CONTROL_RST, result.control);
}

test "Transport.exchange sends a DATA frame and parses a piggybacked DATA response" {
    // Simulate an NCP that immediately echoes back a DATA frame acking our
    // frame 0 (ack_num=1) and sending its own frame 0 (frm_num=0) containing
    // a canned "response" payload.
    const cmd = [_]u8{ 0xAA, 0xBB, 0xCC };
    var response_payload = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    randomizeInPlace(&response_payload); // NCP would randomize before sending

    var content: [8]u8 = undefined;
    content[0] = dataControlByte(0, false, 1); // frm_num=0, ack our frame 0
    std.mem.copyForwards(u8, content[1..5], &response_payload);

    var ncp_frame_buf: [24]u8 = undefined;
    const ncp_frame = try buildFrame(content[0..5], &ncp_frame_buf);

    var r = Io.Reader.fixed(ncp_frame);
    var write_buf: [64]u8 = undefined;
    var w = Io.Writer.fixed(&write_buf);

    var transport = Transport.init(&r, &w);
    var out: [16]u8 = undefined;
    const response = try transport.exchange(&cmd, &out);

    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0x22, 0x33, 0x44 }, response);
    try std.testing.expectEqual(@as(u3, 1), transport.tx_seq);
    try std.testing.expectEqual(@as(u3, 1), transport.rx_seq);
}

test "FrameReader preserves the second of two frames arriving in one read" {
    // Regression: when a frame completed mid-chunk, the bytes after its
    // FLAG (the next frame's head) used to be thrown away with the
    // call-local chunk, so back-to-back frames in one read lost the second
    // one — the dominant source of "CRC mismatch" noise under bursty
    // traffic. Both frames must now come out of consecutive calls.
    var f1_buf: [16]u8 = undefined;
    const f1 = try buildFrame(&.{ ackControlByte(1), 0x55 }, &f1_buf);
    var f2_buf: [16]u8 = undefined;
    const f2 = try buildFrame(&.{ ackControlByte(2), 0x66 }, &f2_buf);

    var both: [32]u8 = undefined;
    std.mem.copyForwards(u8, both[0..f1.len], f1);
    std.mem.copyForwards(u8, both[f1.len .. f1.len + f2.len], f2);

    var r = Io.Reader.fixed(both[0 .. f1.len + f2.len]);
    var fr = FrameReader.init(&r);

    var payload: [8]u8 = undefined;
    const first = (try fr.readFrame(&payload, 1)).?;
    try std.testing.expectEqual(ackControlByte(1), first.control);
    try std.testing.expectEqualSlices(u8, &.{0x55}, payload[0..first.payload_len]);

    // Second frame must be served from the retained chunk tail — no new
    // read needed (the fixed reader is already drained past it anyway).
    const second = (try fr.readFrame(&payload, 1)).?;
    try std.testing.expectEqual(ackControlByte(2), second.control);
    try std.testing.expectEqualSlices(u8, &.{0x66}, payload[0..second.payload_len]);
}

test "receiveData NAKs an out-of-sequence frame instead of resyncing past the lost one" {
    // NCP sends frame 2 while we still expect frame 0 (frames 0 and 1 were
    // lost, e.g. CRC-corrupted). The transport must NOT deliver frame 2 or
    // advance rx_seq (that would cumulatively ACK the lost frames away) —
    // it must reject with a NAK carrying rx_seq=0 so the NCP retransmits.
    var payload = [_]u8{ 0xDE, 0xAD };
    randomizeInPlace(&payload);
    var content: [4]u8 = undefined;
    content[0] = dataControlByte(2, false, 0); // frm_num=2, expected 0
    std.mem.copyForwards(u8, content[1..3], &payload);

    var ncp_frame_buf: [16]u8 = undefined;
    const ncp_frame = try buildFrame(content[0..3], &ncp_frame_buf);

    var r = Io.Reader.fixed(ncp_frame);
    var write_buf: [64]u8 = undefined;
    var w = Io.Writer.fixed(&write_buf);

    var transport = Transport.init(&r, &w);
    var out: [16]u8 = undefined;
    // Reader runs dry after the one bad frame -> receiveData returns null
    // (poll exhaustion), NOT the out-of-sequence payload.
    const result = transport.receiveData(&out, 1) catch |err| blk: {
        // Io.Reader.fixed errors with EndOfStream once drained; either
        // null or that error is acceptable "nothing delivered" behavior.
        try std.testing.expectEqual(error.EndOfStream, err);
        break :blk null;
    };
    try std.testing.expectEqual(@as(?usize, null), result);
    try std.testing.expectEqual(@as(u3, 0), transport.rx_seq); // NOT advanced

    // The transport must have written exactly one NAK frame with ack_num=0.
    var nak_scratch: [8]u8 = undefined;
    const expected_nak = try buildFrame(&.{nakControlByte(0)}, &nak_scratch);
    try std.testing.expectEqualSlices(u8, expected_nak, w.buffered());
}

test "the wedge seam: an NCP ERROR frame surfaces as UnexpectedFrame, and Transport.init resets in place" {
    // **The one recovery path hardware can't be asked to produce on demand.**
    // Cable pulls are repeatable; a genuine ASH wedge is not — a
    // button-mash is the only known trigger and it's opportunistic. So the seam gets tested here instead: the
    // exact frame the NCP sends when it wedges, and the exact reset
    // `Link.rehandshake` performs afterwards.
    //
    // Half one: an ERROR frame (0xC2) arriving where a DATA frame belongs is
    // what `main.zig` classifies as `.recover` and starts recovery on.
    const cmd = [_]u8{ 0xAA, 0xBB, 0xCC };
    var content: [3]u8 = undefined;
    content[0] = CONTROL_ERROR;
    content[1] = 0x02; // version
    content[2] = 0x51; // reset code — the NCP telling us why it gave up
    var ncp_frame_buf: [24]u8 = undefined;
    const ncp_frame = try buildFrame(&content, &ncp_frame_buf);

    var r = Io.Reader.fixed(ncp_frame);
    var write_buf: [64]u8 = undefined;
    var w = Io.Writer.fixed(&write_buf);
    var transport = Transport.init(&r, &w);

    var out: [16]u8 = undefined;
    try std.testing.expectError(error.UnexpectedFrame, transport.exchange(&cmd, &out));

    // Dirty the protocol state, as a real session would have.
    transport.tx_seq = 5;
    transport.rx_seq = 3;
    transport.rejecting = true;

    // Half two: `Link.rehandshake` re-assigns the Transport **value through
    // the same address** after its RST. That has to be a complete protocol
    // reset — sequence numbers restart with the NCP's — and the address must
    // survive, because `Ezsp.Client` holds a `*Transport` and is NOT rebuilt.
    const addr_before = &transport;
    var r2 = Io.Reader.fixed(&.{});
    transport = Transport.init(&r2, &w);

    try std.testing.expectEqual(addr_before, &transport); // the client's pointer stays valid
    try std.testing.expectEqual(@as(u3, 0), transport.tx_seq);
    try std.testing.expectEqual(@as(u3, 0), transport.rx_seq);
    try std.testing.expect(!transport.rejecting);
    // A fresh FrameReader too: no half-parsed bytes from the wedged session
    // can leak into the new one.
    try std.testing.expectEqual(@as(usize, 0), transport.frame_reader.raw_len);
    try std.testing.expect(!transport.frame_reader.discarding);
}

test "Semantic Check" {
    std.testing.refAllDecls(@This());
}
