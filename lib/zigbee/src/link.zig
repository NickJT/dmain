//! Everything between the device path and the EZSP client, owned by one
//! struct: the serial port, its buffers, the reader/writer over it, the ASH
//! transport, and the handshake result.
//!
//! **Why this exists**: all of it used to be `main()` locals, which is fine
//! for a process that dies on any transport error — and hub did. Recovery
//! has to re-handshake or reopen the port *mid-session*, which
//! means something must own these pieces and be able to rebuild them in
//! place. That owner is `Link`. This piece is a pure refactor: no behavior
//! change, verified by an identical boot against the real radio.
//!
//! **Init-in-place is mandatory, not stylistic.** `Ash.Transport` holds
//! pointers into `reader`/`writer`, which live inside this struct — so the
//! struct must already sit at its final address before `open` runs. Hence
//! `var link: Link = undefined; try link.open(io, path, baud);` rather than
//! a `Link.open(...) !Link` returning by value: returning would copy the
//! struct to the caller's address and leave `transport` pointing into the
//! dead temporary. `Coordinator` is unaffected — it still holds only an
//! `*Ezsp.Client`, and `Ezsp.Client` holds a `*Transport` whose address is
//! stable for as long as the `Link` is.
const std = @import("std");
const Io = std.Io;

const Serial = @import("serial");
const Ash = @import("ash");

/// What the engine loop should do about a transport error.
pub const ErrorAction = enum {
    /// The link is broken but the process isn't: re-handshake or reopen.
    recover,
    /// Not a link problem. Let it out — a crash with a stack trace beats a
    /// daemon that hides a logic bug behind a reconnect loop forever.
    propagate,
};

/// Classifies a `pollOnce` error. Deliberately a small allowlist: anything
/// not named here propagates, so a new error type gets a loud failure rather
/// than being silently swallowed into a retry loop.
///
/// **`.recover` is for "the wire lied or went away":**
///   - `UnexpectedFrame` — an NCP ASH ERROR frame, the wedge hub's predecessor hit under
///     button-mash load;
///   - `ReadFailed`/`WriteFailed`/`EndOfStream` — the fd died under us: USB
///     unplug, re-enumeration, a hub glitch;
///   - `HandshakeTimeout` — the NCP stopped answering RST.
///
/// **Everything else propagates**, for two different reasons:
///   - `ExchangeTimeout`/`CallbackTimeout`/`UnexpectedResponse` are already
///     handled benignly at their call sites ("command was sent, response
///     lost under load" — see main.zig's rules drain). They reach here only
///     from `pollOnce` itself, where they mean something stranger than a
///     busy radio, and recovering on them would reset the NCP every time a
///     dial spin buried a response.
///   - `FrameTooShort`/`BufferTooSmall`/OOM are logic bugs. **Note the
///     2026-07-16 lesson**: `BufferTooSmall` DID fire in normal use, but the
///     cause was an EZSP response-matching bug (the NCP echoing our own
///     command back), not a buffer that was too small — and the fix belonged
///     in `ezsp.zig`'s matcher, not here. Neither `.recover` (pointless
///     radio reset) nor `.propagate` (a dead daemon at 2am) would have been
///     the right answer for it. If one of these starts firing in the field,
///     that's the signal to go find the real bug — not to reclassify it.
pub fn classifyTransportError(err: anyerror) ErrorAction {
    return switch (err) {
        error.UnexpectedFrame,
        error.ReadFailed,
        error.WriteFailed,
        error.EndOfStream,
        error.HandshakeTimeout,
        => .recover,
        else => .propagate,
    };
}

/// Classifies a failed **heartbeat** (`Ezsp.Client.nop`), which needs a
/// different rule from `classifyTransportError`.
///
/// The timeouts that are benign from `pollOnce` — a busy radio burying a
/// response under a dial-spin flood — are NOT benign here, because the
/// heartbeat only fires after a stretch of complete silence. A radio with
/// nothing to say that then fails to answer "are you there?" is not busy;
/// it's gone or wedged. Treating those as `.recover` is the whole point of
/// probing.
pub fn classifyHeartbeatError(err: anyerror) ErrorAction {
    return switch (err) {
        error.ExchangeTimeout, error.CallbackTimeout, error.UnexpectedResponse => .recover,
        else => classifyTransportError(err),
    };
}

/// How long to wait before the next recovery attempt, given how many have
/// already failed. 1s, 2s, 5s, 10s, then 30s forever.
///
/// It never gives up: a USB radio that's been unplugged may be plugged back
/// in tomorrow, and this is a house's light switches — quietly retrying
/// every 30s until someone notices is strictly better than exiting and
/// leaving the lights dead until a human reads a log. The 30s floor keeps a
/// permanently-absent radio from spinning the CPU or flooding the log.
pub fn backoffMs(failures: u32) i64 {
    return switch (failures) {
        0 => 0, // nothing has failed yet: first attempt is immediate
        1 => 1_000,
        2 => 2_000,
        3 => 5_000,
        4 => 10_000,
        else => 30_000,
    };
}

pub const Link = struct {
    io: Io,
    path: []const u8,
    baud: u32,
    port: Serial.Port,
    // Sized as they were when they were main() locals — the ASH transport
    // caps EZSP frames at 140 bytes, so 2048 of read buffering is many
    // frames' worth, and writes are one frame at a time.
    read_buf: [2048]u8,
    write_buf: [64]u8,
    reader: Io.File.Reader,
    writer: Io.File.Writer,
    transport: Ash.Transport,
    hs: Ash.HandshakeResult,
    /// Is `port`'s fd currently open? Tracked explicitly because the fd has
    /// to be closed BEFORE a reopen (the port is exclusive — see serial.zig's
    /// TIOCEXCL — so we can't hold both), which creates a window where
    /// `port` holds a stale handle. If the reopen then fails (device still
    /// unplugged), that window becomes permanent until the next attempt, and
    /// closing a closed fd is `EBADF` — which Zig's `Io` treats as a
    /// use-after-free and PANICS on in debug builds. Found by pulling the
    /// real cable (2026-07-17): hub died on the third recovery attempt.
    port_open: bool = false,

    /// Opens the port and completes the ASH handshake, leaving a transport
    /// ready for an `Ezsp.Client`. See the module comment for why this
    /// initializes in place rather than returning a `Link`.
    pub fn open(self: *Link, io: Io, path: []const u8, baud: u32) !void {
        self.io = io;
        self.path = path;
        self.baud = baud;
        self.port_open = false;
        self.port = try Serial.Port.open(io, path, .{ .baud = baud });
        self.port_open = true;
        errdefer self.closePort();
        try self.wireUp();
    }

    /// Closes the port if it's open, and only then. **Idempotent on
    /// purpose**: every failure path in `reconnect` can leave the fd already
    /// closed, and a second `close(2)` on it returns `EBADF`, which Zig's
    /// `Io` calls a use-after-free and panics on. Recovery retries forever
    /// by design, so "close it again" is a routine event here, not an error.
    fn closePort(self: *Link) void {
        if (!self.port_open) return;
        self.port.close(self.io);
        self.port_open = false;
    }

    /// (Re)builds reader/writer/transport over the currently-open port and
    /// handshakes. Split out because `open` and `reconnect` need exactly
    /// the same sequence over a different fd.
    fn wireUp(self: *Link) !void {
        self.writer = self.port.writer(self.io, &self.write_buf);
        self.reader = self.port.reader(self.io, &self.read_buf);
        self.hs = try Ash.handshake(&self.reader.interface, &self.writer.interface);
        self.transport = Ash.Transport.init(&self.reader.interface, &self.writer.interface);
    }

    /// The wedge fast path (the first recovery attempt): RST over the
    /// existing fd, then rebuild the transport **in place**.
    ///
    /// `Ash.Transport.init` zeroes `tx_seq`/`rx_seq`/`rejecting` and builds
    /// a fresh `FrameReader`, so re-assigning the value is a complete
    /// protocol-level reset — and because it's assigned through the same
    /// address, `&self.transport` stays valid and the `Ezsp.Client` holding
    /// it needs no rebuild.
    ///
    /// The ASH RST resets the NCP itself, so a caller must follow this with
    /// the full EZSP re-init (version → config → endpoints → networkInit):
    /// the NCP's endpoint registration and config live in RAM only. The
    /// network survives in NVM.
    pub fn rehandshake(self: *Link) !void {
        self.hs = try Ash.handshake(&self.reader.interface, &self.writer.interface);
        self.transport = Ash.Transport.init(&self.reader.interface, &self.writer.interface);
    }

    /// The device-gone path: the USB device disappeared or re-enumerated,
    /// so the fd itself is dead and no amount of RST will help. Closes
    /// (best-effort — the close may well fail on a vanished device, which
    /// is not a reason to give up) and opens the path again from scratch.
    ///
    /// **One attempt only.** Backoff and retry scheduling belong to the
    /// caller's recovery state machine, so that the engine loop keeps
    /// ticking between attempts rather than blocking here.
    pub fn reconnect(self: *Link) !void {
        // Close first, unconditionally: the port is exclusive, so the old fd
        // must be gone before the new open can succeed. Both steps below are
        // failure paths that must leave `port_open` HONEST, or the next
        // attempt double-closes and panics (see `port_open`).
        self.closePort();
        self.port = try Serial.Port.open(self.io, self.path, .{ .baud = self.baud });
        self.port_open = true;
        errdefer self.closePort();
        try self.wireUp();
    }

    pub fn close(self: *Link) void {
        self.closePort();
    }
};

/// The recovery state machine's *decisions*, with no IO in them: given the
/// clock, what should the loop do right now? `main.zig` owns the acting
/// (and the actual `Link`), this owns the when — which is what makes the
/// escalation testable by stepping a fake clock rather than by unplugging a
/// radio forty times.
pub const Recovery = struct {
    failures: u32 = 0,
    next_attempt_ms: i64 = 0,
    /// Log sparsely: the first failure, then roughly every 30s. A radio
    /// that's been unplugged for the weekend must not write 200k lines.
    last_reported_ms: i64 = 0,

    pub const Step = enum {
        /// Not due yet — tick the console/TUI and come back.
        wait,
        /// First attempt: RST over the existing fd. The port is usually
        /// still fine for an ASH wedge (the NCP is confused, not gone).
        try_rehandshake,
        /// The fd itself is suspect: close and reopen the path.
        try_reconnect,
    };

    pub fn begin(self: *Recovery, now_ms: i64) void {
        self.failures = 0;
        self.next_attempt_ms = now_ms; // try immediately
        self.last_reported_ms = now_ms;
    }

    pub fn decide(self: *const Recovery, now_ms: i64) Step {
        if (now_ms < self.next_attempt_ms) return .wait;
        return if (self.failures == 0) .try_rehandshake else .try_reconnect;
    }

    pub fn recordFailure(self: *Recovery, now_ms: i64) void {
        self.failures += 1;
        self.next_attempt_ms = now_ms + backoffMs(self.failures);
    }

    /// Whether this failure is worth a log line (first one, then ~every 30s).
    pub fn shouldReport(self: *Recovery, now_ms: i64) bool {
        if (self.failures <= 1) return true;
        if (now_ms - self.last_reported_ms >= 30_000) {
            self.last_reported_ms = now_ms;
            return true;
        }
        return false;
    }
};

test "reconnect can fail repeatedly without double-closing the fd" {
    // The exact shape that killed hub on the real rig (2026-07-17): pull the
    // cable, and every reconnect attempt closes the port and then fails to
    // reopen it. Attempt N+1 must not close the fd attempt N already closed
    // — `EBADF` is a use-after-free to Zig's `Io`, and it panics on it.
    //
    // A nonexistent path IS an unplugged device as far as `open` is
    // concerned, which makes the failure reproducible without hardware —
    // the regression this test exists for needs no radio, only the honesty
    // of `port_open`.
    const io = std.testing.io;
    var link: Link = undefined;
    try std.testing.expectError(error.FileNotFound, link.open(io, "/nonexistent/hub-test-radio", 460800));
    // open() failed, so nothing is open — and close() must be a no-op, not
    // a close of whatever `port` happens to contain.
    try std.testing.expect(!link.port_open);
    link.close();

    // Now the recovery loop's actual behaviour: attempt after attempt, each
    // closing-then-failing-to-open. Before the fix this panicked on the
    // second one.
    var attempt: u8 = 0;
    while (attempt < 5) : (attempt += 1) {
        try std.testing.expectError(error.FileNotFound, link.reconnect());
        try std.testing.expect(!link.port_open);
    }
    link.close(); // still a no-op; still not a double close
}

test "classifyTransportError: a small allowlist recovers, everything else propagates" {
    // The wire lied or went away.
    try std.testing.expectEqual(ErrorAction.recover, classifyTransportError(error.UnexpectedFrame));
    try std.testing.expectEqual(ErrorAction.recover, classifyTransportError(error.ReadFailed));
    try std.testing.expectEqual(ErrorAction.recover, classifyTransportError(error.WriteFailed));
    try std.testing.expectEqual(ErrorAction.recover, classifyTransportError(error.EndOfStream));
    try std.testing.expectEqual(ErrorAction.recover, classifyTransportError(error.HandshakeTimeout));

    // Already handled benignly at their call sites; recovering on these
    // would reset the NCP every time a dial spin buried a response.
    try std.testing.expectEqual(ErrorAction.propagate, classifyTransportError(error.ExchangeTimeout));
    try std.testing.expectEqual(ErrorAction.propagate, classifyTransportError(error.CallbackTimeout));
    try std.testing.expectEqual(ErrorAction.propagate, classifyTransportError(error.UnexpectedResponse));

    // Logic bugs: die loudly rather than hide in a retry loop.
    try std.testing.expectEqual(ErrorAction.propagate, classifyTransportError(error.FrameTooShort));
    try std.testing.expectEqual(ErrorAction.propagate, classifyTransportError(error.BufferTooSmall));
    try std.testing.expectEqual(ErrorAction.propagate, classifyTransportError(error.OutOfMemory));

    // An error nobody has thought about yet must NOT be silently retried.
    try std.testing.expectEqual(ErrorAction.propagate, classifyTransportError(error.SomethingNobodyHasSeenYet));
}

test "classifyHeartbeatError: silence-then-no-answer means gone, not busy" {
    // The difference that matters: from pollOnce these mean "a flood buried
    // the response" and are handled benignly at their call sites. From a
    // heartbeat — sent only after a stretch of total silence — they mean the
    // NCP isn't answering at all.
    try std.testing.expectEqual(ErrorAction.recover, classifyHeartbeatError(error.ExchangeTimeout));
    try std.testing.expectEqual(ErrorAction.recover, classifyHeartbeatError(error.CallbackTimeout));
    try std.testing.expectEqual(ErrorAction.recover, classifyHeartbeatError(error.UnexpectedResponse));
    try std.testing.expectEqual(ErrorAction.propagate, classifyTransportError(error.ExchangeTimeout)); // ...unlike here

    // The rest of the rules are shared — including that a logic bug still dies.
    try std.testing.expectEqual(ErrorAction.recover, classifyHeartbeatError(error.WriteFailed));
    try std.testing.expectEqual(ErrorAction.recover, classifyHeartbeatError(error.EndOfStream));
    try std.testing.expectEqual(ErrorAction.propagate, classifyHeartbeatError(error.BufferTooSmall));
}

test "backoffMs escalates 1/2/5/10s then flattens at 30s forever" {
    try std.testing.expectEqual(@as(i64, 0), backoffMs(0)); // first attempt is immediate
    try std.testing.expectEqual(@as(i64, 1_000), backoffMs(1));
    try std.testing.expectEqual(@as(i64, 2_000), backoffMs(2));
    try std.testing.expectEqual(@as(i64, 5_000), backoffMs(3));
    try std.testing.expectEqual(@as(i64, 10_000), backoffMs(4));
    try std.testing.expectEqual(@as(i64, 30_000), backoffMs(5));
    try std.testing.expectEqual(@as(i64, 30_000), backoffMs(6));
    try std.testing.expectEqual(@as(i64, 30_000), backoffMs(9999)); // a radio gone for the weekend
}

test "Recovery: rehandshake first, then reconnect, with the backoff stepped on a fake clock" {
    var r: Recovery = .{};
    var now: i64 = 1_000_000;
    r.begin(now);

    // Attempt 0 is immediate, and is the cheap one: RST over the existing
    // fd, since an ASH wedge means a confused NCP, not a missing one.
    try std.testing.expectEqual(Recovery.Step.try_rehandshake, r.decide(now));

    // It failed. Now we wait 1s, and from here on the fd itself is suspect.
    r.recordFailure(now);
    try std.testing.expectEqual(Recovery.Step.wait, r.decide(now));
    try std.testing.expectEqual(Recovery.Step.wait, r.decide(now + 999));
    now += 1_000;
    try std.testing.expectEqual(Recovery.Step.try_reconnect, r.decide(now));

    // Fail again: 2s, then 5s, then 10s.
    r.recordFailure(now);
    try std.testing.expectEqual(Recovery.Step.wait, r.decide(now + 1_999));
    now += 2_000;
    try std.testing.expectEqual(Recovery.Step.try_reconnect, r.decide(now));
    r.recordFailure(now);
    now += 5_000;
    try std.testing.expectEqual(Recovery.Step.try_reconnect, r.decide(now));
    r.recordFailure(now);
    now += 10_000;
    try std.testing.expectEqual(Recovery.Step.try_reconnect, r.decide(now));

    // And from here it flattens: a radio that never comes back retries
    // every 30s forever rather than giving up on the house's lights.
    r.recordFailure(now);
    try std.testing.expectEqual(Recovery.Step.wait, r.decide(now + 29_999));
    now += 30_000;
    try std.testing.expectEqual(Recovery.Step.try_reconnect, r.decide(now));

    // A success resets the escalation: the next wedge starts cheap again.
    r.begin(now);
    try std.testing.expectEqual(Recovery.Step.try_rehandshake, r.decide(now));
}

test "Recovery.shouldReport: first failure, then ~every 30s — not 200k lines over a weekend" {
    var r: Recovery = .{};
    var now: i64 = 0;
    r.begin(now);

    r.recordFailure(now);
    try std.testing.expect(r.shouldReport(now)); // the first one always
    r.recordFailure(now);
    try std.testing.expect(!r.shouldReport(now)); // then quiet
    now += 29_000;
    try std.testing.expect(!r.shouldReport(now));
    now += 1_500;
    try std.testing.expect(r.shouldReport(now)); // ~30s later, one line
    try std.testing.expect(!r.shouldReport(now)); // and quiet again
}

test "Semantic Check" {
    std.testing.refAllDecls(@This());
}
