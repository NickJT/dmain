//! Raw, non-blocking terminal input, and putting the terminal back afterwards.
//!
//! **Seven copies of this existed before it was one**, in six applications, `hub`
//! among them. They agreed
//! on the mechanism and disagreed on four flags, so the flags are the caller's
//! and the mechanism is not.
//!
//! ## The trick worth knowing
//!
//! `cc[V.MIN] = 0` with `cc[V.TIME] = 0`. A `read` on the terminal then returns
//! **immediately** with however many bytes are waiting, possibly zero, instead
//! of blocking for a full line or for any input at all. No `O_NONBLOCK` and no
//! `fcntl`, and the caller's loop is free to do its own work between polls —
//! which for a dashboard means collating, and for a control panel means servicing a
//! serial port on a 100 ms cadence.
//!
//! ## Why this uses the raw syscalls and not `std.posix`
//!
//! **The reason is output rather than behaviour, and it was observed on hardware
//! (2026-09-02).** `posix.tcgetattr` maps `NOTTY` to a clean error and
//! sends every other errno to `unexpectedErrno`, which in a Debug build dumps a
//! stack trace to stderr *before* returning. A stdin that is not a terminal is an
//! ordinary condition for several callers — a tool run as `tool < /dev/null &`,
//! `hub` under launchd, a service under systemd — and **on macOS `/dev/null` answers
//! `ENODEV`, not `NOTTY`**, so a correct `catch return null` still printed nine
//! lines of trace over the program's first real output.
//!
//! So every call here goes through `posix.system.*`: any failure means "no
//! terminal to put into raw mode", which is exactly what the `?` in the return
//! type says. It also makes `restore` async-signal-safe, which `app/house/hub` needs —
//! it calls it from a panic handler, and a command-line tool from a signal handler; a
//! stack dump at either moment runs unsafe code at the worst possible time.
//!
//! `std.posix` remains the right *type* source: `posix.termios` and `posix.V` are
//! the cross-platform definitions, and nothing here touches `std.os.linux`.

const std = @import("std");
const posix = std.posix;

/// What kind of terminal the caller wants. Every default is what a full-screen
/// application wants, because four of the six callers are one; the two that read
/// ordinary lines say so.
pub const Mode = struct {
    /// Leave Ctrl-C and Ctrl-Z generating signals.
    ///
    /// **Default on, and the default is the safe one even though half the
    /// callers override it.** A program that turns signals off and then fails to
    /// decode Ctrl-C itself leaves a raw terminal that needs another window to
    /// kill. Turn it off only when there is something to protect — `hub` and
    /// `dmain admin` both have a half-typed command line — and then handle the byte.
    signals: bool = true,

    /// Leave the input translations alone: CR→NL, parity checking, 8th-bit
    /// stripping, break-as-signal and software flow control.
    ///
    /// **Default off, which is what a keystroke reader wants.** Clearing them
    /// means bytes arrive as typed — and `IXON` in particular, left on, means
    /// Ctrl-S freezes the terminal and looks like a hang. A caller reading whole
    /// *lines* wants them left on, because it wants Enter to arrive as `"\n"`
    /// rather than as a carriage return.
    translate_input: bool = false,

    /// Leave `OPOST` on, so a bare `"\n"` is still translated to `"\r\n"` on the
    /// way out.
    ///
    /// **Default off**: a full-screen application positions every write itself
    /// and prints its own `"\r\n"`. A caller that writes ordinary lines wants it
    /// on, and turning it off under one produces a staircase down the right of
    /// the screen rather than an error.
    translate_output: bool = false,

    /// Wait for at least one byte rather than returning with whatever is there.
    ///
    /// Default off — see the trick above, which is the whole point of this
    /// module. A command-line tool wants it on, reading a
    /// key at a time with nothing else to do in between.
    blocking: bool = false,
};

/// A terminal switched to raw mode, holding what it takes to switch it back.
pub const Raw = struct {
    original: posix.termios,

    /// Switch stdin to raw mode, or report that there is no terminal.
    ///
    /// **`null` rather than an error, because "nobody is at a keyboard" is not a
    /// failure** for most callers here: output piped to a file, a `--once` mode,
    /// a service under launchd or systemd. A caller that genuinely requires a
    /// terminal checks for `null` and says so in its own words.
    pub fn enable(mode: Mode) ?Raw {
        var original: posix.termios = undefined;
        if (posix.errno(posix.system.tcgetattr(posix.STDIN_FILENO, &original)) != .SUCCESS) {
            return null;
        }

        var raw = original;

        if (!mode.translate_input) {
            raw.iflag.BRKINT = false;
            raw.iflag.ICRNL = false;
            raw.iflag.INPCK = false;
            raw.iflag.ISTRIP = false;
            raw.iflag.IXON = false;
        }
        if (!mode.translate_output) raw.oflag.OPOST = false;

        // Unconditional: a program reading keys wants neither, and no caller
        // among the seven wanted otherwise.
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;

        if (!mode.signals) {
            raw.lflag.ISIG = false;
            raw.lflag.IEXTEN = false;
        }

        raw.cc[@backingInt(posix.V.MIN)] = if (mode.blocking) 1 else 0;
        raw.cc[@backingInt(posix.V.TIME)] = 0;

        if (posix.errno(posix.system.tcsetattr(posix.STDIN_FILENO, .FLUSH, &raw)) != .SUCCESS) {
            return null;
        }
        return .{ .original = original };
    }

    /// Restore the settings that were in force before `enable`.
    ///
    /// **Async-signal-safe, and deliberately.** `app/house/hub` calls this from its
    /// panic handler and a command-line tool from a signal handler; a `std.posix` wrapper
    /// could dump a stack trace there, which is non-async-signal-safe code at
    /// the worst possible moment. The result is discarded because there is
    /// nothing useful left to do about a failure to tidy up.
    pub fn restore(self: Raw) void {
        _ = posix.system.tcsetattr(posix.STDIN_FILENO, .FLUSH, &self.original);
    }
};

/// Read whatever is waiting on stdin. Never blocks once `Raw.enable` has run
/// with `blocking` off; returns an empty slice when nothing has been typed since
/// the last poll.
///
/// A read error is reported as "nothing waiting" rather than propagated. The
/// loop that calls this is a render loop, and the right response to a transient
/// read failure is to draw the same frame again.
pub fn poll(buf: []u8) []const u8 {
    const n = posix.read(posix.STDIN_FILENO, buf) catch return buf[0..0];
    return buf[0..n];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the defaults are the full-screen ones, with the safe exception" {
    // Four of the six callers are full-screen applications, so the defaults are
    // theirs. `signals` is the exception: its default is the safe value rather
    // than the common one, and the argument in `Mode` only holds while that is
    // true.
    const m: Mode = .{};
    try testing.expect(m.signals);
    try testing.expect(!m.translate_input);
    try testing.expect(!m.translate_output);
    try testing.expect(!m.blocking);
}

test "a missing terminal is null rather than an error or a stack trace" {
    // Under `zig build test` stdin is not a tty, so this is the path every
    // piped, launchd and systemd caller takes. If it ever returns non-null here,
    // the not-a-terminal detection has stopped working.
    //
    // Skipped when stdin *is* a tty — running the suite from an interactive
    // shell would otherwise leave that terminal in raw mode.
    var probe: posix.termios = undefined;
    const have_tty = posix.errno(posix.system.tcgetattr(posix.STDIN_FILENO, &probe)) == .SUCCESS;
    if (have_tty) return error.SkipZigTest;
    try testing.expect(Raw.enable(.{}) == null);
}
