//! `dmain admin H mirror` and `dmain admin H history`: the house logs copied to
//! this machine, and a range of them folded for the admin app's charts.
//!
//! **The mirror is a cache.** It lives in `~/Library/Caches/dmain/<server>/`, holds
//! only the two house logs (never the raw capture or a settings file), and can be
//! deleted at any time: the server keeps the logs, and `mirror` fetches them again.
//! Past days never change, so `rsync` skips them and tops up today's.
//!
//! **History needs no server.** It folds the mirror with the same reader as every
//! other screen, so any range works offline. Both print JSON lines, ending with
//! `{"done":{"ok","why"}}`, as the app's other requests do.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const display_cfg = @import("display.zig");
const reader = @import("reader");
const Day = @import("day_file").Day;
const config = @import("config.zig");

const history = @import("history.zig");

pub const usage =
    \\  dmain admin <server> mirror        copy the server's house logs to this Mac's cache
    \\  dmain admin <server> history <from-ms> <to-ms> [raw]
    \\                         fold the mirror for a range, Unix milliseconds; raw
    \\                         leaves out display.json's corrections
    \\
;

pub fn isRequest(word: []const u8) bool {
    return std.mem.eql(u8, word, "mirror") or std.mem.eql(u8, word, "history");
}

/// The mirror of `host`'s logs: `<home>/Library/Caches/dmain/<server>`.
fn mirrorDir(a: Allocator, home: []const u8, host: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ home, "Library", "Caches", "dmain", host });
}

fn write(out: *Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{}, out);
    try out.writeByte('\n');
    try out.flush();
}

fn done(out: *Io.Writer, ok: bool, why: ?[]const u8) !bool {
    try write(out, .{ .done = .{ .ok = ok, .why = why } });
    return ok;
}

/// Runs one request. True if it did what it was asked.
pub fn run(gpa: Allocator, arena: Allocator, io: Io, out: *Io.Writer, host: []const u8, words: []const []const u8, home: ?[]const u8, app: *const config.Config) !bool {
    const home_dir = home orelse return done(out, false, "HOME isn't set, so there's nowhere to keep the mirror");
    const dir = try mirrorDir(arena, home_dir, host);
    if (std.mem.eql(u8, words[0], "mirror") and words.len == 1) return mirror(gpa, arena, io, out, host, dir, app);
    if (std.mem.eql(u8, words[0], "history") and (words.len == 3 or (words.len == 4 and std.mem.eql(u8, words[3], "raw")))) {
        const from = std.fmt.parseInt(i64, words[1], 10) catch return error.BadUsage;
        const to = std.fmt.parseInt(i64, words[2], 10) catch return error.BadUsage;
        if (to <= from) return error.BadUsage;
        return fold(gpa, arena, io, out, dir, app, from, to, words.len == 4);
    }
    return error.BadUsage;
}

/// The two log directories, as the server names them from `~/dmain`, and where each goes here.
fn sources(app: *const config.Config) [2]struct { remote: []const u8, local: []const u8 } {
    return .{
        .{ .remote = app.hue_log, .local = "hue" },
        .{ .remote = app.hub_log, .local = "hub" },
    };
}

fn mirror(gpa: Allocator, arena: Allocator, io: Io, out: *Io.Writer, host: []const u8, dir: []const u8, app: *const config.Config) !bool {
    for (sources(app)) |s| {
        const into = try std.fs.path.join(arena, &.{ dir, s.local });
        Io.Dir.cwd().createDirPath(io, into) catch |err|
            return done(out, false, try std.fmt.allocPrint(arena, "couldn't make {s} ({t})", .{ into, err }));
        // The paths in dmain.json are from the server's ~/dmain, where its dmain runs.
        const from = try std.fmt.allocPrint(arena, "{s}:dmain/{s}/", .{ host, s.remote });
        const to = try std.fmt.allocPrint(arena, "{s}/", .{into});
        try write(out, .{ .line = try std.fmt.allocPrint(arena, "{s} -> {s}", .{ from, to }) });
        const result = std.process.run(gpa, io, .{
            .argv = &.{ "rsync", "-a", "-e", "ssh -o BatchMode=yes -o ConnectTimeout=10", from, to },
            .stdout_limit = .limited(64 * 1024),
            .stderr_limit = .limited(64 * 1024),
        }) catch |err| return done(out, false, try std.fmt.allocPrint(arena, "couldn't run rsync ({t})", .{err}));
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        if (!result.term.success()) {
            const why = std.mem.trim(u8, result.stderr, " \n");
            return done(out, false, try std.fmt.allocPrint(arena, "rsync failed: {s}", .{if (why.len > 0) why else "no reason given"}));
        }
    }
    return done(out, true, null);
}

fn fold(gpa: Allocator, arena: Allocator, io: Io, out: *Io.Writer, dir: []const u8, app: *const config.Config, from: i64, to: i64, raw: bool) !bool {
    var warn_buf: [256]u8 = undefined;
    var warn: Io.Writer = .fixed(&warn_buf);
    var display = display_cfg.load(gpa, io, Io.Dir.cwd(), app.display_config, &warn) catch
        return done(out, false, warn.buffered());
    defer display.deinit();

    var f = try history.Fold.init(arena, display, .{
        .from = from,
        .to = to,
        .stale_ms = @as(i64, display.stale_min) * 60_000,
        .raw = raw,
    });
    var found = false;
    for (sources(app)) |s| {
        const path = try std.fs.path.join(arena, &.{ dir, s.local });
        var logs = Io.Dir.cwd().openDir(io, path, .{}) catch continue;
        defer logs.close(io);
        found = true;
        // The day before the range too, for what was true at its start.
        var day_ms = from - 24 * 3600 * 1000;
        var last: ?Day = null;
        while (day_ms <= to + 6 * 3600 * 1000) : (day_ms += 6 * 3600 * 1000) {
            const day = Day.of(.fromNanoseconds(@as(i96, day_ms) * std.time.ns_per_ms));
            if (last) |l| if (l.eql(day)) continue;
            last = day;
            _ = reader.replay(gpa, io, logs, day, &f) catch {};
        }
    }
    if (!found) return done(out, false, "there's no mirror yet: run mirror first");
    const h = try f.finish();
    try write(out, .{ .history = h });
    return done(out, true, if (f.bad_lines > 0) try std.fmt.allocPrint(arena, "{d} lines didn't read", .{f.bad_lines}) else null);
}
