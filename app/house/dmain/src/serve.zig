//! `dmain serve`: the house's state, as pages for a phone on the LAN.
//!
//!   GET /                       the temperatures
//!   GET /api/temps              their state, as `live.Live.json` describes
//!   GET /motion                 each sensor's last motion
//!   GET /api/motion             its state, as `motion.Board.json` describes
//!   GET /rooms                  each room's on/off, and safety alarms
//!   GET /api/rooms              their state, as `rooms.Rooms.json` describes
//!   GET /style.css, /common.js  what the pages share
//!   GET /manifest.webmanifest   so it can be added to a home screen
//!   GET /icon-192.png, /icon-512.png
//!
//! The listener is `lib/httpd`'s, admitting only private addresses
//! (`httpd.isPrivate`): the router forwards nothing to the server, and this is the
//! second wall behind that one.

const std = @import("std");
const Io = std.Io;
const httpd = @import("httpd");
const reader = @import("reader");
const houselog = @import("houselog");
const Day = @import("day_file").Day;
const display_cfg = @import("display.zig");
const dmain_config = @import("config.zig");
const Live = @import("live.zig").Live;
const Rooms = @import("rooms.zig").Rooms;
const pages = @import("pages.zig");

const HUE_SOURCE = "hue-bridge";
const HUB_SOURCE = "hub";

/// How often the house log is read for new lines. Sensors report every few
/// minutes and the page asks every 15 s; a second keeps the page current
/// without reading a file more than it needs to.
const poll_ms: u64 = 1000;

pub const Site = struct {
    cfg: *const display_cfg.Config,
    mutex: Io.Mutex = .init,
    live: *Live,
    rooms: *Rooms,

    pub fn handle(self: *Site, io: Io, arena: std.mem.Allocator, req: httpd.Request, rd: *Io.Reader, wr: *Io.Writer) !void {
        _ = rd;
        if (!std.mem.eql(u8, req.method, "GET")) return httpd.respond(wr, 405, "text/plain", "GET only\n");
        const path = if (std.mem.indexOfScalar(u8, req.path, '?')) |q| req.path[0..q] else req.path;
        if (std.mem.eql(u8, path, "/")) return httpd.respond(wr, 200, "text/html; charset=utf-8", pages.index_html);
        if (std.mem.eql(u8, path, "/api/temps")) {
            var body: Io.Writer.Allocating = .init(arena);
            const now_ms = Io.Timestamp.now(io, .real).toMilliseconds();
            {
                self.mutex.lockUncancelable(io);
                defer self.mutex.unlock(io);
                try self.live.json(&body.writer, self.cfg.display, self.cfg.stale_min, @intCast(now_ms));
            }
            return httpd.respond(wr, 200, "application/json", body.written());
        }
        if (std.mem.eql(u8, path, "/motion")) return httpd.respond(wr, 200, "text/html; charset=utf-8", pages.motion_html);
        if (std.mem.eql(u8, path, "/api/motion")) {
            var body: Io.Writer.Allocating = .init(arena);
            const now_ms = Io.Timestamp.now(io, .real).toMilliseconds();
            {
                self.mutex.lockUncancelable(io);
                defer self.mutex.unlock(io);
                try self.live.motionJson(&body.writer, @intCast(now_ms));
            }
            return httpd.respond(wr, 200, "application/json", body.written());
        }
        if (std.mem.eql(u8, path, "/rooms")) return httpd.respond(wr, 200, "text/html; charset=utf-8", pages.rooms_html);
        if (std.mem.eql(u8, path, "/api/rooms")) {
            var body: Io.Writer.Allocating = .init(arena);
            const now_ms = Io.Timestamp.now(io, .real).toMilliseconds();
            {
                self.mutex.lockUncancelable(io);
                defer self.mutex.unlock(io);
                try self.rooms.json(arena, &body.writer, @intCast(now_ms));
            }
            return httpd.respond(wr, 200, "application/json", body.written());
        }
        if (std.mem.eql(u8, path, "/style.css")) return httpd.respond(wr, 200, "text/css; charset=utf-8", pages.style_css);
        if (std.mem.eql(u8, path, "/common.js")) return httpd.respond(wr, 200, "text/javascript; charset=utf-8", pages.common_js);
        if (std.mem.eql(u8, path, "/manifest.webmanifest")) return httpd.respond(wr, 200, "application/manifest+json", pages.manifest);
        if (std.mem.eql(u8, path, "/icon-192.png")) return httpd.respond(wr, 200, "image/png", pages.icon_192);
        if (std.mem.eql(u8, path, "/icon-512.png")) return httpd.respond(wr, 200, "image/png", pages.icon_512);
        return httpd.respond(wr, 404, "text/plain", "not found\n");
    }
};

/// What the Hue follower hands records to: everything, including whether the
/// logger behind the pages is alive.
const HueFeed = struct {
    live: *Live,
    rooms: *Rooms,

    pub fn record(self: *HueFeed, r: houselog.Record) void {
        self.live.record(r);
        self.rooms.record(r);
    }

    pub fn bad(_: *HueFeed, _: []const u8, _: houselog.ParseError) void {}
};

/// hub's records reach the rooms and the temperature table, but not the logger
/// state, which the Temperature and Motion pages show for the Hue log. hub's
/// sensors there are judged by their own links and readings.
const HubFeed = struct {
    live: *Live,
    rooms: *Rooms,

    pub fn record(self: *HubFeed, r: houselog.Record) void {
        _ = self.live.table.apply(r) catch {};
        self.rooms.record(r);
    }

    pub fn bad(_: *HubFeed, _: []const u8, _: houselog.ParseError) void {}
};

pub fn run(gpa: std.mem.Allocator, io: Io, app: *const dmain_config.Config, cfg: *const display_cfg.Config, out: *Io.Writer) !void {
    const cwd = Io.Dir.cwd();
    var hue_dir = cwd.openDir(io, app.hue_log, .{}) catch |err| {
        try out.print("dmain: cannot open the Hue log at {s} ({t})\n", .{ app.hue_log, err });
        return err;
    };
    defer hue_dir.close(io);
    var hub_dir = cwd.openDir(io, app.hub_log, .{}) catch |err| {
        try out.print("dmain: cannot open hub's log at {s} ({t})\n", .{ app.hub_log, err });
        return err;
    };
    defer hub_dir.close(io);

    var live = try Live.init(gpa, cfg.motion);
    defer live.deinit();
    const source_configs = [_]@import("rooms.zig").SourceConfig{
        .{ .name = HUE_SOURCE, .checks_silence = true },
        .{ .name = HUB_SOURCE, .checks_silence = false },
    };
    var rooms = try Rooms.init(gpa, &source_configs, app.rooms);
    defer rooms.deinit();
    var site: Site = .{ .cfg = cfg, .live = &live, .rooms = &rooms };
    var hue_feed: HueFeed = .{ .live = &live, .rooms = &rooms };
    var hub_feed: HubFeed = .{ .live = &live, .rooms = &rooms };

    // From the top of today's files: the pages start with what the logs know.
    const today_at_start = Day.of(Io.Timestamp.now(io, .real));
    var hue_follower = reader.Follower.init(hue_dir, today_at_start);
    defer hue_follower.deinit(gpa);
    var hub_follower = reader.Follower.init(hub_dir, today_at_start);
    defer hub_follower.deinit(gpa);

    var http = httpd.Server(Site).init(gpa, &site, .{ .port = app.port, .allow = httpd.isPrivate });
    // The pages are the point of this command, so with no port there is nothing
    // to do, and the service manager's retry is what should happen next.
    http.bind(io) catch |err| {
        try out.print("dmain: cannot serve on port {d} ({t})\n", .{ app.port, err });
        return err;
    };
    var listen_task = io.async(httpd.Server(Site).listenTask, .{ &http, io });
    defer {
        http.stop(io);
        _ = listen_task.cancel(io);
    }
    try out.print("dmain: serving on port {d}, from {s} and {s}\n", .{ app.port, app.hue_log, app.hub_log });
    try out.flush();

    while (true) {
        const today = Day.of(Io.Timestamp.now(io, .real));
        site.mutex.lockUncancelable(io);
        _ = hue_follower.poll(gpa, io, today, &hue_feed) catch |err| {
            try out.print("dmain: reading the Hue log failed ({t})\n", .{err});
            try out.flush();
        };
        _ = hub_follower.poll(gpa, io, today, &hub_feed) catch |err| {
            try out.print("dmain: reading hub's log failed ({t})\n", .{err});
            try out.flush();
        };
        site.mutex.unlock(io);
        Io.sleep(io, Io.Duration.fromMilliseconds(poll_ms), Io.Clock.real) catch break;
    }
}
