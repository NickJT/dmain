//! huelog — the only client of the Hue bridge.
//!
//! Follows the bridge's event stream (`hue.event_stream`) and writes two files
//! a day:
//!
//!   data/raw/YYYY-MM-DD.jsonl    what the bridge said, verbatim (`hue.capture`)
//!   data/house/YYYY-MM-DD.jsonl  the house log (`houselog`), translated from it
//!
//! Everything else in the house reads the house log, never the bridge.
//!
//! **The house log is always the translation of the capture.** Live, each
//! capture record goes through `hue.translate` as it is written; `huelog
//! rebuild DAY…` puts a day's capture through the same translator from the
//! top. The two can only differ if the translator changed, which is what
//! rebuild is for. **Today's house log is rebuilt at every start**, so a
//! restart leaves no hole in it and a deployed translator change covers the
//! whole day; the live translator then carries on from where that left it.
//! Rebuild refuses today for the same reason: the running logger owns it.
//!
//! **Each day's capture stands alone.** The full resource list is captured on
//! every connect, and the stream is re-opened on the first line of each local
//! day to capture it again, so a day file carries the names and topology it
//! needs to be read without its neighbours. The bridge's stream carries only
//! updates, so it is also re-opened at once whenever a message announces a
//! device added or removed.
//!
//! **A heartbeat every few minutes, on clock boundaries.** A gap in heartbeats
//! means this process was not running. Heartbeats come from this process's own
//! clock, so they say nothing about the bridge.
//!
//! **A silent bridge is treated as a dead connection.** The stream only listens,
//! so after a network drop it can wait for ever on a socket that looks healthy,
//! and did, for three hours. The main loop watches for silence and cuts the
//! stream, which reconnects it. If the silence outlasts twice the limit,
//! something is hung that a cut cannot reach, such as a request in progress, so
//! the process exits and systemd starts it again: a restart loses nothing, since
//! today's house log is rebuilt from the capture.

const std = @import("std");
const Io = std.Io;

const config = @import("config.zig");
const translate = @import("translate");
const light_ids = @import("light_ids");
const atomic_file = @import("atomic_file");
const houselog = @import("houselog");

const event_stream = @import("event_stream");
const capture = @import("capture");
const sse_events = @import("sse_events");
const Resources = @import("resources");
const Registry = @import("maps").ResourceRegistry;
const Local = @import("local_time");
const day_file = @import("day_file");
const Day = day_file.Day;

/// Backoff between reconnection attempts when the bridge drops us.
const reconnect_ms: u64 = 5_000;

const tick_ms: u64 = 1000;

const Shared = struct {
    mutex: Io.Mutex = Io.Mutex.init,
    raw: day_file.DayFile,
    house: day_file.DayFile,
    translator: translate.Translator,
    settings: houselog.settings.Publisher,
    /// The local day the last resource list was captured.
    resources_day: ?Day = null,
    /// A message announced a device added or removed.
    topology_changed: bool = false,
};

/// How long after the limit a hung process gives up, as a multiple of it.
const exit_after_limits = 2;

const App = struct {
    io: Io,
    gpa: std.mem.Allocator,
    cfg: *const config.Config,
    shared: Shared,
    liveness: event_stream.Liveness = .{},
    running: std.atomic.Value(bool) = .init(true),

    /// One line to stdout, which is the journal under systemd. Formatted
    /// whole and written once, because both loops print.
    fn say(self: *App, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        var w = Io.Writer.fixed(&buf);
        Local.formatLocalDateTime(self.io, &w) catch {};
        w.print(" " ++ fmt ++ "\n", args) catch {
            _ = w.writeAll("…\n") catch {};
        };
        Io.File.stdout().writeStreamingAll(self.io, w.buffered()) catch {};
    }

    /// One capture record, and its translation. Formatted outside the lock —
    /// a resource list is half a megabyte — and appended under it.
    fn record(self: *App, kind: capture.Kind, note: ?[]const u8, data: ?[]const u8) void {
        const at = now(self.io);
        var line: Io.Writer.Allocating = .init(self.gpa);
        defer line.deinit();
        capture.write(&line.writer, at, kind, note, data) catch {
            self.say("[capture] cannot format a {t} record — out of memory", .{kind});
            return;
        };
        self.shared.mutex.lockUncancelable(self.io);
        defer self.shared.mutex.unlock(self.io);
        self.shared.raw.append(at, line.written());
        var sink: HouseSink = .{ .file = &self.shared.house, .gpa = self.gpa };
        self.shared.translator.feed(.{ .at = at, .kind = kind, .note = note, .data = data }, &sink) catch |err| {
            self.say("[house] could not translate a {t} record ({t})", .{ kind, err });
        };
    }
};

/// Where translated records go: one line each onto a day file.
const HouseSink = struct {
    file: *day_file.DayFile,
    gpa: std.mem.Allocator,

    pub fn emit(self: *HouseSink, r: houselog.Record) void {
        var line: Io.Writer.Allocating = .init(self.gpa);
        defer line.deinit();
        houselog.format(&line.writer, r) catch return;
        self.file.append(r.at, line.written());
    }
};

fn now(io: Io) Io.Timestamp {
    return Io.Timestamp.now(io, .real);
}

const StreamHandler = struct {
    app: *App,

    pub fn snapshot(self: StreamHandler, registry: *Registry, raw: []const u8) void {
        _ = registry;
        const app = self.app;
        app.record(.resources, null, raw);
        app.shared.mutex.lockUncancelable(app.io);
        app.shared.resources_day = Day.of(now(app.io));
        app.shared.topology_changed = false;
        app.shared.mutex.unlock(app.io);
        app.say("[resources] {d} KB captured", .{raw.len / 1024});
    }

    pub fn connected(self: StreamHandler) void {
        self.app.record(.up, null, null);
        self.app.say("[bridge] connected to {s}", .{self.app.cfg.host});
    }

    pub fn ended(self: StreamHandler, err: anyerror) void {
        self.app.record(.down, @errorName(err), null);
        self.app.say("[bridge] stream ended ({t}) — reconnecting in {d}s", .{ err, reconnect_ms / 1000 });
    }

    pub fn unparseable(self: StreamHandler, payload: []const u8, err: anyerror) void {
        self.app.record(.unparseable, payload, null);
        self.app.say("[bridge] unparseable message ({t}), captured as a note", .{err});
    }

    pub fn message(self: StreamHandler, registry: *Registry, payload: []const u8, events: []const Resources.EventUpdate) void {
        _ = registry;
        _ = events;
        const app = self.app;
        app.record(.message, null, payload);

        // `events` holds updates only; additions and removals are the other
        // container types, and the only way to learn their names and owners
        // is a fresh resource list.
        var arena = std.heap.ArenaAllocator.init(app.gpa);
        defer arena.deinit();
        // An automation's times aren't in the model, so a changed one needs a fresh
        // list too. A state change mentions the type but carries no configuration.
        if (std.mem.indexOf(u8, payload, "\"behavior_instance\"") != null and
            std.mem.indexOf(u8, payload, "\"configuration\"") != null)
        {
            app.shared.mutex.lockUncancelable(app.io);
            app.shared.topology_changed = true;
            app.shared.mutex.unlock(app.io);
            return;
        }
        const containers = sse_events.parseContainers(arena.allocator(), payload) catch return;
        for (containers.items) |c| switch (c.ctnrType) {
            .add, .delete => {
                app.shared.mutex.lockUncancelable(app.io);
                app.shared.topology_changed = true;
                app.shared.mutex.unlock(app.io);
                return;
            },
            else => {},
        };
    }

    /// True on the first line of a new local day, or after an add/delete.
    pub fn resync(self: StreamHandler) bool {
        const app = self.app;
        app.shared.mutex.lockUncancelable(app.io);
        const new_day = if (app.shared.resources_day) |d| !d.eql(Day.of(now(app.io))) else false;
        const changed = app.shared.topology_changed;
        app.shared.mutex.unlock(app.io);
        if (new_day) app.say("[bridge] new day — reconnecting to capture the resource list", .{});
        if (changed and !new_day) app.say("[bridge] a device or an automation changed — reconnecting to capture the resource list", .{});
        return new_day or changed;
    }
};

fn streamTask(app: *App) void {
    event_stream.follow(
        app.gpa,
        app.io,
        .{ .host = app.cfg.host, .port = app.cfg.port, .id = app.cfg.id, .key = app.cfg.key },
        StreamHandler{ .app = app },
        &app.running,
        Io.Duration.fromMilliseconds(reconnect_ms),
        &app.liveness,
    );
}

/// Once a tick: end a connection the bridge has gone silent on.
fn watchStream(app: *App) void {
    const limit_ms: i64 = @as(i64, app.cfg.silence_limit_min) * 60 * 1000;
    const silent = app.liveness.silentMs(app.io);
    if (silent > exit_after_limits * limit_ms) {
        app.record(.down, "StreamHung", null);
        app.say("[bridge] silent for {d} min and a reconnect has not helped — exiting for systemd to restart", .{@divTrunc(silent, 60_000)});
        std.process.exit(1);
    }
    if (silent > limit_ms and app.liveness.cut(app.io)) {
        app.say("[bridge] silent for {d} min — assuming the connection is dead", .{@divTrunc(silent, 60_000)});
    }
}

/// How often to compare settings with the last file. A power-on setting seen a
/// minute late harms nothing.
const settings_check_s: i64 = 60;

/// Writes `settings.json` if the bridge's settings have changed. Best-effort, as
/// a logger must not die over it.
fn publishSettings(app: *App, dir: Io.Dir) void {
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    app.shared.mutex.lockUncancelable(app.io);
    defer app.shared.mutex.unlock(app.io);
    const entries = app.shared.translator.settings(arena.allocator()) catch return;
    if (entries.len == 0) return; // no resource list yet: keep the last file
    const changed = app.shared.settings.publish(app.io, dir, translate.source, now(app.io), entries) catch |err| {
        app.say("[settings] cannot write: {t}", .{err});
        return;
    };
    if (changed) app.say("[settings] {s} updated, {d} entries", .{ houselog.settings.FILE, entries.len });
}

/// A small file that changes rarely. Read back rather than remembered, so a restart
/// doesn't rewrite it.
fn writeIfChanged(app: *App, dir: Io.Dir, arena: std.mem.Allocator, file: []const u8, text: []const u8) bool {
    if (dir.readFileAlloc(app.io, file, arena, .limited(1 << 20))) |existing| {
        if (std.mem.eql(u8, existing, text)) return false;
    } else |_| {}
    atomic_file.write(app.io, dir, file, text) catch |err| {
        app.say("[settings] cannot write {s}: {t}", .{ file, err });
        return false;
    };
    return true;
}

/// The Bridge's ids for the house's lights, for a program that writes to it, and
/// what runs by the clock on it. Both empty until a resource list has arrived, when
/// the last files are kept.
fn publishBridgeFiles(app: *App, dir: Io.Dir) void {
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    app.shared.mutex.lockUncancelable(app.io);
    const lights = app.shared.translator.lightIds(a);
    const schedules = app.shared.translator.schedules(a);
    app.shared.mutex.unlock(app.io);

    const light_list = lights catch return;
    if (light_list.len > 0) {
        const text = light_ids.render(a, light_list) catch return;
        if (writeIfChanged(app, dir, a, light_ids.FILE, text)) {
            app.say("[settings] {s} updated, {d} lights", .{ light_ids.FILE, light_list.len });
        }
    }
    const schedule_list = schedules catch return;
    if (schedule_list.len > 0) {
        const text = houselog.schedules.render(a, translate.source, schedule_list) catch return;
        if (writeIfChanged(app, dir, a, houselog.schedules.FILE, text)) {
            app.say("[settings] {s} updated, {d} schedules", .{ houselog.schedules.FILE, schedule_list.len });
        }
    }
}

fn boundaryAfter(now_s: i64, interval_s: i64) i64 {
    return @divFloor(now_s, interval_s) * interval_s + interval_s;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var dba: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer _ = dba.deinit();
    const gpa = dba.allocator();

    var out_buf: [1024]u8 = undefined;
    var fw: Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
    const out = &fw.interface;

    const cwd = Io.Dir.cwd();
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var cfg = config.load(gpa, io, cwd, out) catch |err| {
        try out.print("huelog: cannot start — {t}\n", .{err});
        try out.flush();
        return err;
    };
    defer cfg.deinit();
    try out.flush();

    var root = cwd.createDirPathOpen(io, cfg.data_dir, .{}) catch |err| {
        try out.print("huelog: cannot create {s} ({t})\n", .{ cfg.data_dir, err });
        try out.flush();
        return err;
    };
    defer root.close(io);
    var raw_dir = try root.createDirPathOpen(io, "raw", .{});
    defer raw_dir.close(io);
    var house_dir = try root.createDirPathOpen(io, "house", .{});
    defer house_dir.close(io);

    if (args.len >= 2 and std.mem.eql(u8, args[1], "rebuild")) {
        const today = Day.of(now(io));
        for (args[2..]) |day_s| {
            const day = Day.parse(day_s) catch {
                try out.print("huelog: {s} is not YYYY-MM-DD\n", .{day_s});
                continue;
            };
            if (day.eql(today)) {
                try out.print("huelog: {s} is today — the running logger rebuilds it at every start\n", .{day_s});
                continue;
            }
            var tr = translate.Translator.init(gpa);
            defer tr.deinit();
            rebuild(gpa, io, raw_dir, house_dir, day, &tr, out) catch |err| {
                try out.print("huelog: {s}: {t}\n", .{ day_s, err });
            };
        }
        if (args.len == 2) try out.print("usage: huelog rebuild YYYY-MM-DD…\n", .{});
        try out.flush();
        return;
    }

    var app: App = .{
        .io = io,
        .gpa = gpa,
        .cfg = &cfg,
        .shared = .{
            .raw = day_file.DayFile.init(io, raw_dir, "jsonl", null),
            .house = day_file.DayFile.init(io, house_dir, "jsonl", null),
            .translator = translate.Translator.init(gpa),
            .settings = .{ .gpa = gpa },
        },
    };
    defer {
        app.shared.settings.deinit();
        app.shared.raw.close();
        app.shared.house.close();
        app.shared.translator.deinit();
    }

    // Today so far, before anything new is appended to either file.
    rebuild(gpa, io, raw_dir, house_dir, Day.of(now(io)), &app.shared.translator, out) catch |err| switch (err) {
        error.FileNotFound => {}, // the first start of the day
        else => try out.print("huelog: today's house log could not be rebuilt ({t})\n", .{err}),
    };
    try out.flush();

    app.record(.start, null, null);
    app.say("[start] huelog up — capturing to {s}/raw/, heartbeat every {d} min", .{ cfg.data_dir, cfg.heartbeat_min });

    app.liveness.touch(io);
    var stream_task = io.async(streamTask, .{&app});
    defer {
        app.running.store(false, .release);
        stream_task.cancel(io);
    }

    const heartbeat_s: i64 = @as(i64, cfg.heartbeat_min) * 60;
    var next_heartbeat = boundaryAfter(now(io).toSeconds(), heartbeat_s);
    var next_settings: i64 = 0;
    while (app.running.load(.acquire)) {
        const t = now(io).toSeconds();
        if (t >= next_heartbeat) {
            app.record(.heartbeat, null, null);
            next_heartbeat = boundaryAfter(t, heartbeat_s);
        }
        if (t >= next_settings) {
            publishSettings(&app, root);
            publishBridgeFiles(&app, root);
            next_settings = t + settings_check_s;
        }
        watchStream(&app);
        Io.sleep(io, Io.Duration.fromMilliseconds(tick_ms), Io.Clock.real) catch break;
    }
}

/// A day's house log, regenerated from its capture by the live translator.
/// Written beside the old file and renamed over it, so a reader never sees it
/// half-made.
fn rebuild(gpa: std.mem.Allocator, io: Io, raw_dir: Io.Dir, house_dir: Io.Dir, day: Day, tr: *translate.Translator, out: *Io.Writer) !void {
    var name_buf: [32]u8 = undefined;
    const name = try day.fileName(&name_buf, "jsonl");

    const text = try raw_dir.readFileAlloc(io, name, gpa, .limited(1 << 30));
    defer gpa.free(text);

    var result: Io.Writer.Allocating = .init(gpa);
    defer result.deinit();
    const Sink = struct {
        w: *Io.Writer,
        pub fn emit(self: *@This(), r: houselog.Record) void {
            houselog.format(self.w, r) catch {};
        }
    };
    var sink: Sink = .{ .w = &result.writer };

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    var bad: usize = 0;
    while (lines.next()) |line| {
        // The last line can be half-written if the logger is running.
        if (line.len == 0 or lines.peek() == null) continue;
        _ = arena.reset(.retain_capacity);
        const rec = capture.parse(arena.allocator(), line) catch {
            bad += 1;
            continue;
        };
        try tr.feed(rec, &sink);
        n += 1;
    }

    var tmp_buf: [40]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{name});
    try house_dir.writeFile(io, .{ .sub_path = tmp, .data = result.written() });
    try house_dir.rename(tmp, house_dir, name, io);
    try out.print("huelog: {s} — {d} capture record(s) → {d} KB of house log{s}\n", .{
        name, n, result.written().len / 1024, if (bad > 0) " (some lines unreadable)" else "",
    });
}
