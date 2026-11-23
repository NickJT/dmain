//! The coordinator: owns the EZSP client, the device registry, and the
//! rules engine. Ported from hub's predecessor daemon (`Ctx` + its free
//! functions), minus two things that moved elsewhere:
//!   - the `Hardware` registry (source-code device list) → `config.zig`
//!     (`devices.json`, so adding a device is no longer a recompile);
//!   - the interactive console parser (`handleLine`/`help` text) → not
//!     ported; `main.zig` drives this module directly for now, until the
//!     TUI becomes the real control surface.
//!
//! Touchlink reset was also dropped entirely (not ported) — the predecessor's own
//! research concluded it never worked because Hue's firmware doesn't
//! honor the Touchlink inter-PAN handshake as specified (a message-format
//! conflict at the spec level, not a bug in our implementation), so it
//! isn't worth carrying forward.
//!
//! Everything else — device-table self-healing, ZDO discovery, bind +
//! configure-reporting commissioning, On/Off + Level sends + the rules
//! engine driving them, remove, OTA no-image responder — is the same
//! protocol machinery, same reasoning, same hardware-verified behavior as
//! the predecessor this was ported from. Comments here state why each
//! step exists where it is not obvious, and note what changed in the port. `rules.json`'s schema and semantics are unchanged from the predecessor —
//! that mapping was already JSON there; only the device *identity*
//! registry needed to move out of source (see `config.zig`).
const std = @import("std");
const Io = std.Io;

const Ezsp = @import("ezsp");
const Zdo = @import("zdo");
const Zcl = @import("zcl");
const Ieee = @import("ieee");
const ConfigMod = @import("config");
const Config = ConfigMod.Config;
const HouseLog = @import("house_log");
const Model = @import("model");
const Registry = Model.Registry;
const Device = Model.Device;
const Persist = @import("persist");
const HumidityRun = @import("humidity_run");

/// Humidity sensors a run is tracked for; a house has a bathroom or two.
const MAX_HUMIDITY = 4;

/// Maximum queued automation actions awaiting the main loop's drain —
/// not one slot, since a single event (e.g. a motion trip) can match
/// several rules and drive several targets.
pub const PENDING_ACTIONS_CAP = 8;
/// Minimum gap between rule actions to the SAME target. ~8 actions/sec is
/// well past any human mash or dial spin, so dimming still feels smooth,
/// but a runaway event source (stuck button, flapping sensor) collapses
/// to this rate instead of flooding the radio.
const ACTION_DEBOUNCE_MS: i64 = 120;

/// The gesture phase an event carries, which turns a `level_up`/
/// `level_down` action into a Move/Stop ramp or a discrete Step:
///   press   → start a continuous Move (ramp begins immediately — a tap
///             is just a very short ramp, a nudge)
///   hold    → dropped (the Move already ramps until Stop; re-sending it
///             would be redundant)
///   release → Stop (end the ramp)
///   tick    → one discrete Step — for events with no hold/release
///             notion (dial detents, motion occupancy).
/// On/off/toggle actions act only on press/tick and ignore hold/release.
pub const Phase = enum { press, hold, release, tick };

pub const PendingAction = struct {
    target: ConfigMod.Target, // an IEEE (checked live at drain time) or a group_id
    action: ConfigMod.Action,
    phase: Phase,
    // Optional colour to apply alongside an `on` (a
    // rule's `colour` field, already parsed to CIE xy). null for every
    // other action, and for schedule/web actions (which have no colour).
    colour: ?ConfigMod.ColourXy = null,
};

/// Small fixed ring of per-group debounce timestamps — groups aren't
/// tracked in `model.Registry` (they have no join state, just config
/// membership), so they can't share `Device.last_action_ms` the way
/// device targets do. Sized the same as `queried_nwks`; a real fleet has
/// few groups.
const MAX_GROUP_DEBOUNCE = 8;

/// Sleepy targets: each unicast sits in the parent's indirect-transmission
/// buffer for only ~7.68s (`applyDefaultConfig`'s `INDIRECT_TRANSMISSION_TIMEOUT`)
/// and is dropped unless the device data-polls within that window — every
/// wait here comfortably outlasts that buffer while the user keeps a
/// battery device awake.
const SETUP_EMPTY_BUDGET: u8 = 10;

pub const Coordinator = struct {
    io: Io,
    ezsp: *Ezsp.Client,
    model: *Registry,
    /// The running config, read only on the engine loop. `adoptConfig` is the
    /// one thing that changes it, so a pointer taken inside one tick stays
    /// valid, and replaced configs are never freed.
    config: *const Config,
    /// Where other tasks read the running config. Null in tests that have none.
    live: ?*ConfigMod.Live = null,
    last_settings_poll_ms: i64 = 0,
    settings_poll_cursor: usize = 0,
    /// The house log, when it could be opened. Never required.
    house: ?*HouseLog.Writer = null,
    /// When an open permit closes, unix ms; 0 when none has been opened.
    permit_until_ms: i64 = 0,
    /// Every config a reload has adopted, freed only by `freeAdoptedConfigs`.
    adopted_configs: std.ArrayList(*Config) = .empty,
    out: *Io.Writer,
    /// True while `main.zig` has the terminal in watch mode's raw,
    /// cursor-addressed state — flips where `say` sends command responses.
    /// See `say`'s doc comment.
    tui: bool = false,
    /// The console's "how many log lines have I printed" cursor, owned by
    /// `main.zig`. `say` drains through it before printing so the two output
    /// paths stay in order — see `say` and `model.Registry.drainTo`. Null in
    /// tests, where there is no console to keep ordered.
    log_cursor: ?*usize = null,
    /// Is the radio usable right now? `main.zig` clears this while the link
    /// is down and sets it again on recovery.
    ///
    /// **Read by `main.zig`'s `runCommand`, which refuses radio-touching
    /// commands while it is false.** That guard is not cosmetic: on the
    /// startup-wait path the port was never opened, so the
    /// `Ash.Transport` this client points at is uninitialized memory — a
    /// send through it is a general protection fault, not a catchable error.
    /// Typing `on bulb1` at a hub that is still waiting for its radio used
    /// to kill the process outright.
    link_up: bool = true,
    /// The Trust Center link key hash seed **of the network this radio is
    /// currently on**, if we know it. Null otherwise — including for every
    /// session that merely resumes a stored network, since the NCP will not
    /// export it. `writeBackup` preserves whatever the file already holds
    /// when this is null; see `persist.seedForBackup`.
    ///
    /// **It belongs to the network, not the session** — every path that
    /// changes which network the radio is on must set it:
    /// `formFreshNetwork` (a brand-new seed) and `restoreNetwork` (the
    /// restored network's seed, or null if the backup had none). A real
    /// bug found by the 2026-07-16 restore experiment: leaving it stale
    /// across a network change wrote the *previous* network's seed into the
    /// new network's backup — a file that both lies and reports "seed: yes"
    /// on a later restore.
    tclk_hash_seed: ?[16]u8 = null,
    zdo_seq: u8 = 0xC0,
    zcl_seq: u8 = 0x60,
    // Recently IEEE-queried nwk addresses (see maybeResolveSender) — a
    // small ring so a chatty unknown sender gets one query, not one per
    // message. An entry ages out after 8 other unknowns are queried.
    queried_nwks: [8]u16 = @splat(0),
    queried_idx: usize = 0,
    // Automation rules matched during event decoding queue their action
    // here rather than sending immediately (sending from inside pollOnce
    // would re-enter it via sendOnOff/sendLevel*) — the caller's main
    // loop drains this, never nested inside another command's poll loop
    // (same discipline as `model.awake_pending_setup`).
    pending_actions: [PENDING_ACTIONS_CAP]PendingAction = undefined,
    pending_count: usize = 0,
    // Per-group debounce timestamps (see MAX_GROUP_DEBOUNCE's doc comment).
    // A fixed-size open-addressed table: (0, 0) entries are "empty".
    group_debounce_ids: [MAX_GROUP_DEBOUNCE]u16 = @splat(0),
    group_debounce_ms: [MAX_GROUP_DEBOUNCE]i64 = @splat(0),
    // Each humidity sensor's shower detector, by wire IEEE; `null` is free.
    // Session state: a restart mid-run forgets the run, and its `dry` with it.
    humidity_ieee: [MAX_HUMIDITY]?[8]u8 = @splat(null),
    humidity: [MAX_HUMIDITY]HumidityRun.Detector = @splat(.{}),
    // Attribute polling: when the last poll went out, and
    // which device to consider next. See `pollStaleState`.
    last_state_poll_ms: i64 = 0,
    state_poll_cursor: usize = 0,
    // A factory-fresh IAS Zone sensor sent a Zone Enroll Request (it's awake
    // now). The IAS handler runs inside a poll callback, so it can't send —
    // it stashes the sender's IEEE here and the main loop drains it into
    // `enrollIasZone` at the top level (same discipline as
    // `model.awake_pending_setup`).
    pending_enroll: ?[8]u8 = null,

    /// Which of the two callers is bringing the stack up. The sequence is
    /// identical either way — that's the point of sharing it — but three
    /// things differ, and each difference is load-bearing. See `initStack`.
    pub const InitMode = enum { initial, recovery };

    /// Brings the NCP up: version negotiation, config, endpoint
    /// registration, then resume-or-form. Mirrors `daemon.zig`'s `main()`
    /// setup section exactly, and the order matters: EZSP config values must
    /// be set before `networkInit`, and the coordinator must register its
    /// application endpoints or devices have nothing to bind to.
    ///
    /// Shared by startup and by recovery rather than duplicated,
    /// because an ASH RST resets the NCP itself: config and endpoint
    /// registration live in NCP **RAM** and are gone after a wedge, so
    /// recovery must redo all of it. Only the network survives, in NVM.
    ///
    /// The three differences between the modes:
    ///   - **`.recovery` NEVER forms a network.** This is the important one.
    ///     `networkInit` failing at startup means "fresh install, form one";
    ///     the same status mid-session means the NCP's NVM lost the network
    ///     (0x93), and forming would hand every commissioned device in the
    ///     house a new PAN they aren't joined to — silently orphaning the
    ///     lot. It reports loudly and returns `error.NetworkResumeFailed`
    ///     instead, leaving the radio down and the log damning.
    ///   - **`.recovery` resets the EZSP client first** (`ezsp.reset()`),
    ///     clearing sequence numbers, framing, and callbacks decoded from
    ///     the network we just lost.
    ///   - **Output routing**: `.initial` prints via `self.out` (it runs
    ///     before `main.zig` has built a `View`, so there's no frame to
    ///     corrupt and no log a reader could have been watching);
    ///     `.recovery` reports via `model.report`, since it can fire at any
    ///     moment — including while watch mode owns the terminal.
    pub fn initStack(self: *Coordinator, mode: InitMode) !void {
        if (mode == .recovery) self.ezsp.reset();

        const version = try self.ezsp.negotiateVersion();
        switch (mode) {
            .initial => {
                try self.out.print("hub: NCP EZSP v{d}\n", .{version.protocol_version});
                try self.out.flush();
                self.model.logToFile(self.io, "hub: NCP EZSP v{d}", .{version.protocol_version});
            },
            .recovery => try self.model.report(self.io, "[link] NCP back: EZSP v{d}", .{version.protocol_version}),
        }
        try self.ezsp.applyDefaultConfig();
        try self.ezsp.registerEndpoints();

        const init_status = try self.ezsp.networkInit();
        if (init_status == Ezsp.STATUS_SUCCESS) {
            switch (mode) {
                .initial => {
                    try self.out.print("hub: resumed stored network\n", .{});
                    self.model.logToFile(self.io, "hub: resumed stored network", .{});
                },
                .recovery => try self.model.report(self.io, "[link] resumed stored network", .{}),
            }
        } else switch (mode) {
            .initial => {
                try self.out.print("hub: no stored network (status=0x{x:0>2}) — forming a new one\n", .{init_status});
                self.model.logToFile(self.io, "hub: no stored network (status=0x{x:0>2}) — forming a new one", .{init_status});
                try self.formFreshNetwork();
            },
            .recovery => {
                try self.model.report(self.io, "[link] networkInit failed (status=0x{x:0>2}) after reset — the NCP's NVM has LOST the network", .{init_status});
                try self.model.report(self.io, "[link] NOT forming a new one: that would orphan every commissioned device. Radio stays down.", .{});
                try self.model.report(self.io, "[link] recover the network with `restore` (see hub-coordinator.json), or `form` deliberately to start over", .{});
                return error.NetworkResumeFailed;
            },
        }
        try self.ezsp.setJoinPolicy(Ezsp.DECISION_ALLOW_PRECONFIGURED_KEY_JOINS);
        if (mode == .initial) try self.out.flush();
    }

    /// Startup path. See `initStack`.
    pub fn bootstrap(self: *Coordinator) !void {
        return self.initStack(.initial);
    }

    /// Recovery path: the NCP has just been reset (by an ASH RST or a port
    /// reopen), so its RAM-side config and endpoints are gone and must be
    /// re-applied before the radio is usable again. Never forms.
    ///
    /// Also drops any queued automation actions: they were decided against
    /// the state of a network that has since been down, and a resurrected
    /// Level `Move` whose matching `Stop` was lost in the wedge would ramp a
    /// bulb to its limit and stay there. A dropped action is a light that
    /// didn't change; a stuck Move is a light you have to go and fix.
    pub fn reinitAfterReset(self: *Coordinator) !void {
        self.pending_count = 0;
        try self.initStack(.recovery);
    }

    /// Random PAN/extended-PAN/network key + hashed-TCLK seed, then form
    /// and wait for NETWORK_UP. Split out of `bootstrap` so the `form`
    /// command (leave + re-form mid-session) can reuse it.
    fn formFreshNetwork(self: *Coordinator) !void {
        var random_bytes: [42]u8 = undefined; // last 16 = tclk hash seed
        Io.random(self.io, &random_bytes);
        const pan_id: u16 = 1 + (((@as(u16, random_bytes[0]) | (@as(u16, random_bytes[1]) << 8))) % 0xFFFE);
        var extended_pan_id: [8]u8 = undefined;
        std.mem.copyForwards(u8, &extended_pan_id, random_bytes[2..10]);
        var network_key: [16]u8 = undefined;
        std.mem.copyForwards(u8, &network_key, random_bytes[10..26]);
        // The one instant this seed is ever observable: it goes into the
        // NCP and can never be read back out. Stash it before the call so
        // `writeBackup` can record it — without it, a restore onto a
        // replacement radio cannot re-derive the hashed Trust Center link
        // keys, and every device has to rejoin. (The pre-existing PAN
        // 0x9928 network predates this capture: already-joined devices
        // resume on the network key alone, but a restored network's future
        // joins cannot be derived.)
        self.tclk_hash_seed = random_bytes[26..42].*;
        try self.ezsp.setInitialSecurityState(network_key, 0, random_bytes[26..42].*);
        try self.ezsp.formNetwork(.{
            .extended_pan_id = extended_pan_id,
            .pan_id = pan_id,
            .radio_channel = 15,
            .network_key = network_key,
        });
        try self.ezsp.waitForNetworkUp(10);
    }

    /// Leaves the current network and forms a fresh one in-session.
    /// DESTRUCTIVE — every joined device is orphaned. Exists to compare
    /// resumed-vs-fresh behavior without restarting the process.
    pub fn reformNetwork(self: *Coordinator) !void {
        try self.say("hub: leaving current network and forming a fresh one...", .{});
        const leave_status = try self.ezsp.leaveNetwork();
        if (leave_status != Ezsp.STATUS_SUCCESS and leave_status != Ezsp.STATUS_NOT_JOINED) {
            try self.say("hub: leaveNetwork status=0x{x:0>2}", .{leave_status});
        }
        var down_polls: u8 = 0;
        while (down_polls < 10) : (down_polls += 1) {
            const cb = try self.pollOnce() orelse continue;
            switch (cb) {
                .stack_status => |s| if (s == 0x91) break,
                else => {},
            }
        }
        try self.formFreshNetwork();
        try self.ezsp.setJoinPolicy(Ezsp.DECISION_ALLOW_PRECONFIGURED_KEY_JOINS);
        self.model.devices.clearRetainingCapacity();
        _ = self.model.revision.fetchAdd(1, .release);
        self.model.awake_pending_setup = null;
        self.model.save(self.io, Io.Dir.cwd());
        // A deliberate `form` IS the user asking for this network, so it
        // authorizes the record to be replaced (force=true) — the previous
        // network's file is renamed aside, not deleted. Without this the
        // next startup would refuse to back up the new network, since the
        // file on disk would still name the old one.
        self.writeBackup(true) catch |err| {
            try self.model.report(self.io, "coordinator backup after form failed: {t}", .{err});
        };
        try self.printStatus();
    }

    // ── Coordinator backup ──────────────────────────────────────────

    /// How far past the saved counter a restore jumps. The backup is only
    /// rewritten hourly, so the real counter has moved on since it was
    /// written (a four-send test advanced it ~4,100) — and a coordinator
    /// whose counter has gone BACKWARDS is ignored by every device that
    /// remembers a higher one, as replay protection. Overshooting is
    /// harmless; undershooting is silent death. The doc's only stated bound
    /// is `< MAX_INT32U`.
    pub const RESTORE_COUNTER_MARGIN: u32 = 0x10000;

    /// Exports everything needed to rebuild this network on a replacement
    /// radio: PAN/channel from `getNetworkParameters`, the network key +
    /// its frame counter from `getCurrentNetworkKey`, our own EUI64, and
    /// the TCLK hash seed if we have one. Written atomically to
    /// `hub-coordinator.json` (see `persist.zig`).
    ///
    /// **Engine-loop callers only** — it talks to the radio, so the usual
    /// rule applies (never from a web/TUI task; `main.zig` calls it at
    /// startup, hourly, and from the `backup` command, all on the loop).
    ///
    /// Load-and-merge, not blind overwrite: the existing file is read first
    /// so an hourly rewrite from a session that merely *resumed* the
    /// network preserves a `tclk_hash_seed` recorded at form time by some
    /// earlier session. That seed is unrecoverable, so clobbering it with
    /// null would be permanent — see `persist.seedForBackup`.
    ///
    /// **Refuses to overwrite a backup belonging to a different network**
    /// unless `force` (see `persist.isDifferentNetwork` for the hole this
    /// closes: a blank replacement radio auto-forms a new network at
    /// bootstrap, and the startup backup would erase the dead network's key
    /// — the file destroying itself exactly when it's needed). `force` is
    /// for the case where the new network is what the user actually asked
    /// for: a deliberate `form`, or `backup force`. Even then the old file
    /// is moved aside rather than deleted.
    ///
    /// Errors propagate; every caller catches and warns (a failed backup
    /// must never take the coordinator down with it).
    pub fn writeBackup(self: *Coordinator, force: bool) !void {
        const params = try self.ezsp.getNetworkParameters();
        const key = try self.ezsp.getCurrentNetworkKey();
        const eui = try self.ezsp.getEui64();

        var arena = std.heap.ArenaAllocator.init(self.model.gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const live_seed_hex: ?[]const u8 = if (self.tclk_hash_seed) |seed|
            try a.dupe(u8, &std.fmt.bytesToHex(seed, .lower))
        else
            null;
        const existing = Persist.loadBackup(self.io, Io.Dir.cwd(), a);

        // Display order for the two address fields, wire order for key
        // material — the conventions `CoordinatorBackup` documents.
        var epid_display: [8]u8 = undefined;
        for (params.extended_pan_id, 0..) |b, i| epid_display[7 - i] = b;
        const epid_hex = try a.dupe(u8, &std.fmt.bytesToHex(epid_display, .lower));

        if (Persist.isDifferentNetwork(existing, epid_hex, params.pan_id)) {
            const old = existing.?;
            if (!force) {
                try self.model.report(self.io, "backup REFUSED: {s} holds network PAN 0x{X:0>4}, but this radio is on PAN 0x{X:0>4}", .{ Persist.BACKUP_FILE, old.pan_id, params.pan_id });
                try self.model.report(self.io, "  overwriting would destroy the only copy of PAN 0x{X:0>4}'s key. If this radio is a replacement, restore instead;", .{old.pan_id});
                try self.model.report(self.io, "  if the new network is intentional, use `backup force` (the old file is kept, renamed).", .{});
                return error.BackupWouldClobberDifferentNetwork;
            }
            // Forced, but still not destroyed: a network key is not
            // something to delete because one command was typed.
            var name_buf: [64]u8 = undefined;
            const archive = try Persist.archiveNameFor(&name_buf, old.pan_id);
            if (Io.Dir.cwd().rename(Persist.BACKUP_FILE, Io.Dir.cwd(), archive, self.io)) {
                try self.model.report(self.io, "backup: PAN 0x{X:0>4}'s record moved aside to {s}", .{ old.pan_id, archive });
            } else |err| {
                try self.model.report(self.io, "backup: could not archive the old record ({t}) — refusing rather than overwriting it", .{err});
                return err;
            }
        }

        const backup: Persist.CoordinatorBackup = .{
            .saved_at_unix = @intCast(Io.Timestamp.now(self.io, .real).toSeconds()),
            .eui64 = try Ieee.formatReversedAlloc(a, &eui),
            .pan_id = params.pan_id,
            .extended_pan_id = epid_hex,
            .channel = params.radio_channel,
            .nwk_update_id = params.nwk_update_id,
            .channel_mask = params.channel_mask,
            .network_key = try a.dupe(u8, &std.fmt.bytesToHex(key.key, .lower)),
            .key_sequence_number = key.sequence_number,
            .outgoing_frame_counter = key.outgoing_frame_counter,
            .tclk_hash_seed = Persist.seedForBackup(live_seed_hex, existing),
        };

        const text = try Persist.serializeBackup(a, backup);
        try Persist.writeSecretAtomic(self.io, Io.Dir.cwd(), Persist.BACKUP_FILE, text);
    }

    /// What a restore would do, or did — reported before acting so the user
    /// sees the network they're about to bring back.
    pub const RestorePlan = struct {
        pan_id: u16,
        channel: u8,
        counter_from_file: u32,
        counter_to_set: u32,
        has_seed: bool,
    };

    /// Rebuilds a saved network on this radio: the restore half of the coordinator backup's
    /// backup. **DESTRUCTIVE** — it leaves whatever network the radio is on.
    ///
    /// The sequence is the one Silicon Labs' own docs prescribe for
    /// `sl_zigbee_set_outgoing_nwk_frame_counter` ("intended for device
    /// restoration purposes"), and each step's ordering is load-bearing:
    ///   1. leave the current network — the counter set is documented as
    ///      no-network-only (this firmware turns out to allow it while
    ///      joined, but the sequence follows the documented contract);
    ///   2. set the NWK frame counter **before** `setInitialSecurityState`,
    ///      to `saved + RESTORE_COUNTER_MARGIN` (never backwards — see that
    ///      constant);
    ///   3. `setInitialSecurityState` with the saved key/sequence/seed —
    ///      its bitmask must carry `NO_FRAME_COUNTER_RESET` or the counter write is
    ///      undone (hub's already does);
    ///   4. `formNetwork` with the saved PAN/extended-PAN/channel — the
    ///      *same* network, not a new one; the devices are still configured
    ///      for it.
    ///
    /// The device table is deliberately NOT cleared (unlike `reformNetwork`):
    /// this is the same network coming back, so every device keeps its nwk.
    pub fn restoreNetwork(self: *Coordinator, backup: Persist.CoordinatorBackup) !RestorePlan {
        var key: [16]u8 = undefined;
        _ = std.fmt.hexToBytes(&key, backup.network_key) catch return error.BadBackupKey;
        var epid_display: [8]u8 = undefined;
        _ = std.fmt.hexToBytes(&epid_display, backup.extended_pan_id) catch return error.BadBackupExtendedPanId;
        // Display order in the file, wire order on the air.
        var epid_wire: [8]u8 = undefined;
        for (epid_display, 0..) |b, i| epid_wire[7 - i] = b;

        var seed: [16]u8 = undefined;
        const has_seed = backup.tclk_hash_seed != null;
        if (backup.tclk_hash_seed) |hex| {
            _ = std.fmt.hexToBytes(&seed, hex) catch return error.BadBackupSeed;
            // The seed now belongs to the network we're about to be on.
            self.tclk_hash_seed = seed;
        } else {
            // This network has no recorded seed, and neither do we now —
            // anything still held here is the PREVIOUS network's and must
            // not leak into this one's backup (see the field's comment).
            self.tclk_hash_seed = null;
            // No seed recorded (a network formed before hub captured them
            // — its future joins cannot survive a restore). A random seed keeps the
            // stack happy without pretending we know the real one.
            //
            // This is LESS costly than it sounds, and the 2026-07-16 restore
            // experiment measured it rather than guessing: a seedless
            // restore of PAN 0x9928 brought the whole fleet back with NO
            // rejoin and NO reset — bulbs, socket, and both sensors,
            // bindings and reporting configs intact. Already-commissioned
            // devices resume on the network KEY alone; the seed derives the
            // hashed Trust Center link keys, which matter for APS-level key
            // operations and future joins, not for traffic to devices that
            // already hold their keys.
            Io.random(self.io, &seed);
            try self.model.report(self.io, "restore: no tclk_hash_seed in the backup — commissioned devices should still resume (the seed matters for future joins/TC key ops)", .{});
        }

        const plan: RestorePlan = .{
            .pan_id = backup.pan_id,
            .channel = backup.channel,
            .counter_from_file = backup.outgoing_frame_counter,
            .counter_to_set = backup.outgoing_frame_counter +| RESTORE_COUNTER_MARGIN,
            .has_seed = has_seed,
        };

        try self.model.report(self.io, "restore: leaving the current network...", .{});
        const leave_status = try self.ezsp.leaveNetwork();
        if (leave_status != Ezsp.STATUS_SUCCESS and leave_status != Ezsp.STATUS_NOT_JOINED) {
            try self.model.report(self.io, "restore: leaveNetwork status=0x{x:0>2}", .{leave_status});
        }
        var down_polls: u8 = 0;
        while (down_polls < 10) : (down_polls += 1) {
            const cb = try self.pollOnce() orelse continue;
            switch (cb) {
                .stack_status => |s| if (s == 0x91) break,
                else => {},
            }
        }

        try self.model.report(self.io, "restore: setting NWK frame counter {d} → {d}", .{ plan.counter_from_file, plan.counter_to_set });
        try self.ezsp.setNwkFrameCounter(plan.counter_to_set);

        try self.model.report(self.io, "restore: applying saved security state (seed: {s})", .{if (has_seed) "yes" else "NONE — partial restore"});
        try self.ezsp.setInitialSecurityState(key, backup.key_sequence_number, seed);

        try self.model.report(self.io, "restore: forming PAN 0x{X:0>4} on channel {d}...", .{ backup.pan_id, backup.channel });
        try self.ezsp.formNetwork(.{
            .extended_pan_id = epid_wire,
            .pan_id = backup.pan_id,
            .radio_channel = backup.channel,
            .network_key = key,
            .network_key_sequence = backup.key_sequence_number,
        });
        try self.ezsp.waitForNetworkUp(10);
        try self.ezsp.setJoinPolicy(Ezsp.DECISION_ALLOW_PRECONFIGURED_KEY_JOINS);
        // Record the network we just brought back, or `hub-coordinator.json`
        // keeps describing whatever the radio was on BEFORE the restore —
        // which then trips the different-network guard on the next startup
        // and refuses to back up at all. force=true: a restore IS the user
        // asking for this network, and the superseded record is archived
        // rather than deleted. (Found by the 2026-07-16 experiment: after a
        // restore the file still named the throwaway network.)
        self.writeBackup(true) catch |err| {
            try self.model.report(self.io, "restore: network is up, but re-recording the backup failed: {t}", .{err});
        };
        return plan;
    }

    /// What the radio says of its network now. Each question that fails is left
    /// out rather than failing the rest; with the link down, none is asked.
    pub fn networkFacts(self: *Coordinator, up: bool) HouseLog.NetFacts {
        var f: HouseLog.NetFacts = .{ .up = up, .permit_until_ms = self.permit_until_ms };
        if (!up) return f;
        if (self.ezsp.getNetworkParameters()) |p| {
            f.channel = p.radio_channel;
            f.pan = p.pan_id;
        } else |_| {}
        f.children.used = if (self.ezsp.childCount()) |n| n else |_| null;
        f.neighbours.used = if (self.ezsp.neighborCount()) |n| n else |_| null;
        if (self.ezsp.getConfigurationValue(Ezsp.CONFIG_MAX_END_DEVICE_CHILDREN)) |r| {
            if (r.status == 0) f.children.size = r.value;
        } else |_| {}
        if (self.ezsp.getConfigurationValue(Ezsp.CONFIG_NEIGHBOR_TABLE_SIZE)) |r| {
            if (r.status == 0) f.neighbours.size = r.value;
        } else |_| {}
        return f;
    }

    pub fn printStatus(self: *Coordinator) !void {
        const params = try self.ezsp.getNetworkParameters();
        try self.say("network: PAN 0x{X:0>4}, channel {d}, {d} device(s) seen", .{ params.pan_id, params.radio_channel, self.model.devices.items.len });
    }

    pub fn permitJoin(self: *Coordinator, secs: u8) !void {
        try self.ezsp.permitJoining(secs);
        self.permit_until_ms = Io.Timestamp.now(self.io, .real).toMilliseconds() + @as(i64, secs) * 1000;
        // model.report, not self.out: reachable from watch mode's
        // single-key `permit` action, not just the console command.
        try self.model.report(self.io, "hub: network open for {d}s", .{secs});
    }

    /// Makes `new` the running config, for this loop and for the web task.
    pub fn adoptConfig(self: *Coordinator, new: *Config) !void {
        try self.adopted_configs.append(self.model.gpa, new);
        self.config = new;
        if (self.live) |live| live.set(new);
    }

    /// For shutdown, once the web task has stopped and nothing reads them.
    pub fn freeAdoptedConfigs(self: *Coordinator) void {
        const gpa = self.model.gpa;
        for (self.adopted_configs.items) |config| {
            config.deinit();
            gpa.destroy(config);
        }
        self.adopted_configs.deinit(gpa);
    }

    // ── Command-response output ─────────────────────────────────────

    /// Prints the reply to a command the user just typed. **Every command
    /// response must go through here rather than `self.out` directly** —
    /// watch mode has a command line, so any
    /// console command can now run while the terminal is in raw,
    /// cursor-addressed mode, where a direct write lands wherever the
    /// cursor happens to sit and corrupts the frame. That's the same class
    /// of bug four earlier fixes each fixed one call site at a time; this
    /// makes the routing structural instead. Console mode still writes
    /// straight through, unchanged and immediate.
    ///
    /// `fmt` carries no trailing newline — console mode adds one, and the
    /// log is a list of lines, not a byte stream.
    ///
    /// Command responses ONLY. Async/unsolicited lines (`[event]`,
    /// `[report]`, `[rule]`) always call `model.report` directly, in both
    /// modes: console mode drains and prints those once per tick, so
    /// sending them through here would print them immediately and scramble
    /// their order against the rest of the event stream.
    pub fn say(self: *Coordinator, comptime fmt: []const u8, args: anytype) !void {
        if (self.tui) return self.model.report(self.io, fmt, args);
        // Flush anything reported since the console last drained, BEFORE
        // this response — otherwise the two paths interleave backwards
        // within a single command. Costs nothing: the
        // lines were going to print on the next tick anyway; they just print
        // in the order they happened.
        if (self.log_cursor) |cursor| self.model.drainTo(self.io, self.out, cursor) catch {};
        try self.out.print(fmt ++ "\n", args);
        try self.out.flush();
        // Mirror the response into hub.log too, so the durable record is
        // comprehensive — console-mode command responses used to live only
        // in the terminal, while watch-mode ones (via model.report above)
        // were kept. Now both are. logToFile skips the in-memory log, so
        // this doesn't double-print to the console via the next drain.
        self.model.logToFile(self.io, fmt, args);
    }

    // ── Naming ──────────────────────────────────────────────────────

    /// Registry name for an IEEE (wire order), if configured.
    fn deviceName(self: *Coordinator, ieee: [8]u8) ?[]const u8 {
        return self.config.nameFor(ieee);
    }

    /// Prints "name (aa:bb:...)" for configured devices, bare IEEE otherwise.
    /// Used by command-response output (which writes straight to
    /// `self.out`, since it only runs synchronously in console mode).
    fn printDeviceLabel(self: *Coordinator, writer: *Io.Writer, ieee: [8]u8) !void {
        if (self.deviceName(ieee)) |name| {
            try writer.print("{s} (", .{name});
            try Ieee.printReversed(writer, &ieee);
            try writer.print(")", .{});
        } else {
            try Ieee.printReversed(writer, &ieee);
        }
    }

    /// Same label, but into a caller-supplied buffer rather than a
    /// writer — for building `model.report()` format args (the async
    /// event-log path, which formats a whole line in one `print`
    /// rather than writing incrementally to `self.out`).
    fn deviceLabelBuf(self: *Coordinator, buf: []u8, ieee: [8]u8) ![]const u8 {
        var w = Io.Writer.fixed(buf);
        try self.printDeviceLabel(&w, ieee);
        return w.buffered();
    }

    // ── Pointer-stable device access ────────────────────────────────
    //
    // `model.Registry.devices` is a flat `ArrayList(Device)`: any
    // `upsert` of a device we haven't seen before appends, which can
    // realloc the backing array and invalidate every outstanding
    // `*Device`. Commands here poll the radio (`awaitZdo`/`awaitZcl`/
    // `pollOnce`) many times while they run, and unrelated traffic
    // arriving during those waits goes through exactly that upsert path —
    // so a `*Device` held across a wait is a use-after-free waiting for a
    // chatty enough fleet.
    //
    // The rule that removes the hazard: commands identify their target by
    // IEEE (stable, never moves) and re-resolve through these two helpers
    // immediately before each field access, never holding the pointer
    // across a wait. If the device left mid-command the re-resolve fails
    // with `error.DeviceVanished`, which callers report like any other
    // command failure.

    /// The live entry for `ieee`, or `error.DeviceVanished` if it's gone
    /// from the table (it left, or was removed, while the command ran).
    /// The returned pointer is only valid until the next poll — see the
    /// section comment above.
    fn requireDevice(self: *Coordinator, ieee: [8]u8) !*Device {
        return self.model.findByIeee(ieee) orelse error.DeviceVanished;
    }

    /// `requireDevice` for the overwhelmingly common case: the target's
    /// current nwk address, read fresh for one send. Re-resolving per send
    /// also picks up a re-association that happened mid-command for free.
    fn deviceNwk(self: *Coordinator, ieee: [8]u8) !u16 {
        return (try self.requireDevice(ieee)).nwk;
    }

    /// Registry name for the device currently holding a nwk address, "?"
    /// if unknown.
    fn senderLabel(self: *Coordinator, sender: u16) []const u8 {
        if (self.model.findByNwk(sender)) |d| return self.deviceName(d.ieee) orelse "?";
        return "?";
    }

    // ── Target resolution ───────────────────────────────────────────

    /// Resolves a token: a configured registry name, an IEEE
    /// ("00:17:88:...") or a nwk ("0x1234"/"1234") — table lookup only,
    /// no network traffic.
    pub fn findDevice(self: *Coordinator, token: []const u8) ?*Device {
        if (self.config.ieeeFor(token)) |ieee| return self.model.findByIeee(ieee);
        if (std.mem.indexOfScalar(u8, token, ':') != null) {
            const ieee = Ieee.parseReversed(token) catch return null;
            return self.model.findByIeee(ieee);
        }
        const stripped = if (std.mem.startsWith(u8, token, "0x")) token[2..] else token;
        const nwk = std.fmt.parseInt(u16, stripped, 16) catch return null;
        return self.model.findByNwk(nwk);
    }

    /// The IEEE a token denotes without consulting the table: a
    /// configured name or an explicit colon-hex IEEE. Null for nwk tokens
    /// (those only mean anything via the table).
    fn tokenIeee(self: *Coordinator, token: []const u8) ?[8]u8 {
        if (self.config.ieeeFor(token)) |ieee| return ieee;
        if (std.mem.indexOfScalar(u8, token, ':') != null) {
            return Ieee.parseReversed(token) catch null;
        }
        return null;
    }

    /// Table lookup with self-healing fallback: for tokens that carry an
    /// IEEE but aren't in the table, broadcasts a NWK_addr_req before
    /// giving up — so a device whose nwk we lost while hub was down is
    /// findable without waiting for it to announce.
    ///
    /// Returns the target's IEEE, not a `*Device`: this is the entry point
    /// for every one-target command, and each of those then polls the radio
    /// for seconds — a pointer handed out here would be exactly the one
    /// held across a wait (see the pointer-stable-access section above).
    pub fn resolveTarget(self: *Coordinator, token: []const u8) !?[8]u8 {
        if (self.findDevice(token)) |dev| return dev.ieee;
        const ieee = self.tokenIeee(token) orelse return null;
        try self.say("hub: '{s}' not in table — broadcasting NWK address lookup...", .{token});
        _ = try self.nwkAddrLookup(ieee);
        if (self.model.findByIeee(ieee) == null) return null;
        return ieee;
    }

    // ── Poll loop + self-healing ────────────────────────────────────

    /// One callback-poll round; updates the device table and prints
    /// membership/network events. Returns the raw callback so command
    /// handlers looping on this can filter for the responses they await.
    pub fn pollOnce(self: *Coordinator) !?Ezsp.Callback {
        const cb = try self.ezsp.pollCallback(1) orelse return null;
        switch (cb) {
            .trust_center_join => |ev| {
                if (ev.status == Ezsp.DEVICE_UPDATE_DEVICE_LEFT) {
                    if (try self.model.markLeft(self.io, ev.new_node_eui64)) {
                        if (self.house) |house| house.link(ev.new_node_eui64, .disconnected);
                        var buf: [64]u8 = undefined;
                        const label = try self.deviceLabelBuf(&buf, ev.new_node_eui64);
                        try self.model.report(self.io, "[event] device left: {s} nwk=0x{X:0>4}", .{ label, ev.new_node_id });
                    }
                } else {
                    try self.upsertAndReport(ev.new_node_eui64, ev.new_node_id, "joined");
                    self.markAwakeForSetup(ev.new_node_eui64);
                }
            },
            .stack_status => |status| {
                const label: []const u8 = switch (status) {
                    0x90 => "network up",
                    0x91 => "network down",
                    0x9C => "network opened for joining",
                    0x9D => "network closed to joining",
                    else => "stack status",
                };
                try self.model.report(self.io, "[event] {s} (0x{x:0>2})", .{ label, status });
            },
            .key_establishment => |ke| {
                var buf: [64]u8 = undefined;
                const label = try self.deviceLabelBuf(&buf, ke.partner);
                try self.model.report(self.io, "[event] key establishment with {s}: status=0x{x:0>2}", .{ label, ke.status });
            },
            .incoming_message => |msg| {
                self.model.noteLink(self.io, msg.sender, msg.last_hop_lqi, msg.last_hop_rssi);
                // Devices poll our OTA server every few seconds; answer so
                // they back off instead of spamming.
                if (msg.aps.cluster_id == Zcl.CLUSTER_OTA) {
                    self.respondOtaNoImage(&msg) catch {};
                    return cb;
                }
                if (msg.aps.profile_id == Zdo.PROFILE_ID) {
                    try self.handleZdoMessage(&msg);
                    return cb;
                }
                // Self-healing: a sender we can't map to a device means a
                // stale or missing table entry — ask it who it is.
                try self.maybeResolveSender(msg.sender);
                if (msg.aps.profile_id == Zcl.PROFILE_HA) {
                    if (try self.printZclEvent(&msg)) return cb;
                }
                try self.model.report(self.io, "[msg] profile=0x{x:0>4} cluster=0x{x:0>4} from nwk=0x{X:0>4} ({s}) len={d}", .{ msg.aps.profile_id, msg.aps.cluster_id, msg.sender, self.senderLabel(msg.sender), msg.contents_len });
            },
            else => {},
        }
        return cb;
    }

    /// Wraps `Registry.upsert` with the console reporting the predecessor's
    /// `upsertDevice` did inline: only speak up when something actually
    /// changed (new device, re-association, rejoin), persist on any
    /// nwk-affecting change.
    /// Records a reading, and logs it to the house log if it's news. On/off is
    /// also polled every 30 s or so, so an unchanged answer isn't an event.
    fn noteReading(self: *Coordinator, ieee: [8]u8, reading: Model.Reading) !void {
        const was_on = if (self.model.findByIeee(ieee)) |d| d.on else null;
        try self.model.recordReading(self.io, ieee, reading);
        const house = self.house orelse return;
        const dev = self.model.findByIeee(ieee) orelse return;
        if (dev.reported_lost) {
            dev.reported_lost = false;
            HouseLog.restartSettingsPass(dev);
            house.link(ieee, .connected);
            var buf: [64]u8 = undefined;
            const label = try self.deviceLabelBuf(&buf, ieee);
            try self.model.report(self.io, "[link] {s} is answering again", .{label});
        }
        if (reading == .on and was_on == reading.on) return;
        house.reading(dev, reading);
    }

    fn upsertAndReport(self: *Coordinator, ieee: [8]u8, nwk: u16, verb_for_new: []const u8) !void {
        const result = try self.model.upsert(self.io, ieee, nwk);
        if (result == .unchanged) return;
        if (self.model.findByIeee(ieee)) |d| HouseLog.restartSettingsPass(d);
        if (self.house) |house| house.link(ieee, .connected);
        var buf: [64]u8 = undefined;
        const label = try self.deviceLabelBuf(&buf, ieee);
        switch (result) {
            .unchanged => unreachable,
            .new => {
                self.model.save(self.io, Io.Dir.cwd());
                try self.model.report(self.io, "[event] device {s}: {s} nwk=0x{X:0>4}", .{ verb_for_new, label, nwk });
            },
            .reassociated => {
                self.model.save(self.io, Io.Dir.cwd());
                try self.model.report(self.io, "[event] device re-associated: {s} nwk=0x{X:0>4}", .{ label, nwk });
            },
            .rejoined => {
                try self.model.report(self.io, "[event] device rejoined: {s} nwk=0x{X:0>4}", .{ label, nwk });
            },
        }
    }

    /// An announce/join means the device's radio is listening RIGHT NOW —
    /// the one reliable moment to commission a sleepy device. The engine's
    /// main loop drains `model.awake_pending_setup` (never nested inside
    /// a poll callback). An address RESPONSE does not qualify — the
    /// parent answers those on a sleeping child's behalf.
    fn markAwakeForSetup(self: *Coordinator, ieee: [8]u8) void {
        _ = self.model.findByIeee(ieee) orelse return;
        // upsert() already set awake_pending_setup if pending_setup was
        // true; nothing else to do here. Kept as a named step (mirrors
        // the predecessor's separate markAwakeForSetup) since Device Announce also
        // calls this, not just trust_center_join.
    }

    /// ZDO traffic arriving at endpoint 0. Device Announce carries nwk +
    /// IEEE — the ONLY signal a mains router gives after a power cycle (it
    /// resumes, it does not rejoin, so no trust_center_join fires).
    /// Address responses (from `maybeResolveSender`'s IEEE queries and
    /// `nwkAddrLookup`'s broadcasts) carry the same pair.
    fn handleZdoMessage(self: *Coordinator, msg: *const Ezsp.IncomingMessage) !void {
        switch (msg.aps.cluster_id) {
            Zdo.CLUSTER_DEVICE_ANNOUNCE => {
                if (Zdo.parseDeviceAnnounce(msg.payload())) |ann| {
                    // An announce is always worth a console line — it's
                    // how a power-cycled router says hello — even when
                    // the table doesn't change (known device, same nwk).
                    const quiet = if (self.model.findByIeee(ann.ieee)) |d| d.joined and d.nwk == ann.nwk_addr else false;
                    const result = try self.model.upsert(self.io, ann.ieee, ann.nwk_addr);
                    if (result == .new or result == .reassociated) self.model.save(self.io, Io.Dir.cwd());
                    if (self.model.findByIeee(ann.ieee)) |d| HouseLog.restartSettingsPass(d);
                    if (quiet) {
                        var buf: [64]u8 = undefined;
                        const label = try self.deviceLabelBuf(&buf, ann.ieee);
                        try self.model.report(self.io, "[event] device announce: {s} nwk=0x{X:0>4} (unchanged — power cycle?)", .{ label, ann.nwk_addr });
                    } else if (result != .unchanged) {
                        var buf: [64]u8 = undefined;
                        const label = try self.deviceLabelBuf(&buf, ann.ieee);
                        try self.model.report(self.io, "[event] device announce: {s} nwk=0x{X:0>4}", .{ label, ann.nwk_addr });
                    }
                    self.markAwakeForSetup(ann.ieee);
                } else |_| {}
            },
            Zdo.CLUSTER_NWK_ADDR_RSP, Zdo.CLUSTER_IEEE_ADDR_RSP => {
                const rsp = Zdo.parseAddrRsp(msg.payload()) catch return;
                if (rsp.status != Zdo.STATUS_SUCCESS) return;
                const result = try self.model.upsert(self.io, rsp.ieee, rsp.nwk_addr);
                if (result == .new or result == .reassociated) self.model.save(self.io, Io.Dir.cwd());
            },
            else => {},
        }
    }

    /// Fires a ZDO IEEE_addr_req at a nwk we've seen traffic from but
    /// can't map to a device (stale table, or never learned).
    /// Fire-and-forget: the 0x8001 response arrives like any other
    /// message and `handleZdoMessage` upserts the table. Rate-limited via
    /// `queried_nwks`.
    fn maybeResolveSender(self: *Coordinator, sender: u16) !void {
        if (sender == 0x0000 or sender >= 0xFFF8) return; // ourselves / broadcast pseudo-addresses
        if (self.model.findByNwk(sender) != null) return;
        for (self.queried_nwks) |q| {
            if (q == sender) return;
        }
        self.queried_nwks[self.queried_idx] = sender;
        self.queried_idx = (self.queried_idx + 1) % self.queried_nwks.len;

        self.zdo_seq +%= 1;
        var req_buf: [5]u8 = undefined;
        const req = Zdo.buildIeeeAddrReq(self.zdo_seq, sender, &req_buf);
        _ = self.ezsp.sendUnicast(sender, .{
            .profile_id = Zdo.PROFILE_ID,
            .cluster_id = Zdo.CLUSTER_IEEE_ADDR_REQ,
            .source_endpoint = Zdo.ENDPOINT,
            .destination_endpoint = Zdo.ENDPOINT,
        }, self.zdo_seq, req) catch return;
        try self.model.report(self.io, "[event] unknown sender nwk=0x{X:0>4} — sent IEEE address query", .{sender});
    }

    /// Answers an OTA QueryNextImage with NO_IMAGE_AVAILABLE so the
    /// device stops polling our (image-less) OTA server every few
    /// seconds. Fire-and-forget, safe to call from `pollOnce` (a plain
    /// `sendUnicast`, no nested poll loop).
    fn respondOtaNoImage(self: *Coordinator, msg: *const Ezsp.IncomingMessage) !void {
        const frame = Zcl.parseFrame(msg.payload()) catch return;
        if (!frame.isClusterSpecific() or frame.command_id != Zcl.OTA_CMD_QUERY_NEXT_IMAGE) return;
        var buf: [4]u8 = undefined;
        const rsp = Zcl.buildQueryNextImageNoImage(frame.zcl_seq, &buf);
        _ = self.ezsp.sendUnicast(msg.sender, .{
            .profile_id = Zcl.PROFILE_HA,
            .cluster_id = Zcl.CLUSTER_OTA,
            .source_endpoint = 1,
            .destination_endpoint = msg.aps.source_endpoint,
        }, self.zcl_seq, rsp) catch {};
    }

    /// Broadcasts a ZDO NWK_addr_req for `ieee` and waits briefly for an
    /// answer. The device table is updated as a side effect (the response
    /// flows through `pollOnce` → `handleZdoMessage` → upsert); the
    /// return value just says whether the network answered.
    fn nwkAddrLookup(self: *Coordinator, ieee: [8]u8) !bool {
        self.zdo_seq +%= 1;
        var req_buf: [11]u8 = undefined;
        const req = Zdo.buildNwkAddrReq(self.zdo_seq, ieee, &req_buf);
        const sent = try self.ezsp.sendBroadcast(Ezsp.BROADCAST_RX_ON_WHEN_IDLE, .{
            .profile_id = Zdo.PROFILE_ID,
            .cluster_id = Zdo.CLUSTER_NWK_ADDR_REQ,
            .source_endpoint = Zdo.ENDPOINT,
            .destination_endpoint = Zdo.ENDPOINT,
        }, 0, self.zdo_seq, req);
        if (sent.status != Ezsp.STATUS_SUCCESS) {
            try self.say("hub: NWK address broadcast refused by NCP (status=0x{x:0>2})", .{sent.status});
            return false;
        }
        if (try self.awaitZdo(Zdo.CLUSTER_NWK_ADDR_RSP, self.zdo_seq, 4)) |msg| {
            const rsp = Zdo.parseAddrRsp(msg.payload()) catch return false;
            return rsp.status == Zdo.STATUS_SUCCESS and std.mem.eql(u8, &rsp.ieee, &ieee);
        }
        return false;
    }

    /// Waits for a ZDO response matching `cluster` + echoed `zdo_seq`.
    /// Only empty polls count against the budget (unrelated traffic must
    /// not starve the wait); membership churn during the wait updates the
    /// device table via `pollOnce`.
    fn awaitZdo(self: *Coordinator, cluster: u16, zdo_seq: u8, empty_budget: u8) !?Ezsp.IncomingMessage {
        var empty_polls: u8 = 0;
        var total_polls: u16 = 0;
        const total_cap: u16 = @as(u16, empty_budget) * 8;
        while (empty_polls < empty_budget and total_polls < total_cap) : (total_polls += 1) {
            const cb = try self.pollOnce() orelse {
                empty_polls += 1;
                continue;
            };
            switch (cb) {
                .incoming_message => |msg| {
                    if (msg.aps.profile_id == Zdo.PROFILE_ID and msg.aps.cluster_id == cluster and
                        msg.contents_len >= 1 and msg.contents[0] == zdo_seq)
                    {
                        return msg;
                    }
                },
                else => {},
            }
        }
        return null;
    }

    /// Waits for a ZCL response matching our sequence + command id; same
    /// only-empty-polls-count budget discipline as `awaitZdo`.
    /// `global` selects which frame-type bit to require: `true` for
    /// global commands (e.g. Configure Reporting Response), `false` for
    /// cluster-specific ones (e.g. Groups' Add Group Response) — ZCL's
    /// two command spaces both start numbering at 0x00, so the frame
    /// type is what disambiguates a match, not just the command id.
    fn awaitZcl(self: *Coordinator, cluster: u16, zcl_seq: u8, command_id: u8, global: bool) !?Ezsp.IncomingMessage {
        var empty_polls: u8 = 0;
        var total_polls: u8 = 0;
        while (empty_polls < 4 and total_polls < 32) : (total_polls += 1) {
            const cb = try self.pollOnce() orelse {
                empty_polls += 1;
                continue;
            };
            switch (cb) {
                .incoming_message => |msg| {
                    if (msg.aps.profile_id != Zcl.PROFILE_HA or msg.aps.cluster_id != cluster) continue;
                    const frame = Zcl.parseFrame(msg.payload()) catch continue;
                    const type_matches = if (global) frame.isGlobal() else frame.isClusterSpecific();
                    if (type_matches and frame.zcl_seq == zcl_seq and frame.command_id == command_id) {
                        return msg;
                    }
                },
                else => {},
            }
        }
        return null;
    }

    // ── Capability recording ────────────────────────────────────────

    /// Which discovered-capability slot a cluster proves the existence of.
    pub const Capability = enum { onoff, occupancy, ias_zone, controller };

    /// Records that `sender` has `cap` on `endpoint` — **learned from the
    /// device's own traffic**, not from asking it.
    ///
    /// **Why this exists.** `web.zig`/`screens.zig` classify a device by its
    /// discovered capability endpoints, and those were only ever set by
    /// `discoverDevice` — a ZDO round-trip. A sleepy end device can lose that
    /// race forever: the real `moisture` sensor answered the Active Endpoints
    /// request and was asleep again before the Simple Descriptor request
    /// arrived (`endpoint 1: no response`), so it stayed unclassified and the
    /// web page **hid a device that was actively reporting alarms**.
    ///
    /// But a report is proof. A ZoneStatusChangeNotification can only come
    /// from an IAS Zone cluster; an Occupancy report from an Occupancy
    /// cluster; and each carries the source endpoint it came from. So a
    /// device that talks to us at all is classifiable, with no round-trip and
    /// no wake window to hit. Discovery remains the path for devices that
    /// have never said anything.
    ///
    /// Only fills an empty slot: `discover`'s answer (which sees the whole
    /// descriptor) is never overwritten by an inference, and this never
    /// re-saves on every report.
    fn noteCapability(self: *Coordinator, sender: u16, cap: Capability, endpoint: u8) !void {
        const dev = self.model.findByNwk(sender) orelse return;
        const slot = switch (cap) {
            .onoff => &dev.onoff_endpoint,
            .occupancy => &dev.occupancy_endpoint,
            .ias_zone => &dev.ias_zone_endpoint,
            .controller => &dev.controller_endpoint,
        };
        if (slot.* != null) return;
        slot.* = endpoint;
        _ = self.model.revision.fetchAdd(1, .release); // the TUI/web should re-render
        self.model.save(self.io, Io.Dir.cwd());
        const label = switch (cap) {
            .onoff => "On/Off",
            .occupancy => "Occupancy",
            .ias_zone => "IAS Zone",
            .controller => "controller — it drives other devices",
        };
        try self.model.report(self.io, "[learn] {s}: {s} cluster on endpoint {d} (from its own report)", .{ self.senderLabel(sender), label, endpoint });
    }

    /// Records every capability a Simple Descriptor proves, from the
    /// descriptor itself. Shared by `discoverDevice` and `setupDevice`
    ///.
    ///
    /// `setupDevice` walks the exact same descriptors to decide what to bind
    /// and then **threw this away** — a pure oversight that meant `setup`
    /// could commission a device perfectly while leaving it unclassified and
    /// therefore invisible on the web page.
    fn recordDescriptorCapabilities(self: *Coordinator, ieee: [8]u8, d: Zdo.SimpleDescriptor) !void {
        const dev = try self.requireDevice(ieee);
        const wants = [_]struct { cluster: u16, slot: *?u8, label: []const u8 }{
            .{ .cluster = Zcl.CLUSTER_ON_OFF, .slot = &dev.onoff_endpoint, .label = "On/Off" },
            .{ .cluster = Zcl.CLUSTER_OCCUPANCY, .slot = &dev.occupancy_endpoint, .label = "Occupancy" },
            .{ .cluster = Zcl.CLUSTER_IAS_ZONE, .slot = &dev.ias_zone_endpoint, .label = "IAS Zone" },
            .{ .cluster = Zcl.CLUSTER_COLOR_CONTROL, .slot = &dev.color_endpoint, .label = "Color" },
        };
        var changed = false;
        for (wants) |w| {
            if (!d.hasInputCluster(w.cluster) or w.slot.* != null) continue;
            w.slot.* = d.endpoint;
            changed = true;
            try self.model.report(self.io, "{s} cluster on endpoint {d}", .{ w.label, d.endpoint });
        }
        // A controller has none of the above: its On/Off and Level clusters
        // are OUTPUTS (it drives them on other devices). Without this, a
        // dimmer discovers as entirely capability-less and is
        // indistinguishable from a device we've simply never reached —
        // so `screens.zig` would have to guess which. The observation path
        // (`noteCapability(.controller)`) catches one that never gets
        // discovered; this catches one that never gets pressed.
        if (dev.controller_endpoint == null and
            (d.hasOutputCluster(Zcl.CLUSTER_ON_OFF) or d.hasOutputCluster(Zcl.CLUSTER_LEVEL_CONTROL)))
        {
            dev.controller_endpoint = d.endpoint;
            changed = true;
            try self.model.report(self.io, "controller (drives On/Off/Level) on endpoint {d}", .{d.endpoint});
        }
        if (changed) {
            _ = self.model.revision.fetchAdd(1, .release);
            self.model.save(self.io, Io.Dir.cwd());
        }
    }

    // ── Event decoding (console reporting) ──────────────────────────

    /// Decodes device-originated ZCL traffic into readable console
    /// events. Returns true if decoded/printed; false falls through to
    /// the generic `[msg]` line. Automation hooks (`fireEvent`) are left
    /// out here — that's the rules engine, ported in a later step; this
    /// only reports.
    fn printZclEvent(self: *Coordinator, msg: *const Ezsp.IncomingMessage) !bool {
        const frame = Zcl.parseFrame(msg.payload()) catch return false;
        const who = self.senderLabel(msg.sender);

        if (frame.isGlobal()) {
            switch (frame.command_id) {
                Zcl.CMD_REPORT_ATTRIBUTES => {
                    var it = Zcl.AttributeReports{ .data = frame.payload };
                    var printed = false;
                    while (it.next()) |rec| {
                        try self.printAttributeReport(who, msg.sender, msg.aps.source_endpoint, msg.aps.cluster_id, &rec);
                        printed = true;
                    }
                    return printed;
                },
                // A device ANSWERING a poll. Same records,
                // same handling as a report it volunteered — a value is a
                // value, however we came by it — but a different payload
                // layout, hence the separate iterator (see zcl.zig).
                Zcl.CMD_READ_ATTRIBUTES_RSP => {
                    var it = Zcl.ReadAttributeResponses{ .data = frame.payload };
                    var printed = false;
                    while (it.next()) |rec| {
                        try self.printAttributeReport(who, msg.sender, msg.aps.source_endpoint, msg.aps.cluster_id, &rec);
                        printed = true;
                    }
                    return printed;
                },
                Zcl.CMD_DEFAULT_RESPONSE => {
                    const rsp = Zcl.parseDefaultResponse(msg.payload()) orelse return false;
                    try self.model.report(self.io, "[event] {s} default response: cmd=0x{x:0>2} status=0x{x:0>2}", .{ who, rsp.command_id, rsp.status });
                    return true;
                },
                Zcl.CMD_CONFIGURE_REPORTING_RSP => return true,
                else => return false,
            }
        }
        if (!frame.isClusterSpecific()) return false;

        // A cluster-specific frame arriving FROM a device is a command it
        // sent us — only a controller does that (a light reports its
        // attributes; it doesn't tell anyone else to switch). This is the
        // only evidence of controller-ness hub ever gets: a dimmer's On/Off
        // and Level clusters are OUTPUTS, and `discoverDevice` only records
        // inputs. Safe against our own multicast echo (sender 0x0000, which
        // `noteCapability` can't resolve to a device) and against lights
        // (their On/Off traffic is an attribute report, decoded elsewhere).
        switch (msg.aps.cluster_id) {
            Zcl.CLUSTER_ON_OFF, Zcl.CLUSTER_LEVEL_CONTROL, Zcl.CLUSTER_PHILIPS_BUTTON => {
                try self.noteCapability(msg.sender, .controller, msg.aps.source_endpoint);
            },
            else => {},
        }

        switch (msg.aps.cluster_id) {
            Zcl.CLUSTER_ON_OFF => {
                switch (frame.command_id) {
                    Zcl.ONOFF_CMD_OFF, Zcl.ONOFF_CMD_ON, Zcl.ONOFF_CMD_TOGGLE => {
                        const name: []const u8 = switch (frame.command_id) {
                            Zcl.ONOFF_CMD_OFF => "off",
                            Zcl.ONOFF_CMD_ON => "on",
                            else => "toggle",
                        };
                        try self.model.report(self.io, "[event] {s} (nwk=0x{X:0>4}) sent on/off command: {s}", .{ who, msg.sender, name });
                    },
                    Zcl.ONOFF_CMD_OFF_WITH_EFFECT => {
                        const owe = Zcl.parseOffWithEffect(frame.payload) orelse return false;
                        try self.model.report(self.io, "[event] {s} sent off-with-effect (effect={d} variant={d})", .{ who, owe.effect_id, owe.effect_variant });
                    },
                    Zcl.ONOFF_CMD_ON_WITH_RECALL_GLOBAL_SCENE => {
                        try self.model.report(self.io, "[event] {s} sent on-with-recall-global-scene", .{who});
                    },
                    Zcl.ONOFF_CMD_ON_WITH_TIMED_OFF => {
                        const owto = Zcl.parseOnWithTimedOff(frame.payload) orelse return false;
                        try self.model.report(self.io, "[event] {s} sent on-with-timed-off (on {d}.{d}s, off-wait {d}.{d}s)", .{ who, owto.on_time_tenths / 10, owto.on_time_tenths % 10, owto.off_wait_tenths / 10, owto.off_wait_tenths % 10 });
                    },
                    else => return false,
                }
                return true;
            },
            Zcl.CLUSTER_LEVEL_CONTROL => {
                const p = frame.payload;
                switch (frame.command_id) {
                    Zcl.LEVEL_CMD_STEP, Zcl.LEVEL_CMD_STEP_WITH_ONOFF => {
                        if (p.len < 4) return false;
                        const dir: []const u8 = if (p[0] == 0) "up" else "down";
                        const transition = @as(u16, p[2]) | (@as(u16, p[3]) << 8);
                        try self.model.report(self.io, "[event] {s} sent level step {s} {d} ({d}.{d}s)", .{ who, dir, p[1], transition / 10, transition % 10 });
                    },
                    Zcl.LEVEL_CMD_MOVE, Zcl.LEVEL_CMD_MOVE_WITH_ONOFF => {
                        if (p.len < 2) return false;
                        const dir: []const u8 = if (p[0] == 0) "up" else "down";
                        try self.model.report(self.io, "[event] {s} sent level move {s} rate={d}", .{ who, dir, p[1] });
                    },
                    Zcl.LEVEL_CMD_STOP, Zcl.LEVEL_CMD_STOP_WITH_ONOFF => {
                        try self.model.report(self.io, "[event] {s} sent level stop", .{who});
                    },
                    Zcl.LEVEL_CMD_MOVE_TO_LEVEL, Zcl.LEVEL_CMD_MOVE_TO_LEVEL_WITH_ONOFF => {
                        if (p.len < 3) return false;
                        const transition = @as(u16, p[1]) | (@as(u16, p[2]) << 8);
                        try self.model.report(self.io, "[event] {s} sent move-to-level {d} ({d}.{d}s)", .{ who, p[0], transition / 10, transition % 10 });
                    },
                    else => return false,
                }
                return true;
            },
            Zcl.CLUSTER_PHILIPS_BUTTON => {
                if (frame.command_id != 0x00) return false;
                const ev = Zcl.parseHueNotification(frame.payload) orelse return false;
                if (ev.isDial()) {
                    // The Tap dial reuses this notification for rotation
                    // (button field == 20). The genLevelCtrl `step`
                    // command that accompanies it carries the step size;
                    // this adds the herdsman-style direction/speed.
                    try self.model.report(self.io, "[event] {s} dial rotate {s} ({s})", .{ who, ev.dialDirection(), ev.dialSpeed() });
                    // Automation: each rotation detent is a single-shot event.
                    try self.fireEvent(who, if (std.mem.eql(u8, ev.dialDirection(), "right")) "dial_right" else "dial_left", .tick);
                } else {
                    // Button semantics are per-device (dimmer: 1=on
                    // 2=dim-up 3=dim-down 4=off; dial: just 1-4), so print
                    // the raw number — unambiguous — not a device-specific
                    // label.
                    const eighths: u16 = ev.time;
                    try self.model.report(self.io, "[event] {s} button {d}: {s} ({d}.{d}s)", .{ who, ev.button, ev.typeName(), eighths / 8, (eighths % 8) * 125 / 100 });
                    if (self.house) |house| {
                        if (ev.button >= 1 and ev.button <= 4) {
                            if (HouseLog.buttonEvent(ev.event_type)) |event| {
                                if (self.model.findByNwk(msg.sender)) |d| house.button(d.ieee, ev.button, event);
                            }
                        }
                    }
                    // Automation: fire button<N> with the gesture phase, so
                    // a level action taps (press), ramps (hold), and stops
                    // (release). Type 1=hold, 2/3=release; ignore anything
                    // else.
                    if (ev.button >= 1 and ev.button <= 4) {
                        const phase: ?Phase = switch (ev.event_type) {
                            0 => .press,
                            1 => .hold,
                            2, 3 => .release,
                            else => null,
                        };
                        if (phase) |p| {
                            var ev_buf: [8]u8 = undefined;
                            const ev_name = std.fmt.bufPrint(&ev_buf, "button{d}", .{ev.button}) catch return true;
                            try self.fireEvent(who, ev_name, p);
                        }
                    }
                }
                return true;
            },
            Zcl.CLUSTER_IAS_ZONE => switch (frame.command_id) {
                // A factory-fresh IAS sensor asks to be enrolled before it
                // will report anything. It's awake right now, but
                // we're inside a poll callback — so learn the capability and
                // defer the actual enrollment sends to the main loop via
                // `pending_enroll` (same rule as every other event-triggered
                // send). Without this the request falls through unanswered
                // and the sensor stays silent forever.
                Zcl.IAS_CMD_ZONE_ENROLL_REQUEST => {
                    try self.noteCapability(msg.sender, .ias_zone, msg.aps.source_endpoint);
                    const req = Zcl.parseZoneEnrollRequest(frame.payload);
                    if (self.model.findByNwk(msg.sender)) |d| {
                        self.pending_enroll = d.ieee;
                        if (req) |r| {
                            if (d.zone_type != r.zone_type) {
                                d.zone_type = r.zone_type;
                                self.model.save(self.io, Io.Dir.cwd());
                            }
                            try self.model.report(self.io, "[event] {s}: IAS Zone Enroll Request (type=0x{X:0>4}) — enrolling", .{ who, r.zone_type });
                        } else {
                            try self.model.report(self.io, "[event] {s}: IAS Zone Enroll Request — enrolling", .{who});
                        }
                    }
                    return true;
                },
                Zcl.IAS_CMD_ZONE_STATUS_CHANGE_NOTIFICATION => {
                    const s = Zcl.parseIasZoneStatusChange(frame.payload) orelse return false;
                    // The notification IS the proof: only an IAS Zone cluster
                    // sends one. This is what makes a sleepy leak sensor — which
                    // never survives discovery's second round-trip — classifiable
                    // and therefore visible on the web page.
                    try self.noteCapability(msg.sender, .ias_zone, msg.aps.source_endpoint);
                    // alarm1 is the sensor's primary trigger — "water
                    // detected" for a leak sensor, "open" for contact,
                    // "motion" for PIR, etc., depending on the physical
                    // device; we don't know the zone type here so we print
                    // generically.
                    try self.model.report(self.io, "[report] {s}: {s}{s}{s}", .{
                        who,
                        if (s.alarm1()) "ALARM" else "clear",
                        if (s.tamper()) " tamper" else "",
                        if (s.batteryLow()) " low-battery" else "",
                    });
                    if (self.model.findByNwk(msg.sender)) |d| {
                        try self.noteReading(d.ieee, .{ .alert = s.alarm1() });
                    }
                    // Automation: mirrors motion's occupied/clear — lets a
                    // rule react to the sensor tripping (e.g. flash a light
                    // on a leak).
                    try self.fireEvent(who, if (s.alarm1()) "alarm" else "clear", .tick);
                    return true;
                },
                else => return false,
            },
            else => return false,
        }
    }

    /// Takes an answer to `pollSettings`, if this is one.
    fn noteSetting(self: *Coordinator, who: []const u8, sender: u16, cluster: u16, rec: *const Zcl.AttributeRecord) !bool {
        const dev = self.model.findByNwk(sender) orelse return false;
        if (cluster == HouseLog.CLUSTER_BASIC and (rec.attr_id == HouseLog.ATTR_MODEL or rec.attr_id == HouseLog.ATTR_FIRMWARE)) {
            const text = Zcl.charString(rec) orelse return true;
            if (rec.attr_id == HouseLog.ATTR_MODEL) {
                dev.model_id = Model.ShortText.of(text);
            } else {
                dev.firmware = Model.ShortText.of(text);
            }
            self.model.save(self.io, Io.Dir.cwd());
            try self.model.report(self.io, "[settings] {s}: {s} {s}", .{ who, if (rec.attr_id == HouseLog.ATTR_MODEL) "model" else "firmware", text });
            return true;
        }
        if (cluster == HouseLog.CLUSTER_ON_OFF and rec.attr_id == HouseLog.ATTR_STARTUP_ON_OFF) {
            const value = rec.intValue() orelse return true;
            dev.startup_on_off = @truncate(@as(u64, @bitCast(value)));
            try self.model.report(self.io, "[settings] {s}: power-on on/off 0x{x:0>2}", .{ who, dev.startup_on_off.? });
            return true;
        }
        if (cluster == HouseLog.CLUSTER_LEVEL and rec.attr_id == HouseLog.ATTR_STARTUP_LEVEL) {
            const value = rec.intValue() orelse return true;
            dev.startup_level = @truncate(@as(u64, @bitCast(value)));
            try self.model.report(self.io, "[settings] {s}: power-on level 0x{x:0>2}", .{ who, dev.startup_level.? });
            return true;
        }
        return false;
    }

    fn printAttributeReport(self: *Coordinator, who: []const u8, sender: u16, source_endpoint: u8, cluster: u16, rec: *const Zcl.AttributeRecord) !void {
        // Resolved once, used by every recordReading call below — null if
        // the sender isn't in the table yet (recordReading no-ops then,
        // same as fireEvent already tolerates via its "?" controller check).
        const ieee: ?[8]u8 = if (self.model.findByNwk(sender)) |d| d.ieee else null;

        if (try self.noteSetting(who, sender, cluster, rec)) return;

        const v = rec.intValue();
        if (v) |val| {
            if (cluster == Zcl.CLUSTER_OCCUPANCY and rec.attr_id == 0x0000) {
                const occupied = val & 1 != 0;
                try self.noteCapability(sender, .occupancy, source_endpoint);
                try self.model.report(self.io, "[report] {s}: occupancy: {s}", .{ who, if (occupied) "occupied" else "clear" });
                if (ieee) |e| try self.noteReading(e, .{ .occupancy = occupied });
                // Automation: fire occupied/clear events.
                try self.fireEvent(who, if (occupied) "occupied" else "clear", .tick);
            } else if (cluster == Zcl.CLUSTER_TEMPERATURE and rec.attr_id == 0x0000) {
                const centi: i64 = val;
                const whole = @divTrunc(centi, 100);
                const frac = @abs(@rem(centi, 100));
                try self.model.report(self.io, "[report] {s}: temperature: {d}.{d:0>2}°C", .{ who, whole, frac });
                if (ieee) |e| try self.noteReading(e, .{ .temperature_centi = @intCast(val) });
            } else if (cluster == Zcl.CLUSTER_HUMIDITY and rec.attr_id == 0x0000) {
                if (val == Zcl.HUMIDITY_UNKNOWN) {
                    try self.model.report(self.io, "[report] {s}: humidity: unknown", .{who});
                } else {
                    // Unsigned: a padded signed integer prints its sign, as "59.+80".
                    const centi: u16 = @intCast(val);
                    try self.model.report(self.io, "[report] {s}: humidity: {d}.{d:0>2}%", .{ who, centi / 100, centi % 100 });
                    if (ieee) |e| {
                        try self.noteReading(e, .{ .humidity_centi = @intCast(val) });
                        try self.humidityReading(e, who, centi);
                    }
                }
            } else if (cluster == Zcl.CLUSTER_ILLUMINANCE and rec.attr_id == 0x0000) {
                const lux = std.math.pow(f64, 10.0, (@as(f64, @floatFromInt(val)) - 1.0) / 10000.0);
                try self.model.report(self.io, "[report] {s}: illuminance: ~{d:.0} lux (raw {d})", .{ who, lux, val });
                if (ieee) |e| try self.noteReading(e, .{ .illuminance_raw = @intCast(val) });
            } else if (cluster == Zcl.CLUSTER_POWER_CONFIG and rec.attr_id == 0x0021) {
                try self.model.report(self.io, "[report] {s}: battery: {d}.{d}%", .{ who, @divTrunc(val, 2), @rem(val, 2) * 5 });
                // BatteryPercentageRemaining is in half-percent units;
                // Device.battery_pct stores whole percent, matching what
                // the console/TUI actually wants to display.
                if (ieee) |e| try self.noteReading(e, .{ .battery_pct = @intCast(@divTrunc(val, 2)) });
            } else if (cluster == Zcl.CLUSTER_POWER_CONFIG and rec.attr_id == 0x0020) {
                try self.model.report(self.io, "[report] {s}: battery voltage: {d}.{d}V", .{ who, @divTrunc(val, 10), @rem(val, 10) });
            } else if (cluster == Zcl.CLUSTER_ON_OFF and rec.attr_id == 0x0000) {
                const on = val != 0;
                try self.noteCapability(sender, .onoff, source_endpoint);
                try self.model.report(self.io, "[report] {s}: {s}", .{ who, if (on) "on" else "off" });
                if (ieee) |e| try self.noteReading(e, .{ .on = on });
            } else {
                try self.model.report(self.io, "[report] {s} (nwk=0x{X:0>4}): cluster 0x{X:0>4} attr 0x{X:0>4} = {d}", .{ who, sender, cluster, rec.attr_id, val });
            }
        } else {
            try self.model.report(self.io, "[report] {s} (nwk=0x{X:0>4}): cluster 0x{X:0>4} attr 0x{X:0>4} type 0x{x:0>2} len={d}", .{ who, sender, cluster, rec.attr_id, rec.data_type, rec.raw.len });
        }
    }

    // ── Discovery ────────────────────────────────────────────────────

    fn zdoActiveEndpoints(self: *Coordinator, ieee: [8]u8, empty_budget: u8) !?Zdo.ActiveEpRsp {
        var attempt: u8 = 0;
        while (attempt < 3) : (attempt += 1) {
            // Re-resolved per attempt, not hoisted: each attempt awaits.
            const nwk = try self.deviceNwk(ieee);
            self.zdo_seq +%= 1;
            var req_buf: [3]u8 = undefined;
            const req = Zdo.buildActiveEpReq(self.zdo_seq, nwk, &req_buf);
            const sent = try self.ezsp.sendUnicast(nwk, .{
                .profile_id = Zdo.PROFILE_ID,
                .cluster_id = Zdo.CLUSTER_ACTIVE_EP_REQ,
                .source_endpoint = Zdo.ENDPOINT,
                .destination_endpoint = Zdo.ENDPOINT,
            }, self.zdo_seq, req);
            if (sent.status != Ezsp.STATUS_SUCCESS) continue;
            if (try self.awaitZdo(Zdo.CLUSTER_ACTIVE_EP_RSP, self.zdo_seq, empty_budget)) |msg| {
                return try Zdo.parseActiveEpRsp(msg.payload());
            }
        }
        return null;
    }

    fn zdoSimpleDescriptor(self: *Coordinator, ieee: [8]u8, ep: u8, empty_budget: u8) !?Zdo.SimpleDescRsp {
        var attempt: u8 = 0;
        while (attempt < 3) : (attempt += 1) {
            const nwk = try self.deviceNwk(ieee);
            self.zdo_seq +%= 1;
            var req_buf: [4]u8 = undefined;
            const req = Zdo.buildSimpleDescReq(self.zdo_seq, nwk, ep, &req_buf);
            const sent = try self.ezsp.sendUnicast(nwk, .{
                .profile_id = Zdo.PROFILE_ID,
                .cluster_id = Zdo.CLUSTER_SIMPLE_DESC_REQ,
                .source_endpoint = Zdo.ENDPOINT,
                .destination_endpoint = Zdo.ENDPOINT,
            }, self.zdo_seq, req);
            if (sent.status != Ezsp.STATUS_SUCCESS) continue;
            if (try self.awaitZdo(Zdo.CLUSTER_SIMPLE_DESC_RSP, self.zdo_seq, empty_budget)) |msg| {
                return try Zdo.parseSimpleDescRsp(msg.payload());
            }
        }
        return null;
    }

    /// Reports via `model.report` throughout, not `self.out` — reachable
    /// from both console commands and (via `setupDevice`) watch-mode's
    /// single-key `setup` action, so it can't assume a synchronous
    /// foreground console (see `sendOnOff`'s routing-fix comment for why
    /// that split matters: watch mode has the terminal in raw/cursor-
    /// addressed mode, where a stray direct write would corrupt the frame).
    pub fn discoverDevice(self: *Coordinator, ieee: [8]u8) !void {
        const eps = try self.zdoActiveEndpoints(ieee, 4) orelse return error.ZdoTimeout;
        if (eps.status != Zdo.STATUS_SUCCESS) return error.ZdoStatusError;

        for (eps.endpoints[0..eps.endpoint_count]) |ep| {
            const rsp = try self.zdoSimpleDescriptor(ieee, ep, 4) orelse {
                try self.model.report(self.io, "endpoint {d}: no response", .{ep});
                continue;
            };
            if (rsp.status != Zdo.STATUS_SUCCESS) continue;
            const d = rsp.descriptor;

            var line: std.Io.Writer.Allocating = .init(self.model.gpa);
            defer line.deinit();
            try line.writer.print("endpoint {d}: profile=0x{X:0>4} device=0x{X:0>4}  in: ", .{ d.endpoint, d.profile_id, d.device_id });
            for (d.input_clusters[0..d.input_cluster_count], 0..) |c, i| {
                if (i > 0) try line.writer.writeAll(", ");
                try line.writer.print("0x{X:0>4}", .{c});
            }
            try line.writer.writeAll("  out: ");
            for (d.output_clusters[0..d.output_cluster_count], 0..) |c, i| {
                if (i > 0) try line.writer.writeAll(", ");
                try line.writer.print("0x{X:0>4}", .{c});
            }
            try self.model.report(self.io, "{s}", .{line.writer.buffered()});

            // Re-resolved here rather than once at the top: the descriptor
            // fetch above awaited, so any pointer taken before it could
            // have been invalidated by traffic arriving meanwhile.
            try self.recordDescriptorCapabilities(ieee, d);
        }
        try self.refineColorCapability(ieee);
    }

    /// The descriptor walk sets `color_endpoint` from the Color Control
    /// cluster merely being *present* — but a white-ambiance bulb has that
    /// cluster and only does colour temperature, not RGB (xy), answering
    /// Move to Color with UNSUP_CLUSTER_COMMAND. This confirms the xy
    /// capability by reading ColorCapabilities and clears `color_endpoint`
    /// if it's not there, so a rule colour is silently ignored on such a
    /// bulb (the user's "ignore if no colour setting" requirement) rather
    /// than firing a Move to Color the bulb rejects. Shared by
    /// `discoverDevice` and `setupDevice`, since both fill the slot from the
    /// descriptor and would otherwise disagree.
    fn refineColorCapability(self: *Coordinator, ieee: [8]u8) !void {
        const ep = (try self.requireDevice(ieee)).color_endpoint orelse return;
        const caps = try self.readColorCapabilities(ieee, ep);
        const xy = if (caps) |c| (c & COLORCAP_XY != 0) else false;
        const dev = try self.requireDevice(ieee);
        if (!xy) {
            dev.color_endpoint = null;
            self.model.save(self.io, Io.Dir.cwd());
            try self.model.report(self.io, "colour: temperature-only (not RGB) — rule colours will be ignored for this device", .{});
        } else {
            try self.model.report(self.io, "colour: RGB (xy) capable", .{});
        }
    }

    // ── Commissioning (bind + configure reporting) ──────────────────

    const ReportSetup = struct { cluster: u16, cfg: Zcl.ReportingConfig };
    const report_setups = [_]ReportSetup{
        .{ .cluster = Zcl.CLUSTER_OCCUPANCY, .cfg = .{ .attr_id = 0x0000, .data_type = 0x18, .min_interval_s = 0, .max_interval_s = 3600 } },
        .{ .cluster = Zcl.CLUSTER_TEMPERATURE, .cfg = .{ .attr_id = 0x0000, .data_type = 0x29, .min_interval_s = 30, .max_interval_s = 900, .reportable_change = 50 } },
        // uint16 (0x21), reported on a 1% change: finer is noise from a breath.
        .{ .cluster = Zcl.CLUSTER_HUMIDITY, .cfg = .{ .attr_id = 0x0000, .data_type = 0x21, .min_interval_s = 30, .max_interval_s = 900, .reportable_change = 100 } },
        .{ .cluster = Zcl.CLUSTER_ILLUMINANCE, .cfg = .{ .attr_id = 0x0000, .data_type = 0x21, .min_interval_s = 30, .max_interval_s = 900, .reportable_change = 500 } },
        .{ .cluster = Zcl.CLUSTER_POWER_CONFIG, .cfg = .{ .attr_id = 0x0021, .data_type = 0x20, .min_interval_s = 3600, .max_interval_s = 43200, .reportable_change = 2 } },
        // Lights' own OnOff attribute (0x0000, Boolean — discrete type, so
        // buildConfigureReporting correctly omits reportable_change).
        // CLUSTER_ON_OFF also appears in bind_only_outputs below, but that
        // entry only matches the OUTPUT-cluster loop (controllers like the
        // dimmer, whose On/Off is what THEY send from) — this one only
        // matches the INPUT-cluster loop (lights, whose On/Off is what
        // THEY receive commands on and can report their own state from).
        // min_interval=0 so a toggle is reported immediately, max=3600 as
        // an hourly resync heartbeat, matching occupancy's own choice.
        .{ .cluster = Zcl.CLUSTER_ON_OFF, .cfg = .{ .attr_id = 0x0000, .data_type = 0x10, .min_interval_s = 0, .max_interval_s = 3600 } },
    };
    const bind_only_outputs = [_]u16{ Zcl.CLUSTER_ON_OFF, Zcl.CLUSTER_LEVEL_CONTROL };
    const bind_only_inputs = [_]u16{ Zcl.CLUSTER_PHILIPS_BUTTON, Zcl.CLUSTER_IAS_ZONE };

    fn bindCluster(self: *Coordinator, ieee: [8]u8, endpoint: u8, cluster: u16, our_ieee: [8]u8) !bool {
        return self.sendBindChange(.bind, ieee, endpoint, cluster, our_ieee, 1);
    }

    pub const BindChange = enum { bind, unbind };

    /// One Bind_req or Unbind_req to the source device. True only if the
    /// device confirmed it: false covers both a refusal, which is reported
    /// here, and no answer, which the caller words for its own context.
    fn sendBindChange(
        self: *Coordinator,
        change: BindChange,
        src_ieee: [8]u8,
        src_endpoint: u8,
        cluster: u16,
        dst_ieee: [8]u8,
        dst_endpoint: u8,
    ) !bool {
        const nwk = try self.deviceNwk(src_ieee);
        const req_cluster: u16, const rsp_cluster: u16 = switch (change) {
            .bind => .{ Zdo.CLUSTER_BIND_REQ, Zdo.CLUSTER_BIND_RSP },
            .unbind => .{ Zdo.CLUSTER_UNBIND_REQ, Zdo.CLUSTER_UNBIND_RSP },
        };
        self.zdo_seq +%= 1;
        var req_buf: [22]u8 = undefined;
        const req = switch (change) {
            .bind => Zdo.buildBindReq(self.zdo_seq, src_ieee, src_endpoint, cluster, dst_ieee, dst_endpoint, &req_buf),
            .unbind => Zdo.buildUnbindReq(self.zdo_seq, src_ieee, src_endpoint, cluster, dst_ieee, dst_endpoint, &req_buf),
        };
        const sent = try self.ezsp.sendUnicast(nwk, .{
            .profile_id = Zdo.PROFILE_ID,
            .cluster_id = req_cluster,
            .source_endpoint = Zdo.ENDPOINT,
            .destination_endpoint = Zdo.ENDPOINT,
        }, self.zdo_seq, req);
        if (sent.status != Ezsp.STATUS_SUCCESS) return false;
        if (try self.awaitZdo(rsp_cluster, self.zdo_seq, SETUP_EMPTY_BUDGET)) |msg| {
            const rsp = Zdo.parseBindRsp(msg.payload()) catch return false;
            if (rsp.status != Zdo.STATUS_SUCCESS) {
                try self.model.report(self.io, "  {t} 0x{X:0>4} ep{d}: ZDO status=0x{x:0>2}", .{ change, cluster, src_endpoint, rsp.status });
                return false;
            }
            return true;
        }
        return false;
    }

    /// Points a controller's on/off and level commands straight at a light,
    /// or takes them away again. The entry lives in the controller's own
    /// binding table, so the light then obeys it with this process out of the
    /// path. The controller's entries for us are separate and stay, so its
    /// button events keep arriving either way.
    pub fn changeOutputBinding(self: *Coordinator, change: BindChange, source: [8]u8, target: [8]u8) !void {
        var source_buf: [64]u8 = undefined;
        var target_buf: [64]u8 = undefined;
        const source_label = try self.deviceLabelBuf(&source_buf, source);
        const target_label = try self.deviceLabelBuf(&target_buf, target);
        const src_endpoint = (try self.requireDevice(source)).controller_endpoint orelse {
            try self.say("{t}: {s} has no known controller endpoint — run `setup` on it first", .{ change, source_label });
            return;
        };
        const dst_endpoint = (try self.requireDevice(target)).onoff_endpoint orelse {
            try self.say("{t}: {s} has no known on/off endpoint — run `setup` on it first", .{ change, target_label });
            return;
        };
        try self.model.report(self.io, "hub: {t} {s} → {s} ep{d} — if the source is battery-powered, press its buttons once a second now", .{ change, source_label, target_label, dst_endpoint });
        var changed: usize = 0;
        for (bind_only_outputs) |cluster| {
            if (try self.sendBindChange(change, source, src_endpoint, cluster, target, dst_endpoint)) {
                changed += 1;
                try self.model.report(self.io, "  {t} 0x{X:0>4} done", .{ change, cluster });
            }
        }
        if (changed == bind_only_outputs.len) {
            try self.model.report(self.io, "{t} done: {d} cluster(s)", .{ change, changed });
        } else {
            try self.model.report(self.io, "{t} incomplete: {d} of {d} cluster(s) — no answer or refused; it's safe to run it again", .{ change, changed, bind_only_outputs.len });
        }
    }

    fn configureReporting(self: *Coordinator, ieee: [8]u8, endpoint: u8, cluster: u16, cfg: Zcl.ReportingConfig) !bool {
        const nwk = try self.deviceNwk(ieee);
        self.zcl_seq +%= 1;
        var frame_buf: [16]u8 = undefined;
        const frame = Zcl.buildConfigureReporting(self.zcl_seq, cfg, &frame_buf);
        const sent = try self.ezsp.sendUnicast(nwk, .{
            .profile_id = Zcl.PROFILE_HA,
            .cluster_id = cluster,
            .source_endpoint = 1,
            .destination_endpoint = endpoint,
        }, self.zcl_seq, frame);
        if (sent.status != Ezsp.STATUS_SUCCESS) return false;
        if (try self.awaitZcl(cluster, self.zcl_seq, Zcl.CMD_CONFIGURE_REPORTING_RSP, true)) |msg| {
            const rsp_frame = Zcl.parseFrame(msg.payload()) catch return false;
            const status = Zcl.parseConfigureReportingRsp(rsp_frame.payload) orelse return false;
            if (status != 0x00) {
                try self.model.report(self.io, "  report-config 0x{X:0>4} attr 0x{X:0>4}: ZCL status=0x{x:0>2}", .{ cluster, cfg.attr_id, status });
                return false;
            }
            return true;
        }
        return false;
    }

    /// Binds controller/sensor clusters to our endpoint 1 and configures
    /// attribute reporting on the sensor clusters — the step that makes
    /// button presses and sensor reports actually arrive: devices send
    /// nothing until the coordinator binds and configures reporting. Sleepy devices only answer
    /// while awake; on timeout the caller should mark `pending_setup` so
    /// the engine retries on the next announce.
    pub fn setupDevice(self: *Coordinator, ieee: [8]u8) !void {
        const our_ieee = try self.ezsp.getEui64();
        var label_buf: [64]u8 = undefined;
        const label = try self.deviceLabelBuf(&label_buf, ieee);
        try self.model.report(self.io, "hub: setting up {s} — if it's battery-powered, keep pressing its buttons / triggering it now", .{label});
        const eps = try self.zdoActiveEndpoints(ieee, SETUP_EMPTY_BUDGET) orelse return error.ZdoTimeout;
        if (eps.status != Zdo.STATUS_SUCCESS) return error.ZdoStatusError;

        var binds: usize = 0;
        var reports: usize = 0;
        for (eps.endpoints[0..eps.endpoint_count]) |ep| {
            const rsp = try self.zdoSimpleDescriptor(ieee, ep, SETUP_EMPTY_BUDGET) orelse continue;
            if (rsp.status != Zdo.STATUS_SUCCESS) continue;
            const d = rsp.descriptor;
            // Accept both profiles a real endpoint might register under —
            // see PROFILE_ZLL's doc comment (zcl.zig) for why an older
            // Hue bulb needs this too, not just current-generation ones.
            if (d.profile_id != Zcl.PROFILE_HA and d.profile_id != Zcl.PROFILE_ZLL) continue;

            // Free: we're already holding the descriptor `discover` would
            // have had to ask for (setup used to read this
            // and drop it, leaving a commissioned device unclassified).
            try self.recordDescriptorCapabilities(ieee, d);

            for (d.input_clusters[0..d.input_cluster_count]) |cluster| {
                const wants_reports = for (report_setups) |rs| {
                    if (rs.cluster == cluster) break true;
                } else false;
                const bind_only = std.mem.indexOfScalar(u16, &bind_only_inputs, cluster) != null;
                if (!wants_reports and !bind_only) continue;

                if (try self.bindCluster(ieee, ep, cluster, our_ieee)) {
                    binds += 1;
                    try self.model.report(self.io, "  bound 0x{X:0>4} ep{d}", .{ cluster, ep });
                }
                if (wants_reports) {
                    for (report_setups) |rs| {
                        if (rs.cluster != cluster) continue;
                        if (try self.configureReporting(ieee, ep, cluster, rs.cfg)) {
                            reports += 1;
                            try self.model.report(self.io, "  reporting configured 0x{X:0>4} attr 0x{X:0>4}", .{ cluster, rs.cfg.attr_id });
                        }
                    }
                }
            }
            for (d.output_clusters[0..d.output_cluster_count]) |cluster| {
                if (std.mem.indexOfScalar(u16, &bind_only_outputs, cluster) == null) continue;
                if (try self.bindCluster(ieee, ep, cluster, our_ieee)) {
                    binds += 1;
                    try self.model.report(self.io, "  bound 0x{X:0>4} ep{d} (controller output)", .{ cluster, ep });
                }
            }
        }
        try self.refineColorCapability(ieee);
        // An IAS Zone device needs enrollment, not just a bind, before it
        // reports. Bind + Configure Reporting — what setup does for
        // every other sensor — is not how IAS Zone status works. Runs here
        // (command context, device kept awake by the user) as the proactive
        // path alongside the async enroll-request handler.
        if ((try self.requireDevice(ieee)).ias_zone_endpoint != null) {
            try self.enrollIasZone(ieee);
        }
        (try self.requireDevice(ieee)).pending_setup = false;
        try self.model.report(self.io, "setup done: {d} binding(s), {d} reporting config(s)", .{ binds, reports });
    }

    /// Enrolls an IAS Zone sensor: writes our EUI64 into its `IAS_CIE_Address`
    /// so it knows where to send notifications, then grants enrollment with a
    /// Zone Enroll Response (the missing piece for a factory-fresh
    /// security sensor, which stays silent until this runs). Fire-and-forget
    /// at the ZCL level, like every event-triggered send — the proof it
    /// worked is the sensor starting to report, not a wire ack. Main-loop /
    /// command context only (it sends): reached from `setupDevice` and from
    /// `main.zig`'s `pending_enroll` drain, never from a poll callback.
    pub fn enrollIasZone(self: *Coordinator, ieee: [8]u8) !void {
        const dev = try self.requireDevice(ieee);
        const ep = dev.ias_zone_endpoint orelse {
            try self.model.report(self.io, "IAS enroll: no zone endpoint known — skipping", .{});
            return;
        };
        const nwk = try self.deviceNwk(ieee);
        const label = self.config.nameFor(ieee) orelse "device";
        const our_ieee = try self.ezsp.getEui64();

        // 1. Write IAS_CIE_Address = our EUI64.
        self.zcl_seq +%= 1;
        var wbuf: [14]u8 = undefined;
        const wframe = Zcl.buildWriteIasCieAddress(self.zcl_seq, our_ieee, &wbuf);
        const w = try self.ezsp.sendUnicast(nwk, .{
            .profile_id = Zcl.PROFILE_HA,
            .cluster_id = Zcl.CLUSTER_IAS_ZONE,
            .source_endpoint = 1,
            .destination_endpoint = ep,
        }, self.zcl_seq, wframe);
        if (w.status != Ezsp.STATUS_SUCCESS) {
            try self.model.report(self.io, "IAS enroll {s}: CIE-address write refused (status=0x{x:0>2})", .{ label, w.status });
            return;
        }

        // 2. Grant enrollment.
        self.zcl_seq +%= 1;
        var ebuf: [5]u8 = undefined;
        const eframe = Zcl.buildZoneEnrollResponse(self.zcl_seq, 0x00, 0x00, &ebuf); // Success, zoneId 0
        const e = try self.ezsp.sendUnicast(nwk, .{
            .profile_id = Zcl.PROFILE_HA,
            .cluster_id = Zcl.CLUSTER_IAS_ZONE,
            .source_endpoint = 1,
            .destination_endpoint = ep,
        }, self.zcl_seq, eframe);
        if (e.status != Ezsp.STATUS_SUCCESS) {
            try self.model.report(self.io, "IAS enroll {s}: enroll-response refused (status=0x{x:0>2})", .{ label, e.status });
            return;
        }
        try self.model.report(self.io, "IAS enrolled {s} (CIE address written, enrollment granted) — it should now report", .{label});
    }

    // ── Remove ────────────────────────────────────────────────────────

    /// ZDO Mgmt_Leave_req — cleanly un-joins a device instead of orphaning
    /// it. On success the device is dropped from the table + file. Reports
    /// via `model.report` throughout — see `discoverDevice`'s doc comment
    /// for why (reachable from watch mode's single-key `remove` action).
    pub fn removeDevice(self: *Coordinator, ieee: [8]u8) !void {
        const nwk = try self.deviceNwk(ieee);
        self.zdo_seq +%= 1;
        var req_buf: [10]u8 = undefined;
        const req = Zdo.buildMgmtLeaveReq(self.zdo_seq, ieee, &req_buf);
        const sent = try self.ezsp.sendUnicast(nwk, .{
            .profile_id = Zdo.PROFILE_ID,
            .cluster_id = Zdo.CLUSTER_MGMT_LEAVE_REQ,
            .source_endpoint = Zdo.ENDPOINT,
            .destination_endpoint = Zdo.ENDPOINT,
        }, self.zdo_seq, req);
        if (sent.status != Ezsp.STATUS_SUCCESS) {
            try self.model.report(self.io, "remove: NCP refused send (status=0x{x:0>2})", .{sent.status});
            return;
        }
        if (try self.awaitZdo(Zdo.CLUSTER_MGMT_LEAVE_RSP, self.zdo_seq, SETUP_EMPTY_BUDGET)) |msg| {
            const rsp = Zdo.parseBindRsp(msg.payload()) catch {
                try self.model.report(self.io, "remove: unparseable Mgmt_Leave_rsp", .{});
                return;
            };
            if (rsp.status != Zdo.STATUS_SUCCESS) {
                try self.model.report(self.io, "remove: ZDO status=0x{x:0>2}", .{rsp.status});
                return;
            }
        } else {
            try self.model.report(self.io, "remove: no Mgmt_Leave_rsp (sleepy target? it may still leave once it wakes) — keeping table entry", .{});
            return;
        }
        var polls: u8 = 0;
        while (polls < 6) : (polls += 1) {
            _ = try self.pollOnce();
        }
        var label_buf: [64]u8 = undefined;
        const label = try self.deviceLabelBuf(&label_buf, ieee);
        _ = try self.model.delete(self.io, ieee);
        self.model.save(self.io, Io.Dir.cwd());
        try self.model.report(self.io, "removed {s} from network and table — use `permit` when you want it back", .{label});
    }

    /// XY bit of the Color Control ColorCapabilities bitmap (ZCL
    /// 5.2.2.2.10, bit 3) — the one that says a device actually supports
    /// Move to Color (RGB). A white-ambiance bulb has the Color Control
    /// cluster but not this bit (it's 0x0010, colour-temp only), and
    /// answers Move to Color with UNSUP_CLUSTER_COMMAND.
    const COLORCAP_XY: u16 = 0x0008;

    /// Reads the Color Control ColorCapabilities attribute (0x400A) from
    /// `ep`. The cluster being *present* (what the descriptor walk sees)
    /// does NOT mean xy Move to Color is supported — this reads the bitmap
    /// so we know for real. Returns null if the device didn't answer
    /// (asleep, or no Color Control cluster). `ep` is passed in rather than
    /// re-derived via `controlEndpoint` on purpose: that would form an
    /// inferred-error-set cycle (controlEndpoint → discoverDevice →
    /// refineColorCapability → here). Engine-loop/command callers only.
    fn readColorCapabilities(self: *Coordinator, ieee: [8]u8, ep: u8) !?u16 {
        const nwk = try self.deviceNwk(ieee);
        self.zcl_seq +%= 1;
        const seq = self.zcl_seq;
        var buf: [5]u8 = undefined;
        const frame = Zcl.buildReadAttributes(seq, 0x400A, &buf);
        const sent = try self.ezsp.sendUnicast(nwk, .{
            .profile_id = Zcl.PROFILE_HA,
            .cluster_id = Zcl.CLUSTER_COLOR_CONTROL,
            .source_endpoint = 1,
            .destination_endpoint = ep,
        }, seq, frame);
        if (sent.status != Ezsp.STATUS_SUCCESS) return null;
        const msg = try self.awaitZcl(Zcl.CLUSTER_COLOR_CONTROL, seq, Zcl.CMD_READ_ATTRIBUTES_RSP, true) orelse return null;
        const fr = Zcl.parseFrame(msg.payload()) catch return null;
        var it = Zcl.ReadAttributeResponses{ .data = fr.payload };
        const rec = it.next() orelse return null;
        return @intCast(rec.intValue() orelse return null);
    }

    /// The `colorcaps <device>` console diagnostic — reports which colour
    /// commands a device actually supports.
    pub fn probeColorCapabilities(self: *Coordinator, ieee: [8]u8) !void {
        const ep = self.controlEndpoint(ieee) catch {
            try self.say("colorcaps: no control endpoint", .{});
            return;
        };
        const caps = (try self.readColorCapabilities(ieee, ep)) orelse {
            try self.say("colorcaps: no response (asleep, or no Color Control cluster)", .{});
            return;
        };
        try self.say("colorcaps: 0x{x:0>4} — hue/sat={s} xy={s} colour-temp={s} (xy is what RGB colour needs)", .{
            caps,
            if (caps & 0x01 != 0) "yes" else "no",
            if (caps & COLORCAP_XY != 0) "yes" else "no",
            if (caps & 0x10 != 0) "yes" else "no",
        });
    }

    // ── On/Off + Level control ───────────────────────────────────────

    /// The bulb/light control endpoint — ZDO-discovered (On/Off and Level
    /// Control live on the same endpoint on Hue lights). Runs discovery
    /// if we haven't found it yet.
    fn controlEndpoint(self: *Coordinator, ieee: [8]u8) !u8 {
        if ((try self.requireDevice(ieee)).onoff_endpoint == null) {
            try self.say("hub: discovering control endpoint first...", .{});
            try self.discoverDevice(ieee);
        }
        // Re-resolved: discoverDevice awaits (and is what set this field).
        return (try self.requireDevice(ieee)).onoff_endpoint orelse error.NoOnOffCluster;
    }

    fn confirmZclCommand(self: *Coordinator, cluster: u16) !void {
        var confirmed = false;
        var empty_polls: u8 = 0;
        var total_polls: u8 = 0;
        while (empty_polls < 4 and total_polls < 20 and !confirmed) : (total_polls += 1) {
            const cb = try self.pollOnce() orelse {
                empty_polls += 1;
                continue;
            };
            switch (cb) {
                .incoming_message => |msg| {
                    if (msg.aps.cluster_id == cluster) {
                        if (Zcl.parseDefaultResponse(msg.payload())) |rsp| {
                            if (rsp.zcl_seq == self.zcl_seq) {
                                try self.say("  confirmed (status=0x{x:0>2})", .{rsp.status});
                                confirmed = true;
                            }
                        }
                    }
                },
                else => {},
            }
        }
        if (!confirmed) {
            try self.say("  no confirmation (command may still have been applied)", .{});
        }
    }

    /// Sends On/Off/Toggle, optionally blocking for the target's Default
    /// Response. `confirm=true` is the interactive-command path (the user
    /// wants feedback); `executeAction` (the rules engine) calls this with
    /// `confirm=false` (fire-and-forget), because blocking there once choked
    /// the ASH transport under button-mashing.
    pub fn sendOnOff(self: *Coordinator, ieee: [8]u8, command_id: u8, name: []const u8, confirm: bool) !void {
        const dest_ep = try self.controlEndpoint(ieee);
        // After controlEndpoint, which may have run a full discovery.
        const nwk = try self.deviceNwk(ieee);
        self.zcl_seq +%= 1;
        var frame_buf: [3]u8 = undefined;
        const frame = Zcl.buildClusterCommand(self.zcl_seq, command_id, &frame_buf);
        const sent = try self.ezsp.sendUnicast(nwk, .{
            .profile_id = Zcl.PROFILE_HA,
            .cluster_id = Zcl.CLUSTER_ON_OFF,
            .source_endpoint = 1,
            .destination_endpoint = dest_ep,
        }, self.zcl_seq, frame);
        if (sent.status != Ezsp.STATUS_SUCCESS) {
            // `confirm` also tells us which caller this is, and the two
            // want different sinks: true is a typed command's response, so
            // `say` (console prints it now; watch mode logs it — see say's
            // doc comment); false is `executeAction`'s async rules-drain
            // path, which must always go to `model.report` so it stays
            // ordered with the rest of the event stream in both modes.
            if (confirm) {
                try self.say("'{s}': NCP refused send (status=0x{x:0>2})", .{ name, sent.status });
            } else {
                try self.model.report(self.io, "'{s}': NCP refused send (status=0x{x:0>2})", .{ name, sent.status });
            }
            return;
        }
        if (!confirm) {
            try self.model.report(self.io, "'{s}' sent", .{name});
            return;
        }
        try self.say("'{s}' sent...", .{name});
        try self.confirmZclCommand(Zcl.CLUSTER_ON_OFF);
    }

    /// The console's `identify <target> [secs]`: the device shows itself (a light
    /// flashes) for `seconds`, 0 stops it. Unicast with a confirmed Default Response.
    pub fn sendIdentify(self: *Coordinator, ieee: [8]u8, seconds: u16, name: []const u8) !void {
        const dest_ep = try self.controlEndpoint(ieee);
        const nwk = try self.deviceNwk(ieee);
        self.zcl_seq +%= 1;
        var frame_buf: [5]u8 = undefined;
        const frame = Zcl.buildIdentify(self.zcl_seq, seconds, &frame_buf);
        const sent = try self.ezsp.sendUnicast(nwk, .{
            .profile_id = Zcl.PROFILE_HA,
            .cluster_id = Zcl.CLUSTER_IDENTIFY,
            .source_endpoint = 1,
            .destination_endpoint = dest_ep,
        }, self.zcl_seq, frame);
        if (sent.status != Ezsp.STATUS_SUCCESS) {
            try self.say("'{s}': NCP refused send (status=0x{x:0>2})", .{ name, sent.status });
            return;
        }
        try self.say("'{s}' identifying for {d} s...", .{ name, seconds });
        try self.confirmZclCommand(Zcl.CLUSTER_IDENTIFY);
    }

    // Level Control tuning. Step = one tap; Move ramps at MOVE_RATE
    // units/sec while a dim button is held (full 0-254 range in ~5s),
    // until Stop.
    const LEVEL_STEP_SIZE: u8 = 25; // ~10% of the 0-254 range per tap
    const LEVEL_TRANSITION_TENTHS: u16 = 3; // 0.3s — smooth but responsive
    const LEVEL_MOVE_RATE: u8 = 50; // units/second while held

    /// Sends a pre-built Level Control frame fire-and-forget (only rule
    /// actions drive Level, never a blocking console command — so no
    /// confirm path). The Default Response flows back and prints as an
    /// `[event]`. `desc` labels the console line.
    fn sendLevelFrame(self: *Coordinator, ieee: [8]u8, frame: []const u8, name: []const u8, desc: []const u8) !void {
        const dest_ep = try self.controlEndpoint(ieee);
        const nwk = try self.deviceNwk(ieee);
        const sent = try self.ezsp.sendUnicast(nwk, .{
            .profile_id = Zcl.PROFILE_HA,
            .cluster_id = Zcl.CLUSTER_LEVEL_CONTROL,
            .source_endpoint = 1,
            .destination_endpoint = dest_ep,
        }, self.zcl_seq, frame);
        // Always the async rules path (see this fn's doc comment) — same
        // model.report reasoning as sendOnOff's confirm=false branch.
        if (sent.status != Ezsp.STATUS_SUCCESS) {
            try self.model.report(self.io, "'{s}' level {s}: NCP refused send (status=0x{x:0>2})", .{ name, desc, sent.status });
            return;
        }
        try self.model.report(self.io, "'{s}' level {s} sent", .{ name, desc });
    }

    fn sendLevelStep(self: *Coordinator, ieee: [8]u8, up: bool, name: []const u8) !void {
        self.zcl_seq +%= 1;
        var buf: [7]u8 = undefined;
        const frame = Zcl.buildLevelStep(self.zcl_seq, up, LEVEL_STEP_SIZE, LEVEL_TRANSITION_TENTHS, &buf);
        try self.sendLevelFrame(ieee, frame, name, if (up) "step up" else "step down");
    }

    fn sendLevelMove(self: *Coordinator, ieee: [8]u8, up: bool, name: []const u8) !void {
        self.zcl_seq +%= 1;
        var buf: [5]u8 = undefined;
        const frame = Zcl.buildLevelMove(self.zcl_seq, up, LEVEL_MOVE_RATE, &buf);
        try self.sendLevelFrame(ieee, frame, name, if (up) "move up (ramp)" else "move down (ramp)");
    }

    fn sendLevelStop(self: *Coordinator, ieee: [8]u8, name: []const u8) !void {
        self.zcl_seq +%= 1;
        var buf: [3]u8 = undefined;
        const frame = Zcl.buildClusterCommand(self.zcl_seq, Zcl.LEVEL_CMD_STOP_WITH_ONOFF, &buf);
        try self.sendLevelFrame(ieee, frame, name, "stop");
    }

    /// How long a `brightness` command's transition takes. Matches the feel
    /// of Hue's own default (~400ms) — a smooth settle, not an instant jump,
    /// and short enough to read as immediate.
    const MOVE_TO_LEVEL_TRANSITION_TENTHS: u16 = 4;

    /// The console's `brightness <n> <target>` for a single device: absolute
    /// level (0-254, already converted from percent at the console boundary),
    /// Move to Level with On/Off. Unlike the gesture-phased Level sends above,
    /// this IS a typed command, so it confirms via Default Response like
    /// `sendOnOff` does (and uses `say`, not `model.report`, for the same
    /// reason as sendOnOff's confirm=true branch).
    pub fn sendLevelMoveToLevel(self: *Coordinator, ieee: [8]u8, level: u8, name: []const u8) !void {
        const dest_ep = try self.controlEndpoint(ieee);
        const nwk = try self.deviceNwk(ieee);
        self.zcl_seq +%= 1;
        var buf: [6]u8 = undefined;
        const frame = Zcl.buildMoveToLevel(self.zcl_seq, level, MOVE_TO_LEVEL_TRANSITION_TENTHS, &buf);
        const sent = try self.ezsp.sendUnicast(nwk, .{
            .profile_id = Zcl.PROFILE_HA,
            .cluster_id = Zcl.CLUSTER_LEVEL_CONTROL,
            .source_endpoint = 1,
            .destination_endpoint = dest_ep,
        }, self.zcl_seq, frame);
        if (sent.status != Ezsp.STATUS_SUCCESS) {
            try self.say("'{s}': NCP refused send (status=0x{x:0>2})", .{ name, sent.status });
            return;
        }
        try self.say("'{s}' sent...", .{name});
        try self.confirmZclCommand(Zcl.CLUSTER_LEVEL_CONTROL);
    }

    /// `brightness` for a group — fire-and-forget multicast, same as every
    /// other group send (group-addressed frames get no per-member Default
    /// Response worth waiting on).
    pub fn sendGroupLevelMoveToLevel(self: *Coordinator, group_id: u16, level: u8, name: []const u8) !void {
        self.zcl_seq +%= 1;
        var buf: [6]u8 = undefined;
        const frame = Zcl.buildMoveToLevel(self.zcl_seq, level, MOVE_TO_LEVEL_TRANSITION_TENTHS, &buf);
        try self.sendGroupFrame(group_id, Zcl.CLUSTER_LEVEL_CONTROL, frame, name, "brightness");
    }

    /// The `colour <#RRGGBB> <target>` console command — device or group,
    /// mirroring how `brightness` dispatches. A device without a
    /// (confirmed, xy-capable) colour cluster is reported, not silently
    /// skipped, since here the user asked for it explicitly (unlike a rule
    /// colour, which is meant to be ignored on a non-colour target).
    pub fn setColour(self: *Coordinator, target: []const u8, xy: ConfigMod.ColourXy) !void {
        if (self.config.groupIdFor(target)) |group_id| {
            try self.sendGroupColor(group_id, xy, target);
            return;
        }
        const ieee = try self.resolveTarget(target) orelse {
            try self.say("unknown device or group '{s}'", .{target});
            return;
        };
        const dev = try self.requireDevice(ieee);
        if (dev.color_endpoint == null) {
            try self.say("'{s}' isn't an RGB colour bulb (no xy Color Control) — try `colorcaps {s}`", .{ target, target });
            return;
        }
        const ep = dev.color_endpoint.?;
        const nwk = try self.deviceNwk(ieee);
        self.zcl_seq +%= 1;
        var buf: [9]u8 = undefined;
        const frame = Zcl.buildMoveToColor(self.zcl_seq, xy.x, xy.y, MOVE_TO_LEVEL_TRANSITION_TENTHS, &buf);
        const sent = try self.ezsp.sendUnicast(nwk, .{
            .profile_id = Zcl.PROFILE_HA,
            .cluster_id = Zcl.CLUSTER_COLOR_CONTROL,
            .source_endpoint = 1,
            .destination_endpoint = ep,
        }, self.zcl_seq, frame);
        if (sent.status != Ezsp.STATUS_SUCCESS) {
            try self.say("'{s}' colour: NCP refused send (status=0x{x:0>2})", .{ target, sent.status });
            return;
        }
        try self.say("'{s}' colour sent...", .{target});
        try self.confirmZclCommand(Zcl.CLUSTER_COLOR_CONTROL);
    }

    /// A rule's colour: Move to Color, fire-and-forget
    /// (a rule action is always the async path). **Skipped silently for a
    /// device with no discovered Color Control cluster** — that's the
    /// "ignore the colour for a target that has no colour setting"
    /// requirement, done by capability rather than by hoping the bulb
    /// ignores it. A device that hasn't been discovered yet (no
    /// `color_endpoint` either way) is also skipped — no capability, no
    /// send.
    fn sendColor(self: *Coordinator, ieee: [8]u8, xy: ConfigMod.ColourXy, name: []const u8) !void {
        const dev = self.requireDevice(ieee) catch return;
        const ep = dev.color_endpoint orelse return; // no colour capability → ignore, as specified
        const nwk = try self.deviceNwk(ieee);
        self.zcl_seq +%= 1;
        var buf: [9]u8 = undefined;
        const frame = Zcl.buildMoveToColor(self.zcl_seq, xy.x, xy.y, MOVE_TO_LEVEL_TRANSITION_TENTHS, &buf);
        const sent = try self.ezsp.sendUnicast(nwk, .{
            .profile_id = Zcl.PROFILE_HA,
            .cluster_id = Zcl.CLUSTER_COLOR_CONTROL,
            .source_endpoint = 1,
            .destination_endpoint = ep,
        }, self.zcl_seq, frame);
        if (sent.status != Ezsp.STATUS_SUCCESS) {
            try self.model.report(self.io, "'{s}' colour: NCP refused send (status=0x{x:0>2})", .{ name, sent.status });
            return;
        }
        try self.model.report(self.io, "'{s}' colour sent", .{name});
    }

    /// A group's colour — fire-and-forget multicast. Unlike the unicast
    /// path there's no per-member capability check: a member without a
    /// Color Control cluster ignores a cluster-specific frame for a cluster
    /// it doesn't implement (ZCL's own rule), so the multicast is safe to
    /// send to a mixed group.
    fn sendGroupColor(self: *Coordinator, group_id: u16, xy: ConfigMod.ColourXy, name: []const u8) !void {
        self.zcl_seq +%= 1;
        var buf: [9]u8 = undefined;
        const frame = Zcl.buildMoveToColor(self.zcl_seq, xy.x, xy.y, MOVE_TO_LEVEL_TRANSITION_TENTHS, &buf);
        try self.sendGroupFrame(group_id, Zcl.CLUSTER_COLOR_CONTROL, frame, name, "colour");
    }

    // ── Groups ───────────────────────────────────────────────────────

    /// Sends ZCL Add Group to one device (unicast — membership has to be
    /// established per-device before a group-addressed send means
    /// anything to it) and awaits its Add Group Response. The binding
    /// this creates lives on the device and persists there, same as ZDO
    /// bindings — safe to call again (idempotent) if unsure a device
    /// already joined.
    pub fn joinGroup(self: *Coordinator, ieee: [8]u8, group_id: u16) !bool {
        const dest_ep = try self.controlEndpoint(ieee);
        const nwk = try self.deviceNwk(ieee);
        self.zcl_seq +%= 1;
        var frame_buf: [6]u8 = undefined;
        const frame = Zcl.buildAddGroup(self.zcl_seq, group_id, &frame_buf);
        const sent = try self.ezsp.sendUnicast(nwk, .{
            .profile_id = Zcl.PROFILE_HA,
            .cluster_id = Zcl.CLUSTER_GROUPS,
            .source_endpoint = 1,
            .destination_endpoint = dest_ep,
        }, self.zcl_seq, frame);
        if (sent.status != Ezsp.STATUS_SUCCESS) {
            try self.say("  add-group 0x{X:0>4}: NCP refused send (status=0x{x:0>2})", .{ group_id, sent.status });
            return false;
        }
        if (try self.awaitZcl(Zcl.CLUSTER_GROUPS, self.zcl_seq, Zcl.GROUPS_CMD_ADD_GROUP_RESPONSE, false)) |msg| {
            const frame_hdr = Zcl.parseFrame(msg.payload()) catch return false;
            const rsp = Zcl.parseAddGroupResponse(frame_hdr.payload) orelse return false;
            // DUPLICATE_EXISTS = the device is already a member (a re-add,
            // which startup auto-setup does every boot). That's the
            // idempotent success case, not a failure — count it as joined
            // and don't cry wolf.
            if (rsp.status == Zcl.STATUS_SUCCESS or rsp.status == Zcl.STATUS_DUPLICATE_EXISTS) return true;
            try self.say("  add-group 0x{X:0>4}: ZCL status=0x{x:0>2}", .{ group_id, rsp.status });
            return false;
        }
        try self.say("  add-group 0x{X:0>4}: no response (target asleep?)", .{group_id});
        return false;
    }

    pub const SceneOp = enum { add, store, recall, view };

    /// One Scenes command to one light, in group 0, and its answer reported.
    /// `values` is for `add` only. Recall answers with a Default Response; the rest
    /// with a response of their own.
    pub fn sceneCommand(self: *Coordinator, ieee: [8]u8, name: []const u8, op: SceneOp, scene_id: u8, values: Zcl.SceneValues) !void {
        const dest_ep = try self.controlEndpoint(ieee);
        const nwk = try self.deviceNwk(ieee);
        self.zcl_seq +%= 1;
        var add_buf: [17]u8 = undefined;
        var ref_buf: [6]u8 = undefined;
        const frame = switch (op) {
            .add => Zcl.buildAddScene(self.zcl_seq, 0, scene_id, 0, values, &add_buf),
            .store => Zcl.buildSceneRef(self.zcl_seq, Zcl.SCENES_CMD_STORE, 0, scene_id, &ref_buf),
            .recall => Zcl.buildSceneRef(self.zcl_seq, Zcl.SCENES_CMD_RECALL, 0, scene_id, &ref_buf),
            .view => Zcl.buildSceneRef(self.zcl_seq, Zcl.SCENES_CMD_VIEW, 0, scene_id, &ref_buf),
        };
        const sent = try self.ezsp.sendUnicast(nwk, .{
            .profile_id = Zcl.PROFILE_HA,
            .cluster_id = Zcl.CLUSTER_SCENES,
            .source_endpoint = 1,
            .destination_endpoint = dest_ep,
        }, self.zcl_seq, frame);
        if (sent.status != Ezsp.STATUS_SUCCESS) {
            try self.say("'{s}' scene {t}: NCP refused send (status=0x{x:0>2})", .{ name, op, sent.status });
            return;
        }
        if (op == .recall) {
            try self.say("'{s}' scene {d} recall sent...", .{ name, scene_id });
            return self.confirmZclCommand(Zcl.CLUSTER_SCENES);
        }
        const response: u8 = switch (op) {
            .add => Zcl.SCENES_CMD_ADD,
            .store => Zcl.SCENES_CMD_STORE,
            .view => Zcl.SCENES_CMD_VIEW,
            .recall => unreachable,
        };
        const msg = try self.awaitZcl(Zcl.CLUSTER_SCENES, self.zcl_seq, response, false) orelse {
            try self.say("'{s}' scene {d} {t}: no response", .{ name, scene_id, op });
            return;
        };
        const header = Zcl.parseFrame(msg.payload()) catch return;
        if (op != .view) {
            const rsp = Zcl.parseSceneStatus(header.payload) orelse return;
            try self.say("'{s}' scene {d} {t}: status=0x{x:0>2}{s}", .{ name, scene_id, op, rsp.status, if (rsp.status == Zcl.STATUS_SUCCESS) " (success)" else "" });
            return;
        }
        const viewed = Zcl.parseViewSceneResponse(header.payload) orelse {
            try self.say("'{s}' scene {d} view: a reply that doesn't parse", .{ name, scene_id });
            return;
        };
        if (viewed.status.status != Zcl.STATUS_SUCCESS) {
            try self.say("'{s}' scene {d} view: status=0x{x:0>2}", .{ name, scene_id, viewed.status.status });
            return;
        }
        var level_buf: [8]u8 = undefined;
        const on_text = if (viewed.values.on) |on| (if (on) "on" else "off") else "not stored";
        const level_text = if (viewed.values.level) |level| try std.fmt.bufPrint(&level_buf, "{d}", .{level}) else "not stored";
        try self.say("'{s}' scene {d}: {s}, level {s}, transition {d} s", .{ name, scene_id, on_text, level_text, viewed.transition_s });
    }

    /// Adds every configured member of `group` to Zigbee group
    /// `group.group_id`, resolving each member name via `resolveTarget`
    /// (self-healing, same as `setup`/`discover`/on-off-toggle). Reports
    /// progress per member; safe to re-run (e.g. after adding a member to
    /// `groups.json`) since `joinGroup` is idempotent.
    pub fn setupGroup(self: *Coordinator, group: ConfigMod.GroupEntry) !void {
        try self.say("hub: setting up group '{s}' (0x{X:0>4}), {d} member(s)", .{ group.name, group.group_id, group.members.len });
        var joined: usize = 0;
        for (group.members) |member_name| {
            const ieee = try self.resolveTarget(member_name) orelse {
                try self.say("  {s}: unknown device — see `list`", .{member_name});
                continue;
            };
            if (try self.joinGroup(ieee, group.group_id)) {
                joined += 1;
                try self.say("  {s}: joined group 0x{X:0>4}", .{ member_name, group.group_id });
            }
        }
        try self.say("group '{s}' setup done: {d}/{d} member(s) joined", .{ group.name, joined, group.members.len });
    }

    /// Sends a pre-built ZCL frame to every member of `group_id` at once
    /// via EZSP `sendMulticast` (see its doc comment for the byte-layout
    /// confidence caveat) — the destination endpoint is the ZCL group-
    /// addressing wildcard (0xFF): the NWK/APS layer routes by each
    /// receiving node's group membership, not a specific endpoint.
    /// Always fire-and-forget (see `sendLevelFrame`'s reasoning — there's
    /// no single Default Response to await from a multicast anyway, since
    /// every member may answer independently); reports through
    /// `model.report` since this is only ever reached from the async
    /// rules-drain path (`executeAction`), never a synchronous console
    /// command — see `sendOnOff`'s routing-fix comment for why that split
    /// matters (watch mode has the terminal in raw/cursor-addressed mode).
    fn sendGroupFrame(self: *Coordinator, group_id: u16, cluster: u16, frame: []const u8, name: []const u8, desc: []const u8) !void {
        const aps: Ezsp.ApsFrame = .{
            .profile_id = Zcl.PROFILE_HA,
            .cluster_id = cluster,
            .source_endpoint = 1,
            .destination_endpoint = 0xFF,
            .group_id = group_id,
        };
        const sent = try self.ezsp.sendMulticast(aps, 0, 0, self.zcl_seq, frame);
        if (sent.status != Ezsp.STATUS_SUCCESS) {
            try self.model.report(self.io, "'{s}' group {s}: NCP refused send (status=0x{x:0>2})", .{ name, desc, sent.status });
            return;
        }
        try self.model.report(self.io, "'{s}' group {s} sent", .{ name, desc });
    }

    pub fn sendGroupOnOff(self: *Coordinator, group_id: u16, command_id: u8, name: []const u8) !void {
        self.zcl_seq +%= 1;
        var buf: [3]u8 = undefined;
        const frame = Zcl.buildClusterCommand(self.zcl_seq, command_id, &buf);
        const desc: []const u8 = switch (command_id) {
            Zcl.ONOFF_CMD_ON => "on",
            Zcl.ONOFF_CMD_OFF => "off",
            else => "toggle",
        };
        try self.sendGroupFrame(group_id, Zcl.CLUSTER_ON_OFF, frame, name, desc);
    }

    fn sendGroupLevelStep(self: *Coordinator, group_id: u16, up: bool, name: []const u8) !void {
        self.zcl_seq +%= 1;
        var buf: [7]u8 = undefined;
        const frame = Zcl.buildLevelStep(self.zcl_seq, up, LEVEL_STEP_SIZE, LEVEL_TRANSITION_TENTHS, &buf);
        try self.sendGroupFrame(group_id, Zcl.CLUSTER_LEVEL_CONTROL, frame, name, if (up) "step up" else "step down");
    }

    fn sendGroupLevelMove(self: *Coordinator, group_id: u16, up: bool, name: []const u8) !void {
        self.zcl_seq +%= 1;
        var buf: [5]u8 = undefined;
        const frame = Zcl.buildLevelMove(self.zcl_seq, up, LEVEL_MOVE_RATE, &buf);
        try self.sendGroupFrame(group_id, Zcl.CLUSTER_LEVEL_CONTROL, frame, name, if (up) "move up (ramp)" else "move down (ramp)");
    }

    fn sendGroupLevelStop(self: *Coordinator, group_id: u16, name: []const u8) !void {
        self.zcl_seq +%= 1;
        var buf: [3]u8 = undefined;
        const frame = Zcl.buildClusterCommand(self.zcl_seq, Zcl.LEVEL_CMD_STOP_WITH_ONOFF, &buf);
        try self.sendGroupFrame(group_id, Zcl.CLUSTER_LEVEL_CONTROL, frame, name, "stop");
    }

    // ── Attribute polling (state for devices that won't report) ─────

    /// How stale a light's On/Off state may get before hub asks for it.
    ///
    /// The fallback the first On/Off work deferred, made concrete by a real
    /// device: `bulb2` answers Configure Reporting with `UNSUP_GENERAL_COMMAND`
    /// — an older bulb that simply cannot report — so its state showed as
    /// "unknown" on the web page forever while being perfectly controllable.
    /// Reporting-capable lights are unaffected in practice: they report on
    /// change (min_interval=0), which keeps them fresh and skips the poll.
    ///
    /// Also fixes "state unknown after a restart" for every light: reports
    /// are session state, so a fresh hub knows nothing until something
    /// changes. Now it asks.
    pub const STATE_POLL_STALE_MS: i64 = 30_000;
    /// One device per tick at most, so a fleet of lights spreads its polls
    /// across ticks instead of bursting — the same discipline that keeps the
    /// rules engine from flooding the radio.
    const STATE_POLL_INTERVAL_MS: i64 = 3_000;

    /// Asks ONE stale light for its On/Off state, if any is due.
    ///
    /// **Fire-and-forget, never an await loop** — the standing design rule
    /// recorded earlier: the response comes back through `pollOnce` and is
    /// decoded by `printZclEvent` like any other attribute report. This
    /// function sends and returns; it does not wait for anything.
    ///
    /// Engine-loop callers only (it touches the radio).
    pub fn pollStaleState(self: *Coordinator) !void {
        const now = self.nowMs();
        if (now - self.last_state_poll_ms < STATE_POLL_INTERVAL_MS) return;

        // Round-robin from where we left off, so one unreachable device
        // can't monopolise the poll and starve the rest.
        const n = self.model.devices.items.len;
        if (n == 0) return;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const idx = (self.state_poll_cursor + i) % n;
            const dev = self.model.devices.items[idx];
            const ep = dev.onoff_endpoint orelse continue;
            if (!dev.joined) continue;
            if (now - dev.state_polled_ms < STATE_POLL_STALE_MS) continue;
            if (dev.on != null and now - dev.last_seen_ms < STATE_POLL_STALE_MS) continue;

            self.state_poll_cursor = (idx + 1) % n;
            self.last_state_poll_ms = now;
            self.model.devices.items[idx].state_polled_ms = now;

            self.zcl_seq +%= 1;
            var buf: [5]u8 = undefined;
            const frame = Zcl.buildReadAttributes(self.zcl_seq, 0x0000, &buf);
            const sent = self.ezsp.sendUnicast(dev.nwk, .{
                .profile_id = Zcl.PROFILE_HA,
                .cluster_id = Zcl.CLUSTER_ON_OFF,
                .source_endpoint = 1,
                .destination_endpoint = ep,
            }, self.zcl_seq, frame) catch return; // benign: it's a poll, try again later
            _ = sent;
            return; // one per tick
        }
    }

    /// Tells the house log about any light that has stopped answering, because
    /// otherwise an unplugged light goes on looking like its last state forever.
    pub fn noteLostLights(self: *Coordinator) !void {
        const house = self.house orelse return;
        const now = self.nowMs();
        for (self.model.devices.items) |*dev| {
            if (!HouseLog.lightLooksLost(dev, now)) continue;
            dev.reported_lost = true;
            house.link(dev.ieee, .disconnected);
            var buf: [64]u8 = undefined;
            const label = try self.deviceLabelBuf(&buf, dev.ieee);
            try self.model.report(self.io, "[link] {s} has stopped answering", .{label});
        }
    }

    /// Asks ONE device for one setting, if any is due. Fire-and-forget, like
    /// `pollStaleState`: the answer arrives through `pollOnce` and `noteSetting`
    /// takes it. Engine-loop callers only (it touches the radio).
    pub fn pollSettings(self: *Coordinator) !void {
        const now = self.nowMs();
        if (now - self.last_settings_poll_ms < STATE_POLL_INTERVAL_MS) return;
        const n = self.model.devices.items.len;
        if (n == 0) return;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const idx = (self.settings_poll_cursor + i) % n;
            const dev = &self.model.devices.items[idx];
            const q = HouseLog.settingsQuery(dev, now) orelse continue;

            self.settings_poll_cursor = (idx + 1) % n;
            self.last_settings_poll_ms = now;
            dev.settings_polled_ms = now;
            dev.settings_next = (q.index + 1) % q.count;
            if (dev.settings_next == 0) dev.settings_rounds +|= 1;

            self.zcl_seq +%= 1;
            var buf: [5]u8 = undefined;
            const frame = Zcl.buildReadAttributes(self.zcl_seq, q.attr, &buf);
            const sent = self.ezsp.sendUnicast(dev.nwk, .{
                .profile_id = Zcl.PROFILE_HA,
                .cluster_id = q.cluster,
                .source_endpoint = 1,
                .destination_endpoint = q.endpoint,
            }, self.zcl_seq, frame) catch return; // benign: it's a poll, try again later
            _ = sent;
            return; // one per tick
        }
    }

    // ── Rules engine ─────────────────────────────────────────────────

    /// A humidity reading through its sensor's shower detector, firing `humid`
    /// when a shower starts.
    fn humidityReading(self: *Coordinator, ieee: [8]u8, who: []const u8, centi: u16) !void {
        const d = self.humidityFor(ieee) orelse return;
        const low = d.windowLow(self.nowMs());
        if (!d.reading(centi, self.nowMs())) return;
        try self.model.report(self.io, "[humidity] {s}: a shower, {d}.{d:0>2}% to {d}.{d:0>2}% within {d} min", .{ who, low.? / 100, low.? % 100, centi / 100, centi % 100, @divTrunc(HumidityRun.WINDOW_MS, 60_000) });
        try self.fireEvent(who, "humid", .tick);
    }

    /// Ends each run that has stopped rising for long enough. Called from the
    /// main loop, as no reading need come to end it.
    pub fn tickHumidity(self: *Coordinator) !void {
        const now = self.nowMs();
        for (self.humidity_ieee, &self.humidity) |key, *d| {
            const ieee = key orelse continue;
            if (!d.tick(now)) continue;
            const who = self.config.nameFor(ieee) orelse "?";
            try self.model.report(self.io, "[humidity] {s}: no rise for {d} min, the run is over", .{ who, @divTrunc(HumidityRun.RUN_AFTER_RISE_MS, 60_000) });
            try self.fireEvent(who, "dry", .tick);
        }
    }

    fn humidityFor(self: *Coordinator, ieee: [8]u8) ?*HumidityRun.Detector {
        for (&self.humidity_ieee, &self.humidity) |*key, *d| {
            if (key.*) |k| {
                if (std.mem.eql(u8, &k, &ieee)) return d;
            } else {
                key.* = ieee;
                return d;
            }
        }
        return null;
    }

    fn nowMs(self: *Coordinator) i64 {
        return Io.Timestamp.now(self.io, .awake).toMilliseconds();
    }

    /// `group_debounce_ids`/`_ms` form a small fixed lookup table keyed by
    /// group_id (0 = empty slot — a real Zigbee group_id is never 0x0000,
    /// same reservation as nwk 0x0000 meaning "the coordinator").
    fn groupDebounceMs(self: *Coordinator, group_id: u16) i64 {
        for (self.group_debounce_ids, 0..) |gid, i| {
            if (gid == group_id) return self.group_debounce_ms[i];
        }
        return 0; // never debounced before -> "a long time ago"
    }

    fn setGroupDebounceMs(self: *Coordinator, group_id: u16, ms: i64) void {
        for (self.group_debounce_ids, 0..) |gid, i| {
            if (gid == group_id) {
                self.group_debounce_ms[i] = ms;
                return;
            }
        }
        for (self.group_debounce_ids, 0..) |gid, i| {
            if (gid == 0) {
                self.group_debounce_ids[i] = group_id;
                self.group_debounce_ms[i] = ms;
                return;
            }
        }
        // Table full (more distinct groups firing than MAX_GROUP_DEBOUNCE
        // — an unlikely fleet size): overwrite slot 0 rather than drop the
        // update silently. Debounce is a rate-limit, not correctness-
        // critical, so losing one slot's history here is a fine tradeoff.
        self.group_debounce_ids[0] = group_id;
        self.group_debounce_ms[0] = ms;
    }

    /// Appends one action to `pending_actions` for the caller's main loop
    /// to drain (never sent from here directly — see `PendingAction`'s
    /// doc comment for why). Returns `false` if the queue is full (an
    /// unlikely, silently-dropped case) so callers can decide whether
    /// that's worth a log line. Shared by `fireEvent` (a physical
    /// event matched a rule) and `sched.zig`'s scheduled-time firing
    /// (`main.zig` calls this directly) — a schedule is just a rule
    /// whose trigger is wall-clock time instead of a button/sensor.
    pub fn enqueueAction(self: *Coordinator, target: ConfigMod.Target, action: ConfigMod.Action, phase: Phase) bool {
        return self.enqueueActionColour(target, action, phase, null);
    }

    /// As `enqueueAction`, but carrying an optional colour to apply with an
    /// `on`. Only the rules path (`fireEvent`) has a
    /// colour to pass; schedule/web use the plain `enqueueAction`.
    pub fn enqueueActionColour(self: *Coordinator, target: ConfigMod.Target, action: ConfigMod.Action, phase: Phase, colour: ?ConfigMod.ColourXy) bool {
        if (self.pending_count >= self.pending_actions.len) return false;
        self.pending_actions[self.pending_count] = .{ .target = target, .action = action, .phase = phase, .colour = colour };
        self.pending_count += 1;
        return true;
    }

    /// Every rule matching (controller, event) queues its action, tagged
    /// with the gesture `phase`. Prints a `[rule]` line per match; the
    /// caller's main loop actually sends (see `pending_actions`), keeping
    /// this out of a nested `pollOnce`. One event may match several rules
    /// (several targets) — all are queued. No-op when the controller is
    /// unknown ("?") or has no matching rule. `rule.target` resolves to
    /// either a device or a group (`Config.resolveTargetName`) — once
    /// resolved, both flow through the exact same phase-filtering,
    /// debounce, and queueing logic below, matching the "same
    /// control semantics as a single bulb" requirement.
    pub fn fireEvent(self: *Coordinator, controller_name: []const u8, event: []const u8, phase: Phase) !void {
        if (std.mem.eql(u8, controller_name, "?")) return;
        for (self.config.rules) |rule| {
            if (!std.mem.eql(u8, rule.controller, controller_name)) continue;
            if (!std.mem.eql(u8, rule.event, event)) continue;
            const action = ConfigMod.parseAction(rule.action) orelse continue; // validated at load

            // Phase relevance per action:
            //  on/off/toggle — act once, on the initial press/tick;
            //    hold/release are meaningless.
            //  level — press starts a Move, release Stops it, tick
            //    (dial/motion) is a discrete Step; hold is a no-op (the
            //    Move already ramps continuously) so drop it here — no
            //    queue, no console line.
            switch (action) {
                .on, .off, .toggle => if (phase != .press and phase != .tick) continue,
                .level_up, .level_down => if (phase == .hold) continue,
            }

            const target = self.config.resolveTargetName(rule.target) orelse continue; // validated at load

            // Device targets must actually be in the live table (never
            // joined/announced this session) or there's nothing to send
            // to; groups have no such join-state — a group with an
            // unreachable member is harmless to send to (that member just
            // doesn't answer), so no "not in table" check applies to them.
            if (target == .bridge and action != .on and action != .off) continue; // refused at load
            if (target == .device and self.model.findByIeee(target.device) == null) {
                try self.model.report(self.io, "[rule] {s} {s} → {s} {s}: target not in table (join/power-cycle it)", .{ controller_name, event, rule.target, rule.action });
                continue;
            }

            // Debounce only the "start" phases (press/tick) — a flood of
            // those (mash, dial spin) collapses to ACTION_DEBOUNCE_MS. A
            // dropped press just means that tap starts no Move; the
            // matching release still Stops (a harmless no-op). Stop
            // (release) MUST NOT be debounced — dropping it would leave a
            // real ramp running to the bulb's limit.
            if (phase == .press or phase == .tick) {
                const now = self.nowMs();
                const last = switch (target) {
                    .device => |ieee| self.model.findByIeee(ieee).?.last_action_ms, // just checked above
                    .group => |gid| self.groupDebounceMs(gid),
                    // The Bridge's sender keeps only the latest wish per light.
                    .bridge => 0,
                };
                if (now - last < ACTION_DEBOUNCE_MS) continue;
                switch (target) {
                    .device => |ieee| self.model.findByIeee(ieee).?.last_action_ms = now,
                    .group => |gid| self.setGroupDebounceMs(gid, now),
                    .bridge => {},
                }
            }

            // A rule's colour rides with the `on` (validated at load; a
            // malformed value already warned and parses to null here, so a
            // bad colour just means "no colour", never a failed rule).
            const colour: ?ConfigMod.ColourXy = if (action == .on)
                (if (rule.colour) |c| ConfigMod.parseColourXy(c) else null)
            else
                null;
            if (!self.enqueueActionColour(target, action, phase, colour)) continue; // queue full (unlikely) — drop
            const gesture: []const u8 = switch (action) {
                .level_up, .level_down => switch (phase) {
                    .press => " (ramp)",
                    .tick => " (step)",
                    .release => " (stop)",
                    .hold => "", // filtered above
                },
                else => "",
            };
            try self.model.report(self.io, "[rule] {s} {s} → {s} {s}{s}", .{ controller_name, event, rule.target, rule.action, gesture });
        }
    }

    /// Executes one queued automation action against its target (drained
    /// by the caller's main loop). For a device target, checks the IEEE is
    /// still in the live table first (it may have left since queueing;
    /// each send then re-resolves its nwk, picking up a re-association for
    /// free) — for a group target there's nothing to re-resolve,
    /// `group_id` is all a multicast send needs. Rule actions are
    /// FIRE-AND-FORGET: unlike a console command, an event-stream-
    /// triggered action must NOT block on the target's Default Response —
    /// doing so let the inbound backlog grow under button-mashing until
    /// the ASH transport choked (observed as `error.UnexpectedFrame` — an
    /// NCP ASH ERROR frame). The response still arrives and is decoded by
    /// `pollOnce` as an `[event]`.
    pub fn executeAction(self: *Coordinator, act: PendingAction) !void {
        switch (act.target) {
            .device => |ieee| {
                if (self.model.findByIeee(ieee) == null) return;
                const label = self.config.nameFor(ieee) orelse "target";
                switch (act.action) {
                    .on => {
                        try self.sendOnOff(ieee, Zcl.ONOFF_CMD_ON, label, false);
                        // Colour rides with the `on`.
                        // Independent of On/Off, so it's a second send —
                        // skipped inside sendColor if this device has no
                        // colour capability.
                        if (act.colour) |xy| try self.sendColor(ieee, xy, label);
                    },
                    .off => try self.sendOnOff(ieee, Zcl.ONOFF_CMD_OFF, label, false),
                    .toggle => try self.sendOnOff(ieee, Zcl.ONOFF_CMD_TOGGLE, label, false),
                    // Gesture-aware: a button PRESS starts a continuous
                    // Move (ramp) right away, RELEASE stops it — so a tap
                    // is a brief ramp (a nudge) and a hold ramps until let
                    // go, with no dead zone and no redundant re-sends
                    // (hold events are dropped in fireEvent). Dial
                    // detents and motion are single-shot `.tick` → one
                    // discrete Step.
                    .level_up, .level_down => {
                        const up = act.action == .level_up;
                        switch (act.phase) {
                            .press => try self.sendLevelMove(ieee, up, label),
                            .tick => try self.sendLevelStep(ieee, up, label),
                            .release => try self.sendLevelStop(ieee, label),
                            .hold => {}, // filtered in fireEvent; the Move already ramps
                        }
                    },
                }
            },
            // The caller sends these to the Bridge, off the radio's loop.
            .bridge => {},
            .group => |group_id| {
                const label = self.config.groupNameFor(group_id) orelse "group";
                switch (act.action) {
                    .on => {
                        try self.sendGroupOnOff(group_id, Zcl.ONOFF_CMD_ON, label);
                        if (act.colour) |xy| try self.sendGroupColor(group_id, xy, label);
                    },
                    .off => try self.sendGroupOnOff(group_id, Zcl.ONOFF_CMD_OFF, label),
                    .toggle => try self.sendGroupOnOff(group_id, Zcl.ONOFF_CMD_TOGGLE, label),
                    .level_up, .level_down => {
                        const up = act.action == .level_up;
                        switch (act.phase) {
                            .press => try self.sendGroupLevelMove(group_id, up, label),
                            .tick => try self.sendGroupLevelStep(group_id, up, label),
                            .release => try self.sendGroupLevelStop(group_id, label),
                            .hold => {},
                        }
                    },
                }
            },
        }
    }
};

test "Semantic Check" {
    std.testing.refAllDecls(@This());
}
