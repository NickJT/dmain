//! The admin link: one JSON object a line between an agent beside the logs and
//! the admin screens on another machine, over a pipe such as `ssh`.
//!
//! The agent sends the house log lines unparsed and the settings files whole, so
//! the screens fold the same records a local reader would, and draw the same rows.
//!
//! | From | Message | |
//! |---|---|---|
//! | agent | `{"agent":V}` | first line: the link version it speaks |
//! | admin | `{"admin":V}` | first line, the same |
//! | agent | `{"src":"hue","line":"…"}` | one house log line, as written |
//! | agent | `{"file":"power_on","path":"…","text":"…"}` | a file whole, when it changes |
//! | agent | `{"file":"power_on","path":"…","error":"FileNotFound"}` | a file that wouldn't read |
//! | both | `{"ping":true}` | still there. Each side gives up on a quiet other |
//! | admin | `{"hub":"list"}` | one line for hub's console, passed on as typed |
//! | agent | `{"hub_line":"…"}` | a line from hub's console: its log, and what a command printed |
//! | agent | `{"hub_done":true}` | the last command has finished |
//! | agent | `{"hub_up":true}`, `{"hub_down":"…"}` | hub's console answers, or why it doesn't |
//!
//! | admin | `{"run":"power_on","confirm":false,"files":[{"name":"…","text":"…"}]}` | check, or with `confirm` apply, these wanted files |
//! | agent | `{"run_line":"…"}` | what the run printed |
//! | agent | `{"run_end":true}` | the run has finished, and whether it succeeded |
//! | agent | `{"services":[{"unit":"hub","active":"active",…}]}` | each service's state, when it changes |
//! | admin | `{"journal":"hub"}` | follow this service's journal instead of any other |
//! | agent | `{"journal_line":"…"}` | a line of it |
//! | admin | `{"restart":"hub"}` | restart it, asked for with a typed confirm |
//! | agent | `{"restarted":"hub"}`, with `"error"` if systemd refused | the restart is queued |
//! | admin | `{"identify":"00:17:88:…"}` | ask the Bridge to have this device show itself |
//! | agent | `{"identified":"00:17:88:…"}`, with `"error"` if it couldn't | the Bridge took it |
//! | admin | `{"forget":"00:17:88:…"}` | delete this device on the Bridge, which un-joins it |
//! | agent | `{"forgot":"00:17:88:…"}`, with `"error"` if it couldn't | the Bridge took it |
//! | admin | `{"bridge":true}` | what the Bridge is and holds, read from it now |
//! | agent | `{"bridge_info":{…}}`, with `"error"` if it couldn't | that |
//! | admin | `{"search":true}` | start the Bridge's device search |
//! | agent | `{"searched":true}`, with `"error"` if it couldn't | the Bridge took it |
//! | admin | `{"scenes":true}` | each Bridge room's scenes, read from the Bridge now |
//! | agent | `{"room_scenes":[{"room":"…","scenes":["…"]}]}`, with `"error"` if it couldn't | them |
//!
//! **Requests are few, and each is checked where it lands.** A console line goes
//! to hub as typed, so hub's own refusals and its `confirm` words still decide what
//! runs. A run takes the wanted files' contents, never a path, so what is checked is
//! the copy that was sent. A service is one of three by name, never a unit string.
//! A device to identify is an IEEE address or a Bridge id, refused in any other shape.
//!
//! **A version mismatch ends the link at the first line**: the two ends are
//! deployed separately, and a reader guessing at the other's fields draws a
//! house that isn't there. Unknown fields are refused for the same reason.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
pub const RoomScenes = @import("room_scenes.zig").RoomScenes;
pub const BridgeInfo = @import("bridge_info").Info;

pub const VERSION: u32 = 10;

/// Longer than any settings file, which is the longest line sent.
pub const MAX_LINE = 4 << 20;

/// How often each end pings, and how long it waits for the other before giving up.
pub const PING_MS: i64 = 15_000;
pub const SILENCE_MS: i64 = 60_000;

pub const Source = enum { hue, hub };

/// The files the screens read. None of them holds a secret, and nothing else is
/// sent: the agent can't be asked for a file by name.
pub const FileId = enum { hue_settings, hub_settings, power_on, hue_schedules, hub_schedules, hub_network };

/// What a run checks or applies: dmain's two wanted files, or hub's config.
pub const Target = enum { power_on, switches, hub, rooms, sensors, schedules, actions };

pub const NamedFile = struct { name: []const u8, text: []const u8 };

/// The house's services, each a systemd user unit of the same name.
pub const Unit = enum { huelog, hub, dmain };

pub const Service = struct {
    unit: Unit,
    /// systemd's words: `active`, `running`, `enabled` and the rest.
    active: []const u8,
    sub: []const u8,
    enabled: []const u8,
    /// When it last became active, unix seconds.
    since: ?i64 = null,
    restarts: u32 = 0,
    /// Its binary was replaced after it started, so it isn't running what's on disk.
    newer_binary: bool = false,
};

pub const Message = union(enum) {
    agent: u32,
    admin: u32,
    ping,
    log: struct { src: Source, line: []const u8 },
    file: struct { id: FileId, path: []const u8, text: ?[]const u8, err: ?[]const u8 },
    hub: []const u8,
    hub_line: []const u8,
    hub_done,
    hub_up,
    hub_down: []const u8,
    run: struct { target: Target, confirm: bool, files: []const NamedFile },
    run_line: []const u8,
    run_end: bool,
    services: []const Service,
    journal: Unit,
    journal_line: []const u8,
    restart: Unit,
    restarted: struct { unit: Unit, err: ?[]const u8 },
    identify: []const u8,
    identified: struct { dev: []const u8, err: ?[]const u8 },
    bridge,
    /// Empty when `err` says why.
    bridge_info: struct { info: BridgeInfo, err: ?[]const u8 },
    search,
    searched: ?[]const u8,
    forget: []const u8,
    forgot: struct { dev: []const u8, err: ?[]const u8 },
    scenes,
    room_scenes: struct { list: []const RoomScenes, err: ?[]const u8 },
};

/// A device as the house names it: an IEEE address, `00:17:88:01:0e:7d:d5:ad`, or
/// `hue:` and the Bridge's id for one with none.
pub fn isDevice(text: []const u8) bool {
    if (std.mem.startsWith(u8, text, "hue:")) {
        const id = text[4..];
        if (id.len != 36) return false;
        for (id, 0..) |c, i| {
            const dash = i == 8 or i == 13 or i == 18 or i == 23;
            if (dash != (c == '-')) return false;
            if (!dash and !std.ascii.isHex(c)) return false;
        }
        return true;
    }
    if (text.len != 23) return false;
    for (text, 0..) |c, i| {
        if (i % 3 == 2) {
            if (c != ':') return false;
        } else if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

const Wire = struct {
    agent: ?u32 = null,
    admin: ?u32 = null,
    ping: ?bool = null,
    src: ?Source = null,
    line: ?[]const u8 = null,
    file: ?FileId = null,
    path: ?[]const u8 = null,
    text: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
    hub: ?[]const u8 = null,
    hub_line: ?[]const u8 = null,
    hub_done: ?bool = null,
    hub_up: ?bool = null,
    hub_down: ?[]const u8 = null,
    run: ?Target = null,
    confirm: ?bool = null,
    files: ?[]const NamedFile = null,
    run_line: ?[]const u8 = null,
    run_end: ?bool = null,
    services: ?[]const Service = null,
    journal: ?Unit = null,
    journal_line: ?[]const u8 = null,
    restart: ?Unit = null,
    restarted: ?Unit = null,
    identify: ?[]const u8 = null,
    identified: ?[]const u8 = null,
    bridge: ?bool = null,
    bridge_info: ?BridgeInfo = null,
    search: ?bool = null,
    searched: ?bool = null,
    forget: ?[]const u8 = null,
    forgot: ?[]const u8 = null,
    scenes: ?bool = null,
    room_scenes: ?[]const RoomScenes = null,
};

pub const ParseError = error{ NotAMessage, OutOfMemory };

/// One line, without its newline. Strings live in `arena`.
pub fn parse(arena: Allocator, line: []const u8) ParseError!Message {
    const w = std.json.parseFromSliceLeaky(Wire, arena, line, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotAMessage,
    };
    var kinds: u8 = 0;
    inline for (.{ "agent", "admin", "ping", "src", "file", "hub", "hub_line", "hub_done", "hub_up", "hub_down", "run", "run_line", "run_end", "services", "journal", "journal_line", "restart", "restarted", "identify", "identified", "bridge", "bridge_info", "search", "searched", "forget", "forgot", "scenes", "room_scenes" }) |name| {
        if (@field(w, name) != null) kinds += 1;
    }
    if (kinds != 1) return error.NotAMessage;
    // Only a log line, a file and a run carry more than their one field.
    const run_extras = w.confirm != null or w.files != null;
    const extras = w.line != null or w.path != null or w.text != null or w.@"error" != null or run_extras;
    if (w.run) |target| {
        if (w.line != null or w.path != null or w.text != null or w.@"error" != null) return error.NotAMessage;
        return .{ .run = .{ .target = target, .confirm = w.confirm orelse return error.NotAMessage, .files = w.files orelse return error.NotAMessage } };
    }
    if (w.src) |src| {
        if (w.path != null or w.text != null or w.@"error" != null) return error.NotAMessage;
        return .{ .log = .{ .src = src, .line = w.line orelse return error.NotAMessage } };
    }
    if (w.restarted) |unit| {
        if (w.line != null or w.path != null or w.text != null or run_extras) return error.NotAMessage;
        return .{ .restarted = .{ .unit = unit, .err = w.@"error" } };
    }
    if (w.identified) |dev| {
        if (w.line != null or w.path != null or w.text != null or run_extras) return error.NotAMessage;
        return .{ .identified = .{ .dev = dev, .err = w.@"error" } };
    }
    if (w.bridge_info) |info| {
        if (w.line != null or w.path != null or w.text != null or run_extras) return error.NotAMessage;
        return .{ .bridge_info = .{ .info = info, .err = w.@"error" } };
    }
    if (w.searched != null) {
        if (w.line != null or w.path != null or w.text != null or run_extras) return error.NotAMessage;
        return .{ .searched = w.@"error" };
    }
    if (w.forgot) |dev| {
        if (w.line != null or w.path != null or w.text != null or run_extras) return error.NotAMessage;
        return .{ .forgot = .{ .dev = dev, .err = w.@"error" } };
    }
    if (w.room_scenes) |list| {
        if (w.line != null or w.path != null or w.text != null or run_extras) return error.NotAMessage;
        return .{ .room_scenes = .{ .list = list, .err = w.@"error" } };
    }
    if (w.file) |id| {
        if (w.line != null) return error.NotAMessage;
        // A file comes with exactly one of its text and why it has none.
        if ((w.text == null) == (w.@"error" == null)) return error.NotAMessage;
        return .{ .file = .{ .id = id, .path = w.path orelse return error.NotAMessage, .text = w.text, .err = w.@"error" } };
    }
    if (extras) return error.NotAMessage;
    if (w.agent) |v| return .{ .agent = v };
    if (w.admin) |v| return .{ .admin = v };
    if (w.ping != null) return .ping;
    if (w.hub) |command| return .{ .hub = command };
    if (w.hub_line) |text| return .{ .hub_line = text };
    if (w.hub_done != null) return .hub_done;
    if (w.hub_up != null) return .hub_up;
    if (w.run_line) |text| return .{ .run_line = text };
    if (w.run_end) |ok| return .{ .run_end = ok };
    if (w.services) |list| return .{ .services = list };
    if (w.journal) |unit| return .{ .journal = unit };
    if (w.journal_line) |text| return .{ .journal_line = text };
    if (w.restart) |unit| return .{ .restart = unit };
    if (w.identify) |dev| return .{ .identify = dev };
    if (w.forget) |dev| return .{ .forget = dev };
    if (w.bridge != null) return .bridge;
    if (w.search != null) return .search;
    if (w.scenes != null) return .scenes;
    return .{ .hub_down = w.hub_down.? };
}

/// One message and its newline.
pub fn write(w: *Writer, m: Message) Writer.Error!void {
    const wire: Wire = switch (m) {
        .agent => |v| .{ .agent = v },
        .admin => |v| .{ .admin = v },
        .ping => .{ .ping = true },
        .log => |l| .{ .src = l.src, .line = l.line },
        .file => |f| .{ .file = f.id, .path = f.path, .text = f.text, .@"error" = f.err },
        .hub => |line| .{ .hub = line },
        .hub_line => |line| .{ .hub_line = line },
        .hub_done => .{ .hub_done = true },
        .hub_up => .{ .hub_up = true },
        .hub_down => |why| .{ .hub_down = why },
        .run => |r| .{ .run = r.target, .confirm = r.confirm, .files = r.files },
        .run_line => |text| .{ .run_line = text },
        .run_end => |ok| .{ .run_end = ok },
        .services => |list| .{ .services = list },
        .journal => |unit| .{ .journal = unit },
        .journal_line => |text| .{ .journal_line = text },
        .restart => |unit| .{ .restart = unit },
        .restarted => |r| .{ .restarted = r.unit, .@"error" = r.err },
        .identify => |dev| .{ .identify = dev },
        .identified => |r| .{ .identified = r.dev, .@"error" = r.err },
        .forget => |dev| .{ .forget = dev },
        .bridge => .{ .bridge = true },
        .bridge_info => |r| .{ .bridge_info = r.info, .@"error" = r.err },
        .search => .{ .search = true },
        .searched => |err| .{ .searched = true, .@"error" = err },
        .forgot => |r| .{ .forgot = r.dev, .@"error" = r.err },
        .scenes => .{ .scenes = true },
        .room_scenes => |r| .{ .room_scenes = r.list, .@"error" = r.err },
    };
    try std.json.Stringify.value(wire, .{ .emit_null_optional_fields = false }, w);
    try w.writeByte('\n');
}

/// What was last sent of each file, so one is sent again only when it changes.
pub const Sent = struct {
    hashes: [@typeInfo(FileId).@"enum".field_names.len]?u64 = @splat(null),

    /// Whether `id` now reads differently from when this last returned true for it.
    /// A text and an error are never equal, whatever their bytes.
    pub fn changed(self: *Sent, id: FileId, text: ?[]const u8, err: ?[]const u8) bool {
        var h = std.hash.Wyhash.init(0);
        h.update(if (text != null) "t" else "e");
        h.update(text orelse err orelse "");
        const hash = h.final();
        const slot = &self.hashes[@backingInt(id)];
        if (slot.* == hash) return false;
        slot.* = hash;
        return true;
    }
};

/// Bytes in as they arrive from a pipe, complete lines out.
pub const Lines = struct {
    buf: std.ArrayList(u8) = .empty,
    start: usize = 0,

    pub fn deinit(self: *Lines, gpa: Allocator) void {
        self.buf.deinit(gpa);
    }

    /// Invalidates every line `next` has returned.
    pub fn append(self: *Lines, gpa: Allocator, bytes: []const u8) error{ OutOfMemory, LineTooLong }!void {
        const rest = self.buf.items.len - self.start;
        std.mem.copyForwards(u8, self.buf.items[0..rest], self.buf.items[self.start..]);
        self.buf.shrinkRetainingCapacity(rest);
        self.start = 0;
        if (std.mem.findScalar(u8, self.buf.items, '\n') == null and rest + bytes.len > MAX_LINE)
            return error.LineTooLong;
        try self.buf.appendSlice(gpa, bytes);
    }

    /// The next complete line, without its newline, or null until more arrives.
    /// Empty lines are skipped.
    pub fn next(self: *Lines) ?[]const u8 {
        while (std.mem.findScalarPos(u8, self.buf.items, self.start, '\n')) |end| {
            const line = self.buf.items[self.start..end];
            self.start = end + 1;
            if (line.len > 0) return line;
        }
        return null;
    }
};

const testing = std.testing;

fn roundTrip(a: Allocator, m: Message) !Message {
    var out: std.Io.Writer.Allocating = .init(a);
    try write(&out.writer, m);
    const text = out.written();
    try testing.expect(std.mem.endsWith(u8, text, "\n"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "\n"));
    return parse(a, text[0 .. text.len - 1]);
}

test "every message survives the trip, a house log line and a multi-line file byte for byte" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqual(@as(u32, VERSION), (try roundTrip(a, .{ .agent = VERSION })).agent);
    try testing.expectEqual(@as(u32, 7), (try roundTrip(a, .{ .admin = 7 })).admin);
    try testing.expect(try roundTrip(a, .ping) == .ping);
    try testing.expectEqualStrings("reload confirm", (try roundTrip(a, .{ .hub = "reload confirm" })).hub);
    try testing.expectEqualStrings("12:00:01 panel: on \"x\"", (try roundTrip(a, .{ .hub_line = "12:00:01 panel: on \"x\"" })).hub_line);
    try testing.expect(try roundTrip(a, .hub_done) == .hub_done);
    try testing.expect(try roundTrip(a, .hub_up) == .hub_up);
    try testing.expectEqualStrings("ConnectionRefused", (try roundTrip(a, .{ .hub_down = "ConnectionRefused" })).hub_down);
    const files = [_]NamedFile{ .{ .name = "devices.json", .text = "{\n\"devices\": []\n}\n" }, .{ .name = "rules.json", .text = "{}" } };
    const run = (try roundTrip(a, .{ .run = .{ .target = .hub, .confirm = true, .files = &files } })).run;
    try testing.expectEqual(Target.hub, run.target);
    try testing.expect(run.confirm);
    try testing.expectEqual(@as(usize, 2), run.files.len);
    try testing.expectEqualStrings(files[0].text, run.files[0].text);
    try testing.expectEqualStrings("21 dimmers, 0 would change.", (try roundTrip(a, .{ .run_line = "21 dimmers, 0 would change." })).run_line);
    try testing.expect(!(try roundTrip(a, .{ .run_end = false })).run_end);
    const services = [_]Service{
        .{ .unit = .hub, .active = "active", .sub = "running", .enabled = "enabled", .since = 1794426778 },
        .{ .unit = .dmain, .active = "failed", .sub = "failed", .enabled = "enabled", .restarts = 3, .newer_binary = true },
    };
    const got = (try roundTrip(a, .{ .services = &services })).services;
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqual(@as(?i64, 1794426778), got[0].since);
    try testing.expect(got[1].newer_binary and got[1].since == null);
    try testing.expectEqual(Unit.huelog, (try roundTrip(a, .{ .journal = .huelog })).journal);
    try testing.expectEqual(Unit.hub, (try roundTrip(a, .{ .restart = .hub })).restart);
    try testing.expectEqualStrings("00:17:88:01:0e:7d:d5:ad", (try roundTrip(a, .{ .identify = "00:17:88:01:0e:7d:d5:ad" })).identify);
    const refused = (try roundTrip(a, .{ .identified = .{ .dev = "d", .err = "not on the Bridge" } })).identified;
    try testing.expectEqualStrings("not on the Bridge", refused.err.?);
    try testing.expect((try roundTrip(a, .{ .identified = .{ .dev = "d", .err = null } })).identified.err == null);
    try testing.expect((try roundTrip(a, .scenes)) == .scenes);
    try testing.expectEqualStrings("d", (try roundTrip(a, .{ .forget = "d" })).forget);
    try testing.expect((try roundTrip(a, .bridge)) == .bridge);
    try testing.expect((try roundTrip(a, .search)) == .search);
    try testing.expect((try roundTrip(a, .{ .searched = null })).searched == null);
    try testing.expectEqualStrings("busy", (try roundTrip(a, .{ .searched = "busy" })).searched.?);
    const info = (try roundTrip(a, .{ .bridge_info = .{ .info = .{ .name = "Hue Bridge", .counts = .{ .scenes = 3 } }, .err = null } })).bridge_info;
    try testing.expectEqualStrings("Hue Bridge", info.info.name.?);
    try testing.expectEqual(@as(u32, 3), info.info.counts.scenes);
    try testing.expectEqualStrings("no key", (try roundTrip(a, .{ .bridge_info = .{ .info = .{}, .err = "no key" } })).bridge_info.err.?);
    try testing.expectEqualStrings("not on the Bridge", (try roundTrip(a, .{ .forgot = .{ .dev = "d", .err = "not on the Bridge" } })).forgot.err.?);
    const rooms = [_]RoomScenes{ .{ .room = "Lounge", .scenes = &.{ "Relax", "Read" } }, .{ .room = "Hall", .scenes = &.{} } };
    const got_scenes = (try roundTrip(a, .{ .room_scenes = .{ .list = &rooms, .err = null } })).room_scenes;
    try testing.expectEqualStrings("Read", got_scenes.list[0].scenes[1]);
    try testing.expectEqual(@as(usize, 0), got_scenes.list[1].scenes.len);
    try testing.expectEqualStrings("couldn't read the Bridge", (try roundTrip(a, .{ .room_scenes = .{ .list = &.{}, .err = "couldn't read the Bridge" } })).room_scenes.err.?);
    const ok = (try roundTrip(a, .{ .restarted = .{ .unit = .dmain, .err = null } })).restarted;
    try testing.expect(ok.unit == .dmain and ok.err == null);
    try testing.expectEqualStrings("Access denied", (try roundTrip(a, .{ .restarted = .{ .unit = .hub, .err = "Access denied" } })).restarted.err.?);

    const record = "{\"v\":4,\"src\":\"hue\",\"t\":\"2026-11-11T09:00:00.000Z\",\"kind\":\"motion\",\"dev\":\"00:17\",\"on\":true}";
    const log = (try roundTrip(a, .{ .log = .{ .src = .hub, .line = record } })).log;
    try testing.expectEqual(Source.hub, log.src);
    try testing.expectEqualStrings(record, log.line);

    const text = "{\n  \"v\": 1,\n  \"name\": \"Lounge \\u00e9 \\\"spot\\\"\"\n}\n";
    const file = (try roundTrip(a, .{ .file = .{ .id = .power_on, .path = "power-on.json", .text = text, .err = null } })).file;
    try testing.expectEqual(FileId.power_on, file.id);
    try testing.expectEqualStrings(text, file.text.?);
    try testing.expect(file.err == null);

    const missing = (try roundTrip(a, .{ .file = .{ .id = .hub_settings, .path = "../hub/data/settings.json", .text = null, .err = "FileNotFound" } })).file;
    try testing.expect(missing.text == null);
    try testing.expectEqualStrings("FileNotFound", missing.err.?);
}

test "a line that isn't exactly one message is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "usage, from the directory holding dmain.json:",
        "{}",
        "{\"agent\":1,\"admin\":1}",
        "{\"agent\":1,\"extra\":2}",
        "{\"src\":\"zwave\",\"line\":\"x\"}",
        "{\"src\":\"hue\"}",
        "{\"file\":\"hue_settings\",\"path\":\"p\"}",
        "{\"file\":\"hue_settings\",\"path\":\"p\",\"text\":\"t\",\"error\":\"e\"}",
        "{\"file\":\"huelog_json\",\"path\":\"p\",\"text\":\"t\"}",
        "{\"file\":\"power_on\",\"text\":\"t\"}",
        "{\"hub\":\"list\",\"line\":\"x\"}",
        "{\"hub\":\"list\",\"hub_line\":\"x\"}",
        "{\"hub_done\":true,\"path\":\"p\"}",
        "{\"run\":\"hub\",\"files\":[]}",
        "{\"run\":\"hub\",\"confirm\":true}",
        "{\"run_line\":\"x\",\"confirm\":true}",
        "{\"run\":\"hub\",\"confirm\":true,\"files\":[{\"name\":\"a\"}]}",
        "{\"restart\":\"sshd\"}",
        "{\"restart\":\"hub\",\"error\":\"x\"}",
        "{\"journal\":\"hub\",\"line\":\"x\"}",
    }) |line| {
        try testing.expectError(error.NotAMessage, parse(a, line));
    }
}

test "a file is sent again only when it reads differently" {
    var sent: Sent = .{};
    try testing.expect(sent.changed(.power_on, "{}", null));
    try testing.expect(!sent.changed(.power_on, "{}", null));
    try testing.expect(sent.changed(.hub_settings, "{}", null));
    try testing.expect(sent.changed(.power_on, null, "FileNotFound"));
    try testing.expect(!sent.changed(.power_on, null, "FileNotFound"));
    try testing.expect(sent.changed(.power_on, "FileNotFound", null));
    try testing.expect(sent.changed(.power_on, "{ }", null));
}

test "lines come out whole however the bytes arrive" {
    var lines: Lines = .{};
    defer lines.deinit(testing.allocator);
    try lines.append(testing.allocator, "one\ntw");
    try testing.expectEqualStrings("one", lines.next().?);
    try testing.expect(lines.next() == null);
    try lines.append(testing.allocator, "o\n\nthree");
    try testing.expectEqualStrings("two", lines.next().?);
    try testing.expect(lines.next() == null);
    try lines.append(testing.allocator, "\n");
    try testing.expectEqualStrings("three", lines.next().?);
    try testing.expect(lines.next() == null);
    try testing.expectEqual(@as(usize, 0), lines.buf.items.len - lines.start);
}

test "a line that never ends is refused rather than grown without limit" {
    var lines: Lines = .{};
    defer lines.deinit(testing.allocator);
    const chunk = try testing.allocator.alloc(u8, MAX_LINE / 2 + 1);
    defer testing.allocator.free(chunk);
    @memset(chunk, 'x');
    try lines.append(testing.allocator, chunk);
    try testing.expectError(error.LineTooLong, lines.append(testing.allocator, chunk));
}

test "only an IEEE address or a Bridge id is a device" {
    try testing.expect(isDevice("00:17:88:01:0e:7d:d5:ad"));
    try testing.expect(isDevice("hue:0a1b2c3d-0000-4000-8000-0123456789ab"));
    try testing.expect(!isDevice("00:17:88:01:0e:7d:d5"));
    try testing.expect(!isDevice("00:17:88:01:0e:7d:d5:zz"));
    try testing.expect(!isDevice("00-17-88-01-0e-7d-d5-ad"));
    try testing.expect(!isDevice("hue:../../etc/passwd"));
    try testing.expect(!isDevice("panel"));
}
