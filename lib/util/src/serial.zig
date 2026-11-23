//! Serial port setup for the coordinator radio. **macOS and Linux** — the
//! platform choice this project started with (macOS only, inherited from
//! the PoCs) was reversed, since long-run
//! testing moves to a Fedora machine.
//!
//! Everything about the port that isn't OS-specific (raw byte mode, 8N1,
//! no flow control, VMIN=0/VTIME=10) is shared. Three things genuinely
//! differ and are gated on `builtin.target.os.tag`:
//!   - **ioctl numbers**: `TIOCEXCL`/`TCIOFLUSH` use BSD's encoding on
//!     Darwin and Linux's own on Linux.
//!   - **flow-control flag names**: BSD spells it as two flags
//!     (`CCTS_OFLOW`/`CRTS_IFLOW`), Linux as one (`CRTSCTS`).
//!   - **how a baud rate is set**: see `setBaud`.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Io = std.Io;

const is_darwin = builtin.target.os.tag.isDarwin();

/// How the port behaves, beyond the raw 8N1 that every caller wants.
pub const Options = struct {
    /// The line rate, or `null` to leave it alone.
    ///
    /// **`null` is for a character device that has no line rate**, and there are
    /// two real ones: a pty, which is how this module is tested against a real
    /// tty without a board on the desk, and a USB CDC-ACM port, where the baud
    /// is a no-op the class specification carries but nothing honours. On macOS
    /// the arbitrary-baud `IOSSIOSPEED` ioctl *fails* on both — found by opening
    /// a pty, which returned `IoctlFailed` — so a port that has no baud has to be
    /// able to say so rather than be refused.
    baud: ?u32,

    /// How long a read waits for a first byte, in tenths of a second — the
    /// termios `VTIME`, with `VMIN` at zero. Zero returns immediately with
    /// whatever is there, possibly nothing.
    ///
    /// **This is a decision, not a detail, and the two callers want opposite
    /// things.** `lib/zigbee`'s link is driven *by* the radio: its loop has
    /// nothing to do until a frame arrives, so waiting a second beats spinning,
    /// and the default is its 10. A control panel driven by a 100 ms
    /// render tick and services the port on the way round; a read that could
    /// block for a second there would freeze the display for ten frames, so it
    /// passes 0 and polls.
    read_timeout_ds: u8 = 10,
};

pub const Port = struct {
    file: Io.File,

    pub const OpenError = posix.OpenError || posix.TermiosGetError || posix.TermiosSetError ||
        error{ IoctlFailed, UnsupportedBaudRate };

    /// Opens `path` (e.g. "/dev/cu.usbmodemE072A1D9E42C1" on macOS,
    /// "/dev/ttyACM0" on Linux), puts it into raw passthrough byte mode, and
    /// applies `options` (see `setBaud` for the per-OS baud mechanism).
    pub fn open(io: Io, path: []const u8, options: Options) OpenError!Port {
        const fd = try posix.openat(posix.AT.FDCWD, path, .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
        const file: Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        errdefer file.close(io);

        try configureRaw(fd, options);
        return .{ .file = file };
    }

    pub fn reader(self: Port, io: Io, buffer: []u8) Io.File.Reader {
        return .initStreaming(self.file, io, buffer);
    }

    pub fn writer(self: Port, io: Io, buffer: []u8) Io.File.Writer {
        return .initStreaming(self.file, io, buffer);
    }

    pub fn close(self: Port, io: Io) void {
        self.file.close(io);
    }
};

/// Clears line-discipline/canonical-mode flags (equivalent to cfmakeraw),
/// forces 8N1 with CLOCAL/CREAD, and leaves flow control disabled — ASH-level
/// flow control is a protocol-layer concern, not this one.
fn applyRawFlags(term: *posix.termios, read_timeout_ds: u8) void {
    term.iflag = .{};
    term.oflag = .{};
    term.lflag = .{};

    term.cflag.CSIZE = .CS8;
    term.cflag.CREAD = true;
    term.cflag.CLOCAL = true;
    term.cflag.PARENB = false;
    term.cflag.CSTOPB = false;
    // Hardware flow control off, spelled differently per platform: BSD has
    // separate output-CTS/input-RTS flags, Linux one combined CRTSCTS.
    if (is_darwin) {
        term.cflag.CCTS_OFLOW = false;
        term.cflag.CRTS_IFLOW = false;
    } else {
        term.cflag.CRTSCTS = false;
    }

    // VMIN=0 always: never block for a byte count. VTIME is the caller's — see
    // `Options.read_timeout_ds` for why the two callers disagree.
    term.cc[@backingInt(posix.V.MIN)] = 0;
    term.cc[@backingInt(posix.V.TIME)] = read_timeout_ds;

    if (is_darwin) {
        term.ispeed = .B9600; // placeholder; IOSSIOSPEED overrides it (see setBaud)
        term.ospeed = .B9600;
    }
}

fn configureRaw(fd: posix.fd_t, options: Options) Port.OpenError!void {
    // Exclusive access: without TIOCEXCL, the OS happily lets a second
    // process open the same serial device, and the two readers steal bytes
    // from each other — observed for real as garbled frames the moment a
    // scripted zd run collided with an interactive one. With it, the
    // second open fails immediately with EBUSY (error.DeviceBusy) instead.
    if (ioctl(fd, TIOCEXCL) != 0) return error.IoctlFailed;

    var term = try posix.tcgetattr(fd);
    applyRawFlags(&term, options.read_timeout_ds);
    // On Linux the baud lives *in* the termios struct, so it has to be set
    // before tcsetattr writes it; on Darwin it's a separate ioctl that has
    // to come after (see setBaud).
    if (!is_darwin) if (options.baud) |b| try setTermiosBaud(&term, b);
    try posix.tcsetattr(fd, .NOW, term);
    if (options.baud) |b| try setBaud(fd, b);

    // Discard any bytes already queued (e.g. leftover NCP chatter from a
    // prior session) so protocol handshakes start from a clean slate.
    if (tcflush(fd, TCIOFLUSH) != 0) return error.IoctlFailed;
}

extern "c" fn tcflush(fd: posix.fd_t, queue_selector: c_int) c_int;
/// <sys/termios.h> on macOS/BSD numbers these 1/2/3 (in/out/both); Linux's
/// <bits/termios.h> numbers them 0/1/2 — the same name means a different
/// value, which is exactly the kind of constant that silently flushes the
/// wrong queue if it's carried across platforms unchecked.
const TCIOFLUSH: c_int = if (is_darwin) 3 else 2;

/// Mark the terminal exclusive; further open() attempts by other processes
/// fail with EBUSY until closed. `_IO('t', 13)` from <sys/ttycom.h> on
/// Darwin; a plain 0x540C from <asm-generic/ioctls.h> on Linux.
const TIOCEXCL: c_ulong = if (is_darwin) 0x2000740D else 0x540C;

extern "c" fn ioctl(fd: posix.fd_t, request: c_ulong, ...) c_int;

/// _IOW('T', 2, speed_t) from <IOKit/serial/ioss.h> — macOS's arbitrary-baud
/// ioctl, needed because Zig's macOS speed_t enum tops out at B230400.
const IOSSIOSPEED: c_ulong = 0x80085402;

/// Darwin: an ioctl issued *after* tcsetattr (which resets the driver-level
/// speed override), accepting any rate including non-standard ones.
/// Linux: nothing to do here — `setTermiosBaud` already put the rate in the
/// termios struct that tcsetattr wrote.
fn setBaud(fd: posix.fd_t, baud: u32) Port.OpenError!void {
    if (!is_darwin) return;
    var speed: c_ulong = baud;
    const rc = ioctl(fd, IOSSIOSPEED, &speed);
    if (posix.errno(rc) != .SUCCESS) return error.IoctlFailed;
}

/// Linux's standard-rate path: 460800 is a standard `B460800` there, so no
/// custom-baud ioctl is needed — but it can't simply be assigned to
/// `term.ispeed`/`ospeed` either. `std.posix.tcsetattr` on Linux issues the
/// legacy `TCSETS` ioctl, and the kernel's own `struct termios` for that
/// call has no speed fields at all: it reads the rate from the CBAUD bits
/// of `c_cflag`, and ignores the trailing `ispeed`/`ospeed` that Zig's
/// (glibc-shaped) struct carries. Zig's `tc_cflag_t` models those bits as
/// padding, so they're set by bit here. `speed_t`'s own values on Linux are
/// already the CBAUD encoding (B460800 == 0x1004), which is what makes this
/// a mask-and-or rather than a lookup.
/// `ispeed`/`ospeed` are set too — harmless, and correct for anything that
/// does read them (glibc's cfgetospeed, a future TCSETS2 switch).
fn setTermiosBaud(term: *posix.termios, baud: u32) Port.OpenError!void {
    const speed = speedForBaud(baud) orelse return error.UnsupportedBaudRate;
    const CBAUD: u32 = 0o010017; // low nibble + CBAUDEX (bit 12)
    var bits: u32 = @bitCast(term.cflag);
    bits = (bits & ~CBAUD) | @backingInt(speed);
    term.cflag = @bitCast(bits);
    term.ispeed = speed;
    term.ospeed = speed;
}

/// The standard rates worth supporting — 460800 is the one the ZBT-2 uses; the
/// rest are here so an explicit
/// `baud` argument to `hub` isn't silently limited to one value. A rate
/// with no standard constant fails loudly on Linux (`UnsupportedBaudRate`)
/// rather than quietly running at the wrong speed; Darwin's IOSSIOSPEED
/// takes arbitrary rates and never consults this.
fn speedForBaud(baud: u32) ?posix.speed_t {
    return switch (baud) {
        9600 => .B9600,
        19200 => .B19200,
        38400 => .B38400,
        57600 => .B57600,
        115200 => .B115200,
        230400 => .B230400,
        460800 => .B460800,
        921600 => .B921600,
        else => null,
    };
}

// ---- naming a port, and refusing a bad one usefully -----------------------
//
// One copy for every instrument's command line: a typo used to print a banner
// and put an empty instrument on screen before admitting the port was wrong,
// or end in a stack trace from `main`. **The port is the first argument**,
// bare names accepted, and a wrong one answered with the ports present.

/// Bare `cu.usbmodem1401` means `/dev/cu.usbmodem1401`. **A path is anything
/// with a separator in it**, so this cannot swallow one, and it removes the
/// commonest typo without guessing at anything else.
pub fn devicePath(gpa: std.mem.Allocator, arg: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, arg, '/') != null) return arg;
    return gpa.print("/dev/{s}", .{arg});
}

/// The names a USB CDC device takes: `cu.` because the `tty.` twin blocks
/// on carrier detect.
const cdc_prefix = if (is_darwin) "cu.usbmodem" else "ttyACM";

/// What a user can actually type, when what they typed is not there.
pub fn listPorts(io: std.Io, out: *std.Io.Writer) void {
    var dir = std.Io.Dir.cwd().openDir(io, "/dev", .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    var found = false;
    while (it.next(io) catch null) |e| {
        if (!std.mem.startsWith(u8, e.name, cdc_prefix)) continue;
        if (!found) out.writeAll("\nserial devices present:\n") catch {};
        found = true;
        out.print("  /dev/{s}\n", .{e.name}) catch {};
    }
    if (!found) out.print("\nno /dev/{s}* devices are present.\n", .{cdc_prefix}) catch {};
}

/// Check a port before anything starts, and **exit rather than return**: every
/// caller's next move is to abandon the run, and an error bubbling out of
/// `main` prints a stack trace where a bench user wants a device list.
///
/// `access` rather than an open, because opening a USB CDC port and closing it
/// again is the manoeuvre that has wedged a board.
///
/// **A port that has just re-enumerated is a real case, not a typo.** An SWD
/// flash resets the target, the device drops off USB and comes back a second
/// or so later, and a command issued in that window finds nothing. The message
/// says so, because the remedy is to wait rather than to go looking for the
/// cable.
pub fn mustExist(io: std.Io, out: *std.Io.Writer, who: []const u8, path: []const u8) void {
    std.Io.Dir.cwd().access(io, path, .{}) catch |e| {
        out.print("{s}: cannot open {s} — {t}\n", .{ who, path, e }) catch {};
        if (e == error.FileNotFound)
            out.writeAll("(a board that has just been reset is off USB for a second or so)\n") catch {};
        listPorts(io, out);
        out.flush() catch {};
        std.process.exit(2);
    };
}

test "a bare device name gains /dev/, and a path is left alone" {
    const p = try devicePath(std.testing.allocator, "cu.usbmodem1401");
    defer std.testing.allocator.free(p);
    try std.testing.expectEqualStrings("/dev/cu.usbmodem1401", p);
    try std.testing.expectEqualStrings("./tty", try devicePath(std.testing.allocator, "./tty"));
}

test "IOSSIOSPEED matches the _IOW('T', 2, speed_t) formula" {
    if (!is_darwin) return error.SkipZigTest;
    const IOC_IN: c_ulong = 0x80000000;
    const group: c_ulong = 'T';
    const num: c_ulong = 2;
    const len: c_ulong = @sizeOf(c_ulong); // speed_t is `unsigned long` on macOS
    const derived = IOC_IN | ((len & 0x1fff) << 16) | (group << 8) | num;
    try std.testing.expectEqual(derived, IOSSIOSPEED);
}

test "TIOCEXCL matches the _IO('t', 13) formula" {
    if (!is_darwin) return error.SkipZigTest;
    const IOC_VOID: c_ulong = 0x20000000;
    const group: c_ulong = 't';
    const num: c_ulong = 13;
    try std.testing.expectEqual(IOC_VOID | (group << 8) | num, TIOCEXCL);
}

test "setTermiosBaud writes the rate into cflag's CBAUD bits, preserving the rest" {
    if (is_darwin) return error.SkipZigTest; // Darwin sets baud by ioctl, not in the struct
    var term: posix.termios = std.mem.zeroes(posix.termios);
    // A pre-existing rate that must be cleared, not OR'd into: 9600's
    // encoding (0x0D) shares bits with 460800's (0x1004) low nibble.
    term.cflag.CREAD = true;
    var bits: u32 = @bitCast(term.cflag);
    bits |= @backingInt(posix.speed_t.B9600);
    term.cflag = @bitCast(bits);

    try setTermiosBaud(&term, 460800);

    const out: u32 = @bitCast(term.cflag);
    try std.testing.expectEqual(@backingInt(posix.speed_t.B460800), out & 0o010017);
    try std.testing.expect(term.cflag.CREAD); // untouched
    try std.testing.expectEqual(posix.speed_t.B460800, term.ospeed);
}

test "setTermiosBaud rejects a non-standard rate rather than running at the wrong speed" {
    if (is_darwin) return error.SkipZigTest;
    var term: posix.termios = std.mem.zeroes(posix.termios);
    try std.testing.expectError(error.UnsupportedBaudRate, setTermiosBaud(&term, 250000));
}

test "the read timeout reaches the termios struct, because two callers disagree" {
    // `lib/zigbee` wants the 1 s default and a polling control panel wants 0. A timeout
    // that silently stayed at 10 would freeze the panel's display for ten frames
    // every time the port went quiet.
    var term: posix.termios = undefined;
    applyRawFlags(&term, 10);
    try std.testing.expectEqual(@as(u8, 0), term.cc[@backingInt(posix.V.MIN)]);
    try std.testing.expectEqual(@as(u8, 10), term.cc[@backingInt(posix.V.TIME)]);

    applyRawFlags(&term, 0);
    try std.testing.expectEqual(@as(u8, 0), term.cc[@backingInt(posix.V.MIN)]);
    try std.testing.expectEqual(@as(u8, 0), term.cc[@backingInt(posix.V.TIME)]);

    try std.testing.expectEqual(@as(u8, 10), (Options{ .baud = 115_200 }).read_timeout_ds);
}

test "a port with no line rate is a legal port" {
    // A pty and a USB CDC-ACM port both have no baud, and on Darwin the
    // arbitrary-baud ioctl fails on them rather than being ignored. `null` is
    // how a caller says so.
    const none: Options = .{ .baud = null };
    try std.testing.expect(none.baud == null);
}

test "applyRawFlags disables canonical/echo/signal/output-post flags" {
    var term: posix.termios = std.mem.zeroes(posix.termios);
    term.iflag.ICRNL = true;
    term.oflag.OPOST = true;
    term.lflag.ECHO = true;
    term.lflag.ICANON = true;
    term.lflag.ISIG = true;

    applyRawFlags(&term, 10);

    try std.testing.expect(!term.oflag.OPOST);
    try std.testing.expect(!term.lflag.ECHO);
    try std.testing.expect(!term.lflag.ICANON);
    try std.testing.expect(!term.lflag.ISIG);
    try std.testing.expect(term.cflag.CSIZE == .CS8);
    try std.testing.expect(term.cflag.CREAD);
    try std.testing.expect(term.cflag.CLOCAL);
}

test "Port.open returns an error for a nonexistent device path" {
    const io = std.testing.io;
    try std.testing.expectError(error.FileNotFound, Port.open(io, "/nonexistent/path/zzz", .{ .baud = 9600 }));
}

test "Semantic Check" {
    std.testing.refAllDecls(@This());
}
