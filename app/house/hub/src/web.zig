//! The LAN web interface: one embedded page and a tiny JSON API,
//! LAN bind only, no auth or TLS. The listener, connection tasks, preconnect
//! timeout and request framing are `lib/httpd`'s (moved there 2026-11-04,
//! when a second application needed them); this file is the handler.
//!
//! Split like `sched.zig` split wall-clock IO from pure decision logic:
//!   - JSON (de)serialization and target/action resolution
//!     (`resolveAction`, `buildStatusJson`) are pure and unit-tested below
//!     against `Io.Reader.fixed`/`Io.Writer.fixed` — no real socket needed.
//!   - One end-to-end test below (`std.Io.Threaded.init`, a real loopback
//!     connection) exercises the network glue too, without needing the
//!     radio.
//!
//! Concurrency: `Server` is the first genuine second consumer running
//! concurrently with the engine's main poll loop (the TUI and console are
//! both synchronous, same thread as the loop). Two rules keep that safe:
//!   - reads go through `model.Registry.snapshotDevices` (mutex-guarded
//!     arena dupe) — never live registry memory: readers get arena
//!     deep-clones.
//!   - writes never touch the radio directly — `Server` has no
//!     `*Coordinator`. A resolved `ActionRequest` is pushed onto
//!     `Server`'s own mutex-guarded queue; `main.zig`'s tick loop drains
//!     it into `Coordinator.enqueueAction`, the same "resolve here, send
//!     from the engine loop" split `sched.zig` already uses for fired
//!     schedules.
//!   `config.zig`'s `Config` needs no mutex of its own: a config is never
//!   mutated once published. A reload swaps a whole new one through
//!   `Live`, so a connection task reads one consistent config per call.
const std = @import("std");
const Io = std.Io;
const httpd = @import("httpd");
const ConfigMod = @import("config");
const Config = ConfigMod.Config;
const Model = @import("model");
const Registry = Model.Registry;
const Device = Model.Device;
const Ieee = @import("ieee");

/// `--port` changes it, for a host with something else on this port.
pub const DEFAULT_PORT: u16 = 8080;

const INDEX_HTML = @embedFile("web_index.html");

/// Cap on a pending request body — this API only ever needs a tiny
/// `{"target":...,"action":...}` object; anything bigger is rejected
/// outright rather than allocated. Must stay comfortably under
/// `lib/httpd`'s 4 KB read buffer (`take` asserts `n <= buffer capacity`).
const MAX_BODY = 1024;

/// A device/group action resolved (pure, no I/O) from an HTTP request.
/// Deliberately doesn't carry the original target *name* — `main.zig`'s
/// drain loop can always re-derive a display name from `target` via
/// `config.nameFor`/`groupNameFor` for its report line, so this stays
/// plain data with no arena/allocator lifetime to manage across the
/// queue hand-off.
pub const ActionRequest = struct {
    target: ConfigMod.Target,
    action: WebAction,
};

/// What a web POST can ask for. `radio` wraps the rules-vocabulary actions
/// and goes through `Coordinator.enqueueAction` like every other radio
/// write; `ack` (the alert-acknowledge button) is a pure
/// model operation, routed by `main.zig`'s drain straight to
/// `model.ackAlert` without ever touching the engine queue. A union rather
/// than adding "ack" to `ConfigMod.Action` because that enum is also
/// rules.json/schedule.json vocabulary, and "ack" in a rule would be
/// meaningless.
pub const WebAction = union(enum) {
    radio: ConfigMod.Action,
    ack,
};

/// Bounds `Server.queue`'s growth — a real LAN control panel issues one
/// action at a time; this is a safety cap against a stuck/hostile client
/// hammering `POST /api/action` faster than `main.zig`'s tick loop drains
/// it, not an expected depth. Mirrors `engine.zig`'s
/// `PENDING_ACTIONS_CAP` in spirit (fixed cap, drop-and-report-false
/// beyond it) though this queue is growable up to the cap rather than a
/// fixed array, since unlike `pending_actions` it's written from a
/// different task than it's read from and sizing it to the single-shot
/// "one rule event, several targets" case doesn't apply here.
pub const MAX_QUEUED_ACTIONS = 32;

/// Owns the listening socket and the mutex-guarded hand-off queue to
/// `main.zig`'s engine loop. Never touches `Ezsp`/`Coordinator` — see the
/// module doc comment for why that split matters.
pub const Server = struct {
    gpa: std.mem.Allocator,
    model: *Registry,
    live: *const ConfigMod.Live,
    mutex: Io.Mutex = .init,
    queue: std.ArrayList(ActionRequest) = .empty,

    pub fn init(gpa: std.mem.Allocator, model: *Registry, live: *const ConfigMod.Live) Server {
        return .{ .gpa = gpa, .model = model, .live = live };
    }

    pub fn deinit(self: *Server) void {
        self.queue.deinit(self.gpa);
    }

    /// Pushes a resolved action onto the queue, silently dropping it once
    /// `MAX_QUEUED_ACTIONS` is reached or on allocation failure — a
    /// dropped web command just means the user's button press didn't
    /// take; retrying is cheap and safe (on/off/toggle are all
    /// idempotent-ish from a user's perspective), not worth failing the
    /// whole request over.
    fn pushAction(self: *Server, io: Io, req: ActionRequest) void {
        self.mutex.lock(io) catch return;
        defer self.mutex.unlock(io);
        if (self.queue.items.len >= MAX_QUEUED_ACTIONS) return;
        self.queue.append(self.gpa, req) catch {};
    }

    /// Drains every queued action into `buf` (bounded by its length,
    /// mirroring `engine.zig`'s fixed-size batch drains in `main.zig`)
    /// for the caller to resolve into `Coordinator.enqueueAction` calls.
    /// Must only be called from the single engine-loop thread — enqueuing
    /// (via `pushAction`, from connection tasks) is the concurrent side
    /// of this hand-off, draining is not.
    pub fn drain(self: *Server, io: Io, buf: []ActionRequest) []ActionRequest {
        self.mutex.lock(io) catch return buf[0..0];
        defer self.mutex.unlock(io);
        const n = @min(buf.len, self.queue.items.len);
        @memcpy(buf[0..n], self.queue.items[0..n]);
        const remaining = self.queue.items.len - n;
        std.mem.copyForwards(ActionRequest, self.queue.items[0..remaining], self.queue.items[n..]);
        self.queue.shrinkRetainingCapacity(remaining);
        return buf[0..n];
    }

    /// `lib/httpd`'s handler entry point: one parsed request.
    pub fn handle(self: *Server, io: Io, arena: std.mem.Allocator, req: httpd.Request, rd: *Io.Reader, wr: *Io.Writer) !void {
        return handleRequest(self, io, arena, req, rd, wr);
    }
};

const ActionBody = struct {
    target: []const u8,
    action: []const u8,
};

pub const ResolveError = error{ InvalidJson, UnknownTarget, UnsupportedAction };

/// Parses a `{"target":"...","action":"..."}` body and resolves it
/// against `config` — pure config lookup, no network, safe to call
/// directly from a connection task. Only on/off/toggle are exposed over
/// the web API: `level_up`/`level_down` are gesture-phased (they need a
/// press/hold/release stream `engine.zig`'s `Phase` models) which a
/// single HTTP request can't carry — matches the requirement of "status +
/// on/off control initially".
pub fn resolveAction(config: *const Config, arena: std.mem.Allocator, body: []const u8) ResolveError!ActionRequest {
    const parsed = std.json.parseFromSliceLeaky(ActionBody, arena, body, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidJson;
    const target = config.resolveTargetName(parsed.target) orelse return error.UnknownTarget;
    if (std.mem.eql(u8, parsed.action, "ack")) {
        // Acknowledging a group is meaningless — alerts latch per device.
        if (target != .device) return error.UnsupportedAction;
        return .{ .target = target, .action = .ack };
    }
    const action = ConfigMod.parseAction(parsed.action) orelse return error.InvalidJson;
    switch (action) {
        .level_up, .level_down => return error.UnsupportedAction,
        .on, .off, .toggle => {},
    }
    return .{ .target = target, .action = .{ .radio = action } };
}

const DeviceStatus = struct {
    name: []const u8,
    room: []const u8,
    ieee: []const u8,
    nwk: []const u8,
    joined: bool,
    // Discovered capability endpoints -- the embedded page uses these
    // (not the live readings below) to sort a device into the motion/
    // lights/alerts sections, since they're set once at discovery time
    // rather than waiting for a first live reading to arrive.
    onoff_endpoint: ?u8,
    occupancy_endpoint: ?u8,
    ias_zone_endpoint: ?u8,
    battery_pct: ?u8,
    temperature_centi: ?i16,
    illuminance_raw: ?u32,
    occupancy: ?bool,
    on: ?bool,
    alert: ?bool,
    // Alert latch: shown until acknowledged, however
    // brief the trip was. `_at_s` is epoch seconds; the page formats it
    // in the browser's own local time.
    alert_latched: bool,
    alert_latched_at_s: i64,
    last_seen_ms: i64,
};

const GroupStatus = struct {
    name: []const u8,
    group_id: u16,
    members: []const []const u8,
};

const StatusBody = struct {
    devices: []DeviceStatus,
    groups: []GroupStatus,
};

/// Builds the `/api/status` JSON body in `arena` from a device snapshot
/// (`Registry.snapshotDevices` — already mutex-cloned, so this never
/// touches live registry memory) and `config` (never mutated once published —
/// see the module doc comment). Pure otherwise, unit-tested below without
/// a real registry or socket. Unconfigured devices get `name = ""`,
/// `room = ""` — same "unconfigured" convention `screens.zig`'s config
/// screen uses; the embedded page shows the bare IEEE for those and skips
/// their action buttons (an unconfigured device isn't `resolveTargetName`-
/// reachable anyway).
fn buildStatusJson(arena: std.mem.Allocator, config: *const Config, devices: []const Device) ![]const u8 {
    const rows = try arena.alloc(DeviceStatus, devices.len);
    for (devices, 0..) |d, i| {
        rows[i] = .{
            .name = config.nameFor(d.ieee) orelse "",
            .room = config.roomFor(d.ieee),
            .ieee = try Ieee.formatReversedAlloc(arena, &d.ieee),
            .nwk = try arena.print("0x{x:0>4}", .{d.nwk}),
            .joined = d.joined,
            .onoff_endpoint = d.onoff_endpoint,
            .occupancy_endpoint = d.occupancy_endpoint,
            .ias_zone_endpoint = d.ias_zone_endpoint,
            .battery_pct = d.battery_pct,
            .temperature_centi = d.temperature_centi,
            .illuminance_raw = d.illuminance_raw,
            .occupancy = d.occupancy,
            .on = d.on,
            .alert = d.alert,
            .alert_latched = d.alert_latched,
            .alert_latched_at_s = d.alert_latched_at_s,
            .last_seen_ms = d.last_seen_ms,
        };
    }
    const groups = try arena.alloc(GroupStatus, config.groups.len);
    for (config.groups, 0..) |g, i| groups[i] = .{ .name = g.name, .group_id = g.group_id, .members = g.members };

    var aw: Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(StatusBody{ .devices = rows, .groups = groups }, .{}, &aw.writer);
    return aw.writer.buffered();
}

/// Routes one request to its handler. The only state this touches besides
/// the wire is `server.model`/`server.live` (read-only per the module
/// doc comment) and `server.pushAction` (the one write path, itself
/// mutex-guarded) — never `server.gpa` for anything long-lived, everything
/// per-request is `arena`-scoped and freed when the connection closes.
fn handleRequest(server: *Server, io: Io, arena: std.mem.Allocator, head: httpd.Request, rd: *Io.Reader, wr: *Io.Writer) !void {
    if (std.mem.eql(u8, head.method, "GET") and std.mem.eql(u8, head.path, "/")) {
        return httpd.respond(wr, 200, "text/html; charset=utf-8", INDEX_HTML);
    }
    if (std.mem.eql(u8, head.method, "GET") and std.mem.eql(u8, head.path, "/api/status")) {
        const devices = try server.model.snapshotDevices(io, arena);
        const body = try buildStatusJson(arena, server.live.get(), devices);
        return httpd.respond(wr, 200, "application/json", body);
    }
    if (std.mem.eql(u8, head.method, "POST") and std.mem.eql(u8, head.path, "/api/action")) {
        if (head.content_length == 0 or head.content_length > MAX_BODY) {
            return httpd.respondJsonError(arena, wr, 400, "missing or oversized body");
        }
        const body = rd.take(head.content_length) catch {
            return httpd.respondJsonError(arena, wr, 400, "truncated body");
        };
        const action = resolveAction(server.live.get(), arena, body) catch |err| {
            const msg: []const u8 = switch (err) {
                error.InvalidJson => "invalid JSON body -- expected {\"target\":...,\"action\":...}",
                error.UnknownTarget => "unknown target -- see devices.json/groups.json",
                error.UnsupportedAction => "unsupported action -- only on/off/toggle",
            };
            return httpd.respondJsonError(arena, wr, 400, msg);
        };
        server.pushAction(io, action);
        return httpd.respond(wr, 200, "application/json", "{\"ok\":true}");
    }
    return httpd.respondJsonError(arena, wr, 404, "not found");
}

// ── Tests ───────────────────────────────────────────────────────────

/// A request as `lib/httpd` would hand it over, from the text a client sent.
fn testRequest(rd: *Io.Reader) !httpd.Request {
    const h = try httpd.parseRequestHead(rd);
    return .{ .method = h.method, .path = h.path, .content_length = h.content_length, .peer = .{ .ip4 = Io.net.Ip4Address.loopback(0) } };
}

test "resolveAction: resolves a device, rejects gesture actions and unknown targets" {
    const gpa = std.testing.allocator;
    var cfg = Config.init(gpa);
    defer cfg.deinit();
    const devices = [_]ConfigMod.DeviceEntry{.{ .name = "bulb1", .ieee = "00:17:88:01:08:d1:40:dd" }};
    cfg.devices = @constCast(&devices);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const req = try resolveAction(&cfg, arena.allocator(), "{\"target\":\"bulb1\",\"action\":\"on\"}");
    try std.testing.expectEqual(ConfigMod.Action.on, req.action.radio);
    try std.testing.expectEqualSlices(u8, &(try Ieee.parseReversed("00:17:88:01:08:d1:40:dd")), &req.target.device);

    // ack is a device-only model action, routed as its
    // own union arm rather than through the radio path.
    const ack = try resolveAction(&cfg, arena.allocator(), "{\"target\":\"bulb1\",\"action\":\"ack\"}");
    try std.testing.expectEqual(WebAction.ack, ack.action);

    try std.testing.expectError(error.UnsupportedAction, resolveAction(&cfg, arena.allocator(), "{\"target\":\"bulb1\",\"action\":\"level_up\"}"));
    try std.testing.expectError(error.UnknownTarget, resolveAction(&cfg, arena.allocator(), "{\"target\":\"ghost\",\"action\":\"on\"}"));
    try std.testing.expectError(error.InvalidJson, resolveAction(&cfg, arena.allocator(), "{\"target\":\"bulb1\",\"action\":\"explode\"}"));
    try std.testing.expectError(error.InvalidJson, resolveAction(&cfg, arena.allocator(), "not json"));
}

test "resolveAction: resolves a group target" {
    const gpa = std.testing.allocator;
    var cfg = Config.init(gpa);
    defer cfg.deinit();
    const members = [_][]const u8{"bulb1"};
    const groups = [_]ConfigMod.GroupEntry{.{ .name = "landing", .group_id = 7, .members = &members }};
    cfg.groups = @constCast(&groups);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const req = try resolveAction(&cfg, arena.allocator(), "{\"target\":\"landing\",\"action\":\"toggle\"}");
    try std.testing.expectEqual(@as(u16, 7), req.target.group);
    try std.testing.expectEqual(ConfigMod.Action.toggle, req.action.radio);
    // A group can't be acked — alerts latch per device.
    try std.testing.expectError(error.UnsupportedAction, resolveAction(&cfg, arena.allocator(), "{\"target\":\"landing\",\"action\":\"ack\"}"));
}

test "buildStatusJson: includes configured name/room and unconfigured devices" {
    const gpa = std.testing.allocator;
    var cfg = Config.init(gpa);
    defer cfg.deinit();
    const devices = [_]ConfigMod.DeviceEntry{.{ .name = "bulb1", .ieee = "00:17:88:01:08:d1:40:dd", .room = "kitchen" }};
    cfg.devices = @constCast(&devices);
    const members = [_][]const u8{"bulb1"};
    const groups = [_]ConfigMod.GroupEntry{.{ .name = "landing", .group_id = 7, .members = &members }};
    cfg.groups = @constCast(&groups);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const live: [2]Device = .{
        .{ .ieee = try Ieee.parseReversed("00:17:88:01:08:d1:40:dd"), .nwk = 0xD714, .battery_pct = 87, .onoff_endpoint = 11, .on = true },
        // unconfigured, and standing in for a motion+alerting sensor at
        // once (just to exercise both new discovered-endpoint fields in
        // one device rather than adding a third).
        .{ .ieee = .{ 9, 9, 9, 9, 9, 9, 9, 9 }, .nwk = 0x0042, .occupancy_endpoint = 2, .ias_zone_endpoint = 3, .alert = true },
    };
    const json = try buildStatusJson(arena.allocator(), &cfg, &live);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"bulb1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"room\":\"kitchen\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"battery_pct\":87") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"onoff_endpoint\":11") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"on\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"occupancy_endpoint\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ias_zone_endpoint\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"alert\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"landing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"group_id\":7") != null);
    // Unconfigured device: empty name/room, not omitted from the list.
    try std.testing.expect(std.mem.indexOf(u8, json, "09:09:09:09:09:09:09:09") != null);
}

test "handleRequest: unknown path is a 404 JSON error" {
    const gpa = std.testing.allocator;
    var model = Registry.init(gpa);
    defer model.deinit();
    var cfg = Config.init(gpa);
    defer cfg.deinit();
    var live = ConfigMod.Live.init(&cfg);
    var server = Server.init(gpa, &model, &live);
    defer server.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var rd = Io.Reader.fixed("GET /nope HTTP/1.1\r\n\r\n");
    var out_buf: [1024]u8 = undefined;
    var wr = Io.Writer.fixed(&out_buf);

    // Any real `Io` works here (single-threaded is fine: `handleRequest`
    // only touches the mutex, never `async`/timers) — reuse `model.zig`'s
    // test helper shape rather than pulling in a full `Threaded` instance
    // for a synchronous-only path.
    const S = struct {
        var threaded: std.Io.Threaded = .init_single_threaded;
    };
    try handleRequest(&server, S.threaded.io(), arena.allocator(), try testRequest(&rd), &rd, &wr);

    const resp = wr.buffered();
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 404 Not Found\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"error\"") != null);
}

test "handleRequest: POST /api/action pushes onto the queue and GET /api/status reflects it" {
    const gpa = std.testing.allocator;
    var model = Registry.init(gpa);
    defer model.deinit();
    var cfg = Config.init(gpa);
    defer cfg.deinit();
    const devices = [_]ConfigMod.DeviceEntry{.{ .name = "bulb1", .ieee = "00:17:88:01:08:d1:40:dd" }};
    cfg.devices = @constCast(&devices);
    var live = ConfigMod.Live.init(&cfg);
    var server = Server.init(gpa, &model, &live);
    defer server.deinit();

    const S = struct {
        var threaded: std.Io.Threaded = .init_single_threaded;
    };
    const io = S.threaded.io();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const body = "{\"target\":\"bulb1\",\"action\":\"on\"}";
    const req_text = try arena.allocator().print("POST /api/action HTTP/1.1\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    var rd = Io.Reader.fixed(req_text);
    var out_buf: [1024]u8 = undefined;
    var wr = Io.Writer.fixed(&out_buf);

    try handleRequest(&server, io, arena.allocator(), try testRequest(&rd), &rd, &wr);
    try std.testing.expect(std.mem.startsWith(u8, wr.buffered(), "HTTP/1.1 200 OK\r\n"));

    var drained: [4]ActionRequest = undefined;
    const got = server.drain(io, &drained);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual(ConfigMod.Action.on, got[0].action.radio);
    try std.testing.expectEqualSlices(u8, &(try Ieee.parseReversed("00:17:88:01:08:d1:40:dd")), &got[0].target.device);
}

test "Server: GET /api/status and POST /api/action over a real TCP loopback" {
    // The one genuinely end-to-end test: a real `Threaded` Io (not
    // `init_single_threaded` — that variant has "no actual async/
    // thread-pool machinery", per model.zig's `testIo` doc comment, so
    // `listenTask`'s accept loop would never run concurrently with this
    // test's own client connection) driving `lib/httpd`'s listener as a real
    // `io.async` task against a real loopback socket. Proves the actual
    // network glue (`lib/httpd`'s connection task, header/body framing, `Connection: close`)
    // this module's other tests deliberately bypass by calling
    // `handleRequest` directly.
    const TEST_PORT: u16 = 18099;
    const gpa = std.testing.allocator;

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var model = Registry.init(gpa);
    defer model.deinit();
    _ = try model.upsert(io, try Ieee.parseReversed("00:17:88:01:08:d1:40:dd"), 0xD714);

    var cfg = Config.init(gpa);
    defer cfg.deinit();
    const devices = [_]ConfigMod.DeviceEntry{.{ .name = "bulb1", .ieee = "00:17:88:01:08:d1:40:dd", .room = "kitchen" }};
    cfg.devices = @constCast(&devices);

    var live = ConfigMod.Live.init(&cfg);
    var server = Server.init(gpa, &model, &live);
    defer server.deinit();

    var http = httpd.Server(Server).init(gpa, &server, .{ .port = TEST_PORT });
    var listen_task = io.async(httpd.Server(Server).listenTask, .{ &http, io });
    defer {
        http.stop(io);
        _ = listen_task.cancel(io);
    }

    const addr: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(TEST_PORT) };
    var connect_tries: u8 = 0;
    var status_stream: Io.net.Stream = while (connect_tries < 50) : (connect_tries += 1) {
        break addr.connect(io, .{ .mode = .stream }) catch {
            Io.sleep(io, Io.Duration.fromMilliseconds(10), .real) catch {};
            continue;
        };
    } else return error.ServerNeverCameUp;

    {
        defer status_stream.close(io);
        var wbuf: [512]u8 = undefined;
        var wr = status_stream.writer(io, &wbuf);
        try wr.interface.writeAll("GET /api/status HTTP/1.1\r\nHost: x\r\n\r\n");
        try wr.interface.flush();

        var rbuf: [8192]u8 = undefined;
        var rd = status_stream.reader(io, &rbuf);
        const resp = try rd.interface.allocRemaining(gpa, .limited(8192));
        defer gpa.free(resp);

        try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
        try std.testing.expect(std.mem.indexOf(u8, resp, "\"name\":\"bulb1\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp, "\"room\":\"kitchen\"") != null);
    }

    var action_stream = try addr.connect(io, .{ .mode = .stream });
    defer action_stream.close(io);
    const body = "{\"target\":\"bulb1\",\"action\":\"off\"}";
    var wbuf: [512]u8 = undefined;
    var wr = action_stream.writer(io, &wbuf);
    try wr.interface.print("POST /api/action HTTP/1.1\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    try wr.interface.flush();

    var rbuf: [4096]u8 = undefined;
    var rd = action_stream.reader(io, &rbuf);
    const resp = try rd.interface.allocRemaining(gpa, .limited(4096));
    defer gpa.free(resp);
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":true") != null);

    var drained: [4]ActionRequest = undefined;
    const got = server.drain(io, &drained);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual(ConfigMod.Action.off, got[0].action.radio);
}

test "Semantic Check" {
    std.testing.refAllDecls(@This());
}
