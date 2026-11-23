//! The wanted files as `dmain admin` on the Mac sees them: the git checkout's copy,
//! read as it's saved, and sent whole to the server to be checked there, then applied
//! only on a typed `confirm`.
//!
//! **What's applied is what was checked.** Applying sends the files again, so if
//! they've changed since the dry run, it checks them again instead.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const link = @import("link.zig");

pub const Target = link.Target;

pub const Spec = struct {
    target: Target,
    key: u8,
    label: []const u8,
    /// From the checkout's `app/house/dmain`. Each is sent under its own base name.
    paths: []const []const u8,
    shown: []const u8,
};

pub const SPECS = [_]Spec{
    .{ .target = .power_on, .key = 'p', .label = "power-on", .paths = &.{"power-on.json"}, .shown = "power-on.json" },
    .{ .target = .switches, .key = 's', .label = "switches", .paths = &.{"rooms.json"}, .shown = "rooms.json, for the dimmers" },
    .{ .target = .rooms, .key = 'r', .label = "rooms", .paths = &.{ "rooms.json", "../hub/devices.json" }, .shown = "rooms.json, ../hub/devices.json" },
    .{ .target = .hub, .key = 'h', .label = "hub", .paths = &.{ "../hub/devices.json", "../hub/rules.json", "../hub/groups.json", "../hub/schedule.json" }, .shown = "../hub/ devices, rules, groups, schedule.json" },
    .{ .target = .sensors, .key = 'm', .label = "sensors", .paths = &.{"rooms.json"}, .shown = "rooms.json, for the motion sensors" },
    .{ .target = .schedules, .key = 't', .label = "schedules", .paths = &.{"rooms.json"}, .shown = "rooms.json, for the timed automations" },
    .{ .target = .actions, .key = 'k', .label = "actions", .paths = &.{"rooms.json"}, .shown = "rooms.json, for the Dial" },
};

/// How often the files are read for a change.
const WATCH_MS: i64 = 2000;
const MAX_FILE = 1 << 20;

pub const Result = struct {
    confirm: bool,
    ok: bool,
    /// A dry run that found changes it would make.
    appliable: bool,
    /// When it ended, local "HH:MM".
    at: [5]u8,
};

pub const Slot = struct {
    /// The files as last read, or null if one wouldn't read.
    seen: ?u64 = null,
    /// What the last dry run checked.
    checked: ?u64 = null,
    read_err: ?[]const u8 = null,
    queued: bool = false,
    /// How many runs have ended, so a watcher can tell one from the next.
    ends: u32 = 0,
    running: ?bool = null,
    lines: std.ArrayList([]u8) = .empty,
    last: ?Result = null,
};

pub const Request = struct { target: Target, confirm: bool, files: []const link.NamedFile };

/// Which targets are checked on their own: all of them for the screens, one
/// for an `apply`, none for a command that doesn't touch the wanted files.
pub const Want = union(enum) { all, none, one: usize };

pub const Wanted = struct {
    gpa: Allocator,
    /// The checkout's `app/house/dmain`, or null if none was found.
    base: ?[]const u8,
    slots: [SPECS.len]Slot = @splat(.{}),
    /// Which slot is running, if any.
    busy: ?usize = null,
    last_watch_ms: i64 = std.math.minInt(i64) / 2,
    changed: bool = false,
    want: Want = .all,

    fn wants(self: *const Wanted, i: usize) bool {
        return switch (self.want) {
            .all => true,
            .none => false,
            .one => |j| i == j,
        };
    }

    pub fn deinit(self: *Wanted) void {
        for (&self.slots) |*slot| {
            for (slot.lines.items) |l| self.gpa.free(l);
            slot.lines.deinit(self.gpa);
        }
        if (self.base) |b| self.gpa.free(b);
    }

    pub fn index(target: Target) usize {
        for (SPECS, 0..) |spec, i| {
            if (spec.target == target) return i;
        }
        unreachable;
    }

    /// The files' contents, into `arena`, or why they wouldn't read.
    fn read(self: *const Wanted, arena: Allocator, io: Io, i: usize) error{ OutOfMemory, Unreadable }![]link.NamedFile {
        const base = self.base orelse return error.Unreadable;
        const spec = SPECS[i];
        const files = try arena.alloc(link.NamedFile, spec.paths.len);
        var dir = Io.Dir.cwd().openDir(io, base, .{}) catch return error.Unreadable;
        defer dir.close(io);
        for (spec.paths, files) |path, *f| {
            f.* = .{
                .name = std.fs.path.basename(path),
                .text = dir.readFileAlloc(io, path, arena, .limited(MAX_FILE)) catch return error.Unreadable,
            };
        }
        return files;
    }

    fn readErr(self: *const Wanted, io: Io, i: usize) []const u8 {
        const base = self.base orelse return "no checkout";
        var dir = Io.Dir.cwd().openDir(io, base, .{}) catch |err| return @errorName(err);
        defer dir.close(io);
        for (SPECS[i].paths) |path| {
            _ = dir.statFile(io, path, .{}) catch |err| return @errorName(err);
        }
        return "unreadable";
    }

    /// Reads the files when it's time, queues a dry run for any that changed,
    /// and returns the next run to send, if one may go now. Its strings are in
    /// `arena`. `can_run` is whether the link is up.
    pub fn poll(self: *Wanted, arena: Allocator, io: Io, can_run: bool) !?Request {
        const now_ms = Io.Timestamp.now(io, .awake).toMilliseconds();
        if (now_ms - self.last_watch_ms >= WATCH_MS) {
            self.last_watch_ms = now_ms;
            for (&self.slots, 0..) |*slot, i| {
                if (!self.wants(i)) continue;
                const files = self.read(arena, io, i) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    error.Unreadable => {
                        if (slot.seen != null or slot.read_err == null) self.changed = true;
                        slot.seen = null;
                        slot.read_err = self.readErr(io, i);
                        continue;
                    },
                };
                const hash = hashOf(files);
                slot.read_err = null;
                if (slot.seen != hash) {
                    slot.seen = hash;
                    slot.queued = true;
                    self.changed = true;
                }
            }
        }
        if (!can_run or self.busy != null) return null;
        for (&self.slots, 0..) |*slot, i| {
            if (!slot.queued or !self.wants(i)) continue;
            slot.queued = false;
            const files = self.read(arena, io, i) catch |err| switch (err) {
                error.OutOfMemory => return err,
                error.Unreadable => continue,
            };
            slot.checked = hashOf(files);
            return self.begin(i, false, files);
        }
        return null;
    }

    fn begin(self: *Wanted, i: usize, confirm: bool, files: []const link.NamedFile) Request {
        const slot = &self.slots[i];
        for (slot.lines.items) |l| self.gpa.free(l);
        slot.lines.clearRetainingCapacity();
        slot.running = confirm;
        self.busy = i;
        self.changed = true;
        return .{ .target = SPECS[i].target, .confirm = confirm, .files = files };
    }

    /// Checks `i` again now, as soon as nothing else is running.
    pub fn recheck(self: *Wanted, i: usize) void {
        self.slots[i].queued = true;
        self.last_watch_ms = std.math.minInt(i64) / 2;
        self.changed = true;
    }

    /// Why `i` can't be applied now, or null if it can.
    pub fn applyRefusal(self: *const Wanted, i: usize) ?[]const u8 {
        const slot = &self.slots[i];
        if (self.busy != null) return "a run is going: wait for it";
        const last = slot.last orelse return "it hasn't been checked yet";
        if (last.confirm) return "it was just applied, and is read back next";
        if (!last.ok) return "its dry run failed: fix the file, save, and it's checked again";
        if (!last.appliable) return "its dry run found nothing to change";
        if (slot.seen != slot.checked) return "it has changed since the dry run, which runs again";
        return null;
    }

    /// The apply that the dry run showed, if the files still read as they did.
    pub fn apply(self: *Wanted, arena: Allocator, io: Io, i: usize) !?Request {
        if (self.applyRefusal(i) != null) return null;
        const files = self.read(arena, io, i) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.Unreadable => return null,
        };
        if (hashOf(files) != self.slots[i].checked) {
            self.recheck(i);
            return null;
        }
        return self.begin(i, true, files);
    }

    pub fn runLine(self: *Wanted, text: []const u8) void {
        const i = self.busy orelse return;
        const copy = self.gpa.dupe(u8, text) catch return;
        self.slots[i].lines.append(self.gpa, copy) catch self.gpa.free(copy);
        self.changed = true;
    }

    pub fn runEnd(self: *Wanted, io: Io, ok_run: bool) void {
        const i = self.busy orelse return;
        const slot = &self.slots[i];
        const confirm = slot.running orelse false;
        const ok = if (SPECS[i].target == .rooms) self.roomsHub(io, i, confirm, ok_run) else ok_run;
        slot.running = null;
        slot.ends += 1;
        self.busy = null;
        slot.last = .{ .confirm = confirm, .ok = ok, .appliable = ok and !confirm and saysWouldChange(slot.lines.items), .at = hhmm(io) };
        // An apply is read back at once, so the screen says what the house now holds.
        if (confirm) slot.queued = true;
        self.changed = true;
    }

    /// `rooms.json`'s other half: hub's `devices.json`, in the checkout, which the
    /// hub row then applies. Its lines join the Bridge's; on an apply that the
    /// Bridge took whole, the file is rewritten. Says whether the run still stands.
    fn roomsHub(self: *Wanted, io: Io, i: usize, confirm: bool, ok: bool) bool {
        const rf = @import("rooms_file.zig");
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const files = self.read(a, io, i) catch {
            self.runLine("hub's devices.json didn't read");
            return false;
        };
        const wanted = rf.parse(a, files[0].text) catch return ok;
        const entries = rf.parseHub(a, files[1].text) catch |err| {
            self.runLine(std.fmt.allocPrint(a, "  can't: hub's devices.json didn't read ({t})", .{err}) catch return false);
            return false;
        };
        if (rf.hubRefusal(a, wanted, entries) catch null) |why| {
            self.runLine(std.fmt.allocPrint(a, "  can't: {s}", .{why}) catch return false);
            return false;
        }
        const found = rf.changes(a, wanted, rf.hubHeld(a, entries) catch return false) catch return false;
        var n: usize = 0;
        for (found) |c| {
            const counts = std.mem.startsWith(u8, c.text, "rename") or std.mem.startsWith(u8, c.text, "move");
            if (counts) n += 1;
            self.runLine(std.fmt.allocPrint(a, "  devices.json: {s}", .{c.text}) catch continue);
        }
        const lines = &self.slots[i].lines;
        if (lines.items.len > 0 and n > 0) {
            const joined = std.fmt.allocPrint(self.gpa, "{s} {d} in hub's devices.json.", .{ lines.items[0], n }) catch null;
            if (joined) |j| {
                self.gpa.free(lines.items[0]);
                lines.items[0] = j;
            }
        }
        if (n == 0 or !ok) return ok;
        if (!confirm) {
            self.runLine("Nothing written. Applying rewrites devices.json in the checkout; the hub row then applies it.");
            return ok;
        }
        var aw: Io.Writer.Allocating = .init(a);
        rf.renderHub(&aw.writer, wanted, entries) catch return false;
        const base = self.base orelse return false;
        var dir = Io.Dir.cwd().openDir(io, base, .{}) catch return false;
        defer dir.close(io);
        dir.writeFile(io, .{ .sub_path = SPECS[i].paths[1], .data = aw.written() }) catch |err| {
            self.runLine(std.fmt.allocPrint(a, "couldn't write devices.json ({t})", .{err}) catch return false);
            return false;
        };
        self.runLine("devices.json rewritten: apply the hub row to give it to hub.");
        return ok;
    }

    /// The link dropped: nothing running will finish.
    pub fn abandon(self: *Wanted, io: Io) void {
        if (self.busy == null) return;
        self.runLine("the link closed before the run finished; what it did is unknown");
        self.runEnd(io, false);
    }

    /// The hash of the files the last dry run checked, as the app shows it and
    /// `apply` is given it back.
    pub fn checkedHex(self: *const Wanted, i: usize, buf: *[16]u8) ?[]const u8 {
        const h = self.slots[i].checked orelse return null;
        return std.fmt.bufPrint(buf, "{x:0>16}", .{h}) catch unreachable;
    }

    /// The target a name means: its label (`power-on`) or its link name (`power_on`).
    pub fn byName(name: []const u8) ?usize {
        for (SPECS, 0..) |spec, i| {
            if (std.mem.eql(u8, name, spec.label) or std.mem.eql(u8, name, @tagName(spec.target))) return i;
        }
        return null;
    }

    /// One line for a target: its last result and summary.
    pub fn status(self: *const Wanted, a: Allocator, i: usize) ![]const u8 {
        const slot = &self.slots[i];
        if (slot.read_err) |err| return std.fmt.allocPrint(a, "can't read it ({s})", .{err});
        if (slot.running) |confirm| return if (confirm) "applying" else "checking";
        const last = slot.last orelse return if (slot.queued) "waiting to be checked" else "not checked";
        const what = if (last.confirm)
            (if (last.ok) "applied" else "apply FAILED")
        else if (!last.ok)
            "dry run FAILED"
        else if (last.appliable)
            "would change"
        else
            "matches";
        const stale = if (slot.seen != slot.checked and !last.confirm) ", saved since" else "";
        return std.fmt.allocPrint(a, "{s} {s}{s}   {s}", .{ &last.at, what, stale, summary(SPECS[i].target, slot.lines.items) });
    }
};

/// Both dmain's bare `apply` and hub's `adopt` say so when they'd change something
/// and haven't.
fn saysWouldChange(lines: []const []const u8) bool {
    for (lines) |l| {
        if (std.mem.startsWith(u8, l, "Nothing written.")) return true;
        if (std.mem.indexOf(u8, l, "nothing applied yet") != null) return true;
    }
    return false;
}

/// dmain's first line counts what differs; hub's last `adopt` line says what it did.
fn summary(target: Target, lines: []const []const u8) []const u8 {
    if (lines.len == 0) return "";
    if (target != .hub) return lines[0];
    var i = lines.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.startsWith(u8, lines[i], "adopt")) return lines[i];
    }
    return lines[lines.len - 1];
}

fn hashOf(files: []const link.NamedFile) u64 {
    var h = std.hash.Wyhash.init(0);
    for (files) |f| {
        h.update(f.name);
        h.update(&std.mem.toBytes(f.text.len));
        h.update(f.text);
    }
    return h.final();
}

fn hhmm(io: Io) [5]u8 {
    const t = @import("local_time").localNow(io);
    var out: [5]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>2}:{d:0>2}", .{ t.hour, t.minute }) catch unreachable;
    return out;
}

/// The checkout's `app/house/dmain`: this directory if it's that, or the one this binary
/// was built in, `zig-out/bin` below it.
pub fn findBase(gpa: Allocator, io: Io) ?[]u8 {
    if (isBase(io, ".")) return real(gpa, io, ".");
    const exe_dir = std.process.executableDirPathAlloc(io, gpa) catch return null;
    defer gpa.free(exe_dir);
    const candidate = std.fs.path.join(gpa, &.{ exe_dir, "..", ".." }) catch return null;
    defer gpa.free(candidate);
    return if (isBase(io, candidate)) real(gpa, io, candidate) else null;
}

/// Shown on screen, so without the `..`s.
fn real(gpa: Allocator, io: Io, path: []const u8) ?[]u8 {
    const full = Io.Dir.cwd().realPathFileAlloc(io, path, gpa) catch return gpa.dupe(u8, path) catch null;
    defer gpa.free(full);
    return gpa.dupe(u8, full) catch null;
}

fn isBase(io: Io, path: []const u8) bool {
    var dir = Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    defer dir.close(io);
    _ = dir.statFile(io, "dmain.json", .{}) catch return false;
    _ = dir.statFile(io, "power-on.json", .{}) catch return false;
    return true;
}

const testing = std.testing;

fn checkout(tmp: *std.testing.TmpDir) !void {
    try tmp.dir.createDirPath(testing.io, "dmain");
    try tmp.dir.createDirPath(testing.io, "hub");
    for ([_][]const u8{ "dmain/power-on.json", "dmain/rooms.json", "hub/devices.json", "hub/rules.json", "hub/groups.json", "hub/schedule.json" }) |p| {
        try tmp.dir.writeFile(testing.io, .{ .sub_path = p, .data = "{}" });
    }
}

fn testBase(tmp: *std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/dmain", .{tmp.sub_path});
}

test "every file is checked once at the start, one run at a time, and again when saved" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try checkout(&tmp);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var w: Wanted = .{ .gpa = testing.allocator, .base = try testBase(&tmp) };
    defer w.deinit();

    try testing.expect(try w.poll(a, testing.io, false) == null);
    const first = (try w.poll(a, testing.io, true)).?;
    try testing.expectEqual(Target.power_on, first.target);
    try testing.expect(!first.confirm);
    try testing.expectEqualStrings("power-on.json", first.files[0].name);
    try testing.expect(try w.poll(a, testing.io, true) == null);
    w.runLine("53 lights, 0 differ.");
    w.runEnd(testing.io, true);
    try testing.expectEqual(Target.switches, (try w.poll(a, testing.io, true)).?.target);
    w.runEnd(testing.io, true);
    try testing.expectEqual(Target.rooms, (try w.poll(a, testing.io, true)).?.target);
    w.runEnd(testing.io, true);
    const hub = (try w.poll(a, testing.io, true)).?;
    try testing.expectEqual(Target.hub, hub.target);
    try testing.expectEqualStrings("schedule.json", hub.files[3].name);
    w.runEnd(testing.io, true);
    try testing.expectEqual(Target.sensors, (try w.poll(a, testing.io, true)).?.target);
    w.runEnd(testing.io, true);
    try testing.expectEqual(Target.schedules, (try w.poll(a, testing.io, true)).?.target);
    w.runEnd(testing.io, true);
    try testing.expectEqual(Target.actions, (try w.poll(a, testing.io, true)).?.target);
    w.runEnd(testing.io, true);
    try testing.expect(try w.poll(a, testing.io, true) == null);

    // rooms.json is the dimmers', the rooms', the sensors' and the schedules', so a save checks them all.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "dmain/rooms.json", .data = "{ }" });
    w.last_watch_ms = std.math.minInt(i64) / 2;
    try testing.expectEqual(Target.switches, (try w.poll(a, testing.io, true)).?.target);
}

test "apply needs a dry run that would change something, of the files as they still are" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try checkout(&tmp);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var w: Wanted = .{ .gpa = testing.allocator, .base = try testBase(&tmp) };
    defer w.deinit();
    const p = Wanted.index(.power_on);

    try testing.expect(w.applyRefusal(p) != null);
    _ = (try w.poll(a, testing.io, true)).?;
    w.runLine("53 lights, 1 differ.");
    w.runLine("Nothing written. `dmain power-on apply confirm` writes these to the Bridge.");
    w.runEnd(testing.io, true);
    try testing.expect(w.applyRefusal(p) == null);
    try testing.expect(std.mem.indexOf(u8, try w.status(a, p), "would change") != null);

    // Saved after the dry run: not applied, checked again.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "dmain/power-on.json", .data = "{\"v\":1}" });
    try testing.expect(try w.apply(a, testing.io, p) == null);
    try testing.expect(w.slots[p].queued);

    // As checked: applied, then read back.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "dmain/power-on.json", .data = "{}" });
    w.slots[p].queued = false;
    const run = (try w.apply(a, testing.io, p)).?;
    try testing.expect(run.confirm);
    try testing.expect(w.applyRefusal(p) != null);
    w.runLine("1 accepted, 0 failed.");
    w.runEnd(testing.io, true);
    try testing.expect(w.slots[p].queued);
    try testing.expect(w.applyRefusal(p) != null);
}

test "a dry run that failed, or found nothing, can't be applied" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try checkout(&tmp);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var w: Wanted = .{ .gpa = testing.allocator, .base = try testBase(&tmp) };
    defer w.deinit();
    const s = Wanted.index(.switches);
    const h = Wanted.index(.hub);
    _ = (try w.poll(a, testing.io, true)).?;
    w.runEnd(testing.io, true);
    _ = (try w.poll(a, testing.io, true)).?;
    w.runLine("21 dimmers, 1 would change.");
    w.runLine("Nothing written: 1 scene name(s) above need fixing first.");
    w.runEnd(testing.io, false);
    try testing.expect(w.applyRefusal(s) != null);
    _ = (try w.poll(a, testing.io, true)).?; // rooms
    w.runEnd(testing.io, true);
    _ = (try w.poll(a, testing.io, true)).?;
    w.runLine("[report] panel: off");
    w.runLine("adopt: nothing to apply");
    w.runEnd(testing.io, true);
    try testing.expect(w.applyRefusal(h) != null);
    try testing.expect(std.mem.indexOf(u8, try w.status(a, h), "adopt: nothing to apply") != null);
}

test "a file that won't read says why, and isn't sent" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try checkout(&tmp);
    try tmp.dir.deleteFile(testing.io, "hub/rules.json");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var w: Wanted = .{ .gpa = testing.allocator, .base = try testBase(&tmp) };
    defer w.deinit();
    for (0..6) |_| {
        _ = (try w.poll(a, testing.io, true)).?;
        w.runEnd(testing.io, true);
    }
    try testing.expect(try w.poll(a, testing.io, true) == null);
    try testing.expectEqualStrings("can't read it (FileNotFound)", try w.status(a, Wanted.index(.hub)));
}

test "each wanted file's key is its own, and none is one of the Config screen's" {
    for (SPECS, 0..) |s, i| {
        try testing.expect(std.mem.indexOfScalar(u8, "cae", s.key) == null);
        for (SPECS[i + 1 ..]) |o| try testing.expect(s.key != o.key);
    }
}
