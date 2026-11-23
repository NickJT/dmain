//! hub — Zigbee control application. Successor to two proofs of concept:
//! direct EZSP coordinator control (from a Zigbee daemon) driving a live model
//! (patterns from a Hue monitor), groups, schedules, and a LAN-only web UI.
//! `engine.zig` + `model.zig` + `config.zig` give hub join/list/
//! control-by-name parity with that daemon, plus its `rules.json`
//! switch→light automation. The `screen` command switches from the line
//! console into a live-updating ANSI dashboard (the monitor's
//! `View`/`Layout`/`screens.zig` pattern), and `terminal` switches back.
//! `schedule.json` (`sched.zig`): a fired schedule enqueues the exact same
//! `PendingAction` a rule-matched physical event would, just triggered by
//! wall-clock time instead. `web.zig` adds a LAN-only
//! HTTP server running as its own `io.async` task alongside
//! this function's engine loop — the first genuinely concurrent second
//! consumer of live state, kept
//! safe by never touching the radio directly (see `web.zig`'s module doc
//! comment for the read/write split).
//!
//! Two control *modes* share one process and one poll loop:
//!   - **console mode** (default): the line-based command interface,
//!     unchanged in behavior. Async/unsolicited
//!     events (`[event]`/`[report]`/`[rule]`, routed through
//!     `model.Registry.report`) are drained and printed each tick, same
//!     appearance as before that routing existed.
//!   - **watch mode** (`screen` command, `terminal` to leave): raw terminal
//!     mode, renders the current `screens.zig` screen + a scrolling log tail
//!     via `View`, and takes typed commands on its own command line — the
//!     same command set the console has, dispatched by the same
//!     `handleLine` (it replaced the single-key
//!     actions this screen once had; see `tickWatch`). ESC only clears
//!     the command line: it used to leave watch mode too, which made a
//!     scroll wheel — whose events arrive as escape sequences — eject the
//!     user into the cooked console.
//! Both modes run the SAME underlying `coord.pollOnce()` / rules-drain /
//! deferred-setup loop — nothing about live network handling or
//! automation pauses while watching. The tradeoff: `pollOnce` blocks up
//! to ~1s when idle (the daemon's proven poll cadence), so watch-mode
//! responsiveness — screen switches, log updates — is capped at ~1s too.
//! Decoupling render cadence from poll cadence would need the engine loop
//! on its own `io.async` task — deliberately not done: `pollOnce` itself
//! must stay on this function's single thread (only the engine loop may
//! touch the radio), so nothing about *this* tradeoff changes now that
//! the web server exists as a separate, non-radio-touching task.
//!
//! A third surface, the web server (`web.zig`), isn't
//! a *mode* at all: it runs continuously on its own `io.async` task
//! regardless of console/watch, independent of the ~1s poll cadence above
//! (it answers `GET /api/status` from a mutex-cloned snapshot, not from
//! `pollOnce`). See `web.zig`'s module doc comment for the concurrency
//! split that makes this safe.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const posix = std.posix;
const term = @import("term");

const LinkMod = @import("link");
const Link = LinkMod.Link;
const Ezsp = @import("ezsp");
const Zcl = @import("zcl");
const Ieee = @import("ieee");
const ConfigMod = @import("config");
const Ctl = @import("ctl");
const HouseLog = @import("house_log");
const LeakAlert = @import("leak_alert");
const BridgeSender = @import("bridge_sender");
const Config = ConfigMod.Config;
const Model = @import("model");
const Engine = @import("engine");
const Coordinator = Engine.Coordinator;
const Screens = @import("screens");
const ViewMod = @import("view");
const View = ViewMod.View;
const LayoutMod = @import("layout");
const Layout = LayoutMod.Layout;
const Sched = @import("sched");
const Web = @import("web");
const httpd = @import("httpd");
const Persist = @import("persist");

/// Overrides Zig's default `std.log` sink (which writes straight to
/// stderr) for the whole program. Every module below `main` — ash.zig's
/// CRC/out-of-sequence warnings, ezsp.zig's protocol-status warnings,
/// this file's own "response lost under load" debug line, and anything
/// future code adds — used to write directly past `View`'s cursor-
/// addressed rendering, landing at whatever column the cursor happened
/// to be during watch mode and corrupting column 1 of that row (`View`
/// never touches column 1 itself past the initial frame draw — that's
/// the box's left border). Routing every log call through the same
/// mutex-guarded `model.Registry.report()` the rest of the app's
/// async/unsolicited output already uses (see model.zig's module doc
/// comment) fixes this the same way direct
/// `self.out.print` calls doing the exact same thing — except this needed
/// a program-wide sink override rather than call-site-by-call-site fixes,
/// since std.log calls are scattered across protocol-layer modules that
/// have no `*Registry`/`Io` of their own to report through directly.
var g_log_target: ?struct { registry: *Model.Registry, io: Io } = null;

fn hubLogFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (g_log_target) |target| {
        // Best-effort, matching model.report()'s own "a missed log line
        // isn't worth crashing over" philosophy — errors here are
        // silently dropped rather than propagated (this fn must be void
        // per std.Options' logFn signature, so there's nowhere to send
        // an error anyway).
        target.registry.report(target.io, "[log:" ++ level.asText() ++ "] " ++ format, args) catch {};
        return;
    }
    // No registry yet (very early startup, before main() sets the
    // target) — fall back to the normal stderr sink. Every call site
    // this early either exits immediately after (usage/arg errors) or
    // hasn't touched the terminal yet, so this is always safe.
    std.log.defaultLog(level, scope, format, args);
}

pub const std_options: std.Options = .{ .logFn = hubLogFn };

/// The terminal settings to put back if we die while watch mode owns the
/// screen. Set by `enterWatchMode`, cleared by
/// `leaveWatchMode`; null means the terminal is in its normal state and the
/// panic handler has nothing to undo.
var g_raw_mode_termios: ?term.Raw = null;

/// Panic handler that hands the terminal back before dying.
///
/// Watch mode leaves the tty in raw mode inside the alternate screen buffer.
/// A panic there would otherwise (a) strand the user's shell with no echo
/// and no line editing — a `reset` away, but you have to know that while
/// looking at a terminal that won't echo `reset` — and (b) print the panic
/// trace INTO the alternate screen, which is discarded the moment anything
/// switches back, so the one thing you needed to read is the one thing you
/// never see.
///
/// Deliberately does the minimum and defers to the real handler: raw
/// syscalls only, no allocation, no `Io` — this runs in a process that has
/// already lost the plot.
fn hubPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    if (g_raw_mode_termios) |saved| {
        g_raw_mode_termios = null; // a panic inside the panic handler must not loop here
        // `Raw.restore` is a bare `tcsetattr` — no allocation, no `Io` — which is
        // what makes it safe to call from here.
        saved.restore();
        // Leave the alternate buffer and show the cursor, so the trace below
        // lands on the user's real scrollback where they can read it.
        // The raw syscall, not `Io`: this handler must not allocate, block,
        // or need an `Io` instance the panicking code may have been holding.
        _ = posix.system.write(posix.STDOUT_FILENO, ansi_leave_alt_screen.ptr, ansi_leave_alt_screen.len);
    }
    std.debug.defaultPanic(msg, first_trace_addr);
}
const ansi_leave_alt_screen = "\x1b[?1049l\x1b[?25h\x1b[0m";

pub const panic = std.debug.FullPanic(hubPanic);

/// The coordinator device path when none is given on the command line —
/// there's exactly one rig per machine here, so typing its path every run
/// was pure error surface. An explicit argv
/// path still wins. Deliberately in-source "for now": a config-file home
/// for it can come later if this ever becomes annoying.
/// Per-OS because hub runs on both. Both defaults name **this
/// rig's radio by its USB serial number** rather than by enumeration order:
/// macOS does that natively (`cu.usbmodem<serial>`), and on Linux
/// `/dev/serial/by-id/` is the equivalent — `/dev/ttyACM<n>` is positional,
/// so a replug can hand the same radio a different number while a second
/// USB-CDC device steals the old one. That matters beyond convenience:
/// `Link.reconnect` reopens this exact path after the device
/// vanishes, and USB unplug/replug is its headline test — udev recreates
/// the by-id symlink pointing at whatever ttyACM<n> the radio came back as,
/// so recovery follows it; a hardcoded ttyACM0 would not.
const DEFAULT_DEVICE_PATH = switch (builtin.target.os.tag) {
    .linux => "/dev/serial/by-id/usb-Nabu_Casa_ZBT-2_E072A1D9E42C-if00",
    else => "/dev/cu.usbmodemE072A1D9E42C1",
};

/// How often the coordinator backup is rewritten while hub runs. See `last_backup_ms`'s comment for why hourly is enough.
const BACKUP_INTERVAL_MS: i64 = 60 * 60 * 1000;

/// Is the radio usable this tick?
///
/// Only the engine loop reads this, and only the loop's single `pollOnce`
/// call site sets `.recovering` — see the trigger-site comment there. While
/// recovering, everything that does NOT touch the radio keeps running:
/// console, TUI, the web task, and the enqueue half of schedules/web
/// actions. Everything that does touch it is skipped until the link is back.
const LinkState = enum { up, recovering };

/// After this much silence from the radio, ask it whether it's still there
/// (`Ezsp.Client.nop`). **This is what makes an unattended unplug visible.**
///
/// The poll loop only reads when the house is quiet, and a read from a
/// vanished USB radio returns no bytes — identical to an idle one. Observed
/// for real (2026-07-17): the cable was out for a full minute and hub logged
/// nothing, because nothing had asked it to write. A coordinator that can't
/// tell "quiet house" from "dead radio" isn't recovering from anything.
///
/// 30s balances the two costs: a dead radio is noticed within half a minute,
/// and a healthy idle one answers one 2-byte frame in that time.
const HEARTBEAT_IDLE_MS: i64 = 30_000;

/// Shared mutable state the console/watch input handlers both touch —
/// bundled so `handleLine`'s `screen` command can switch modes without
/// every other command needing to know `View`/`Layout` exist.
const AppState = struct {
    mode: enum { console, watch } = .console,
    view: *View,
    layout: *Layout,
    term_state: ?term.Raw = null,
    current_screen: Screens.ViewMode = .overview,
    /// Cursor row for the `.overview` screen's selectable device list,
    /// moved with ↑/↓. Clamped to `model.devices.items.len` every watch
    /// tick — meaningless (and ignored) on any other screen.
    ///
    /// A reading aid only, since the command line retired the single-key
    /// actions it used to drive (`s`/`r`/`p`): it marks the row you're
    /// looking at in a long list, while commands name their target
    /// explicitly, exactly as they do in the console.
    selected_row: usize = 0,
    /// The watch-mode command line's buffer. Kept separate from
    /// the console's own line buffer rather than shared: the two modes
    /// accumulate independently, and a half-typed line in one has no
    /// business appearing in the other after a mode switch.
    cmd_buf: [256]u8 = undefined,
    cmd_len: usize = 0,
    /// The command line needs a repaint (a key changed it, or it was just
    /// dispatched/cleared). Starts true so it's drawn on the first tick.
    cmd_dirty: bool = true,
    /// Where we are in an ANSI escape sequence. Terminals
    /// send ↑/↓ — and, in the alternate screen, **mouse wheel events** — as
    /// multi-byte CSI sequences, which can split across reads.
    ///
    /// The old one-token lookahead couldn't span a read, so a split burst
    /// left a bare ESC (which then exited watch mode) and dropped its tail
    /// (`[`, `A`) into the command line as text. Scrolling the wheel would
    /// eject you into the cooked console, which then echoed every further
    /// escape byte — the `^[[A^[[B` confetti from the first live run.
    esc: enum { none, esc, csi } = .none,
    /// Parameter bytes of the CSI sequence in progress (between `[` and the
    /// final byte). Only used to tell a bare ↑/↓ from a longer sequence
    /// (`ESC[1;5A`, mouse reports) we mean to discard.
    esc_params: usize = 0,
    /// stdin hit EOF and is not a terminal — so there is no human to take
    /// commands from, and hub stops reading it.
    ///
    /// **This is what makes hub survive as a service.** Under systemd (or
    /// launchd) stdin is `/dev/null`: the first read returns 0 = EOF, and
    /// `tickConsole` used to treat EOF as "the user quit" and exit — so hub
    /// would die within a tick of every boot, forever.
    ///
    /// Deliberately keyed on **EOF + not-a-TTY**, not on `isatty` alone: a
    /// FIFO isn't a TTY either, and every hardware test this project has
    /// ever run drives hub through one. Gating on isatty alone would have
    /// made hub untestable the same day it became deployable.
    console_eof: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len > 1 and std.mem.eql(u8, args[1], "console")) {
        var client_buffer: [4096]u8 = undefined;
        var client_out: Io.File.Writer = .initStreaming(.stdout(), io, &client_buffer);
        const status = Ctl.runClient(io, args[2..], &client_out.interface) catch |err| blk: {
            std.log.err("hub console: {t}", .{err});
            break :blk 1;
        };
        std.process.exit(status);
    }
    const cli = parseCli(args[1..]) catch |err| {
        std.log.err("{s} — usage: hub [--port N] [device-path] [baud=460800], or hub console [command]", .{switch (err) {
            error.BadBaud => "invalid baud: it must be a number",
            error.BadPort => "invalid port: --port needs a number from 1 to 65535",
            error.TooManyArguments => "too many arguments",
        }});
        std.process.exit(2);
    };
    const path = cli.path orelse DEFAULT_DEVICE_PATH;
    const baud = cli.baud;
    web_port = cli.port;

    var stdout_buffer: [2048]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    if (args.len < 2) try out.print("hub: no device path given — using {s}\n", .{path});

    // Port, buffers, reader/writer, ASH transport and handshake all live in
    // one owner now — `Link` — so recovery has
    // something that can rebuild them mid-session. It must be initialized
    // in place: `transport` points into `link`'s own reader/writer, so the
    // struct has to be at its final address first (see link.zig).
    var link: Link = undefined;
    // Link state starts here rather than at the loop, because the radio not
    // being there YET is now a recoverable condition rather than a fatal one
    // At boot — the appliance case — USB enumeration can
    // easily lag the service manager, and exiting would just hand systemd a
    // restart loop to paper over it. Link recovery already knows how to wait for a
    // radio; this reuses it instead of duplicating the idea badly.
    var link_state: LinkState = .up;
    // When network.json is next due, and the permit it last said.
    var next_network_ms: i64 = 0;
    var network_permit_ms: i64 = 0;
    var recovery: LinkMod.Recovery = .{};
    var coord_link_up_at_start = true;

    if (link.open(io, path, baud)) |_| {
        try out.print("hub: NCP reset ({s}), ASH v{d}\n", .{ link.hs.reset_code.name(), link.hs.version });
    } else |err| {
        try out.print("hub: cannot open coordinator at '{s}': {t}\n", .{ path, err });
        if (args.len < 2) {
            try out.print("hub: that path is the built-in default — pass yours: hub <device-path> [baud=460800]\n", .{});
        }
        try out.print("hub: waiting for the radio (retrying in the background) — web/console still available\n", .{});
        link_state = .recovering;
        recovery.begin(Io.Timestamp.now(io, .awake).toMilliseconds());
        coord_link_up_at_start = false;
    }
    defer link.close();
    try out.flush();

    // `link.transport` is undefined memory if the open above failed. That's
    // safe ONLY because nothing touches the client until the link comes up:
    // `bootstrap` is skipped below, and the loop won't poll while
    // `.recovering`. Recovery's `wireUp` initializes it before first use.
    var ezsp = Ezsp.Client.init(&link.transport);

    var config = Config.init(gpa);
    defer config.deinit();
    config.load(io, Io.Dir.cwd());
    config.loadRules(io, Io.Dir.cwd());
    config.loadGroups(io, Io.Dir.cwd());
    config.loadSchedules(io, Io.Dir.cwd());
    config.loadBridgeIds(io, Io.Dir.cwd(), ConfigMod.BRIDGE_IDS_PATH);

    var model = Model.Registry.init(gpa);
    defer model.deinit();
    model.load(io, Io.Dir.cwd());

    // From here on, every std.log call in the program (this module and
    // everything it calls into) routes through model.report() instead of
    // stderr — see hubLogFn's doc comment. Cleared before model.deinit()
    // runs (defers unwind LIFO, so this one — registered after model's —
    // fires first) so nothing can log through a dangling pointer.
    g_log_target = .{ .registry = &model, .io = io };
    defer g_log_target = null;
    // Persistent log. Opened after the std.log override
    // above, so protocol-layer warnings land in the file too. Best-effort:
    // no file, no problem — see openLog.
    model.openLog(io, Io.Dir.cwd());
    defer model.closeLog(io);

    // Declared before `coord` because `say` drains through it.
    var last_log_total: usize = 0;
    var live_config = ConfigMod.Live.init(&config);
    var coord: Coordinator = .{ .io = io, .ezsp = &ezsp, .model = &model, .config = &config, .live = &live_config, .out = out, .link_up = coord_link_up_at_start, .log_cursor = &last_log_total };
    // Declared before the web server, so this runs after its task has stopped.
    defer coord.freeAdoptedConfigs();

    // The house log. Like the web page, the house runs without it.
    const data_dir: ?Io.Dir = Io.Dir.cwd().createDirPathOpen(io, HouseLog.DATA_DIR, .{}) catch |err| blk: {
        try out.print("hub: NO house log: cannot open {s} ({t})\n", .{ HouseLog.DATA_DIR, err });
        break :blk null;
    };
    defer if (data_dir) |dir| dir.close(io);
    const house_dir: ?Io.Dir = if (data_dir) |dir| dir.createDirPathOpen(io, HouseLog.HOUSE_DIR, .{}) catch |err| blk: {
        try out.print("hub: NO house log: cannot open {s} ({t})\n", .{ HouseLog.HOUSE_DIR, err });
        break :blk null;
    } else null;
    defer if (house_dir) |dir| dir.close(io);
    var house: ?HouseLog.Writer = if (house_dir) |dir| HouseLog.Writer.init(gpa, io, data_dir.?, dir) else null;
    defer if (house) |*h| h.deinit();
    if (house) |*h| {
        coord.house = h;
        h.emit(.start);
        h.emit(if (link_state == .up) .up else .{ .down = "radio not found at startup" });
    }
    if (link_state == .up) try coord.bootstrap();

    if (model.devices.items.len > 0) {
        try out.print("hub: loaded {d} known device(s) from {s}\n", .{ model.devices.items.len, Model.Registry.DEVICES_FILE });
    }
    if (config.devices.len > 0) {
        try out.print("hub: loaded {d} configured device(s) from {s}\n", .{ config.devices.len, ConfigMod.DEVICES_FILE });
        try config.validateDevices(out);
    }
    if (config.groups.len > 0) {
        try out.print("hub: loaded {d} group(s) from {s}\n", .{ config.groups.len, ConfigMod.GROUPS_FILE });
        for (config.groups) |group| {
            try out.print("     {s} (0x{X:0>4}):", .{ group.name, group.group_id });
            for (group.members) |m| try out.print(" {s}", .{m});
            try out.print("\n", .{});
        }
        try config.validateGroups(out);
    }
    if (config.rules.len > 0) {
        try out.print("hub: loaded {d} automation rule(s) from {s}\n", .{ config.rules.len, ConfigMod.RULES_FILE });
        for (config.rules) |rule| {
            try out.print("     {s} {s} → {s} {s}\n", .{ rule.controller, rule.event, rule.action, rule.target });
        }
        try config.validateRules(out);
    }
    if (config.schedules.len > 0) {
        try out.print("hub: loaded {d} schedule(s) from {s}\n", .{ config.schedules.len, ConfigMod.SCHEDULES_FILE });
        for (config.schedules) |sched| {
            try out.print("     {s} {s} → {s} {s}\n", .{ sched.name, sched.time, sched.action, sched.target });
        }
        try config.validateSchedules(out);
    }
    if (link_state == .up) try coord.printStatus();

    // Coordinator backup: the network key, its frame
    // counter, and the PAN/channel live only in the NCP's NVM, so a dead
    // radio would otherwise mean re-commissioning every device by hand.
    // Written now, hourly below, and on demand via `backup`. Never fatal —
    // a coordinator that can't write a backup file is still a working
    // coordinator.
    if (link_state != .up) {
        // No radio yet: nothing to export. The post-recovery backup covers it.
    } else if (coord.writeBackup(false)) {
        try out.print("hub: coordinator backup written to {s}\n", .{Persist.BACKUP_FILE});
    } else |err| switch (err) {
        // Loud, and NOT a warning to skim past: this means the radio is on
        // a different network than the backup describes — most likely a
        // replacement radio that just auto-formed a fresh network. The old
        // record survives (that's the point), and the user needs to know
        // before they do anything else.
        error.BackupWouldClobberDifferentNetwork => {
            try out.print("hub: *** coordinator backup NOT written — see the refusal above ***\n", .{});
        },
        else => std.log.warn("coordinator backup failed: {t}", .{err}),
    }

    // Group auto-setup: a
    // group added to groups.json used to silently do nothing until `group
    // <name>` was typed once — the send reported `sent` and no bulb had
    // actually joined the group. Members are mains-powered lights, so
    // there's no sleepy-device stall, and Add Group is idempotent (an
    // existing member just re-confirms), so this runs every startup rather
    // than tracking done-ness. Failures are logged and skipped — same
    // "never refuse to start" philosophy as config loading. Startup only:
    // recovery deliberately touches nothing beyond the link (bulbs keep
    // group membership in their own NVM).
    if (link_state == .up) {
        for (config.groups) |group| {
            coord.setupGroup(group) catch |err| {
                try out.print("hub: group '{s}' auto-setup failed: {t} — `group {s}` retries it\n", .{ group.name, err, group.name });
            };
        }
    }

    // The LAN web interface: a genuinely concurrent `io.async`
    // task (see `web.zig`'s module doc comment) running alongside this function's own
    // engine loop below. It never touches the radio directly — it only
    // reads `model`/`config` (mutex-cloned / swapped whole on a reload, safe
    // to read concurrently) and pushes resolved actions onto its own
    // queue, which the loop drains into `coord.enqueueAction` every tick,
    // right next to the schedule-firing drain that already does the same
    // "resolve elsewhere, send from the engine loop" split.
    var web_server = Web.Server.init(gpa, &model, &live_config);
    defer web_server.deinit();
    var web_http = httpd.Server(Web.Server).init(gpa, &web_server, .{ .port = web_port });
    // Without the page the house still runs: rules, schedules and the console do
    // not need it, so losing the port is a warning and not a reason to stop.
    const web_bound = if (web_http.bind(io)) true else |err| blk: {
        try out.print("hub: NO web interface: cannot use port {d} ({t}) — `--port` picks another\n", .{ web_port, err });
        model.logToFile(io, "hub: NO web interface: cannot use port {d} ({t})", .{ web_port, err });
        break :blk false;
    };
    var web_task = if (web_bound) io.async(httpd.Server(Web.Server).listenTask, .{ &web_http, io }) else null;
    defer if (web_bound) {
        web_http.stop(io);
        _ = web_task.?.cancel(io);
    };
    if (web_bound) {
        try out.print("hub: web interface on http://0.0.0.0:{d}/ (LAN, no auth)\n", .{web_port});
        model.logToFile(io, "hub: web interface on http://0.0.0.0:{d}/ (LAN, no auth)", .{web_port});
    }

    // The console for a hub with no terminal. Like the web page, the house runs
    // without it, so failing to bind is a warning and not a reason to stop.
    var ctl_server = Ctl.Server.init(&model);
    const ctl_bound = if (ctl_server.bind(io)) true else |err| blk: {
        try out.print("hub: NO control socket: {s} ({t})\n", .{ Ctl.SOCKET_FILE, err });
        model.logToFile(io, "hub: NO control socket: {s} ({t})", .{ Ctl.SOCKET_FILE, err });
        break :blk false;
    };
    var ctl_task = if (ctl_bound) io.concurrent(Ctl.Server.listenTask, .{ &ctl_server, io }) catch |err| blk: {
        try out.print("hub: NO control socket: {t}\n", .{err});
        break :blk null;
    } else null;
    defer if (ctl_task) |*task| {
        ctl_server.stop(io);
        _ = task.cancel(io);
    };

    // Optional, like the control socket: a hub with no Bridge details writes
    // nothing to the Bridge, and that is no reason not to run. Errors print by
    // name only, because bridge.json holds a key.
    var bridge_arena = std.heap.ArenaAllocator.init(gpa);
    defer bridge_arena.deinit();
    const bridge_creds = BridgeSender.loadCredentials(bridge_arena.allocator(), io, Io.Dir.cwd()) catch |err| blk: {
        try model.report(io, "[bridge] no Bridge writes: {t} reading {s}", .{ err, BridgeSender.BRIDGE_FILE });
        break :blk null;
    };
    var bridge_store: BridgeSender.Sender = undefined;
    var bridge_task = if (bridge_creds) |creds| blk: {
        bridge_store = .{ .gpa = gpa, .bridge = creds };
        const task = io.concurrent(BridgeSender.Sender.task, .{ &bridge_store, io }) catch |err| {
            try model.report(io, "[bridge] no Bridge writes: {t}", .{err});
            break :blk null;
        };
        bridge_sender = &bridge_store;
        break :blk task;
    } else null;
    defer if (bridge_task) |*task| {
        bridge_sender = null;
        leak_slot = null;
        _ = task.cancel(io);
    };

    var leak_arena = std.heap.ArenaAllocator.init(gpa);
    defer leak_arena.deinit();
    const leak_setup: ?LeakAlert.Setup = LeakAlert.load(leak_arena.allocator(), io, Io.Dir.cwd()) catch |err| blk: {
        try model.report(io, "[leak] alert off: {t} reading {s}", .{ err, LeakAlert.SETUP_FILE });
        break :blk null;
    };
    var leak_policy: LeakAlert.Policy = .{ .repeat_ms = if (leak_setup) |l| @as(i64, l.repeat_s) * 1000 else 0 };
    if (leak_setup) |l| {
        if (bridge_sender) |sender| {
            leak_slot = sender.slotFor(l.light);
            try model.report(io, "[leak] {s} wet flashes the light for {d} s, every {d} s", .{ l.sensor, l.flash_s, l.repeat_s });
        } else try model.report(io, "[leak] alert off: it needs {s}", .{BridgeSender.BRIDGE_FILE});
    }

    try out.print("hub: ready — type `help` for commands (`screen` opens the live TUI)\n", .{});
    try out.flush();
    // A clean start now marks itself in hub.log too, so the durable record
    // shows "started and resumed at HH:MM", not just recoveries.
    model.logToFile(io, "hub: ready", .{});

    var layout = Layout.init(.wide_single, .{ 0, 0, 0 }, 55);
    var view = View.init(gpa, io, &layout, out);
    defer view.deinit();
    var app: AppState = .{ .view = &view, .layout = &layout };

    var last_revision: usize = 0;
    var last_screen: Screens.ViewMode = .config; // != .overview so the first watch tick always renders
    var last_selected: ?usize = null;
    var line_buf: [256]u8 = undefined;
    var line_len: usize = 0;
    var scheduler: Sched.Scheduler = .{};
    var scheduler_config = coord.config;
    // Hourly backup rewrite. Hourly rather than
    // per-change because the one field that actually moves is the outgoing
    // frame counter, and a restore is allowed to overshoot it (that's what
    // the restore procedure's +0x10000 jump is for) — so a stale-by-an-hour
    // counter is fine, while rewriting a file holding the network key on
    // every send would be pure churn.
    var last_backup_ms: i64 = Io.Timestamp.now(io, .awake).toMilliseconds();
    // Last moment the radio proved it was alive — a callback arrived, or it
    // answered a heartbeat. Drives HEARTBEAT_IDLE_MS.
    var last_radio_ms: i64 = Io.Timestamp.now(io, .awake).toMilliseconds();

    while (true) {
        if (link_state == .up) {
            // **The one and only recovery trigger.** Deliberately not inside
            // setupDevice/executeAction: a wedge is sticky, so a failed
            // command propagates (its call site handles that — see
            // tickConsole's handleLine catch) and the next top-of-loop poll
            // enters recovery within a tick. Recovering mid-command would be
            // actively wrong — the awaited response can never arrive
            // post-reset — and one trigger site means one testable state
            // machine.
            const radio_err: ?anyerror = blk: {
                // One serial poll round (~1s block when idle) —
                // prints/bookkeeps any event it sees. Identical in both modes.
                const cb = coord.pollOnce() catch |err| break :blk err;
                const now_ms = Io.Timestamp.now(io, .awake).toMilliseconds();
                // Anything the radio said is proof it's alive.
                if (cb != null) last_radio_ms = now_ms;

                // ...and if it has said nothing for a while, ASK. Reads alone
                // cannot distinguish an idle radio from an unplugged one —
                // see HEARTBEAT_IDLE_MS. A heartbeat failure is judged by a
                // stricter rule than a poll failure (classifyHeartbeatError):
                // silence followed by no answer means gone, not busy.
                if (now_ms - last_radio_ms >= HEARTBEAT_IDLE_MS) {
                    coord.ezsp.nop() catch |err| switch (LinkMod.classifyHeartbeatError(err)) {
                        .propagate => break :blk err,
                        .recover => {
                            try model.report(io, "[link] no answer to heartbeat after {d}s of silence ({t})", .{ @divTrunc(now_ms - last_radio_ms, 1000), err });
                            break :blk err;
                        },
                    };
                    last_radio_ms = now_ms;
                }
                break :blk null;
            };
            if (radio_err) |err| switch (LinkMod.classifyHeartbeatError(err)) {
                .propagate => return err,
                .recover => {
                    try model.report(io, "[link] transport error ({t}) — starting recovery", .{err});
                    recovery.begin(Io.Timestamp.now(io, .awake).toMilliseconds());
                    link_state = .recovering;
                    coord.link_up = false;
                    if (house) |*h| {
                        var reason_buf: [64]u8 = undefined;
                        const reason = std.fmt.bufPrint(&reason_buf, "{t}", .{err}) catch "radio lost";
                        h.emit(.{ .down = reason });
                    }
                },
            };
        } else {
            // Radio's down: don't touch it, but stay alive and responsive.
            // The web task keeps serving (stale) status on its own thread,
            // and the console/TUI ticks below still run — you can watch the
            // log and `quit`. Schedules and web actions still *enqueue*;
            // their queues are capped, which bounds the backlog.
            const now_ms = Io.Timestamp.now(io, .awake).toMilliseconds();
            const step = recovery.decide(now_ms);
            switch (step) {
                .wait => {
                    // Replaces pollOnce's ~1s block, which we can't use
                    // while the radio is untouchable — without a sleep this
                    // loop would spin a core flat out.
                    io.sleep(.fromMilliseconds(250), .awake) catch {};
                },
                .try_rehandshake, .try_reconnect => {
                    // Attempt 0 is the cheap one (RST over the existing fd —
                    // an ASH wedge means a confused NCP, not a missing one);
                    // from there the fd itself is suspect, so reopen it.
                    //
                    // `port_open` is the veto: when the port was never opened
                    // at all (the boot-before-USB case) there is no fd
                    // to RST over and no reader/writer to hand a handshake —
                    // only a full open makes sense.
                    const rehandshake = step == .try_rehandshake and link.port_open;
                    if (if (rehandshake) link.rehandshake() else link.reconnect()) |_| {
                        // The link is back, but the NCP was reset by that
                        // RST — its config and endpoints live in RAM and are
                        // gone. reinitAfterReset re-applies them and resumes
                        // the network (never forms — see initStack).
                        if (coord.reinitAfterReset()) |_| {
                            try model.report(io, "[link] recovered after {d} failed attempt(s) — radio is back", .{recovery.failures});
                            last_radio_ms = Io.Timestamp.now(io, .awake).toMilliseconds();
                            coord.link_up = true;
                            if (house) |*h| h.emit(.up);
                            // Fresh frame counter, and proof-of-life in the
                            // file: the plan's "backup after recovery".
                            coord.writeBackup(false) catch |err| {
                                std.log.warn("post-recovery backup failed: {t}", .{err});
                            };
                            link_state = .up;
                        } else |err| {
                            // The link works but the stack won't come back
                            // (NVM lost the network — initStack already said
                            // so, loudly). Retrying the port won't fix that,
                            // but neither should we exit: the user may
                            // `restore`. Keep the loop alive, slowly.
                            recovery.recordFailure(now_ms);
                            if (recovery.shouldReport(now_ms)) {
                                try model.report(io, "[link] re-init failed: {t}", .{err});
                            }
                        }
                    } else |err| {
                        recovery.recordFailure(now_ms);
                        if (recovery.shouldReport(now_ms)) {
                            try model.report(io, "[link] recovery attempt {d} failed ({t}) — retrying, next in {d}s", .{ recovery.failures, err, @divTrunc(LinkMod.backoffMs(recovery.failures), 1000) });
                        }
                    }
                },
            }
        }

        if (house) |*h| h.tick(&model, coord.config, link_state == .up);
        // network.json once a minute, and at once when a permit opens. A closed
        // permit drops out at the next write; a reader counts down meanwhile.
        if (house) |*h| {
            const mono_ms = Io.Timestamp.now(io, .awake).toMilliseconds();
            if (mono_ms >= next_network_ms or coord.permit_until_ms != network_permit_ms) {
                next_network_ms = mono_ms + NETWORK_MS;
                network_permit_ms = coord.permit_until_ms;
                h.network(&model, coord.networkFacts(link_state == .up));
            }
        }
        if (leak_slot) |slot| tickLeak(io, &model, coord.config, slot, &leak_policy, leak_setup.?);
        if (bridge_sender) |sender| reportBridge(io, &model, sender);
        try coord.tickHumidity();

        // One command from the control socket per tick. Above the radio gate,
        // because `reload` and `list` work with the radio down; `runCommand`
        // refuses the rest, exactly as it does for the console. Output goes to
        // the log, which is what the client is following, so it never writes to
        // a socket from here.
        if (ctl_task != null) {
            if (try ctl_server.queue.take(io)) |request| {
                const was_tui = coord.tui;
                coord.tui = true;
                defer coord.tui = was_tui;
                defer ctl_server.queue.finish(request.id);
                try model.report(io, "console> {s}", .{request.line()});
                _ = try runCommand(&coord, &app, io, &model, request.line());
            }
        }

        // ── Everything below here touches the radio, so it only runs when
        //    the link is up (the first design said "skip pollOnce AND
        //    radio-touching drains" — only pollOnce was actually gated,
        //    found in testing). While down this is not merely
        //    pointless, it is FATAL: on the startup-wait path the
        //    radio was never opened, so `link.transport` is uninitialized
        //    memory and a send through it is a general protection fault, not
        //    an error you can catch.
        //
        //    Schedules and web actions still ENQUEUE while down — their
        //    queues are capped, which bounds the backlog — they just aren't
        //    drained until the radio is back.
        if (link_state != .up) {
            switch (app.mode) {
                .console => {
                    const keep_running = try tickConsole(&coord, &app, io, out, &model, &last_log_total, &line_buf, &line_len);
                    if (!keep_running) return;
                },
                .watch => {
                    const keep_running = try tickWatch(&coord, &app, io, gpa, &model, coord.config, &last_revision, &last_screen, &last_selected);
                    if (!keep_running) return;
                },
            }
            continue;
        }

        // A pending-setup device just proved it's awake (announce/join) —
        // commission it now, from the top level only (never nested inside
        // another command's poll loop, which would nest one wait inside
        // another).
        if (model.awake_pending_setup) |ieee| {
            model.awake_pending_setup = null;
            if (model.findByIeee(ieee) != null) {
                try model.report(io, "hub: {f} is awake — running deferred setup", .{IeeeFmt{ .ieee = ieee }});
                coord.setupDevice(ieee) catch |err| {
                    if (err == error.ZdoTimeout) {
                        // Re-resolved rather than reusing a pointer from
                        // before the (long, polling) setup attempt — see
                        // engine.zig's pointer-stable-access section.
                        if (model.findByIeee(ieee)) |dev| dev.pending_setup = true;
                    } else {
                        try model.report(io, "deferred setup failed: {t} (still pending — will retry on next announce)", .{err});
                    }
                };
            }
        }

        // An IAS Zone sensor sent a Zone Enroll Request (recorded in the
        // poll callback, which mustn't send). Enroll it now, from the top
        // level — same discipline as deferred setup above.
        if (coord.pending_enroll) |ieee| {
            coord.pending_enroll = null;
            if (coord.model.findByIeee(ieee) != null) {
                coord.enrollIasZone(ieee) catch |err| {
                    try model.report(io, "IAS enrollment failed: {t} (the sensor will re-request if still unenrolled)", .{err});
                };
            }
        }

        // Rule-matched actions run from the top level (sendOnOff/
        // sendLevel* poll internally, so they must not be nested inside
        // pollOnce). The `[rule]` lines already printed from fireEvent.
        // Snapshot + reset the queue first, so events arriving during a
        // send land in the next iteration's batch rather than being lost
        // or re-run.
        if (coord.pending_count > 0) {
            var batch: [Engine.PENDING_ACTIONS_CAP]Engine.PendingAction = undefined;
            const count = coord.pending_count;
            @memcpy(batch[0..count], coord.pending_actions[0..count]);
            coord.pending_count = 0;
            for (batch[0..count]) |act| {
                if (act.target == .bridge) {
                    try toBridge(io, &model, coord.config, act);
                    continue;
                }
                // This drain does NOT trigger link recovery, deliberately —
                // see the `pollOnce` call above, which is the one and only
                // trigger site. A wedge is sticky: if the link is genuinely
                // broken, the next top-of-loop poll (or heartbeat) hits the
                // same error and starts recovery within a tick, so a failed
                // action needs no opinion about the link. Note the errors
                // below are treated as benign HERE while
                // `link.zig`'s `classifyHeartbeatError` treats the same ones
                // as fatal-to-the-link — that isn't a contradiction: here
                // they mean "a flood buried a response we were never going
                // to read anyway"; there they follow 30s of total silence,
                // which means gone rather than busy.
                coord.executeAction(act) catch |err| switch (err) {
                    // The command's DATA frame was sent and ASH-ACKed;
                    // only its NCP response got buried under a callback
                    // flood (a fast dial spin). Fire-and-forget ignores
                    // that response anyway, so this is benign — log at
                    // debug, don't alarm.
                    error.UnexpectedResponse, error.ExchangeTimeout, error.CallbackTimeout => {
                        std.log.debug("rule action: response lost under load (command was sent)", .{});
                    },
                    else => {
                        try model.report(io, "rule action failed: {t}", .{err});
                    },
                };
            }
        }

        // Schedules: same idea as the rules drain above —
        // a schedule is a rule whose trigger is wall-clock time instead
        // of a physical event, so a fired entry just gets resolved and
        // enqueued (`Phase.tick`, a one-shot trigger) into the exact same
        // `pending_actions` queue the block above already drains next
        // tick, reusing `executeAction`'s fire-and-forget send + error
        // handling verbatim.
        // The scheduler remembers "fired today" by position, which a reload can
        // shift. Rebuilding it and discarding one tick marks whatever is due this
        // minute as done, so a reload can't fire a schedule twice.
        if (coord.config != scheduler_config) {
            scheduler_config = coord.config;
            scheduler = .{};
            _ = scheduler.tick(coord.config.schedules, Sched.currentCalendarDay(io));
        }
        if (coord.config.schedules.len > 0) {
            const fired = scheduler.tick(coord.config.schedules, Sched.currentCalendarDay(io));
            for (fired.slice()) |i| {
                const sched = coord.config.schedules[i];
                const target = coord.config.resolveTargetName(sched.target) orelse continue; // validated at load
                const action = ConfigMod.parseAction(sched.action) orelse continue; // validated at load
                if (coord.enqueueAction(target, action, .tick)) {
                    try model.report(io, "[schedule] {s} ({s}) → {s} {s}", .{ sched.name, sched.time, sched.target, sched.action });
                }
            }
        }

        // Ask one stale light for its On/Off state. Only
        // reaches devices that aren't reporting on their own — a bulb that
        // honours Configure Reporting stays fresh and is skipped. Sends
        // fire-and-forget; the answer arrives through pollOnce like any
        // report, so this adds no waiting to the loop.
        coord.pollStaleState() catch |err| {
            std.log.debug("state poll: {t} (harmless — it's a poll, it'll retry)", .{err});
        };
        coord.noteLostLights() catch {};
        coord.pollSettings() catch |err| {
            std.log.debug("settings poll: {t} (harmless — it's a poll, it'll retry)", .{err});
        };

        // Hourly coordinator-backup rewrite — silent on
        // success: this fires unattended forever, and a line an hour saying
        // "still fine" would only train the eye to skip the log.
        const backup_now_ms = Io.Timestamp.now(io, .awake).toMilliseconds();
        if (backup_now_ms - last_backup_ms >= BACKUP_INTERVAL_MS) {
            last_backup_ms = backup_now_ms;
            coord.writeBackup(false) catch |err| {
                std.log.warn("hourly coordinator backup failed: {t}", .{err});
            };
        }

        // Web actions: `Web.Server.drain` is the only place
        // this loop touches `web_server` — everything else about a
        // request (parsing, target/action resolution, reading the
        // status snapshot) already happened on the connection's own
        // `io.async` task. A drained action is already a resolved
        // `ConfigMod.Target`, so this is exactly the schedule block
        // above with a different source: resolve-elsewhere-enqueue-here.
        var web_batch: [Web.MAX_QUEUED_ACTIONS]Web.ActionRequest = undefined;
        for (web_server.drain(io, &web_batch)) |act| {
            const label = switch (act.target) {
                .device => |ieee| coord.config.nameFor(ieee) orelse "?",
                .group => |gid| coord.config.groupNameFor(gid) orelse "?",
                .bridge => "?",
            };
            switch (act.action) {
                .radio => |action| {
                    if (coord.enqueueAction(act.target, action, .tick)) {
                        try model.report(io, "[web] {s} {s}", .{ label, @tagName(action) });
                    }
                },
                // An ack is a model write, not a radio action — it must
                // work even while the link is down, so it never goes near
                // the engine queue (see web.zig's WebAction).
                .ack => {
                    const acked = try model.ackAlert(io, act.target.device);
                    try model.report(io, "[web] {s} alert {s}", .{ label, if (acked) "acknowledged" else "ack: nothing latched" });
                },
            }
        }

        switch (app.mode) {
            .console => {
                const keep_running = try tickConsole(&coord, &app, io, out, &model, &last_log_total, &line_buf, &line_len);
                if (!keep_running) return;
            },
            .watch => {
                const keep_running = try tickWatch(&coord, &app, io, gpa, &model, coord.config, &last_revision, &last_screen, &last_selected);
                if (!keep_running) return;
            },
        }
    }
}

/// Console-mode tick: drain+print any new async log lines, then read
/// whatever's waiting on stdin (a zero-timeout `poll()` check, not
/// `O_NONBLOCK` — fcntl's `F_SETFL` applies to the *open file
/// description*, which stdin/stdout/stderr all share (dup'd from the
/// same controlling-tty fd by the shell), so flipping `O_NONBLOCK` on
/// fd 0 would silently make fd 1 (stdout) non-blocking too — a
/// multi-line print could then return `EAGAIN`, which `std.Io.File.Writer`
/// doesn't retry. Hit for real in the predecessor daemon; `poll()` with timeout=0
/// only checks readability and never mutates any fd's blocking mode.
/// Returns `false` when the user quit (EOF or the `quit` command).
fn tickConsole(
    coord: *Coordinator,
    app: *AppState,
    io: Io,
    out: *Io.Writer,
    model: *Model.Registry,
    last_log_total: *usize,
    line_buf: []u8,
    line_len: *usize,
) !bool {
    try model.drainTo(io, out, last_log_total);

    if (app.console_eof) return true; // headless: nobody is typing (see AppState.console_eof)

    var pfd = [1]posix.pollfd{.{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 }};
    const ready = try posix.poll(&pfd, 0);
    if (ready == 0) return true;

    var in_buf: [256]u8 = undefined;
    const n = try posix.read(posix.STDIN_FILENO, &in_buf);
    if (n == 0) {
        // EOF. What that MEANS depends on who's on the other end.
        const stdin: Io.File = .{ .handle = posix.STDIN_FILENO, .flags = .{ .nonblocking = false } };
        if (stdin.isTty(io) catch false) return false; // a human closed their terminal: quit
        // Not a terminal: `/dev/null` under a service manager, or a pipe
        // that has finished. A daemon must not exit because nobody is
        // typing at it — the house's lights don't care. Go headless: web,
        // rules, schedules and link recovery all keep running.
        app.console_eof = true;
        try model.report(io, "hub: stdin is closed and not a terminal — running headless (web + rules + schedules + recovery)", .{});
        return true;
    }

    for (in_buf[0..n]) |b| {
        if (b == '\n') {
            const keep_running = try runCommand(coord, app, io, model, std.mem.trim(u8, line_buf[0..line_len.*], " \t\r"));
            line_len.* = 0;
            if (!keep_running) return false;
            // `screen` switched us into watch mode mid-buffer: the rest of
            // this read was typed at the console, for the console, and the
            // terminal is now raw and cursor-addressed. Dispatching those
            // lines from here would run them with watch mode's output
            // routing (`coord.tui`) against a frame that hasn't been drawn
            // yet; stop and let tickWatch own the keyboard from here.
            // Only reachable from piped or pasted input — a human types
            // one line per tick — which is exactly how hub gets tested.
            if (app.mode != .console) return true;
        } else if (line_len.* < line_buf.len) {
            line_buf[line_len.*] = b;
            line_len.* += 1;
        }
    }
    return true;
}

/// Watch-mode tick: redraw the frame if the terminal resized, render the
/// log tail, collate + render the current screen if the model, screen, or
/// selection changed, then handle input for the command line.
///
/// Input is a typed command line, NOT the
/// single-key actions this screen once had (`s`/`r`/`p` on the
/// selected row): a keypress gives no echo until the next ~1s tick, so
/// there was no way to tell whether it had registered; a miskey fired
/// immediately with nothing to review; and it was a second command set to
/// remember alongside the console's. So the line takes **the console's own
/// commands, format, and dispatcher** (`handleLine`) — one command set,
/// one parser, one implementation, with watch mode as a second caller.
/// The keys that remain are the ones that can't collide with typing:
///   - ↑/↓ move the selection bar (escape sequences, not characters).
///     `j`/`k` are retired — they're ordinary letters now.
///   - ESC clears a part-typed line, and **only** that. It used to leave
///     watch mode when the line was empty, which sounded tidy and was a
///     trap: a terminal sends ↑/↓ AND mouse-wheel events as ESC-prefixed
///     sequences, so a burst that split across a read left a bare ESC and
///     ejected the user into the cooked console — which then echoed every
///     further escape byte as `^[[A` confetti (first live run).
///     `terminal` is the way out now; `quit` still exits hub in both modes.
/// Screens are switched by typing `screen <name>` — the same command that
/// opened watch mode from the console, which is why `1`/`2` are gone too.
///
/// Returns `false` when the user quit hub entirely (`quit` typed here).
fn tickWatch(
    coord: *Coordinator,
    app: *AppState,
    io: Io,
    gpa: std.mem.Allocator,
    model: *Model.Registry,
    config: *const Config,
    last_revision: *usize,
    last_screen: *Screens.ViewMode,
    last_selected: *?usize,
) !bool {
    const view = app.view;
    const layout = app.layout;

    // Clamp the selection cursor to the live device count every tick —
    // devices join/leave (or get `remove`d from right here) between
    // ticks, and a stale index would otherwise point past the list or at
    // the wrong row after a removal shifts the last entry into its slot
    // (`Registry.delete` is a swap-remove).
    const device_count = model.devices.items.len;
    if (device_count == 0) {
        app.selected_row = 0;
    } else if (app.selected_row >= device_count) {
        app.selected_row = device_count - 1;
    }
    const selected: ?usize = if (app.current_screen == .overview and device_count > 0) app.selected_row else null;

    const frame_redrawn = try view.redrawFrameIfNeeded();

    var frame_arena = std.heap.ArenaAllocator.init(gpa);
    defer frame_arena.deinit();
    const arena = frame_arena.allocator();

    const log_tail = try model.tailLog(io, layout.scroll_height, arena);
    if (log_tail.len > 0) try view.renderLog(log_tail);

    const current_revision = model.revision.load(.acquire);
    const screen_changed = app.current_screen != last_screen.*;
    const selection_changed = !std.meta.eql(selected, last_selected.*);
    const refresh = frame_redrawn or screen_changed or selection_changed or current_revision != last_revision.*;
    if (refresh) {
        const spec = Screens.view_specs.get(app.current_screen);
        if (screen_changed) {
            layout.setMode(spec.layout_mode, spec.columns);
            layout.setTopPercentage(spec.top_pct); // help wants nearly the whole window
            view.headers = spec.headers;
        }
        const now_ms = Io.Timestamp.now(io, .awake).toMilliseconds();
        const plan = try spec.collate(model, config, now_ms, selected, arena, layout);
        switch (plan) {
            .single => |rows| try view.renderRows(rows),
        }
        last_revision.* = current_revision;
    }
    last_screen.* = app.current_screen;
    last_selected.* = selected;

    if (frame_redrawn or app.cmd_dirty) {
        try view.renderCommandLine(app.cmd_buf[0..app.cmd_len]);
        app.cmd_dirty = false;
    }

    var pfd = [1]posix.pollfd{.{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 }};
    const ready = try posix.poll(&pfd, 0);
    if (ready == 0) {
        // A whole tick passed with nothing after an ESC, so it really was a
        // lone ESC press, not the head of a split sequence — the timeout a
        // terminal can't give us. Its only job now is clearing the line
        // (`terminal` leaves watch mode), so resolving it late is harmless.
        if (app.esc == .esc) {
            app.esc = .none;
            clearCommandLine(app);
            try view.renderCommandLine(app.cmd_buf[0..app.cmd_len]);
            app.cmd_dirty = false;
        }
        return true;
    }

    var in_buf: [64]u8 = undefined;
    const n = try posix.read(posix.STDIN_FILENO, &in_buf);
    if (n == 0) return true;

    for (in_buf[0..n]) |key| {
        // A byte at a time through a small escape-sequence state machine.
        // Spans reads by construction, so a burst that
        // splits mid-sequence can no longer leave a bare ESC behind or spill
        // `[`/`A` into the command line as text.
        switch (app.esc) {
            .esc => {
                if (key == '[') {
                    app.esc = .csi;
                    app.esc_params = 0;
                } else {
                    // ESC followed by something that isn't a sequence: treat
                    // the ESC as a real keypress (clear the line), then let
                    // this byte fall through as ordinary input below.
                    app.esc = .none;
                    clearCommandLine(app);
                    const keep = try handleKey(coord, app, io, model, key, device_count);
                    if (!keep) return false;
                    if (app.mode != .watch) return true;
                }
                continue;
            },
            .csi => {
                // Parameter/intermediate bytes are 0x20–0x3F; the sequence
                // ends at the first final byte, 0x40–0x7E.
                if (key >= 0x40 and key <= 0x7E) {
                    app.esc = .none;
                    // Only a BARE ↑/↓ moves the selection. Anything longer
                    // (`ESC[1;5A`, a mouse report, whatever a terminal
                    // invents) is consumed and dropped rather than half-read.
                    if (app.esc_params == 0) switch (key) {
                        'A' => if (app.selected_row > 0) {
                            app.selected_row -= 1;
                        },
                        'B' => if (device_count > 0 and app.selected_row + 1 < device_count) {
                            app.selected_row += 1;
                        },
                        else => {},
                    };
                } else {
                    app.esc_params += 1;
                }
                continue;
            },
            .none => {},
        }

        if (key == 0x1B) {
            // Might be a lone ESC, might be the start of a sequence — the
            // terminal doesn't say. Defer: if the next byte is `[` it's a
            // sequence; if nothing follows within a tick, tickWatch treats it
            // as a real ESC press. Deliberately NOT acted on here: clearing
            // now would wipe a line the user is typing every time they touch
            // the scroll wheel.
            app.esc = .esc;
            continue;
        }
        const keep_running = try handleKey(coord, app, io, model, key, device_count);
        if (!keep_running) return false;
        if (app.mode != .watch) return true; // a command left watch mode
    }

    if (app.cmd_dirty) {
        try view.renderCommandLine(app.cmd_buf[0..app.cmd_len]);
        app.cmd_dirty = false;
    }
    return true;
}

fn enterWatchMode(coord: *Coordinator, app: *AppState) !void {
    // Watch mode draws its own command line into the frame, so no echo and no
    // line buffering; **signals off** because it decodes Ctrl-C itself and a
    // half-typed command should not be lost to a stray one. `util.term` holds
    // the mechanism.
    const state = term.Raw.enable(.{ .signals = false }) orelse {
        try coord.say("hub: raw terminal mode unavailable here (not a real tty?) — `screen` needs one", .{});
        return;
    };
    app.term_state = state;
    g_raw_mode_termios = state; // so a panic can hand the terminal back (see hubPanic)
    app.mode = .watch;
    app.cmd_len = 0;
    app.cmd_dirty = true;
    // From here every command response goes into the log instead of
    // straight to the terminal — see engine.zig's `say`.
    coord.tui = true;
    // Force redrawFrameIfNeeded to redraw on the very next watch tick.
    app.layout.last_width = 0;
    app.layout.last_height = 0;
}

fn leaveWatchMode(coord: *Coordinator, app: *AppState) !void {
    try app.view.restoreScreen();
    if (app.term_state) |r| r.restore();
    app.term_state = null;
    g_raw_mode_termios = null; // terminal is back to normal; nothing to undo
    app.mode = .console;
    coord.tui = false;
}

/// Adapter so `IEEE.printReversed` (writer-based) can be used as a
/// `model.report` format arg (which needs something `std.fmt`-compatible
/// via a `format()` method) without a second allocation.
const IeeeFmt = struct {
    ieee: [8]u8,
    pub fn format(self: IeeeFmt, writer: *Io.Writer) !void {
        try Ieee.printReversed(writer, &self.ieee);
    }
};

/// Console `help`. The command list comes from `screens.zig` so the TUI's
/// help screen and this can't drift; the reference material below stays
/// console-only — it's what a terminal's scrollback is for, and it's exactly
/// what made `help` unusable inside the TUI.
/// The port the web interface was asked for: set once in `main`, read by `help`.
var web_port: u16 = Web.DEFAULT_PORT;

const Cli = struct {
    path: ?[]const u8 = null,
    baud: u32 = 460_800,
    port: u16 = Web.DEFAULT_PORT,
};

/// `hub [--port N] [device-path] [baud]`, the flag anywhere. A mistyped setting
/// stops here rather than quietly running on a default.
fn parseCli(args: []const [:0]const u8) error{ BadBaud, BadPort, TooManyArguments }!Cli {
    var cli: Cli = .{};
    var positional: u8 = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--port")) {
            i += 1;
            if (i == args.len) return error.BadPort;
            cli.port = std.fmt.parseInt(u16, args[i], 10) catch return error.BadPort;
            if (cli.port == 0) return error.BadPort;
            continue;
        }
        switch (positional) {
            0 => cli.path = a,
            1 => cli.baud = std.fmt.parseInt(u32, a, 10) catch return error.BadBaud,
            else => return error.TooManyArguments,
        }
        positional += 1;
    }
    return cli;
}

test "parseCli: defaults, the flag anywhere, and mistakes" {
    const t = std.testing;
    const none = try parseCli(&.{});
    try t.expectEqual(@as(?[]const u8, null), none.path);
    try t.expectEqual(@as(u32, 460_800), none.baud);
    try t.expectEqual(Web.DEFAULT_PORT, none.port);

    const old = try parseCli(&.{ "/dev/ttyACM1", "115200" });
    try t.expectEqualStrings("/dev/ttyACM1", old.path.?);
    try t.expectEqual(@as(u32, 115200), old.baud);

    try t.expectEqual(@as(u16, 8081), (try parseCli(&.{ "--port", "8081" })).port);
    const mid = try parseCli(&.{ "/dev/ttyACM1", "--port", "8081", "115200" });
    try t.expectEqual(@as(u16, 8081), mid.port);
    try t.expectEqual(@as(u32, 115200), mid.baud);

    try t.expectError(error.BadPort, parseCli(&.{"--port"}));
    try t.expectError(error.BadPort, parseCli(&.{ "--port", "0" }));
    try t.expectError(error.BadPort, parseCli(&.{ "--port", "70000" }));
    try t.expectError(error.BadPort, parseCli(&.{ "--port", "http" }));
    try t.expectError(error.BadBaud, parseCli(&.{ "/dev/x", "fast" }));
    try t.expectError(error.TooManyArguments, parseCli(&.{ "/dev/x", "1", "2" }));
}

const HELP_TEXT = "commands:\n" ++ Screens.COMMANDS_HELP ++
    \\
    \\web: http://<this host>:{d}/ (LAN only, no auth) — status + on/off/toggle for
    \\  every devices.json/groups.json name, same targets/actions as this console
    \\automation: rules.json (cwd), loaded at startup. Each rule:
    \\  {{"controller":"<name>","event":"<event>","action":"<action>","target":"<name>"}}
    \\  events: button1..button4, dial_left, dial_right, occupied, clear, alarm,
    \\    humid (a shower's rise), dry (its run is over)
    \\  actions: on, off, toggle, level_up, level_down
    \\  target: a devices.json or groups.json name, or an address; one the Bridge
    \\    holds (huelog's bridge-ids.json) takes on and off only
    \\groups.json (cwd), loaded at startup:
    \\  {{"groups":[{{"name":"<name>","group_id":<int>,"members":["<device>",...]}}]}}
    \\schedule.json (cwd), loaded at startup — fires once per day at local time:
    \\  {{"schedules":[{{"name":"<name>","time":"HH:MM","action":"<action>","target":"<name>"}}]}}
    \\
;

/// Formatted once, then emitted a line at a time through `say` — console
/// mode prints them straight through (identical to the single multi-line
/// print this replaced), while watch mode needs them as separate log
/// entries, since its log renders one entry per row.
fn sayHelp(coord: *Coordinator) !void {
    var buf: [4096]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    try w.print(HELP_TEXT, .{web_port});
    var lines = std.mem.splitScalar(u8, w.buffered(), '\n');
    while (lines.next()) |l| try coord.say("{s}", .{l});
}

/// Clears the watch-mode command line.
fn clearCommandLine(app: *AppState) void {
    app.cmd_len = 0;
    app.cmd_dirty = true;
}

/// One ordinary (non-escape) keypress in watch mode. Returns false to exit
/// hub (`quit` typed on the command line).
fn handleKey(coord: *Coordinator, app: *AppState, io: Io, model: *Model.Registry, key: u8, device_count: usize) !bool {
    _ = device_count;
    switch (key) {
        // Raw mode with ICRNL off delivers Return as CR, not LF.
        '\r', '\n' => {
            const line = std.mem.trim(u8, app.cmd_buf[0..app.cmd_len], " \t");
            if (line.len == 0) {
                clearCommandLine(app);
                return true;
            }
            // Echo the dispatched command into the log the screen already
            // renders: a command whose response is a device event seconds
            // later would otherwise leave no trace that it ran at all.
            try model.report(io, "> {s}", .{line});
            const keep_running = try runCommand(coord, app, io, model, line);
            clearCommandLine(app);
            return keep_running;
        },
        0x7F, 0x08 => if (app.cmd_len > 0) {
            app.cmd_len -= 1;
            app.cmd_dirty = true;
        },
        // Printable ASCII only: every command, target name, and parameter hub
        // accepts is ASCII, and this keeps stray control bytes out of the
        // buffer rather than into a command nobody typed.
        0x20...0x7E => if (app.cmd_len < app.cmd_buf.len) {
            app.cmd_buf[app.cmd_len] = key;
            app.cmd_len += 1;
            app.cmd_dirty = true;
        },
        else => {},
    }
    return true;
}

fn firstToken(line: []const u8) []const u8 {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    return it.next() orelse "";
}

/// hub's Bridge writer, null without `bridge.json`.
var bridge_sender: ?*BridgeSender.Sender = null;
/// The leak alert's light, for the `leak` console command. Null when it's off.
var leak_slot: ?*BridgeSender.Slot = null;

/// One step of the leak alert. Only hands work to the sender, so it can't hold up
/// the radio. The log is what a person reads afterwards, so a failed report isn't
/// worth stopping for.
fn tickLeak(io: Io, model: *Model.Registry, config: *const Config, slot: *BridgeSender.Slot, policy: *LeakAlert.Policy, setup: LeakAlert.Setup) void {
    const now_ms = Io.Timestamp.now(io, .awake).toMilliseconds();
    if (slot.takeResult()) |r| switch (r.outcome) {
        .none => {},
        .accepted => model.report(io, "[leak] the Bridge accepted it", .{}) catch {},
        .failed => policy.flashFailed(now_ms),
    };
    const ieee = config.ieeeFor(setup.sensor) orelse return;
    const dev = model.findByIeee(ieee) orelse return;
    switch (policy.step(dev.alert, dev.alert_latched, now_ms)) {
        .none => {},
        .flash => {
            slot.request(setup.flash_s * 1000);
            model.report(io, "[leak] {s} is wet: flashing for {d} s", .{ setup.sensor, setup.flash_s }) catch {};
        },
        .stop => {
            slot.request(BridgeSender.STOP_FLASH);
            model.report(io, "[leak] {s}: dry or acknowledged, stopping the flash", .{setup.sensor}) catch {};
        },
    }
}

/// A rule's action on a Bridge light, handed to the sender.
fn toBridge(io: Io, model: *Model.Registry, config: *const Config, act: Engine.PendingAction) !void {
    var name_buf: [24]u8 = undefined;
    const name = ieeeText(&name_buf, act.target.bridge);
    const sender = bridge_sender orelse
        return model.report(io, "[bridge] {s} {t}: hub has no {s}", .{ name, act.action, BridgeSender.BRIDGE_FILE });
    const what: u32 = switch (act.action) {
        .on => BridgeSender.ON,
        .off => BridgeSender.OFF,
        else => return, // refused at load
    };
    const id = config.bridgeLightFor(act.target.bridge) orelse
        return model.report(io, "[bridge] {s}: no longer in {s}", .{ name, ConfigMod.BRIDGE_IDS_PATH });
    const slot = sender.slotFor(id) orelse
        return model.report(io, "[bridge] {s}: hub writes to {d} Bridge lights at most", .{ name, BridgeSender.SLOTS });
    slot.setLabel(name);
    slot.request(what);
}

/// What the Bridge said to each rule's write; the leak alert reads its own.
fn reportBridge(io: Io, model: *Model.Registry, sender: *BridgeSender.Sender) void {
    for (&sender.slots) |*slot| {
        if (!slot.claimed.load(.acquire)) break;
        if (leak_slot == slot) continue;
        const r = slot.takeResult() orelse continue;
        var buf: [32]u8 = undefined;
        const what = BridgeSender.describe(&buf, r.request);
        switch (r.outcome) {
            .none => {},
            .accepted => model.report(io, "[bridge] {s}: {s}, accepted", .{ slot.name(), what }) catch {},
            .failed => model.report(io, "[bridge] {s}: {s} failed twice", .{ slot.name(), what }) catch {},
        }
    }
}

fn ieeeText(buf: []u8, wire: [8]u8) []const u8 {
    var w = Io.Writer.fixed(buf);
    Ieee.printReversed(&w, &wire) catch return "?";
    return w.buffered();
}

/// Which commands can run with no radio. An allowlist, not a blocklist: a
/// command added later should default to "needs the radio" and be refused
/// safely, rather than default to "allowed" and fault.
fn commandNeedsRadio(line: []const u8) bool {
    const safe = [_][]const u8{ "help", "screen", "terminal", "quit", "exit", "list", "ack", "reload", "adopt", "leak" };
    const cmd = firstToken(line);
    for (safe) |s| if (std.mem.eql(u8, cmd, s)) return false;
    return true;
}

/// Runs one typed command, absorbing the failures that must not kill the
/// daemon.
///
/// `handleLine`'s per-command `catch`es cover the ordinary cases, but
/// several commands (`status`, `form`, `permit`, `group`) call straight
/// through to the radio with `try` — so before recovery existed, typing
/// `status` at a dead radio propagated `WriteFailed` out of `main` and
/// killed hub. That was survivable when any transport error was fatal
/// anyway; it isn't now. Observed for real (2026-07-17): `status` after a
/// cable pull took the process down with an error trace.
///
/// Transport errors are reported and swallowed **here** rather than
/// triggering recovery directly: a wedge is sticky, so the next top-of-loop
/// `pollOnce` (or heartbeat) enters recovery within a tick, keeping one
/// trigger site and one testable state machine. A logic bug still dies
/// loudly — same rule as the loop's.
fn runCommand(coord: *Coordinator, app: *AppState, io: Io, model: *Model.Registry, line: []const u8) !bool {
    // While the radio is down, refuse the commands that would touch it. On
    // the startup-wait path the transport is uninitialized memory, so this
    // is a crash guard, not a courtesy — see `Coordinator.link_up`.
    if (!coord.link_up and commandNeedsRadio(line)) {
        try coord.say("radio is down (recovering) — `{s}` needs it; the log will say when it's back", .{firstToken(line)});
        return true;
    }
    return handleLine(coord, app, line) catch |err| switch (LinkMod.classifyHeartbeatError(err)) {
        .recover => {
            try model.report(io, "command failed: {t} — the radio looks down; recovery starts on the next tick", .{err});
            return true; // keep running: the loop will handle the link
        },
        .propagate => return err,
    };
}

/// The one command dispatcher, for both control surfaces: the line console
/// reads a line from stdin and calls this; watch mode's command line
/// accumulates a line in the frame and calls
/// this. One command set, one parser, one implementation — the same
/// no-duplication move made by having its single-key actions call
/// the same `Coordinator` methods the console already did.
///
/// Responses go through `coord.say`, never `coord.out` directly: in watch
/// mode a direct write would land in the middle of the cursor-addressed
/// frame (see `say`'s doc comment). Returns `false` to exit hub.
fn handleLine(coord: *Coordinator, app: *AppState, line: []const u8) !bool {
    if (line.len == 0) return true;
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const cmd = it.next() orelse return true;

    if (std.mem.eql(u8, cmd, "quit") or std.mem.eql(u8, cmd, "exit")) {
        // Restore the terminal before the goodbye: typed from watch mode,
        // this is the one response that must not go into a frame that's
        // about to disappear.
        if (app.mode == .watch) try leaveWatchMode(coord, app);
        try coord.say("hub: bye", .{});
        return false;
    } else if (std.mem.eql(u8, cmd, "screen")) {
        // The same command from both modes: from the console it opens
        // watch mode, from watch mode's own command line it switches
        // screens (which is why the digit keys `1`/`2` are gone — see
        // tickWatch's doc comment).
        if (it.next()) |name| {
            if (std.mem.eql(u8, name, "overview") or std.mem.eql(u8, name, "devices")) {
                app.current_screen = .overview;
            } else if (std.mem.eql(u8, name, "config")) {
                app.current_screen = .config;
            } else if (std.mem.eql(u8, name, "help")) {
                app.current_screen = .help;
            } else {
                try coord.say("unknown screen '{s}' — try overview, config or help", .{name});
                return true;
            }
        }
        if (app.mode == .console) try enterWatchMode(coord, app);
    } else if (std.mem.eql(u8, cmd, "help")) {
        // In the TUI, printing help means dumping ~30 lines into a log that
        // renders only its last few — which destroys the log AND leaves a
        // JSON fragment on screen looking like a crash (first live run,
        // 2026-07-17). Show the help SCREEN instead; the command line stays
        // live underneath it, which is the whole point.
        if (app.mode == .watch) {
            app.current_screen = .help;
        } else {
            try sayHelp(coord);
        }
    } else if (std.mem.eql(u8, cmd, "status")) {
        try coord.printStatus();
    } else if (std.mem.eql(u8, cmd, "terminal")) {
        // The way out of watch mode. ESC used to do this,
        // and it was too clever by half: terminals send ↑/↓ and mouse-wheel
        // events as ESC-prefixed sequences, so a split burst ejected you into
        // the cooked console — which then echoed every further escape byte as
        // `^[[A` confetti. One key, three meanings, one of them destructive.
        // Now ESC only clears the command line and this is the only exit.
        if (app.mode == .watch) {
            try leaveWatchMode(coord, app);
        } else {
            try coord.say("already at the terminal — `screen` opens the dashboard", .{});
        }
    } else if (std.mem.eql(u8, cmd, "restore")) {
        // DESTRUCTIVE and rare: leaves the current network to rebuild a
        // saved one. So it reports the plan and does nothing unless the
        // line ends in `confirm` — the same shape as `backup force`, for
        // the same reason (a network is not something to replace because a
        // command was typed nearly right).
        //   restore                       → what it would do, from hub-coordinator.json
        //   restore confirm               → do it
        //   restore <file> [confirm]      → same, from an archived record
        var file: []const u8 = Persist.BACKUP_FILE;
        var confirmed = false;
        while (it.next()) |tok| {
            if (std.mem.eql(u8, tok, "confirm")) confirmed = true else file = tok;
        }

        var arena = std.heap.ArenaAllocator.init(coord.model.gpa);
        defer arena.deinit();
        const a_alloc = arena.allocator();
        var buf: [4096]u8 = undefined;
        const text = Io.Dir.cwd().readFile(coord.io, file, &buf) catch |err| {
            try coord.say("restore: cannot read {s}: {t}", .{ file, err });
            return true;
        };
        const backup = Persist.parseBackup(a_alloc, text) orelse {
            try coord.say("restore: {s} is not a readable backup", .{file});
            return true;
        };

        if (!confirmed) {
            try coord.say("restore would rebuild PAN 0x{X:0>4} (channel {d}) from {s}:", .{ backup.pan_id, backup.channel, file });
            try coord.say("  saved {s}, frame counter {d} → would set {d}", .{ backup.eui64, backup.outgoing_frame_counter, backup.outgoing_frame_counter +| Coordinator.RESTORE_COUNTER_MARGIN });
            if (backup.tclk_hash_seed == null) {
                try coord.say("  NO tclk_hash_seed: the network returns, but every device will need rejoining", .{});
            }
            try coord.say("  THIS LEAVES THE CURRENT NETWORK. Type `restore {s}confirm` to proceed.", .{if (std.mem.eql(u8, file, Persist.BACKUP_FILE)) "" else file});
            return true;
        }

        if (coord.restoreNetwork(backup)) |plan| {
            try coord.say("restore: PAN 0x{X:0>4} is up on channel {d} (counter set to {d}{s})", .{ plan.pan_id, plan.channel, plan.counter_to_set, if (plan.has_seed) "" else ", NO seed — devices need rejoining" });
            try coord.printStatus();
        } else |err| {
            try coord.say("restore FAILED: {t}", .{err});
        }
    } else if (std.mem.eql(u8, cmd, "backup")) {
        // Forces the rewrite the loop does hourly — mostly a verification
        // hook (run it twice a few minutes apart and watch
        // outgoing_frame_counter advance), but also the thing to run before
        // unplugging a radio on purpose.
        // `backup force` overwrites a record belonging to a different
        // network (renaming the old one aside first) — for when the new
        // network is genuinely the one you want kept.
        const force = if (it.next()) |tok| std.mem.eql(u8, tok, "force") else false;
        if (coord.writeBackup(force)) {
            try coord.say("wrote {s} (network key + frame counter + PAN/channel)", .{Persist.BACKUP_FILE});
        } else |err| switch (err) {
            error.BackupWouldClobberDifferentNetwork => {}, // already explained itself, in detail
            else => try coord.say("backup failed: {t}", .{err}),
        }
    } else if (std.mem.eql(u8, cmd, "scene")) {
        const usage = "usage: scene add <light> <1-255> <on|off> <0-100> | scene store|recall|view <light> <1-255>";
        const op_tok = it.next() orelse "";
        const op = std.meta.stringToEnum(Engine.Coordinator.SceneOp, op_tok) orelse {
            try coord.say("{s}", .{usage});
            return true;
        };
        const light = it.next() orelse "";
        // 0 in group 0 is the global scene the On/Off cluster keeps for itself.
        const scene_id = std.fmt.parseInt(u8, it.next() orelse "", 10) catch 0;
        if (light.len == 0 or scene_id == 0) {
            try coord.say("{s}", .{usage});
            return true;
        }
        var values: Zcl.SceneValues = .{};
        if (op == .add) {
            const on_tok = it.next() orelse "";
            const pct = std.fmt.parseInt(u8, it.next() orelse "", 10) catch 255;
            if (!(std.mem.eql(u8, on_tok, "on") or std.mem.eql(u8, on_tok, "off")) or pct > 100) {
                try coord.say("{s}", .{usage});
                return true;
            }
            values = .{ .on = std.mem.eql(u8, on_tok, "on"), .level = @intCast((@as(u16, pct) * 254 + 50) / 100) };
        }
        const ieee = try coord.resolveTarget(light) orelse {
            try coord.say("unknown device '{s}' — see `list`", .{light});
            return true;
        };
        coord.sceneCommand(ieee, light, op, scene_id, values) catch |err| {
            try coord.say("scene failed: {t}", .{err});
        };
    } else if (std.mem.eql(u8, cmd, "tables")) {
        try printTables(coord);
    } else if (std.mem.eql(u8, cmd, "leak")) {
        const slot = leak_slot orelse {
            try coord.say("leak alert is off: it needs {s} and {s}", .{ LeakAlert.SETUP_FILE, BridgeSender.BRIDGE_FILE });
            return true;
        };
        const sub = it.next() orelse "";
        if (std.mem.eql(u8, sub, "test")) {
            const seconds = if (it.next()) |tok| std.fmt.parseInt(u32, tok, 10) catch 5 else 5;
            const limited = std.math.clamp(seconds, 1, 60);
            slot.request(limited * 1000);
            try coord.say("[leak] test flash for {d} s", .{limited});
        } else if (std.mem.eql(u8, sub, "stop")) {
            slot.request(BridgeSender.STOP_FLASH);
            try coord.say("[leak] asked the light to stop", .{});
        } else {
            try coord.say("usage: leak test [seconds] | leak stop", .{});
        }
    } else if (std.mem.eql(u8, cmd, "reload")) {
        const confirm = if (it.next()) |tok| std.mem.eql(u8, tok, "confirm") else false;
        reloadConfig(coord, null, confirm) catch |err| {
            try coord.say("reload failed: {t} — keeping the running config", .{err});
        };
    } else if (std.mem.eql(u8, cmd, "adopt")) {
        if (it.next()) |dir| {
            const confirm = if (it.next()) |tok| std.mem.eql(u8, tok, "confirm") else false;
            reloadConfig(coord, dir, confirm) catch |err| {
                try coord.say("adopt failed: {t} — keeping the running config", .{err});
            };
        } else {
            try coord.say("usage: adopt DIR [confirm]", .{});
        }
    } else if (std.mem.eql(u8, cmd, "form")) {
        try coord.reformNetwork();
    } else if (std.mem.eql(u8, cmd, "permit")) {
        const secs: u8 = if (it.next()) |tok| std.fmt.parseInt(u8, tok, 10) catch 60 else 60;
        try coord.permitJoin(secs);
    } else if (std.mem.eql(u8, cmd, "list")) {
        try listDevices(coord);
    } else if (std.mem.eql(u8, cmd, "discover")) {
        try withTarget(coord, &it, "discover", Coordinator.discoverDevice);
    } else if (std.mem.eql(u8, cmd, "setup")) {
        const tok = it.next() orelse {
            try coord.say("usage: setup <target>", .{});
            return true;
        };
        const ieee = try coord.resolveTarget(tok) orelse {
            try coord.say("unknown device '{s}' — see `list`", .{tok});
            return true;
        };
        coord.setupDevice(ieee) catch |err| {
            if (err == error.ZdoTimeout) {
                if (coord.model.findByIeee(ieee)) |dev| dev.pending_setup = true;
                try coord.say("setup: no answer — device is probably asleep. Deferred: it will run", .{});
                try coord.say("automatically the next time the device announces, or re-run `setup`", .{});
                try coord.say("while pressing its buttons / triggering it once a second.", .{});
            } else {
                try coord.say("setup failed: {t}", .{err});
            }
        };
    } else if (std.mem.eql(u8, cmd, "bind") or std.mem.eql(u8, cmd, "unbind")) {
        const change: Coordinator.BindChange = if (std.mem.eql(u8, cmd, "bind")) .bind else .unbind;
        const source_tok = it.next();
        const target_tok = it.next();
        if (source_tok == null or target_tok == null) {
            try coord.say("usage: {s} <switch> <light>", .{cmd});
            return true;
        }
        const source = try coord.resolveTarget(source_tok.?) orelse {
            try coord.say("unknown device '{s}' — see `list`", .{source_tok.?});
            return true;
        };
        const target = try coord.resolveTarget(target_tok.?) orelse {
            try coord.say("unknown device '{s}' — see `list`", .{target_tok.?});
            return true;
        };
        coord.changeOutputBinding(change, source, target) catch |err| {
            try coord.say("{s} failed: {t}", .{ cmd, err });
        };
    } else if (std.mem.eql(u8, cmd, "remove")) {
        try withTarget(coord, &it, "remove", Coordinator.removeDevice);
    } else if (std.mem.eql(u8, cmd, "group")) {
        const tok = it.next() orelse {
            try coord.say("usage: group <name>  (joins every groups.json member to its group_id)", .{});
            return true;
        };
        const group = coord.config.groupByName(tok) orelse {
            try coord.say("unknown group '{s}' — see groups.json", .{tok});
            return true;
        };
        try coord.setupGroup(group);
    } else if (std.mem.eql(u8, cmd, "on") or std.mem.eql(u8, cmd, "off") or std.mem.eql(u8, cmd, "toggle")) {
        const tok = it.next() orelse {
            try coord.say("usage: {s} <target>", .{cmd});
            return true;
        };
        const command_id: u8 = if (std.mem.eql(u8, cmd, "on"))
            Zcl.ONOFF_CMD_ON
        else if (std.mem.eql(u8, cmd, "off"))
            Zcl.ONOFF_CMD_OFF
        else
            Zcl.ONOFF_CMD_TOGGLE;
        // A groups.json name gets the same on/off/toggle vocabulary as a
        // device — the "same control semantics as a single
        // bulb" — dispatched to the group (fire-and-forget multicast,
        // reported via the log the console already drains) instead of a
        // per-device unicast (confirm=true, blocks for Default Response).
        if (coord.config.groupIdFor(tok)) |group_id| {
            coord.sendGroupOnOff(group_id, command_id, tok) catch |err| {
                try coord.say("{s} failed: {t}", .{ cmd, err });
            };
            return true;
        }
        const ieee = try coord.resolveTarget(tok) orelse {
            try coord.say("unknown device or group '{s}' — see `list`", .{tok});
            return true;
        };
        coord.sendOnOff(ieee, command_id, cmd, true) catch |err| {
            try coord.say("{s} failed: {t}", .{ cmd, err });
        };
    } else if (std.mem.eql(u8, cmd, "identify")) {
        const usage = "usage: identify <device> [secs=10, 0 stops]";
        const tok = it.next() orelse {
            try coord.say("{s}", .{usage});
            return true;
        };
        const seconds: u16 = if (it.next()) |t| std.fmt.parseInt(u16, t, 10) catch {
            try coord.say("{s}", .{usage});
            return true;
        } else 10;
        const ieee = try coord.resolveTarget(tok) orelse {
            try coord.say("unknown device '{s}' — see `list`", .{tok});
            return true;
        };
        coord.sendIdentify(ieee, seconds, tok) catch |err| {
            try coord.say("identify failed: {t}", .{err});
        };
    } else if (std.mem.eql(u8, cmd, "ack")) {
        const tok = it.next() orelse {
            try coord.say("usage: ack <device>", .{});
            return true;
        };
        // Model-only (no radio — deliberately usable while the link is
        // down, hence its place on commandNeedsRadio's safe list), so the
        // name resolves through devices.json rather than resolveTarget's
        // radio-touching lookup path.
        const ieee = coord.config.ieeeFor(tok) orelse {
            try coord.say("unknown device '{s}' — see devices.json", .{tok});
            return true;
        };
        if (try coord.model.ackAlert(coord.io, ieee)) {
            try coord.say("{s}: alert acknowledged", .{tok});
        } else {
            try coord.say("{s}: no latched alert", .{tok});
        }
    } else if (std.mem.eql(u8, cmd, "colour") or std.mem.eql(u8, cmd, "color")) {
        const hex = it.next() orelse {
            try coord.say("usage: colour <#RRGGBB> <target>", .{});
            return true;
        };
        const tok = it.next() orelse {
            try coord.say("usage: colour <#RRGGBB> <target>", .{});
            return true;
        };
        const xy = ConfigMod.parseColourXy(hex) orelse {
            try coord.say("bad colour '{s}' — want #RRGGBB", .{hex});
            return true;
        };
        coord.setColour(tok, xy) catch |err| {
            try coord.say("colour failed: {t}", .{err});
        };
    } else if (std.mem.eql(u8, cmd, "colorcaps")) {
        const tok = it.next() orelse {
            try coord.say("usage: colorcaps <device>", .{});
            return true;
        };
        const ieee = try coord.resolveTarget(tok) orelse {
            try coord.say("unknown device '{s}'", .{tok});
            return true;
        };
        coord.probeColorCapabilities(ieee) catch |err| {
            try coord.say("colorcaps failed: {t}", .{err});
        };
    } else if (std.mem.eql(u8, cmd, "brightness")) {
        const usage = "usage: brightness <0-100> <target>";
        const pct_tok = it.next() orelse {
            try coord.say("{s}", .{usage});
            return true;
        };
        const tok = it.next() orelse {
            try coord.say("{s}", .{usage});
            return true;
        };
        const pct = std.fmt.parseInt(u8, pct_tok, 10) catch {
            try coord.say("{s}", .{usage});
            return true;
        };
        if (pct > 100) {
            try coord.say("{s}", .{usage});
            return true;
        }
        // Percent is a console-boundary convenience; everything below
        // speaks Zigbee's native 0-254 (100% = 254, the cluster's max).
        const level: u8 = @intCast((@as(u16, pct) * 254 + 50) / 100);
        if (coord.config.groupIdFor(tok)) |group_id| {
            coord.sendGroupLevelMoveToLevel(group_id, level, tok) catch |err| {
                try coord.say("brightness failed: {t}", .{err});
            };
            return true;
        }
        const ieee = try coord.resolveTarget(tok) orelse {
            try coord.say("unknown device or group '{s}' — see `list`", .{tok});
            return true;
        };
        coord.sendLevelMoveToLevel(ieee, level, tok) catch |err| {
            try coord.say("brightness failed: {t}", .{err});
        };
    } else {
        try coord.say("unknown command '{s}' — try `help`", .{cmd});
    }
    return true;
}

/// Each row is formatted into a buffer and emitted as one `say` call
/// rather than written field by field: `say`'s watch-mode sink is a list
/// of log entries, so a row has to arrive as a whole line, not as five
/// incremental writes that would land as five separate rows.
fn listDevices(coord: *Coordinator) !void {
    if (coord.model.devices.items.len == 0) {
        try coord.say("no devices seen yet — try `permit`", .{});
        return;
    }
    for (coord.model.devices.items) |dev| {
        var buf: [128]u8 = undefined;
        var w = Io.Writer.fixed(&buf);
        try w.print("{s: <10}", .{coord.config.nameFor(dev.ieee) orelse "-"});
        try Ieee.printReversed(&w, &dev.ieee);
        try w.print("  nwk=0x{X:0>4}  {s}", .{ dev.nwk, if (dev.joined) "joined" else "left" });
        if (dev.onoff_endpoint) |ep| {
            try w.print("  onoff-ep={d}", .{ep});
        }
        try coord.say("{s}", .{w.buffered()});
    }
}

/// Shared "resolve a target token, call `action`, report the error"
/// pattern for the handful of one-target commands.
/// `tables`: the sizes the radio really settled on, because a request it refuses
/// leaves its own value in place. Read-only. EZSP config ids, UG100 table.
/// How often `network.json` is written: it asks the radio six questions.
const NETWORK_MS: i64 = 60_000;

fn printTables(coord: *Coordinator) !void {
    const Table = struct { id: u16, name: []const u8 };
    const tables = [_]Table{
        .{ .id = 0x01, .name = "packet buffers" },
        .{ .id = 0x02, .name = "router neighbours" },
        .{ .id = 0x04, .name = "bindings" },
        .{ .id = 0x05, .name = "address table" },
        .{ .id = 0x06, .name = "multicast groups" },
        .{ .id = 0x07, .name = "routes" },
        .{ .id = 0x08, .name = "route discoveries" },
        .{ .id = 0x11, .name = "end device children" },
        .{ .id = 0x19, .name = "trust centre address cache" },
        .{ .id = 0x1A, .name = "source routes" },
        .{ .id = 0x1E, .name = "key table" },
    };
    for (tables) |t| {
        const r = try coord.ezsp.getConfigurationValue(t.id);
        if (r.status == 0) {
            try coord.say("{s}: {d}", .{ t.name, r.value });
        } else {
            try coord.say("{s}: not readable (status 0x{x:0>2})", .{ t.name, r.status });
        }
    }
}

/// The files `reload` reads, which `adopt` takes from elsewhere.
const ADOPTED_FILES = [_][]const u8{ ConfigMod.DEVICES_FILE, ConfigMod.RULES_FILE, ConfigMod.GROUPS_FILE, ConfigMod.SCHEDULES_FILE };

/// `reload`: re-reads the config files. Bare, it only reports what would change;
/// `reload confirm` applies it. A file with any problem is refused whole, and the
/// running config carries on untouched.
///
/// `adopt DIR` does the same with the files in DIR, a copy made elsewhere, and on
/// `confirm` also puts them in place of hub's own, so a restart keeps them. Each
/// must be there: a file that's missing reads as empty, which would silently
/// drop every device or rule it held.
fn reloadConfig(coord: *Coordinator, from: ?[]const u8, confirm: bool) !void {
    const gpa = coord.model.gpa;
    const io = coord.io;
    const verb = if (from == null) "reload" else "adopt";
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    const dir = if (from) |path| Io.Dir.cwd().openDir(io, path, .{}) catch |err| {
        return coord.say("adopt: cannot open {s} ({t}) — keeping the running config", .{ path, err });
    } else Io.Dir.cwd();
    defer if (from != null) dir.close(io);
    if (from) |path| for (ADOPTED_FILES) |name| {
        _ = dir.statFile(io, name, .{}) catch |err| {
            return coord.say("adopt: {s} has no {s} ({t}) — keeping the running config", .{ path, name, err });
        };
    };

    const new = try Config.loadChecked(gpa, io, dir, Io.Dir.cwd(), &aw.writer) orelse {
        try sayLines(coord, aw.writer.buffered());
        try coord.say("{s} refused — keeping the running config", .{verb});
        return;
    };
    const count = try ConfigMod.writeChanges(coord.config, new, &aw.writer);
    try sayLines(coord, aw.writer.buffered());

    if (count == 0 or !confirm) {
        if (count == 0) {
            try coord.say("{s}: nothing to apply", .{verb});
        } else {
            try coord.say("{s}: {d} change(s) — nothing applied yet, `{s}{s}{s} confirm` applies them", .{ verb, count, verb, if (from != null) " " else "", from orelse "" });
        }
        new.deinit();
        gpa.destroy(new);
        return;
    }
    coord.adoptConfig(new) catch |err| {
        new.deinit();
        gpa.destroy(new);
        return err;
    };
    try coord.say("{s}: {d} change(s) applied", .{ verb, count });
    if (from != null) try copyAdopted(coord, dir);
}

/// After `adopt`: hub's own files become the ones it now runs.
fn copyAdopted(coord: *Coordinator, from: Io.Dir) !void {
    const gpa = coord.model.gpa;
    const io = coord.io;
    for (ADOPTED_FILES) |name| {
        const text = from.readFileAlloc(io, name, gpa, .limited(ConfigMod.MAX_CONFIG_FILE)) catch |err| {
            try coord.say("adopt: running the new config, but {s} wasn't copied ({t}): copy it by hand, or a restart goes back to the old one", .{ name, err });
            continue;
        };
        defer gpa.free(text);
        Persist.writeFileAtomic(io, Io.Dir.cwd(), name, text) catch |err| {
            try coord.say("adopt: running the new config, but {s} wasn't copied ({t}): copy it by hand, or a restart goes back to the old one", .{ name, err });
        };
    }
}

fn sayLines(coord: *Coordinator, text: []const u8) !void {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| try coord.say("{s}", .{line});
}

fn withTarget(
    coord: *Coordinator,
    it: *std.mem.TokenIterator(u8, .scalar),
    name: []const u8,
    action: fn (*Coordinator, [8]u8) anyerror!void,
) !void {
    const tok = it.next() orelse {
        try coord.say("usage: {s} <target>", .{name});
        return;
    };
    const ieee = try coord.resolveTarget(tok) orelse {
        try coord.say("unknown device '{s}' — see `list`", .{tok});
        return;
    };
    action(coord, ieee) catch |err| {
        try coord.say("{s} failed: {t}", .{ name, err });
    };
}

test "hubLogFn routes into model.report once a target is registered" {
    // Calls hubLogFn directly rather than through std.log.warn(...): under
    // `zig test`, the compiler's own bundled test runner is the actual
    // compilation root (not this file), so std.options.logFn there is
    // never wired to hubLogFn regardless of this file's std_options
    // declaration — that override only takes effect for the real
    // `zig build`/`zig build run` binary, where main.zig genuinely is the
    // root. This test exercises hubLogFn's own routing logic directly,
    // independent of that build-mode-specific wiring.
    const S = struct {
        var threaded: std.Io.Threaded = .init_single_threaded;
    };
    const io = S.threaded.io();
    const gpa = std.testing.allocator;

    var model = Model.Registry.init(gpa);
    defer model.deinit();

    // Before registration: falls through to the default sink without
    // touching `model` — asserted below by the tail containing only the
    // one message logged after registration.
    g_log_target = null;
    hubLogFn(.debug, .default, "unrouted, should not appear in the log", .{});

    g_log_target = .{ .registry = &model, .io = io };
    defer g_log_target = null;
    hubLogFn(.warn, .default, "routed message {d}", .{42});

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const tail = try model.tailLog(io, 5, arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), tail.len);
    try std.testing.expectEqualStrings("[log:warning] routed message 42", tail[0]);
}

test "Semantic Check" {
    // Forces semantic analysis of every module in the graph, so a broken
    // copy/port surfaces in `zig build test` even before main uses it.
    // main() itself isn't called (needs a real serial port + radio), same
    // convention both predecessors used for their live-networking entry points.
    std.testing.refAllDecls(@This());
}
