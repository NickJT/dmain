//! `dmain agent`: the admin link's far end, for `dmain admin <host>` to start over
//! `ssh`. It sends what the screens read, and takes a few named requests: a line
//! for hub's console, a run of wanted files sent whole, a service's journal or its
//! restart, a device to identify. It can't be asked for a file or a unit by name. It exits when the other
//! end goes quiet or away.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const posix = std.posix;
const link = @import("link.zig");
const reader = @import("reader");
const Day = @import("day_file").Day;
const config = @import("config.zig");
const hub_client = @import("hub_client.zig");
const job = @import("job.zig");
const services = @import("services.zig");
const bridge_write = @import("bridge_write");
const bridge_switches = @import("bridge_switches");
const bridge_sensors = @import("bridge_sensors");
const room_scenes = @import("room_scenes.zig");
const bridge_info = @import("bridge_info");

const TICK_MS = 1000;
const RELOAD_MS: i64 = 5000;
const MAX_FILE = 1 << 20;

/// Passes each line of a log on as it was written.
const Forward = struct {
    out: *Io.Writer,
    src: link.Source,
    failed: bool = false,

    pub fn line(self: *Forward, bytes: []const u8) void {
        link.write(self.out, .{ .log = .{ .src = self.src, .line = bytes } }) catch {
            self.failed = true;
        };
    }
};

/// Passes hub's console on, and while hub runs `adopt` for a run, its reply too.
const HubForward = struct {
    out: *Io.Writer,
    failed: bool = false,
    /// A hub run waiting for its done mark.
    run: ?HubRun = null,

    const HubRun = struct {
        /// hub answered as `adopt` at all: one from before it says only "unknown".
        answered: bool = false,
        failed: bool = false,
    };

    fn send(self: *HubForward, m: link.Message) void {
        link.write(self.out, m) catch {
            self.failed = true;
        };
    }
    pub fn hubLine(self: *HubForward, text: []const u8) void {
        self.send(.{ .hub_line = text });
        if (self.run) |*r| {
            self.send(.{ .run_line = text });
            if (std.mem.startsWith(u8, text, "adopt")) r.answered = true;
            if (job.hubSaysFailed(text)) r.failed = true;
        }
    }
    pub fn hubDone(self: *HubForward) void {
        self.send(.hub_done);
        if (self.run) |r| {
            if (!r.answered) self.send(.{ .run_line = "hub didn't answer as `adopt`: it may be older than that command, so deploy hub" });
            self.endRun(r.answered and !r.failed);
        }
    }
    pub fn hubUp(self: *HubForward) void {
        self.send(.hub_up);
    }
    pub fn hubDown(self: *HubForward, why: []const u8) void {
        self.send(.{ .hub_down = why });
        if (self.run != null) {
            self.send(.{ .run_line = "hub's console went away before adopt finished" });
            self.endRun(false);
        }
    }
    fn endRun(self: *HubForward, ok: bool) void {
        self.run = null;
        self.send(.{ .run_end = ok });
    }
    /// For a child's output.
    pub fn runLine(self: *HubForward, text: []const u8) void {
        self.send(.{ .run_line = text });
    }
};

/// Passes a followed journal on.
const JournalForward = struct {
    hub_out: *HubForward,
    pub fn runLine(self: *JournalForward, text: []const u8) void {
        self.hub_out.send(.{ .journal_line = text });
    }
};

const SERVICES_MS: i64 = 5000;

/// Each service's state, sent when it has changed.
fn sendServices(gpa: Allocator, io: Io, last: *u64, hub_out: *HubForward) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const list = services.read(arena.allocator(), io) catch |err| {
        var buf: [80]u8 = undefined;
        return hub_out.send(.{ .journal_line = std.fmt.bufPrint(&buf, "dmain agent: couldn't read the services ({t})", .{err}) catch "dmain agent: couldn't read the services" });
    };
    var aw: Io.Writer.Allocating = .init(arena.allocator());
    std.json.Stringify.value(list, .{}, &aw.writer) catch return;
    const hash = std.hash.Wyhash.hash(0, aw.written());
    if (hash == last.*) return;
    last.* = hash;
    hub_out.send(.{ .services = list });
}

fn restart(gpa: Allocator, io: Io, unit: link.Unit, hub_out: *HubForward) void {
    var buf: [5][]const u8 = undefined;
    const result = std.process.run(gpa, io, .{ .argv = services.restartArgv(&buf, unit), .stdout_limit = .limited(4096), .stderr_limit = .limited(4096) }) catch |err| {
        return hub_out.send(.{ .restarted = .{ .unit = unit, .err = @errorName(err) } });
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    const why = std.mem.trim(u8, result.stderr, " \n");
    hub_out.send(.{ .restarted = .{ .unit = unit, .err = if (result.term.success()) null else if (why.len > 0) why else "systemctl refused" } });
}

/// Starts a run, or answers at once why it can't.
/// Asks the Bridge to have `dev` show itself. Blocks for two requests, the list
/// and the write, which is a few seconds at most.
fn identify(gpa: Allocator, io: Io, app: *const config.Config, dev: []const u8, hub_out: *HubForward) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    hub_out.send(.{ .identified = .{ .dev = dev, .err = identifyErr(gpa, arena.allocator(), io, app, dev) } });
}

/// Deletes `dev` on the Bridge, which un-joins it. Its leaving the inventory is
/// what says it's gone; this says only whether the Bridge took the request.
fn forget(gpa: Allocator, io: Io, app: *const config.Config, dev: []const u8, hub_out: *HubForward) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    hub_out.send(.{ .forgot = .{ .dev = dev, .err = deviceErr(gpa, arena.allocator(), io, app, dev, .forget) } });
}

fn identifyErr(gpa: Allocator, a: Allocator, io: Io, app: *const config.Config, dev: []const u8) ?[]const u8 {
    return deviceErr(gpa, a, io, app, dev, .identify);
}

fn deviceErr(gpa: Allocator, a: Allocator, io: Io, app: *const config.Config, dev: []const u8, what: enum { identify, forget }) ?[]const u8 {
    if (!link.isDevice(dev)) return "that isn't a device";
    const text = Io.Dir.cwd().readFileAlloc(io, app.bridge_file, a, .limited(MAX_FILE)) catch |err|
        return std.fmt.allocPrint(a, "couldn't read the Bridge's address and key ({t})", .{err}) catch "couldn't read the Bridge's key";
    // By name only: this file holds the Bridge's key.
    const bridge = bridge_write.parseCredentials(a, text) catch return "the Bridge's key file isn't right";
    const list = bridge_write.resources(gpa, io, bridge) catch |err|
        return std.fmt.allocPrint(a, "couldn't read the Bridge's devices ({t})", .{err}) catch "couldn't read the Bridge's devices";
    defer gpa.free(list);
    const id = (bridge_write.deviceFor(a, list, dev) catch return "the Bridge's device list didn't read") orelse
        return "the Bridge doesn't have that device";
    var reply: bridge_write.Reply = .{};
    const sent = switch (what) {
        .identify => bridge_write.setDevice(gpa, io, bridge, id, bridge_write.IDENTIFY_BODY, &reply),
        .forget => bridge_write.deleteDevice(gpa, io, bridge, id, &reply),
    };
    sent catch |err| {
        var aw: Io.Writer.Allocating = .init(a);
        aw.writer.print("the Bridge refused it ({t}", .{err}) catch {};
        if (err == error.HttpError and reply.status != 0) {
            aw.writer.writeAll(", ") catch {};
            reply.describe(&aw.writer) catch {};
        }
        aw.writer.writeAll(")") catch {};
        return aw.written();
    };
    return null;
}

/// Each Bridge room's scenes, read now: the Hue app may have changed them since
/// any dry run. Blocks for one request.
fn sendScenes(gpa: Allocator, io: Io, app: *const config.Config, hub_out: *HubForward) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "the Bridge's rooms and scenes didn't read";
    const list = roomScenes(gpa, a, io, app, &why) catch {
        return hub_out.send(.{ .room_scenes = .{ .list = &.{}, .err = why } });
    };
    hub_out.send(.{ .room_scenes = .{ .list = list, .err = null } });
}

/// The Bridge's address and key, by name only: the file holds the key.
fn credentials(a: Allocator, io: Io, app: *const config.Config, why: *[]const u8) !bridge_write.Credentials {
    const text = Io.Dir.cwd().readFileAlloc(io, app.bridge_file, a, .limited(MAX_FILE)) catch |err| {
        why.* = std.fmt.allocPrint(a, "couldn't read the Bridge's address and key ({t})", .{err}) catch "couldn't read the Bridge's key";
        return err;
    };
    return bridge_write.parseCredentials(a, text) catch |err| {
        why.* = "the Bridge's key file isn't right";
        return err;
    };
}

/// The Bridge's whole resource list, in `a`.
fn readResources(gpa: Allocator, a: Allocator, io: Io, app: *const config.Config, why: *[]const u8) ![]const u8 {
    const bridge = try credentials(a, io, app, why);
    const owned = bridge_write.resources(gpa, io, bridge) catch |err| {
        why.* = std.fmt.allocPrint(a, "couldn't read the Bridge ({t})", .{err}) catch "couldn't read the Bridge";
        return err;
    };
    defer gpa.free(owned);
    return a.dupe(u8, owned);
}

/// What the Bridge is and holds, read now.
fn sendBridge(gpa: Allocator, io: Io, app: *const config.Config, hub_out: *HubForward) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "the Bridge's resource list didn't read";
    const resources = readResources(gpa, a, io, app, &why) catch
        return hub_out.send(.{ .bridge_info = .{ .info = .{}, .err = why } });
    const info = bridge_info.parse(a, resources) catch
        return hub_out.send(.{ .bridge_info = .{ .info = .{}, .err = "the Bridge's resource list didn't read" } });
    hub_out.send(.{ .bridge_info = .{ .info = info, .err = null } });
}

/// Starts the Bridge's device search. What it finds reaches huelog's inventory as
/// an add; this says only whether the Bridge took the request.
fn search(gpa: Allocator, io: Io, app: *const config.Config, hub_out: *HubForward) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    hub_out.send(.{ .searched = searchErr(gpa, arena.allocator(), io, app) });
}

fn searchErr(gpa: Allocator, a: Allocator, io: Io, app: *const config.Config) ?[]const u8 {
    var why: []const u8 = "the Bridge's resource list didn't read";
    const resources = readResources(gpa, a, io, app, &why) catch return why;
    const info = bridge_info.parse(a, resources) catch return "the Bridge's resource list didn't read";
    const id = info.discovery_id orelse return "the Bridge has no device search";
    const bridge = credentials(a, io, app, &why) catch return why;
    var reply: bridge_write.Reply = .{};
    bridge_write.setDiscovery(gpa, io, bridge, id, bridge_info.SEARCH_BODY, &reply) catch |err| {
        var aw: Io.Writer.Allocating = .init(a);
        aw.writer.print("the Bridge refused it ({t}", .{err}) catch {};
        if (err == error.HttpError and reply.status != 0) {
            aw.writer.writeAll(", ") catch {};
            reply.describe(&aw.writer) catch {};
        }
        aw.writer.writeAll(")") catch {};
        return aw.written();
    };
    return null;
}

fn roomScenes(gpa: Allocator, a: Allocator, io: Io, app: *const config.Config, why: *[]const u8) ![]const room_scenes.RoomScenes {
    const resources = try readResources(gpa, a, io, app, why);
    const sc = try bridge_sensors.scenes(a, resources);
    const scenes = try a.alloc(room_scenes.Scene, sc.len);
    for (sc, scenes) |x, *y| y.* = .{ .id = x.id, .group_id = x.group_id, .name = x.name, .lit = x.lit };
    const g = try bridge_switches.groups(a, resources);
    const groups = try a.alloc(room_scenes.Group, g.groups.len);
    for (g.groups, groups) |x, *y| y.* = .{ .id = x.group.id, .name = x.group.name, .rtype = x.group.rtype, .devs = x.devs };
    return room_scenes.list(a, groups, scenes);
}

fn startRun(gpa: Allocator, io: Io, app: *const config.Config, r: anytype, hub_conn: *hub_client.Client, hub_out: *HubForward, child: *?job.Child) void {
    if (child.* != null or hub_out.run != null) return failRun(hub_out, "a run is already going");
    if (job.refusal(r.target, r.files)) |why| return failRun(hub_out, why);
    switch (r.target) {
        .power_on, .switches, .rooms, .sensors, .schedules, .actions => {
            child.* = job.Child.start(gpa, io, r.target, r.confirm, r.files[0].text) catch |err| {
                var buf: [80]u8 = undefined;
                return failRun(hub_out, std.fmt.bufPrint(&buf, "couldn't start dmain ({t})", .{err}) catch "couldn't start dmain");
            };
        },
        .hub => {
            // A run can arrive before the loop's first try at hub's socket.
            if (hub_conn.fd() == -1) {
                hub_conn.last_try_ms = std.math.minInt(i64) / 2;
                hub_conn.tick(io, hub_out);
            }
            if (hub_conn.fd() == -1) return failRun(hub_out, "hub's console isn't answering");
            job.stage(io, app.hub_stage, r.files) catch |err| {
                var buf: [120]u8 = undefined;
                return failRun(hub_out, std.fmt.bufPrint(&buf, "couldn't put the files in {s} ({t})", .{ app.hub_stage, err }) catch "couldn't stage the files");
            };
            var buf: [hub_client.MAX_COMMAND]u8 = undefined;
            const command = std.fmt.bufPrint(&buf, "adopt {s}{s}", .{ std.fs.path.basename(app.hub_stage), if (r.confirm) " confirm" else "" }) catch unreachable;
            hub_out.run = .{};
            hub_conn.send(gpa, io, command, hub_out);
        },
    }
}

fn failRun(hub_out: *HubForward, why: []const u8) void {
    hub_out.runLine(why);
    hub_out.send(.{ .run_end = false });
}

const Feed = struct {
    dir: ?Io.Dir,
    follower: ?reader.Follower = null,
    forward: Forward,

    /// Yesterday at once, as `dmain admin` reads it locally, then today as it grows.
    fn open(gpa: Allocator, io: Io, path: []const u8, src: link.Source, out: *Io.Writer, now: Io.Timestamp) Feed {
        var feed: Feed = .{ .dir = null, .forward = .{ .out = out, .src = src } };
        feed.dir = Io.Dir.cwd().openDir(io, path, .{}) catch return feed;
        const yesterday = Day.of(.fromNanoseconds(now.toNanoseconds() - 24 * 3600 * std.time.ns_per_s));
        _ = reader.replay(gpa, io, feed.dir.?, yesterday, &feed.forward) catch {};
        feed.follower = reader.Follower.init(feed.dir.?, Day.of(now));
        return feed;
    }

    fn poll(self: *Feed, gpa: Allocator, io: Io, now: Io.Timestamp) void {
        if (self.follower) |*f| _ = f.poll(gpa, io, Day.of(now), &self.forward) catch {};
    }

    fn close(self: *Feed, gpa: Allocator, io: Io) void {
        if (self.follower) |*f| f.deinit(gpa);
        if (self.dir) |d| d.close(io);
    }
};

fn sendFiles(gpa: Allocator, io: Io, app: *const config.Config, sent: *link.Sent, out: *Io.Writer) !void {
    inline for (@typeInfo(link.FileId).@"enum".field_names) |name| {
        const id = @field(link.FileId, name);
        const path = @field(app, name);
        const text: ?[]u8 = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(MAX_FILE)) catch |err| blk: {
            if (sent.changed(id, null, @errorName(err)))
                try link.write(out, .{ .file = .{ .id = id, .path = path, .text = null, .err = @errorName(err) } });
            break :blk null;
        };
        if (text) |t| {
            defer gpa.free(t);
            if (sent.changed(id, t, null))
                try link.write(out, .{ .file = .{ .id = id, .path = path, .text = t, .err = null } });
        }
    }
}

/// The other end shows stderr's last line as the reason, so that's all there is.
fn refuse(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("dmain agent: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn run(gpa: Allocator, io: Io, app: *const config.Config, out: *Io.Writer) !void {
    try link.write(out, .{ .agent = link.VERSION });
    try out.flush();

    var lines: link.Lines = .{};
    defer lines.deinit(gpa);
    var hello = false;
    var last_heard_ms = Io.Timestamp.now(io, .awake).toMilliseconds();
    var last_ping_ms = last_heard_ms;
    var last_load_ms: i64 = 0;

    var sent: link.Sent = .{};
    var hub_conn: hub_client.Client = .{ .path = app.hub_socket };
    defer hub_conn.deinit(gpa, io);
    var hub_out: HubForward = .{ .out = out };
    var child: ?job.Child = null;
    defer if (child) |*c| c.deinit(gpa);
    var journal: ?job.Child = null;
    defer if (journal) |*j| j.stop(gpa, io);
    var journal_out: JournalForward = .{ .hub_out = &hub_out };
    var services_hash: u64 = 0;
    var last_services_ms: i64 = std.math.minInt(i64) / 2;
    var last_follow_ms: i64 = 0;
    var hue: ?Feed = null;
    var hub: ?Feed = null;
    defer if (hue) |*f| f.close(gpa, io);
    defer if (hub) |*f| f.close(gpa, io);

    while (true) {
        // Waiting on stdin is the loop's tick. A hang-up wakes it at once,
        // whatever it was asked to wait for, and reads as the end.
        var fds = [_]posix.pollfd{
            .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = hub_conn.fd(), .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = if (child) |*c| c.outFd() else -1, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = if (child) |*c| c.errFd() else -1, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = if (journal) |*j| j.outFd() else -1, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = if (journal) |*j| j.errFd() else -1, .events = posix.POLL.IN, .revents = 0 },
        };
        _ = try posix.poll(&fds, TICK_MS);
        if (fds[1].revents != 0) hub_conn.readable(gpa, io, &hub_out);
        if (child) |*c| {
            if (fds[2].revents != 0) c.readable(gpa, false, &hub_out);
            if (fds[3].revents != 0) c.readable(gpa, true, &hub_out);
            if (c.finish(io)) |ok| {
                c.deinit(gpa);
                child = null;
                hub_out.send(.{ .run_end = ok });
            }
        }
        if (journal) |*j| {
            if (fds[4].revents != 0) j.readable(gpa, false, &journal_out);
            if (fds[5].revents != 0) j.readable(gpa, true, &journal_out);
            if (j.finish(io) != null) {
                j.deinit(gpa);
                journal = null;
                hub_out.send(.{ .journal_line = "dmain agent: the journal stopped" });
            }
        }
        if (fds[0].revents != 0) {
            var buf: [4096]u8 = undefined;
            const n = posix.read(posix.STDIN_FILENO, &buf) catch 0;
            if (n == 0) return;
            try lines.append(gpa, buf[0..n]);
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            while (lines.next()) |line| {
                last_heard_ms = Io.Timestamp.now(io, .awake).toMilliseconds();
                const m = link.parse(arena.allocator(), line) catch refuse("that isn't the admin link", .{});
                switch (m) {
                    .admin => |v| {
                        if (v != link.VERSION) refuse("this end speaks link v{d}, admin v{d}. Deploy both", .{ link.VERSION, v });
                        hello = true;
                    },
                    .ping => {},
                    .hub => |command| if (hello) {
                        // hub's reply to a run's `adopt` mustn't mix with another command's.
                        if (hub_out.run != null) {
                            hub_out.hubLine("a run is using hub's console: try again when it's done");
                            hub_out.hubDone();
                        } else hub_conn.send(gpa, io, command, &hub_out);
                    },
                    .run => |r| if (hello) startRun(gpa, io, app, r, &hub_conn, &hub_out, &child),
                    .journal => |unit| if (hello) {
                        if (journal) |*j| j.stop(gpa, io);
                        journal = null;
                        var mbuf: [64]u8 = undefined;
                        var abuf: [8][]const u8 = undefined;
                        journal = job.Child.spawn(io, services.journalArgv(&abuf, services.journalMatch(&mbuf, unit))) catch |err| blk: {
                            var why: [80]u8 = undefined;
                            hub_out.send(.{ .journal_line = std.fmt.bufPrint(&why, "dmain agent: couldn't follow the journal ({t})", .{err}) catch "dmain agent: couldn't follow the journal" });
                            break :blk null;
                        };
                    },
                    .identify => |dev| if (hello) identify(gpa, io, app, dev, &hub_out),
                    .scenes => if (hello) sendScenes(gpa, io, app, &hub_out),
                    .forget => |dev| if (hello) forget(gpa, io, app, dev, &hub_out),
                    .bridge => if (hello) sendBridge(gpa, io, app, &hub_out),
                    .search => if (hello) search(gpa, io, app, &hub_out),
                    .restart => |unit| if (hello) {
                        restart(gpa, io, unit, &hub_out);
                        // So the next state, showing how it went, isn't 5 s away.
                        last_services_ms = std.math.minInt(i64) / 2;
                    },
                    else => refuse("admin sent what only an agent sends", .{}),
                }
            }
        }

        const now_ms = Io.Timestamp.now(io, .awake).toMilliseconds();
        if (now_ms - last_heard_ms > link.SILENCE_MS) return;
        // Nothing is sent before the other end has said who it is.
        if (!hello) continue;

        if (now_ms - last_load_ms >= RELOAD_MS) {
            last_load_ms = now_ms;
            try sendFiles(gpa, io, app, &sent, out);
        }
        hub_conn.tick(io, &hub_out);
        if (now_ms - last_services_ms >= SERVICES_MS) {
            last_services_ms = now_ms;
            sendServices(gpa, io, &services_hash, &hub_out);
        }
        const now = Io.Timestamp.now(io, .real);
        if (hue == null) {
            hue = .open(gpa, io, app.hue_log, .hue, out, now);
            hub = .open(gpa, io, app.hub_log, .hub, out, now);
        }
        // hub's console can wake the loop many times a second; the logs needn't.
        if (now_ms - last_follow_ms >= TICK_MS) {
            last_follow_ms = now_ms;
            hue.?.poll(gpa, io, now);
            hub.?.poll(gpa, io, now);
        }
        if (hue.?.forward.failed or hub.?.forward.failed or hub_out.failed) return error.WriteFailed;
        if (now_ms - last_ping_ms >= link.PING_MS) {
            last_ping_ms = now_ms;
            try link.write(out, .ping);
        }
        try out.flush();
    }
}
