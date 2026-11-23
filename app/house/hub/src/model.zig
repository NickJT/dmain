//! Zigbee-native device registry. Successor to the predecessor daemon's `Ctx.devices` flat
//! array: the same table shape and self-healing semantics
//! (upsert on join/announce/address-response, swap-remove on leave), but
//! growable instead of a fixed `MAX_DEVICES`, and guarded by a mutex +
//! revision counter (an earlier Hue monitor's `Model` pattern) so a
//! future TUI/web reader can safely arena-clone a snapshot instead of
//! touching live memory — proven workable for this exact
//! io.async-tasks-plus-shared-state shape by `src/spike_loop.zig`.
//!
//! Naming/rooms are NOT stored here — `config.zig`'s devices.json is the
//! single source of truth for those; this module only tracks what the
//! network itself tells us (identity, live/discovered state).
const std = @import("std");
const Io = std.Io;
const Ieee = @import("ieee");
const Persist = @import("persist");
const Local = @import("local_time");

pub const Device = struct {
    ieee: [8]u8, // wire order
    nwk: u16,
    joined: bool = true,
    // Discovered capability endpoints — set once by `discoverDevice`
    // (`d.hasInputCluster(...)`, mirrored three times over) and persisted
    // (see `DeviceRecord`/`save`/`load` below), same as identity: what a
    // device IS doesn't change session to session, unlike the live
    // readings below. Used by `web.zig`'s status JSON to categorize
    // devices (lights vs. motion sensors vs. alerting sensors) without
    // waiting for a live reading to arrive first.
    onoff_endpoint: ?u8 = null,
    occupancy_endpoint: ?u8 = null,
    ias_zone_endpoint: ?u8 = null,
    // The IAS zone type from its Zone Enroll Request, which is the only place a
    // sensor says what it senses: a zone status report just says "alarm".
    zone_type: ?u16 = null,
    // What it is, from its Basic cluster. Persisted, as a sleeping sensor may
    // take days to answer again.
    model_id: ?ShortText = null,
    firmware: ?ShortText = null,
    // Its ZCL startup attributes, raw: on/off 0 off, 1 on, 2 toggle, 0xFF previous;
    // level 0 minimum, 0xFF previous, otherwise that level. Session state: re-read
    // at each start, because this is the thing that can quietly change.
    startup_on_off: ?u8 = null,
    startup_level: ?u8 = null,
    // A light stopped answering its polls, and the house log has been told.
    reported_lost: bool = false,
    // Pacing for `pollSettings`. Session state.
    settings_polled_ms: i64 = 0,
    settings_next: u8 = 0,
    settings_rounds: u8 = 0,
    // Set when a device SENDS us a cluster-specific command (a dimmer
    // button, a dial rotation) rather than reporting an attribute — i.e.
    // it drives other devices. The three slots above are all *input*
    // clusters, which a controller has none of: `discoverDevice` looks at
    // `hasInputCluster` only, so a dimmer discovers as entirely
    // capability-less and is indistinguishable from a device we've simply
    // never discovered. That mattered once screens.zig started grouping by
    // role — without this, "controller" would be a guess
    // about every unclassified device, which is exactly what the
    // learn-from-traffic rule exists to avoid.
    controller_endpoint: ?u8 = null,
    // Color Control cluster endpoint. Set from the
    // descriptor walk only — a bulb never SENDS a colour command, so
    // there's no learn-from-traffic path like the others have; a
    // colour-capable light either gets discovered/set-up or it doesn't.
    // A rule's colour is skipped (silently) for a device with this null.
    color_endpoint: ?u8 = null,
    // `setup` timed out (device asleep) — retried automatically the next
    // time it proves it's awake (Device Announce / fresh join). Session
    // state only, not persisted.
    pending_setup: bool = false,
    // Monotonic ms when we last queued a rule action targeting this device
    // (the rules engine). Session state only, not persisted.
    last_action_ms: i64 = 0,

    // Live sensor/state readings — populated by engine.zig's ZCL event
    // decoding (`Registry.recordReading`), for the TUI
    // real-time screen. Session state only, not persisted: these are
    // exactly the kind of thing that goes stale the moment the process
    // restarts, unlike identity/nwk which the network can't re-derive for
    // free. `null` means "never reported this session", not "off"/"zero".
    battery_pct: ?u8 = null, // BatteryPercentageRemaining, half-percent units halved already
    temperature_centi: ?i16 = null, // hundredths of a degree C
    humidity_centi: ?u16 = null, // hundredths of a percent relative humidity
    illuminance_raw: ?u32 = null, // raw MeasuredValue; screens.zig converts to lux
    occupancy: ?bool = null,
    on: ?bool = null, // On/Off cluster's own OnOff attribute (0x0000)
    alert: ?bool = null, // IAS Zone's alarm1 bit (ZoneStatusChangeNotification)
    // Alert LATCH: `alert` is level-triggered — always
    // just the last reading — so a sub-3-second leak trip between web
    // polls used to vanish entirely (a gap found with the web server). The first ALARM sets
    // this and it stays set until a human clears it (`ackAlert` — web
    // acknowledge button or console `ack <name>`), independent of the live
    // state going back to clear. Session state, same rule as every live
    // reading. `alert_latched_at_s` is epoch seconds — wall-clock, not
    // monotonic, because it's shown to a human ("latched 14:32") and the
    // browser formats it in its own local time.
    alert_latched: bool = false,
    alert_latched_at_s: i64 = 0,
    // Monotonic ms of the last upsert (join/announce/address-response) or
    // recordReading call — "how fresh is this row" for the TUI.
    last_seen_ms: i64 = 0,
    // The last hop's link quality and signal for its latest frame. For a device
    // routed through another, that's the router's link. Session state.
    lqi: ?u8 = null,
    rssi: ?i8 = null,
    // Monotonic ms of the last On/Off state poll sent to this device
    // (`pollStaleState`). Session state, not persisted: it paces the
    // asking, and after a restart everything is stale by definition anyway.
    state_polled_ms: i64 = 0,
};

pub const UpsertResult = enum { new, rejoined, reassociated, unchanged };

/// A short string kept inside `Device`, which is copied by value into snapshots.
pub const ShortText = struct {
    len: u8 = 0,
    bytes: [32]u8 = undefined,

    pub fn of(text: []const u8) ShortText {
        var t: ShortText = .{};
        t.len = @intCast(@min(text.len, t.bytes.len));
        @memcpy(t.bytes[0..t.len], text[0..t.len]);
        return t;
    }

    pub fn slice(self: *const ShortText) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// One decoded live reading, as reported by engine.zig's ZCL attribute
/// decoding. A tagged union rather than one method per reading type keeps
/// `Registry`'s public surface from growing one function per cluster.
pub const Reading = union(enum) {
    battery_pct: u8,
    temperature_centi: i16,
    humidity_centi: u16,
    illuminance_raw: u32,
    occupancy: bool,
    on: bool,
    alert: bool,
};

/// Bounded so a long-lived resident process can't grow this forever —
/// unlike the monitor's interactive session (restarted routinely), hub is meant
/// to run indefinitely. Generous enough to give a freshly-opened TUI
/// screen real scrollback.
const MAX_LOG_ENTRIES: usize = 500;

pub const Registry = struct {
    gpa: std.mem.Allocator,
    devices: std.ArrayList(Device),
    mutex: Io.Mutex,
    revision: std.atomic.Value(usize),
    // A pending_setup device just announced/joined (= it's awake NOW).
    // Set inside upsert; the engine's main loop runs the deferred setup —
    // never nested inside a poll callback (mirrors the predecessor's
    // `awake_pending_setup` discipline).
    awake_pending_setup: ?[8]u8 = null,
    // Scrolling event log (the monitor's `Model.log` pattern) — engine.zig's
    // unsolicited/async event lines (`[event]`/`[report]`/`[rule]`) go
    // here via `report()` instead of being printed directly, so both the
    // line console (drains + prints new entries each tick) and a future
    // TUI screen (`View.renderLog` on the tail) can consume the same
    // stream. Command *responses* (a `setup`/`on`/`discover` reply) are
    // synchronous to a typed command and stay as direct `self.out.print`
    // in engine.zig — they only ever fire in console mode.
    log: std.Deque([]const u8),
    // Monotonically increasing count of every `report()` call ever made,
    // independent of `log.len` (which shrinks on eviction) — lets a
    // consumer (main.zig's console-mode drain) track "how many entries
    // have I already printed" without needing deque-position bookkeeping
    // that eviction would invalidate. Single-threaded-loop-only right
    // now, so a plain counter (no atomic) is enough — the same convention
    // `revision` would need revisiting under the io.async migration.
    log_total: usize = 0,
    /// Bumped by every `save`, which is every change to what a device is. Lets a
    /// reader notice one without a hook at each site that makes one.
    save_count: usize = 0,
    /// Append-only mirror of every `report()` line. The in-memory log above caps at MAX_LOG_ENTRIES, so an
    /// unattended 2am wedge-and-recovery has scrolled away by morning —
    /// which is precisely the event recovery exists for, and precisely the
    /// event nobody is watching. Every real bug in this project was
    /// diagnosed from live log output; this is that output, kept.
    ///
    /// Covers `std.log` too, for free: `main.zig`'s `hubLogFn` routes those
    /// through `report()` as well. And startup-phase lines + console command
    /// responses via `logToFile` (which mirrors here without the in-memory
    /// log), so a clean start and every command are in the durable record,
    /// not only recoveries and async events.
    ///
    /// Null = no sink (tests, or a file we couldn't open — see `openLog`:
    /// a coordinator that can't write a log file is still a coordinator).
    log_file: ?Io.File = null,
    /// Append offset for `log_file`. Tracked explicitly rather than relying
    /// on a file position, because `Io.File` here has no seek and
    /// `writeStreamingAll` would write from byte 0 — silently overwriting
    /// the history this file exists to keep. Safe without O_APPEND locking:
    /// only one hub can run at a time (the serial port is opened
    /// exclusively — see serial.zig's TIOCEXCL).
    log_offset: u64 = 0,

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{
            .gpa = gpa,
            .devices = .empty,
            .mutex = .init,
            .revision = std.atomic.Value(usize).init(0),
            .log = std.Deque([]const u8).empty,
        };
    }

    pub fn deinit(self: *Registry) void {
        self.devices.deinit(self.gpa);
        while (self.log.popFront()) |item| self.gpa.free(item);
        self.log.deinit(self.gpa);
    }

    pub const LOG_FILE = "hub.log";
    /// Past this, `openLog` warns once. No rotation: these are low-rate
    /// human-readable event lines, and a size check at startup is enough
    /// until it demonstrably isn't.
    const LOG_WARN_BYTES: u64 = 10 * 1024 * 1024;

    /// Opens `hub.log` for appending. Best-effort by design: on failure it
    /// warns and leaves the sink null, because a coordinator that can't
    /// write its log is still a working coordinator — the house's lights
    /// matter more than the diary.
    pub fn openLog(self: *Registry, io: Io, dir: Io.Dir) void {
        const file = dir.createFile(io, LOG_FILE, .{ .truncate = false }) catch |err| {
            std.log.warn("cannot open {s} ({t}) — running without a persistent log", .{ LOG_FILE, err });
            return;
        };
        // Append from wherever the last session stopped: never truncate.
        // The point is surviving restarts, and a crash-restart loop that
        // erased its own evidence each time would be worse than no log.
        const size: u64 = if (file.stat(io)) |st| st.size else |_| 0;
        if (size > LOG_WARN_BYTES) {
            std.log.warn("{s} is {d} MB — no rotation exists yet; move it aside if it bothers you", .{ LOG_FILE, size / (1024 * 1024) });
        }
        self.log_offset = size;
        self.log_file = file;
    }

    pub fn closeLog(self: *Registry, io: Io) void {
        if (self.log_file) |f| f.close(io);
        self.log_file = null;
    }

    /// Mirrors one already-formatted line to `hub.log`, timestamped.
    /// Caller holds the mutex (`report` does).
    ///
    /// The timestamp is added HERE and not to the in-memory entry on
    /// purpose: the TUI renders those into a fixed-width box where eight
    /// columns of clock on every row would cost more than they're worth,
    /// and the console prints them as they happen. A file read tomorrow
    /// morning has neither of those contexts and needs the time.
    ///
    /// Failures disable the sink rather than propagate: one warning, then
    /// silence. A full disk must not take the coordinator down, and must
    /// not print a warning per line either.
    fn mirrorToFile(self: *Registry, io: Io, txt: []const u8) void {
        const file = self.log_file orelse return;
        var buf: [512]u8 = undefined;
        var w = Io.Writer.fixed(&buf);
        Local.formatLocalTime(io, &w) catch {};
        w.print(" {s}\n", .{txt}) catch {
            // Line longer than the buffer: keep the timestamp, truncate the
            // message. A clipped line beats a lost one.
            w.writeAll("\n") catch {};
        };
        const bytes = w.buffered();
        file.writePositionalAll(io, bytes, self.log_offset) catch |err| {
            std.log.warn("{s} write failed ({t}) — disabling the persistent log for this session", .{ LOG_FILE, err });
            self.log_file = null;
            return;
        };
        self.log_offset += bytes.len;
    }

    /// Writes one line to `hub.log` ONLY — not the in-memory scrolling log,
    /// and not the console. For startup-phase lines that already print to
    /// the console directly via `self.out` for live progress (bootstrap
    /// summary, group auto-setup): this mirrors them into the durable record
    /// so a clean start is visible in `hub.log` like a recovery is, WITHOUT
    /// the in-memory log's console drain re-printing them (a double). Same
    /// best-effort, never-propagate contract as `report`.
    pub fn logToFile(self: *Registry, io: Io, comptime fmt: []const u8, args: anytype) void {
        self.mutex.lock(io) catch return;
        defer self.mutex.unlock(io);
        const txt = self.gpa.print(fmt, args) catch return;
        defer self.gpa.free(txt);
        self.mirrorToFile(io, txt);
    }

    /// Appends one formatted line to the scrolling log, evicting the
    /// oldest entry once `MAX_LOG_ENTRIES` is exceeded. On allocation
    /// failure the message is silently dropped rather than propagating —
    /// a missed log line is not worth crashing the coordinator over.
    pub fn report(self: *Registry, io: Io, comptime fmt: []const u8, args: anytype) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        const txt = self.gpa.print(fmt, args) catch return;
        self.mirrorToFile(io, txt);
        self.log.pushBack(self.gpa, txt) catch {
            self.gpa.free(txt);
            return;
        };
        self.log_total += 1;
        while (self.log.len > MAX_LOG_ENTRIES) {
            if (self.log.popFront()) |old| self.gpa.free(old);
        }
    }

    /// Where a new reader of the log should start, to see only what comes next.
    pub fn logPosition(self: *Registry, io: Io) !usize {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        return self.log_total;
    }

    /// Prints every log line the caller hasn't seen yet, and advances its
    /// cursor. `cursor` is the caller's own "how many entries have I
    /// printed" counter (see `log_total`).
    ///
    /// Shared so that BOTH the console's per-tick drain and
    /// `engine.zig`'s `say` can use it. `say` calls this before printing a
    /// command's response, which is what keeps the two output paths in order:
    /// without it, a command's `[report]`-style lines (queued, drained next
    /// tick) appeared AFTER its response (printed immediately) — so `setup
    /// moisture` printed "no answer — device is probably asleep" *before*
    /// "hub: setting up moisture", which reads like nonsense.
    pub fn drainTo(self: *Registry, io: Io, out: *Io.Writer, cursor: *usize) !void {
        if (self.log_total <= cursor.*) return;
        const new_count = self.log_total - cursor.*;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const tail = try self.tailLog(io, @intCast(new_count), arena.allocator());
        for (tail) |line| try out.print("{s}\n", .{line});
        if (tail.len > 0) try out.flush();
        cursor.* = self.log_total;
    }

    /// Returns the last `tail_len` log entries (or fewer if shorter),
    /// dupe'd into `arena` — non-destructive, mirrors the monitor's `tailLog`.
    pub fn tailLog(self: *Registry, io: Io, tail_len: u32, arena: std.mem.Allocator) ![][]const u8 {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        const len = self.log.len;
        const start: usize = if (len > tail_len) len - @as(usize, tail_len) else 0;
        var out = std.ArrayList([]const u8).empty;
        for (start..len) |i| {
            try out.append(arena, try arena.dupe(u8, self.log.at(i)));
        }
        return out.toOwnedSlice(arena);
    }

    /// Records one live reading against `ieee` and bumps the revision so
    /// a TUI consumer knows to redraw. No-op (not an error) if the device
    /// isn't in the table yet — a reading can arrive interleaved with the
    /// self-healing IEEE lookup that would otherwise add it.
    pub fn recordReading(self: *Registry, io: Io, ieee: [8]u8, reading: Reading) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        const dev = self.findByIeee(ieee) orelse return;
        switch (reading) {
            .battery_pct => |v| dev.battery_pct = v,
            .temperature_centi => |v| dev.temperature_centi = v,
            .humidity_centi => |v| dev.humidity_centi = v,
            .illuminance_raw => |v| dev.illuminance_raw = v,
            .occupancy => |v| dev.occupancy = v,
            .on => |v| dev.on = v,
            .alert => |v| {
                dev.alert = v;
                if (v) {
                    dev.alert_latched = true;
                    dev.alert_latched_at_s = @divTrunc(Io.Timestamp.now(io, .real).toMilliseconds(), 1000);
                }
            },
        }
        dev.last_seen_ms = Io.Timestamp.now(io, .awake).toMilliseconds();
        _ = self.revision.fetchAdd(1, .release);
    }

    /// Clears a latched alert — the human saying "seen
    /// it". Returns false if the device is unknown or nothing was latched,
    /// so callers can word their response honestly. Does NOT touch the live
    /// `alert` — if the sensor is still wet, the next report re-latches,
    /// which is exactly right.
    pub fn ackAlert(self: *Registry, io: Io, ieee: [8]u8) !bool {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        const dev = self.findByIeee(ieee) orelse return false;
        if (!dev.alert_latched) return false;
        dev.alert_latched = false;
        _ = self.revision.fetchAdd(1, .release);
        return true;
    }

    /// Arena-cloned snapshot of every device, safe to read from a task
    /// running concurrently with the engine's poll loop —
    /// the web server is the first genuine second consumer of live
    /// device state (see this file's module doc comment). `Device` owns no pointers/slices, so the "clone" is a
    /// plain arena dupe, not `deep.zig`'s generic recursive one (that's
    /// for structs with strings/slices, which this one has none of).
    pub fn snapshotDevices(self: *Registry, io: Io, arena: std.mem.Allocator) ![]Device {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        return arena.dupe(Device, self.devices.items);
    }

    pub fn findByIeee(self: *Registry, ieee: [8]u8) ?*Device {
        for (self.devices.items) |*d| {
            if (std.mem.eql(u8, &d.ieee, &ieee)) return d;
        }
        return null;
    }

    /// Notes the last hop's link quality for a frame from `nwk`, if it's known.
    pub fn noteLink(self: *Registry, io: Io, nwk: u16, lqi: u8, rssi: i8) void {
        self.mutex.lock(io) catch return;
        defer self.mutex.unlock(io);
        const dev = self.findByNwk(nwk) orelse return;
        dev.lqi = lqi;
        dev.rssi = rssi;
    }

    pub fn findByNwk(self: *Registry, nwk: u16) ?*Device {
        for (self.devices.items) |*d| {
            if (d.nwk == nwk) return d;
        }
        return null;
    }

    /// Inserts or updates a device's nwk/joined state. Mirrors the predecessor's
    /// `upsertDevice`: a known device gets its nwk refreshed and
    /// `joined` set true (the caller decides whether the transition is
    /// worth a log line via the returned tag); an unknown one is appended.
    /// Sets `awake_pending_setup` when a device that was waiting on a
    /// deferred `setup` just proved it's awake.
    pub fn upsert(self: *Registry, io: Io, ieee: [8]u8, nwk: u16) !UpsertResult {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        const now = Io.Timestamp.now(io, .awake).toMilliseconds();
        if (self.findByIeee(ieee)) |dev| {
            const nwk_changed = dev.nwk != nwk;
            const rejoined = !dev.joined;
            dev.nwk = nwk;
            dev.joined = true;
            dev.last_seen_ms = now;
            if (nwk_changed or rejoined) _ = self.revision.fetchAdd(1, .release);
            if (dev.pending_setup) self.awake_pending_setup = ieee;
            if (nwk_changed) return .reassociated;
            if (rejoined) return .rejoined;
            return .unchanged;
        }
        try self.devices.append(self.gpa, .{ .ieee = ieee, .nwk = nwk, .last_seen_ms = now });
        _ = self.revision.fetchAdd(1, .release);
        return .new;
    }

    /// Marks `dev.joined = false` without removing it from the table (a
    /// left device may rejoin later and should keep its history).
    pub fn markLeft(self: *Registry, io: Io, ieee: [8]u8) !bool {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        const dev = self.findByIeee(ieee) orelse return false;
        if (!dev.joined) return false;
        dev.joined = false;
        _ = self.revision.fetchAdd(1, .release);
        return true;
    }

    /// Swap-removes a device. Invalidates `Device` pointers (the last
    /// entry moves) — callers must not hold one across this call.
    pub fn delete(self: *Registry, io: Io, ieee: [8]u8) !bool {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        for (self.devices.items, 0..) |*d, i| {
            if (std.mem.eql(u8, &d.ieee, &ieee)) {
                if (self.awake_pending_setup) |p| {
                    if (std.mem.eql(u8, &p, &ieee)) self.awake_pending_setup = null;
                }
                _ = self.devices.swapRemove(i);
                _ = self.revision.fetchAdd(1, .release);
                return true;
            }
        }
        return false;
    }

    pub const DEVICES_FILE = "hub-devices.json";

    const DeviceRecord = struct {
        ieee: []const u8,
        nwk: []const u8, // "0x1234"
        onoff_endpoint: ?u8,
        occupancy_endpoint: ?u8 = null,
        ias_zone_endpoint: ?u8 = null,
        zone_type: ?u16 = null,
        controller_endpoint: ?u8 = null,
        color_endpoint: ?u8 = null,
        model_id: ?[]const u8 = null,
        firmware: ?[]const u8 = null,
    };
    const DeviceFile = struct { devices: []DeviceRecord };

    /// Persists the table as JSON. This is the piece the NCP does NOT keep
    /// for us (its RAM tables reset on every serial port open) — without
    /// it, a restart forgets which nwk each still-joined device has.
    pub fn save(self: *Registry, io: Io, dir: Io.Dir) void {
        self.save_count += 1;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const records = a.alloc(DeviceRecord, self.devices.items.len) catch return;
        // By pointer: `slice()` below borrows from the device, so a copy made for
        // this loop would leave every record reading the last device's text.
        for (self.devices.items, 0..) |*d, i| {
            const ieee_str = Ieee.formatReversedAlloc(a, &d.ieee) catch return;
            const nwk_str = a.print("0x{x:0>4}", .{d.nwk}) catch return;
            records[i] = .{
                .ieee = ieee_str,
                .nwk = nwk_str,
                .onoff_endpoint = d.onoff_endpoint,
                .occupancy_endpoint = d.occupancy_endpoint,
                .zone_type = d.zone_type,
                .model_id = if (d.model_id) |*t| t.slice() else null,
                .firmware = if (d.firmware) |*t| t.slice() else null,
                .ias_zone_endpoint = d.ias_zone_endpoint,
                .controller_endpoint = d.controller_endpoint,
                .color_endpoint = d.color_endpoint,
            };
        }

        var aw: Io.Writer.Allocating = .init(a);
        std.json.Stringify.value(DeviceFile{ .devices = records }, .{}, &aw.writer) catch return;
        // Atomic: this file is rewritten on every join, so
        // a direct write left a window where a crash mid-write truncated
        // the only record of which nwk each device holds.
        Persist.writeFileAtomic(io, dir, DEVICES_FILE, aw.writer.buffered()) catch |err| {
            std.log.warn("save {s}: {t}", .{ DEVICES_FILE, err });
        };
    }

    /// Loads the table from JSON. Absent file is fine (empty table, not an
    /// error) — a fresh hub checkout has never seen any devices yet.
    pub fn load(self: *Registry, io: Io, dir: Io.Dir) void {
        var buf: [16384]u8 = undefined;
        const text = dir.readFile(io, DEVICES_FILE, &buf) catch return;

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const parsed = std.json.parseFromSliceLeaky(DeviceFile, arena.allocator(), text, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| {
            std.log.warn("{s} parse failed: {t} — starting with an empty device table", .{ DEVICES_FILE, err });
            return;
        };
        // Stamped to "now" (process start), not left at the zero default:
        // a freshly loaded device hasn't been touched by real traffic yet
        // this session, but `last_seen_ms = 0` would make screens.zig's
        // "age since last seen" compute `now - 0`, i.e. the raw `.awake`
        // clock reading (time since boot/wake, not since this device was
        // last seen) — a huge, meaningless number until the device's
        // first real event this session overwrites it via upsert/
        // recordReading. "we don't actually know, so treat load time as
        // the reference point" is the honest default here.
        const now = Io.Timestamp.now(io, .awake).toMilliseconds();
        for (parsed.devices) |rec| {
            const ieee = Ieee.parseReversed(rec.ieee) catch continue;
            const nwk_text = if (std.mem.startsWith(u8, rec.nwk, "0x")) rec.nwk[2..] else rec.nwk;
            const nwk = std.fmt.parseInt(u16, nwk_text, 16) catch continue;
            self.devices.append(self.gpa, .{
                .ieee = ieee,
                .nwk = nwk,
                .onoff_endpoint = rec.onoff_endpoint,
                .occupancy_endpoint = rec.occupancy_endpoint,
                .ias_zone_endpoint = rec.ias_zone_endpoint,
                .zone_type = rec.zone_type,
                .model_id = if (rec.model_id) |t| ShortText.of(t) else null,
                .firmware = if (rec.firmware) |t| ShortText.of(t) else null,
                .controller_endpoint = rec.controller_endpoint,
                .color_endpoint = rec.color_endpoint,
                .last_seen_ms = now,
            }) catch return;
        }
    }
};

/// `upsert`/`markLeft`/`delete`/`report`/`tailLog`/`recordReading` all call
/// `Io.Timestamp.now`/`Io.Mutex.lock`, which — unlike the mutex's
/// uncontended fast path — unconditionally dereference the `Io` vtable, so
/// (unlike some other modules' tests elsewhere in this codebase) `undefined`
/// is not a safe stand-in here. `std.Io.Threaded.init_single_threaded` gives
/// tests a real, working `Io` with no actual async/thread-pool machinery.
fn testIo() std.Io {
    const S = struct {
        var threaded: std.Io.Threaded = .init_single_threaded;
    };
    return S.threaded.io();
}

test "upsert: new device, then unchanged, then reassociated" {
    const io = testIo();
    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();

    const ieee: [8]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    try std.testing.expectEqual(UpsertResult.new, try reg.upsert(io, ieee, 0x1111));
    try std.testing.expectEqual(@as(usize, 1), reg.devices.items.len);
    try std.testing.expectEqual(@as(usize, 1), reg.revision.load(.acquire));

    try std.testing.expectEqual(UpsertResult.unchanged, try reg.upsert(io, ieee, 0x1111));
    try std.testing.expectEqual(@as(usize, 1), reg.revision.load(.acquire));

    try std.testing.expectEqual(UpsertResult.reassociated, try reg.upsert(io, ieee, 0x2222));
    try std.testing.expectEqual(@as(usize, 2), reg.revision.load(.acquire));
    try std.testing.expectEqual(@as(u16, 0x2222), reg.findByIeee(ieee).?.nwk);
}

test "upsert reallocs the table; findByIeee re-resolution still lands on the right entry" {
    // The memory-safety property engine.zig's commands depend on (see its
    // pointer-stable-access section): a command identifies its target by
    // IEEE and re-resolves after every poll, precisely because unrelated
    // traffic arriving mid-command upserts new devices and reallocates the
    // table out from under any pointer taken earlier.
    //
    // What this asserts, deliberately: that a reallocation really happens
    // (capacity grows), and that re-resolving by IEEE afterwards finds the
    // right entry, with its earlier field writes intact, still live.
    //
    // What it does NOT assert, and must not: that the entry's *address*
    // changed. Whether a realloc copies to a new address or resizes in
    // place is the allocator's choice, and `std.testing.allocator`
    // randomizes precisely that per test seed — an earlier version of this
    // test asserted `before != after` and failed roughly one run in three.
    // The address moving is the hazard's trigger, not hub's invariant;
    // re-resolution being correct either way is the invariant.
    const io = testIo();
    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();

    const target: [8]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    _ = try reg.upsert(io, target, 0x1111);
    reg.findByIeee(target).?.onoff_endpoint = 11;
    const capacity_before = reg.devices.capacity;

    // Enough unrelated joins to force the table past its first allocation.
    // No pointer is held across them — that's the whole discipline.
    var i: u8 = 0;
    while (i < 64) : (i += 1) {
        _ = try reg.upsert(io, .{ 0xAA, 0, 0, 0, 0, 0, 0, i }, 0x2000 + @as(u16, i));
    }
    try std.testing.expect(reg.devices.capacity > capacity_before); // a realloc did occur

    const after = reg.findByIeee(target).?;
    try std.testing.expectEqual(@as(u16, 0x1111), after.nwk);
    try std.testing.expectEqual(@as(?u8, 11), after.onoff_endpoint);
    // The re-resolved pointer is the live entry, not a copy of it.
    after.pending_setup = true;
    try std.testing.expect(reg.findByIeee(target).?.pending_setup);
}

test "hub.log: report() mirrors to file, timestamped, and APPENDS across restarts" {
    // The point of this file is the 2am wedge nobody watched: the in-memory
    // log has scrolled away by morning, and a restart must not erase what's
    // left. So the property under test is survival, not just writing.
    const io = testIo();
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var reg = Registry.init(gpa);
        defer reg.deinit();
        reg.openLog(io, tmp.dir);
        defer reg.closeLog(io);
        try reg.report(io, "[link] transport error — starting recovery", .{});
        try reg.report(io, "[link] recovered after {d} failed attempt(s)", .{3});
    }
    // A restart: new Registry, same file.
    {
        var reg = Registry.init(gpa);
        defer reg.deinit();
        reg.openLog(io, tmp.dir);
        defer reg.closeLog(io);
        try reg.report(io, "[link] second session", .{});
    }

    var buf: [4096]u8 = undefined;
    const text = try tmp.dir.readFile(io, Registry.LOG_FILE, &buf);

    // Everything is there, in order, including the first session's lines.
    try std.testing.expect(std.mem.indexOf(u8, text, "[link] transport error — starting recovery") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[link] recovered after 3 failed attempt(s)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[link] second session") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "transport error").? < std.mem.indexOf(u8, text, "second session").?);

    // One line per report, each timestamped ("HH:MM:SS message").
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    var count: usize = 0;
    while (lines.next()) |line| : (count += 1) {
        try std.testing.expect(line.len > 9);
        try std.testing.expectEqual(@as(u8, ':'), line[2]); // HH:MM:SS
        try std.testing.expectEqual(@as(u8, ':'), line[5]);
        try std.testing.expectEqual(@as(u8, ' '), line[8]);
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "logToFile writes to hub.log but NOT the in-memory log (no console double-print)" {
    // Startup lines print to the console directly and are mirrored to the
    // file with this — but must NOT enter the in-memory log, or the console
    // drain would print them a second time. The invariant: file gets the
    // line, log_total does not move.
    const io = testIo();
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var reg = Registry.init(gpa);
    defer reg.deinit();
    reg.openLog(io, tmp.dir);
    defer reg.closeLog(io);

    reg.logToFile(io, "hub: resumed stored network", .{});
    try std.testing.expectEqual(@as(usize, 0), reg.log_total); // in-memory untouched
    try std.testing.expectEqual(@as(usize, 0), reg.log.len);

    var buf: [512]u8 = undefined;
    const text = try tmp.dir.readFile(io, Registry.LOG_FILE, &buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "hub: resumed stored network") != null);
}

test "drainTo prints only what the cursor hasn't seen, in order" {
    // The ordering this exists to fix: `say` drains through
    // this before printing a command's response, so lines reported DURING a
    // command appear before its result — not a tick later, after it.
    const io = testIo();
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    var buf: [512]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    var cursor: usize = 0;

    try reg.report(io, "hub: setting up moisture — keep triggering it", .{});
    try reg.drainTo(io, &w, &cursor);
    try std.testing.expectEqualStrings("hub: setting up moisture — keep triggering it\n", w.buffered());
    try std.testing.expectEqual(reg.log_total, cursor);

    // Nothing new: a second drain must print nothing rather than repeat.
    try reg.drainTo(io, &w, &cursor);
    try std.testing.expectEqualStrings("hub: setting up moisture — keep triggering it\n", w.buffered());

    // Two more, then one drain: both appear, oldest first.
    try reg.report(io, "first", .{});
    try reg.report(io, "second", .{});
    try reg.drainTo(io, &w, &cursor);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "first").? < std.mem.indexOf(u8, out, "second").?);
}

test "hub.log: no sink is not an error — reporting still works without a file" {
    // A coordinator that can't write its log is still a coordinator: the
    // house's lights matter more than the diary.
    const io = testIo();
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    try std.testing.expectEqual(@as(?Io.File, null), reg.log_file);
    try reg.report(io, "still logged in memory", .{});
    try std.testing.expectEqual(@as(usize, 1), reg.log.len);
}

test "upsert: rejoin after markLeft" {
    const io = testIo();
    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();

    const ieee: [8]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    _ = try reg.upsert(io, ieee, 0x1111);
    try std.testing.expect(try reg.markLeft(io, ieee));
    try std.testing.expect(!reg.findByIeee(ieee).?.joined);

    try std.testing.expectEqual(UpsertResult.rejoined, try reg.upsert(io, ieee, 0x1111));
    try std.testing.expect(reg.findByIeee(ieee).?.joined);
}

test "upsert flags awake_pending_setup only when pending" {
    const io = testIo();
    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();

    const ieee: [8]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    _ = try reg.upsert(io, ieee, 0x1111);
    try std.testing.expect(reg.awake_pending_setup == null);

    reg.findByIeee(ieee).?.pending_setup = true;
    _ = try reg.upsert(io, ieee, 0x2222);
    try std.testing.expectEqualSlices(u8, &ieee, &reg.awake_pending_setup.?);
}

test "delete swap-removes and clears matching awake_pending_setup" {
    const io = testIo();
    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();

    const a: [8]u8 = .{ 1, 1, 1, 1, 1, 1, 1, 1 };
    const b: [8]u8 = .{ 2, 2, 2, 2, 2, 2, 2, 2 };
    _ = try reg.upsert(io, a, 0x1111);
    _ = try reg.upsert(io, b, 0x2222);
    reg.awake_pending_setup = a;

    try std.testing.expect(try reg.delete(io, a));
    try std.testing.expectEqual(@as(usize, 1), reg.devices.items.len);
    try std.testing.expect(reg.awake_pending_setup == null);
    try std.testing.expect(reg.findByIeee(a) == null);
    try std.testing.expect(reg.findByIeee(b) != null);

    try std.testing.expect(!try reg.delete(io, a)); // already gone
}

test "report/tailLog: bounded FIFO, non-destructive tail reads" {
    const io = testIo();
    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();

    try reg.report(io, "first {d}", .{1});
    try reg.report(io, "second {d}", .{2});
    try reg.report(io, "third {d}", .{3});

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const tail = try reg.tailLog(io, 2, arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), tail.len);
    try std.testing.expectEqualStrings("second 2", tail[0]);
    try std.testing.expectEqualStrings("third 3", tail[1]);
    // Non-destructive: a second read returns the same tail.
    const tail2 = try reg.tailLog(io, 2, arena.allocator());
    try std.testing.expectEqualStrings("third 3", tail2[1]);
}

test "report evicts the oldest entry past MAX_LOG_ENTRIES" {
    const io = testIo();
    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();

    var i: usize = 0;
    while (i < MAX_LOG_ENTRIES + 10) : (i += 1) {
        try reg.report(io, "line {d}", .{i});
    }
    try std.testing.expectEqual(@as(usize, MAX_LOG_ENTRIES), reg.log.len);
    // log_total counts every report() ever made, unaffected by eviction —
    // this is what lets a consumer track "how many have I drained" across
    // an eviction without deque-position bookkeeping.
    try std.testing.expectEqual(@as(usize, MAX_LOG_ENTRIES + 10), reg.log_total);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const tail = try reg.tailLog(io, 1, arena.allocator());
    // The last line pushed must still be there; the earliest ones evicted.
    try std.testing.expectEqualStrings("line 509", tail[0]);
}

test "recordReading updates fields and bumps revision; no-op for unknown ieee" {
    const io = testIo();
    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();

    const ieee: [8]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    _ = try reg.upsert(io, ieee, 0x1111);
    const rev_before = reg.revision.load(.acquire);

    try reg.recordReading(io, ieee, .{ .battery_pct = 87 });
    try std.testing.expectEqual(@as(?u8, 87), reg.findByIeee(ieee).?.battery_pct);
    try std.testing.expect(reg.revision.load(.acquire) > rev_before);

    try reg.recordReading(io, ieee, .{ .occupancy = true });
    try std.testing.expectEqual(@as(?bool, true), reg.findByIeee(ieee).?.occupancy);
    // Unrelated field from the earlier call must be untouched.
    try std.testing.expectEqual(@as(?u8, 87), reg.findByIeee(ieee).?.battery_pct);

    try reg.recordReading(io, ieee, .{ .on = true });
    try std.testing.expectEqual(@as(?bool, true), reg.findByIeee(ieee).?.on);
    try reg.recordReading(io, ieee, .{ .alert = true });
    try std.testing.expectEqual(@as(?bool, true), reg.findByIeee(ieee).?.alert);

    // Unknown device: no error, no crash, nothing to check but survival.
    try reg.recordReading(io, .{ 9, 9, 9, 9, 9, 9, 9, 9 }, .{ .temperature_centi = 2150 });
}

test "alert latch survives the live state going clear, until ackAlert" {
    const io = testIo();
    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();

    const ieee: [8]u8 = .{ 2, 2, 2, 2, 2, 2, 2, 2 };
    _ = try reg.upsert(io, ieee, 0x2222);

    // A trip sets both the live flag and the latch.
    try reg.recordReading(io, ieee, .{ .alert = true });
    try std.testing.expectEqual(@as(?bool, true), reg.findByIeee(ieee).?.alert);
    try std.testing.expect(reg.findByIeee(ieee).?.alert_latched);

    // The sensor going clear drops the live flag but NOT the latch — this
    // is the whole point: a brief trip stays visible until acknowledged.
    try reg.recordReading(io, ieee, .{ .alert = false });
    try std.testing.expectEqual(@as(?bool, false), reg.findByIeee(ieee).?.alert);
    try std.testing.expect(reg.findByIeee(ieee).?.alert_latched);

    // ack clears the latch and reports it did something; a second ack is a
    // no-op that reports it too (nothing was latched).
    try std.testing.expect(try reg.ackAlert(io, ieee));
    try std.testing.expect(!reg.findByIeee(ieee).?.alert_latched);
    try std.testing.expect(!try reg.ackAlert(io, ieee));
    // Unknown device: false, not a crash.
    try std.testing.expect(!try reg.ackAlert(io, .{ 7, 7, 7, 7, 7, 7, 7, 7 }));
}

test "snapshotDevices: arena-cloned copy, independent of the live table" {
    const io = testIo();
    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();

    _ = try reg.upsert(io, .{ 1, 2, 3, 4, 5, 6, 7, 8 }, 0x1111);
    _ = try reg.upsert(io, .{ 2, 2, 3, 4, 5, 6, 7, 8 }, 0x2222);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const snap = try reg.snapshotDevices(io, arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), snap.len);
    try std.testing.expectEqual(@as(u16, 0x1111), snap[0].nwk);

    // Mutating the live table afterward must not change the snapshot.
    reg.findByIeee(.{ 1, 2, 3, 4, 5, 6, 7, 8 }).?.nwk = 0x9999;
    try std.testing.expectEqual(@as(u16, 0x1111), snap[0].nwk);
}

test "load stamps last_seen_ms to now, not the zero default" {
    // Exercises the REAL load() (not the inline parse-only path the
    // round-trip test below uses) against a real temp directory, so this
    // covers the actual bug: a freshly loaded device that hasn't had any
    // traffic yet this session must not show `now - 0` (the raw `.awake`
    // clock reading, a huge meaningless number) as its age — screens.zig
    // computes age as `now_ms - dev.last_seen_ms`.
    const io = testIo();
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var writer_reg = Registry.init(gpa);
    defer writer_reg.deinit();
    _ = try writer_reg.upsert(io, try Ieee.parseReversed("00:17:88:01:08:d1:40:dd"), 0xD714);
    writer_reg.save(io, tmp.dir);

    const before_load = Io.Timestamp.now(io, .awake).toMilliseconds();
    var reg = Registry.init(gpa);
    defer reg.deinit();
    reg.load(io, tmp.dir);
    const after_load = Io.Timestamp.now(io, .awake).toMilliseconds();

    const dev = reg.findByIeee(try Ieee.parseReversed("00:17:88:01:08:d1:40:dd")).?;
    // Stamped to "now" at load time, not the struct default of 0 —
    // bracketed by two readings taken immediately around the load call.
    try std.testing.expect(dev.last_seen_ms >= before_load);
    try std.testing.expect(dev.last_seen_ms <= after_load);
}

test "save and load keep each device's own model and firmware" {
    const io = testIo();
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const first: [8]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const second: [8]u8 = .{ 8, 7, 6, 5, 4, 3, 2, 1 };
    var reg = Registry.init(gpa);
    defer reg.deinit();
    _ = try reg.upsert(io, first, 0x0001);
    _ = try reg.upsert(io, second, 0x0002);
    reg.findByIeee(first).?.model_id = ShortText.of("SNZB-05P");
    reg.findByIeee(first).?.firmware = ShortText.of("1.0.2");
    reg.findByIeee(second).?.model_id = ShortText.of("929003823101");
    reg.save(io, tmp.dir);

    var loaded = Registry.init(gpa);
    defer loaded.deinit();
    loaded.load(io, tmp.dir);
    try std.testing.expectEqualStrings("SNZB-05P", loaded.findByIeee(first).?.model_id.?.slice());
    try std.testing.expectEqualStrings("1.0.2", loaded.findByIeee(first).?.firmware.?.slice());
    try std.testing.expectEqualStrings("929003823101", loaded.findByIeee(second).?.model_id.?.slice());
    try std.testing.expect(loaded.findByIeee(second).?.firmware == null);
}

test "save/load round-trip through JSON" {
    const io = testIo();
    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();
    _ = try reg.upsert(io, try Ieee.parseReversed("00:17:88:01:08:d1:40:dd"), 0xD714);
    reg.findByIeee(try Ieee.parseReversed("00:17:88:01:08:d1:40:dd")).?.onoff_endpoint = 11;
    _ = try reg.upsert(io, .{ 1, 2, 3, 4, 5, 6, 7, 8 }, 0x0042);
    reg.findByIeee(.{ 1, 2, 3, 4, 5, 6, 7, 8 }).?.occupancy_endpoint = 2;
    reg.findByIeee(.{ 1, 2, 3, 4, 5, 6, 7, 8 }).?.ias_zone_endpoint = 3;

    // Exercise the same serialize path `save` uses, without touching the
    // filesystem: build the JSON text directly and feed it to the parser
    // `load` uses, matching the predecessor's own serialize/parse round-trip test.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var records: [2]Registry.DeviceRecord = undefined;
    for (reg.devices.items, 0..) |d, i| {
        records[i] = .{
            .ieee = try Ieee.formatReversedAlloc(a, &d.ieee),
            .nwk = try a.print("0x{x:0>4}", .{d.nwk}),
            .onoff_endpoint = d.onoff_endpoint,
            .occupancy_endpoint = d.occupancy_endpoint,
            .ias_zone_endpoint = d.ias_zone_endpoint,
        };
    }
    var aw: Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(Registry.DeviceFile{ .devices = &records }, .{}, &aw.writer);
    const text = aw.writer.buffered();

    var reg2 = Registry.init(gpa);
    defer reg2.deinit();
    const parsed = try std.json.parseFromSliceLeaky(Registry.DeviceFile, a, text, .{ .allocate = .alloc_always });
    for (parsed.devices) |rec| {
        const ieee = try Ieee.parseReversed(rec.ieee);
        const nwk = try std.fmt.parseInt(u16, rec.nwk[2..], 16);
        try reg2.devices.append(reg2.gpa, .{
            .ieee = ieee,
            .nwk = nwk,
            .onoff_endpoint = rec.onoff_endpoint,
            .occupancy_endpoint = rec.occupancy_endpoint,
            .ias_zone_endpoint = rec.ias_zone_endpoint,
        });
    }

    try std.testing.expectEqual(@as(usize, 2), reg2.devices.items.len);
    try std.testing.expectEqual(@as(u16, 0xD714), reg2.findByIeee(try Ieee.parseReversed("00:17:88:01:08:d1:40:dd")).?.nwk);
    try std.testing.expectEqual(@as(?u8, 11), reg2.findByIeee(try Ieee.parseReversed("00:17:88:01:08:d1:40:dd")).?.onoff_endpoint);
    try std.testing.expectEqual(@as(?u8, null), reg2.findByIeee(.{ 1, 2, 3, 4, 5, 6, 7, 8 }).?.onoff_endpoint);
    try std.testing.expectEqual(@as(?u8, 2), reg2.findByIeee(.{ 1, 2, 3, 4, 5, 6, 7, 8 }).?.occupancy_endpoint);
    try std.testing.expectEqual(@as(?u8, 3), reg2.findByIeee(.{ 1, 2, 3, 4, 5, 6, 7, 8 }).?.ias_zone_endpoint);
}

test "Semantic Check" {
    std.testing.refAllDecls(@This());
}
