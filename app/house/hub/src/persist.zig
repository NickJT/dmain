//! Durable on-disk state: the atomic-write helper every persistence path in
//! hub now goes through, and the coordinator backup.
//!
//! **Why the backup exists**: the network key, its frame counter, and the
//! PAN/channel live *only* in the NCP's NVM. A dead or wiped radio
//! therefore means re-commissioning every device in the house by hand —
//! cheap to prevent now, miserable to need later. This module is only the
//! file format + safe write; reading the values off the radio is
//! `engine.zig`'s job (only the engine loop may touch it).
//!
//! **Restore is deliberately not implemented.** The design is documented but unverified (nobody has
//! a spare radio to test it against), and a half-tested restore is worse
//! than an honest export plus a written procedure.
//!
//! Dependencies: std only. It's imported by both `model.zig` and
//! `engine.zig`, so keeping it leaf-shaped keeps the module graph acyclic.
const std = @import("std");
const Io = std.Io;

pub const BACKUP_FILE = "hub-coordinator.json";

/// Writes `data` to `sub_path` via a temporary file + rename, so a reader
/// (or a crash) never sees a half-written file: rename is atomic within a
/// directory, so `sub_path` always holds either the old contents or the
/// complete new ones.
///
/// `model.zig`'s `save()` uses this too — `hub-devices.json` is rewritten
/// on every join, and a crash mid-write would truncate the device table
/// that tells us which nwk each device holds.
pub fn writeFileAtomic(io: Io, dir: Io.Dir, sub_path: []const u8, data: []const u8) !void {
    return @import("atomic_file").write(io, dir, sub_path, data);
}

/// `writeFileAtomic`, readable by its owner only: the coordinator backup holds
/// the network key in plaintext, and a default file is readable by everyone.
pub fn writeSecretAtomic(io: Io, dir: Io.Dir, sub_path: []const u8, data: []const u8) !void {
    return @import("atomic_file").writeWith(io, dir, sub_path, data, .fromMode(0o600));
}

/// Everything needed to stand this network back up on a replacement radio.
///
/// **Byte-order conventions differ per field, matching how hub displays
/// each one elsewhere** — worth reading before using this file for a
/// restore:
///   - `eui64` / `extended_pan_id`: **display order** (MSB first), the same
///     orientation `list` and the TUI print. Both are stored reversed from
///     wire order, so a restore must reverse them back before handing them
///     to EZSP.
///   - `network_key` / `tclk_hash_seed`: **wire order, as-is** — key
///     material is never reversed for display (see `ezsp.zig`'s `KeyInfo`),
///     so what's here is what EZSP wants.
pub const CoordinatorBackup = struct {
    saved_at_unix: i64,
    eui64: []const u8, // colon-hex, display order
    pan_id: u16,
    extended_pan_id: []const u8, // hex, display order
    channel: u8,
    nwk_update_id: u8,
    channel_mask: u32,
    network_key: []const u8, // 32 hex chars, wire order
    key_sequence_number: u8,
    outgoing_frame_counter: u32,
    /// The Trust Center link key hash seed, generated at form time and
    /// otherwise never observable — the NCP will not export it. `null`
    /// means "this network predates hub recording it" (true of the
    /// existing PAN 0x9928 network, whose future joins cannot survive a
    /// restore). Captured for every network hub forms from now on.
    tclk_hash_seed: ?[]const u8 = null, // 32 hex chars, wire order
};

/// JSON text for `backup`, owned by `gpa`.
pub fn serializeBackup(gpa: std.mem.Allocator, backup: CoordinatorBackup) ![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try std.json.Stringify.value(backup, .{ .whitespace = .indent_2 }, &aw.writer);
    return aw.toOwnedSlice();
}

/// Parses backup JSON, tolerantly: unknown fields are ignored and anything
/// malformed returns null rather than erroring — same discipline as
/// `config.zig`'s loaders (a damaged file must never stop hub starting).
/// Strings borrow from `arena`.
pub fn parseBackup(arena: std.mem.Allocator, text: []const u8) ?CoordinatorBackup {
    return std.json.parseFromSliceLeaky(CoordinatorBackup, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        std.log.warn("{s} parse failed: {t} — treating as absent", .{ BACKUP_FILE, err });
        return null;
    };
}

/// Reads and parses the backup file. Absent file → null (not an error): on
/// the first ever run there simply isn't one.
pub fn loadBackup(io: Io, dir: Io.Dir, arena: std.mem.Allocator) ?CoordinatorBackup {
    var buf: [4096]u8 = undefined;
    const text = dir.readFile(io, BACKUP_FILE, &buf) catch return null;
    return parseBackup(arena, text);
}

/// True when `existing` records a **different network** than the live one —
/// the signal that overwriting it would destroy the only copy of a key we
/// might still need.
///
/// This exists because of a hole the first design (and its implementation)
/// originally missed, in the exact scenario the backup is *for*: a dead
/// radio is replaced, its NVM is blank, `bootstrap`'s `networkInit` fails,
/// hub **forms a new network**, and the startup backup then overwrites the
/// dead network's key with the new one's. The record you were relying on
/// erases itself at the worst possible moment. See `Coordinator.writeBackup`.
///
/// Compares **network** identity (extended PAN + PAN), not radio identity:
/// after a successful restore onto a replacement radio the EUI64 is new but
/// the network is the same one, and that must still be backed up normally.
pub fn isDifferentNetwork(existing: ?CoordinatorBackup, live_extended_pan_id_hex: []const u8, live_pan_id: u16) bool {
    const old = existing orelse return false; // nothing on disk = nothing to lose
    if (!std.ascii.eqlIgnoreCase(old.extended_pan_id, live_extended_pan_id_hex)) return true;
    return old.pan_id != live_pan_id;
}

/// Where a superseded backup gets moved aside to, rather than deleted:
/// `hub-coordinator-9928.json`. A network key is not something to overwrite
/// on the strength of one command being typed correctly.
pub fn archiveNameFor(buf: []u8, pan_id: u16) ![]const u8 {
    return std.fmt.bufPrint(buf, "hub-coordinator-{x:0>4}.json", .{pan_id});
}

/// Which TCLK hash seed the next backup should carry, given the seed this
/// session knows (`live`, non-null only if *this* process formed the
/// network) and whatever the existing file holds.
///
/// The seed exists for exactly one instant — inside `formFreshNetwork`, at
/// form time — and can never be read back from the NCP. So a later session,
/// which has no `live` seed, must **preserve** the one already on disk
/// rather than overwrite it with null. Without this, the first hourly
/// rewrite after a restart would silently destroy the only copy of a seed
/// recorded at form time.
pub fn seedForBackup(live: ?[]const u8, existing: ?CoordinatorBackup) ?[]const u8 {
    if (live) |seed| return seed; // this session formed the network: freshest truth
    if (existing) |old| return old.tclk_hash_seed; // may itself be null; preserve either way
    return null;
}

test "writeFileAtomic: correct content, no .tmp left behind, overwrites an existing file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFileAtomic(io, tmp.dir, "thing.json", "first");
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("first", try tmp.dir.readFile(io, "thing.json", &buf));
    // The temp file is a means, not an artifact — it must not survive.
    try std.testing.expectError(error.FileNotFound, tmp.dir.readFile(io, "thing.json.tmp", &buf));

    try writeFileAtomic(io, tmp.dir, "thing.json", "second");
    try std.testing.expectEqualStrings("second", try tmp.dir.readFile(io, "thing.json", &buf));
    try std.testing.expectError(error.FileNotFound, tmp.dir.readFile(io, "thing.json.tmp", &buf));
}

test "backup round-trips through JSON" {
    const gpa = std.testing.allocator;
    const original: CoordinatorBackup = .{
        .saved_at_unix = 1_784_000_000,
        .eui64 = "00:17:88:01:0b:57:35:f1",
        .pan_id = 0x9928,
        .extended_pan_id = "dd40d108018817 00"[0..14], // arbitrary; shape is what matters
        .channel = 15,
        .nwk_update_id = 0,
        .channel_mask = 0x07FFF800,
        .network_key = "0123456789abcdef0123456789abcdef",
        .key_sequence_number = 3,
        .outgoing_frame_counter = 12345,
        .tclk_hash_seed = "fedcba9876543210fedcba9876543210",
    };
    const text = try serializeBackup(gpa, original);
    defer gpa.free(text);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const parsed = parseBackup(arena.allocator(), text).?;

    try std.testing.expectEqual(original.saved_at_unix, parsed.saved_at_unix);
    try std.testing.expectEqualStrings(original.eui64, parsed.eui64);
    try std.testing.expectEqual(original.pan_id, parsed.pan_id);
    try std.testing.expectEqual(original.channel, parsed.channel);
    try std.testing.expectEqual(original.channel_mask, parsed.channel_mask);
    try std.testing.expectEqualStrings(original.network_key, parsed.network_key);
    try std.testing.expectEqual(original.key_sequence_number, parsed.key_sequence_number);
    try std.testing.expectEqual(original.outgoing_frame_counter, parsed.outgoing_frame_counter);
    try std.testing.expectEqualStrings(original.tclk_hash_seed.?, parsed.tclk_hash_seed.?);
}

test "parseBackup is tolerant: unknown fields ignored, malformed and truncated files are null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const with_extra =
        \\{"saved_at_unix":1,"eui64":"aa","pan_id":2,"extended_pan_id":"bb","channel":15,
        \\ "nwk_update_id":0,"channel_mask":3,"network_key":"cc","key_sequence_number":0,
        \\ "outgoing_frame_counter":4,"something_a_later_version_added":true}
    ;
    const ok = parseBackup(a, with_extra).?;
    try std.testing.expectEqual(@as(u16, 2), ok.pan_id);
    try std.testing.expectEqual(@as(?[]const u8, null), ok.tclk_hash_seed); // absent → null, not an error

    try std.testing.expectEqual(@as(?CoordinatorBackup, null), parseBackup(a, "{ this is not json"));
    try std.testing.expectEqual(@as(?CoordinatorBackup, null), parseBackup(a, ""));
    // A file truncated mid-write by a crash — exactly what writeFileAtomic
    // exists to prevent, but a reader must survive one anyway.
    try std.testing.expectEqual(@as(?CoordinatorBackup, null), parseBackup(a, with_extra[0 .. with_extra.len / 2]));
}

test "isDifferentNetwork: guards the clobber, but not against a replacement radio's new EUI64" {
    var b: CoordinatorBackup = .{
        .saved_at_unix = 1,
        .eui64 = "60:b7:63:ff:fe:5a:d5:d7",
        .pan_id = 0x9928,
        .extended_pan_id = "605730ec86f99f10",
        .channel = 15,
        .nwk_update_id = 0,
        .channel_mask = 3,
        .network_key = "cc",
        .key_sequence_number = 0,
        .outgoing_frame_counter = 4,
        .tclk_hash_seed = null,
    };

    // Same network: a normal rewrite, always allowed.
    try std.testing.expect(!isDifferentNetwork(b, "605730ec86f99f10", 0x9928));
    try std.testing.expect(!isDifferentNetwork(b, "605730EC86F99F10", 0x9928)); // case is not identity

    // The scenario this guards: a blank replacement radio auto-formed a
    // brand-new network, and writing its key here would erase the only copy
    // of the one we actually want back.
    try std.testing.expect(isDifferentNetwork(b, "aaaaaaaaaaaaaaaa", 0x1234));
    try std.testing.expect(isDifferentNetwork(b, "605730ec86f99f10", 0x1234)); // same epid, different pan
    try std.testing.expect(isDifferentNetwork(b, "aaaaaaaaaaaaaaaa", 0x9928)); // same pan, different epid

    // A restore onto a REPLACEMENT radio: same network, new EUI64. Must not
    // be mistaken for a different network — this file has to stay writable.
    b.eui64 = "aa:bb:cc:dd:ee:ff:00:11";
    try std.testing.expect(!isDifferentNetwork(b, "605730ec86f99f10", 0x9928));

    // First run ever: no file, nothing to protect.
    try std.testing.expect(!isDifferentNetwork(null, "605730ec86f99f10", 0x9928));
}

test "archiveNameFor: names the sidelined file after the network it holds" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hub-coordinator-9928.json", try archiveNameFor(&buf, 0x9928));
    try std.testing.expectEqualStrings("hub-coordinator-0001.json", try archiveNameFor(&buf, 1));
}

test "seedForBackup: a live seed wins, otherwise the on-disk seed is preserved, never clobbered" {
    const on_disk: CoordinatorBackup = .{
        .saved_at_unix = 1,
        .eui64 = "aa",
        .pan_id = 2,
        .extended_pan_id = "bb",
        .channel = 15,
        .nwk_update_id = 0,
        .channel_mask = 3,
        .network_key = "cc",
        .key_sequence_number = 0,
        .outgoing_frame_counter = 4,
        .tclk_hash_seed = "seed-from-form-time",
    };

    // This session formed the network: its seed is the freshest truth.
    try std.testing.expectEqualStrings("live-seed", seedForBackup("live-seed", on_disk).?);
    try std.testing.expectEqualStrings("live-seed", seedForBackup("live-seed", null).?);

    // The case this function exists for: a later session has no live seed,
    // and must NOT overwrite the recorded one with null on its hourly
    // rewrite — that seed is unrecoverable.
    try std.testing.expectEqualStrings("seed-from-form-time", seedForBackup(null, on_disk).?);

    // Nothing anywhere (the pre-existing PAN 0x9928 case): honestly null.
    var no_seed = on_disk;
    no_seed.tclk_hash_seed = null;
    try std.testing.expectEqual(@as(?[]const u8, null), seedForBackup(null, no_seed));
    try std.testing.expectEqual(@as(?[]const u8, null), seedForBackup(null, null));
}

test "Semantic Check" {
    std.testing.refAllDecls(@This());
}
