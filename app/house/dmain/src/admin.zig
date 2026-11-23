//! `dmain admin`: one kind of data across every device, on a screen each, with the
//! devices that differ first. Read-only: changes go through the JSON files, where
//! git keeps their history.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const fleet_mod = @import("fleet.zig");
const rooms_file = @import("rooms_file.zig");
const display_cfg = @import("display.zig");
const houselog = @import("houselog");
const term = @import("term");
const layout_mod = @import("layout");
const view_mod = @import("view");
const reader = @import("reader");
const Day = @import("day_file").Day;
const local_time = @import("local_time");
const config = @import("config.zig");
const link = @import("link.zig");
const hub_client = @import("hub_client.zig");
const wanted_mod = @import("wanted.zig");
const job = @import("job.zig");
const Wanted = wanted_mod.Wanted;

const power_on = @import("power_on.zig");
const Fleet = @import("fleet.zig").Fleet;
const Entry = houselog.settings.Entry;
const Row = view_mod.Row;
const posix = std.posix;

const TICK = Io.Duration.fromMilliseconds(100);
const RELOAD_MS: i64 = 5000;
const MAX_FILE = 1 << 20;

const Screen = enum { home, power_on, firmware, battery, heard, schedules, log, hub, config, services };
const HEADERS = "0 home 1 power-on 2 firmware 3 battery 4 heard 5 schedules 6 log 7 hub 8 config 9 services  q";
const CONFIG_HEADERS = "p s r h choose   c check again   a apply   e edit in Zed   0-9 P screens  j/k  q quit";
const SERVICES_HEADERS = "l h d choose   r restart   0-9 P screens   j/k scroll the journal   q quit";
const HUB_HEADERS = "Type a hub command, Enter sends it.  0-9 on an empty line: screens.  up/down scroll  Esc clears";
const FOLLOW_MS: i64 = 1000;

/// A device and the source it came from, because a hub device's power-on can't be
/// set through the Bridge and so isn't compared with the wanted file.
const Device = struct { entry: Entry, hub: bool };

const Data = struct {
    devices: []const Device,
    wanted: ?power_on.Wanted,
    schedules: []const houselog.schedules.Entry,
    /// How many hub has, or null if its file wouldn't read. It keeps them in its own
    /// config, and has none yet, so they're counted rather than listed.
    hub_schedules: ?usize,
    /// A file that wouldn't load: it says so on screen, because a screen drawn from
    /// half the data looks exactly like a house with fewer devices.
    trouble: ?[]const u8,
    /// hub's network as its radio sees it, or why not. Apart from `trouble`: it
    /// draws one page, and an older hub has no such file.
    network: ?houselog.network.File = null,
    network_err: ?[]const u8 = null,
};

/// A file the screens read, as it was read here or sent over the link.
const FileText = struct {
    path: []const u8 = "",
    text: ?[]const u8 = null,
    /// Why there's no text: an error's name.
    err: ?[]const u8 = null,
};

const Texts = [@typeInfo(link.FileId).@"enum".field_names.len]FileText;

fn file(texts: *const Texts, id: link.FileId) FileText {
    return texts[@backingInt(id)];
}

fn readTexts(arena: Allocator, io: Io, app: *const config.Config) Texts {
    var texts: Texts = undefined;
    inline for (@typeInfo(link.FileId).@"enum".field_names) |name| {
        const path = @field(app, name);
        const slot = &texts[@backingInt(@field(link.FileId, name))];
        slot.* = .{ .path = path };
        if (Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(MAX_FILE))) |text| {
            slot.text = text;
        } else |err| {
            slot.err = @errorName(err);
        }
    }
    return texts;
}

fn load(arena: Allocator, texts: *const Texts) !Data {
    var devices: std.ArrayList(Device) = .empty;
    var trouble: ?[]const u8 = null;
    for ([_]struct { id: link.FileId, hub: bool }{
        .{ .id = .hue_settings, .hub = false },
        .{ .id = .hub_settings, .hub = true },
    }) |source| {
        const f = file(texts, source.id);
        const text = f.text orelse {
            trouble = try std.fmt.allocPrint(arena, "cannot read {s} ({s})", .{ f.path, f.err orelse "not sent yet" });
            continue;
        };
        const parsed = houselog.settings.parse(arena, text) catch |err| {
            trouble = try std.fmt.allocPrint(arena, "cannot read {s} ({t})", .{ f.path, err });
            continue;
        };
        for (parsed.devices) |entry| try devices.append(arena, .{ .entry = entry, .hub = source.hub });
    }

    var wanted: ?power_on.Wanted = null;
    const wanted_src = file(texts, .power_on);
    if (wanted_src.text) |text| {
        wanted = power_on.parse(arena, text) catch |err| blk: {
            trouble = try std.fmt.allocPrint(arena, "{s} is not right ({t})", .{ wanted_src.path, err });
            break :blk null;
        };
    }

    var schedules: []const houselog.schedules.Entry = &.{};
    const schedules_file = file(texts, .hue_schedules);
    if (schedules_file.text) |text| {
        if (houselog.schedules.parse(arena, text)) |parsed| {
            schedules = parsed.schedules;
        } else |err| {
            trouble = try std.fmt.allocPrint(arena, "{s} is not right ({t})", .{ schedules_file.path, err });
        }
    }
    const hub_schedules = countHubSchedules(arena, file(texts, .hub_schedules).text);

    var network: ?houselog.network.File = null;
    var network_err: ?[]const u8 = null;
    const network_file = file(texts, .hub_network);
    if (network_file.text) |text| {
        network = houselog.network.parse(arena, text) catch |err| blk: {
            network_err = try std.fmt.allocPrint(arena, "{s} is not right ({t})", .{ network_file.path, err });
            break :blk null;
        };
    } else network_err = try std.fmt.allocPrint(arena, "cannot read {s} ({s})", .{ network_file.path, network_file.err orelse "not sent yet" });

    return .{ .devices = devices.items, .wanted = wanted, .schedules = schedules, .hub_schedules = hub_schedules, .trouble = trouble, .network = network, .network_err = network_err };
}

fn countHubSchedules(arena: Allocator, text: ?[]const u8) ?usize {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, text orelse return null, .{}) catch return null;
    if (root != .object) return null;
    const list = root.object.get("schedules") orelse return null;
    return if (list == .array) list.array.items.len else null;
}

/// How a row reads against what it should be. The app draws `differs` in orange
/// and `broken` in red; the terminal draws both in its caution colour.
pub const Mark = enum { none, differs, broken };

const Line = struct {
    mark: Mark = .none,
    /// Orders lines within a mark, before the name.
    rank: i64 = 0,
    name: []const u8,
    cells: []const []const u8,
    /// The device's IEEE address, for the app to gather one device across screens.
    dev: ?[]const u8 = null,
};

/// One whole-class screen: a summary, then a row per device, marked ones first.
const Table = struct {
    summary: []const u8,
    /// A heading per cell, for the app; the terminal's summary says it instead.
    columns: []const []const u8,
    /// The terminal's column widths, one per cell.
    widths: []const usize,
    lines: []const Line,

    fn marked(self: Table) usize {
        var n: usize = 0;
        for (self.lines) |l| n += @intFromBool(l.mark != .none);
        return n;
    }
};

fn sortLines(lines: []Line) void {
    std.mem.sort(Line, lines, {}, struct {
        fn lessThan(_: void, a: Line, b: Line) bool {
            if ((a.mark != .none) != (b.mark != .none)) return a.mark != .none;
            if (a.rank != b.rank) return a.rank < b.rank;
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    }.lessThan);
}

fn lineText(arena: Allocator, t: Table, line: Line) ![]const u8 {
    return view_mod.renderColumns(arena, line.cells, t.widths);
}

fn tableRows(arena: Allocator, t: Table) ![]const Row {
    const rows = try arena.alloc(Row, t.lines.len + 2);
    rows[0] = .{ .text = t.summary };
    rows[1] = .{ .text = "" };
    for (t.lines, rows[2..]) |line, *row| {
        row.* = .{ .text = try lineText(arena, t, line), .style = if (line.mark != .none) view_mod.WriteStyle.caution else null };
    }
    return rows;
}

const NAME_W = 26;
const VALUE_W = 24;

fn powerOnRows(arena: Allocator, data: Data) ![]const Row {
    return tableRows(arena, try powerOnTable(arena, data));
}

fn powerOnTable(arena: Allocator, data: Data) !Table {
    var lines: std.ArrayList(Line) = .empty;
    var differ: usize = 0;
    var lights: usize = 0;
    for (data.devices) |d| {
        const now = power_on.wantFrom(d.entry) orelse continue;
        lights += 1;
        var wanted_text: []const u8 = "";
        var differs = false;
        if (d.hub) {
            wanted_text = "(on hub: not compared)";
        } else if (data.wanted) |wanted| {
            const want = power_on.wantFor(wanted, d.entry);
            differs = !power_on.matches(d.entry, want);
            wanted_text = try power_on.describe(arena, want);
        }
        if (differs) differ += 1;
        try lines.append(arena, .{
            .mark = if (differs) .differs else .none,
            .name = d.entry.name,
            .cells = try arena.dupe([]const u8, &.{ d.entry.name, try power_on.describe(arena, now), wanted_text }),
            .dev = d.entry.dev,
        });
    }
    sortLines(lines.items);
    const summary = if (data.wanted == null)
        try std.fmt.allocPrint(arena, "{d} lights. No power-on.json to compare with.", .{lights})
    else
        try std.fmt.allocPrint(arena, "{d} lights, {d} differ from power-on.json. Now, then wanted:", .{ lights, differ });
    return .{ .summary = summary, .columns = &.{ "Name", "Now", "Wanted" }, .widths = &.{ NAME_W, VALUE_W, VALUE_W }, .lines = lines.items };
}

/// The firmware most devices of `model` have, which is what a lone device is
/// compared with: this house doesn't update firmware on purpose, so it's a
/// difference to know about and not a fault.
fn commonFirmware(devices: []const Device, model: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_count: usize = 0;
    for (devices) |d| {
        const fw = d.entry.firmware orelse continue;
        if (!std.mem.eql(u8, d.entry.model orelse continue, model)) continue;
        var count: usize = 0;
        for (devices) |other| {
            const other_fw = other.entry.firmware orelse continue;
            if (std.mem.eql(u8, other.entry.model orelse continue, model) and std.mem.eql(u8, other_fw, fw)) count += 1;
        }
        if (count > best_count) {
            best = fw;
            best_count = count;
        }
    }
    return best;
}

fn firmwareRows(arena: Allocator, data: Data) ![]const Row {
    return tableRows(arena, try firmwareTable(arena, data));
}

fn firmwareTable(arena: Allocator, data: Data) !Table {
    var lines: std.ArrayList(Line) = .empty;
    var differ: usize = 0;
    var unread: usize = 0;
    for (data.devices) |d| {
        const model = d.entry.model;
        const firmware = d.entry.firmware;
        var differs = false;
        if (model) |m| {
            if (firmware) |fw| {
                if (commonFirmware(data.devices, m)) |common| differs = !std.mem.eql(u8, fw, common);
            }
        }
        if (firmware == null) unread += 1;
        if (differs) differ += 1;
        try lines.append(arena, .{
            .mark = if (differs) .differs else .none,
            .name = d.entry.name,
            .cells = try arena.dupe([]const u8, &.{ d.entry.name, model orelse "not read yet", firmware orelse "not read yet" }),
            .dev = d.entry.dev,
        });
    }
    sortLines(lines.items);
    const summary = try std.fmt.allocPrint(arena, "{d} devices, {d} on other firmware than their model's commonest, {d} not read yet.", .{ data.devices.len, differ, unread });
    return .{ .summary = summary, .columns = &.{ "Name", "Model", "Firmware" }, .widths = &.{ NAME_W, VALUE_W, VALUE_W }, .lines = lines.items };
}

fn batteryRows(arena: Allocator, devices: []const fleet_mod.Device) ![]const Row {
    return tableRows(arena, try batteryTable(arena, devices));
}

fn batteryTable(arena: Allocator, devices: []const fleet_mod.Device) !Table {
    var lines: std.ArrayList(Line) = .empty;
    var low: usize = 0;
    var unknown: usize = 0;
    for (devices) |d| {
        if (!d.listed or !d.has_battery) continue;
        const is_low = d.batteryLow();
        if (is_low) low += 1;
        if (d.battery == null) unknown += 1;
        const value = if (d.parked != null) "parked" else if (d.battery) |pct| try std.fmt.allocPrint(arena, "{d}%", .{pct}) else "not reported";
        try lines.append(arena, .{
            .mark = if (is_low) .differs else .none,
            .rank = if (d.battery) |pct| pct else 101,
            .name = d.name,
            .cells = try arena.dupe([]const u8, &.{ d.name, value, d.room orelse "" }),
            .dev = d.dev,
        });
    }
    sortLines(lines.items);
    const summary = try std.fmt.allocPrint(arena, "{d} on battery, {d} at {d}% or below, {d} not reported. Lowest first.", .{ lines.items.len, low, fleet_mod.LOW_BATTERY_PCT, unknown });
    return .{ .summary = summary, .columns = &.{ "Name", "Battery", "Room" }, .widths = &.{ NAME_W, 14, VALUE_W }, .lines = lines.items };
}

fn heardRows(arena: Allocator, devices: []const fleet_mod.Device, now_ms: i64) ![]const Row {
    return tableRows(arena, try heardTable(arena, devices, now_ms));
}

fn heardTable(arena: Allocator, devices: []const fleet_mod.Device, now_ms: i64) !Table {
    var lines: std.ArrayList(Line) = .empty;
    var wrong: usize = 0;
    for (devices) |d| {
        if (!d.listed) continue;
        const looks_wrong = d.looksWrong(now_ms);
        if (looks_wrong) wrong += 1;
        const link_text = if (d.parked) |why|
            try std.fmt.allocPrint(arena, "parked: {s}", .{why})
        else if (d.link) |l| try std.fmt.allocPrint(arena, "{t}", .{l}) else "not reported";
        const age = try fleet_mod.ageText(arena, d.last_heard_ms, now_ms);
        // A link the source calls bad is broken; a sensor gone quiet may just be idle.
        const bad_link = if (d.parked != null) false else if (d.link) |l| l != .connected else false;
        try lines.append(arena, .{
            .mark = if (bad_link) .broken else if (looks_wrong) .differs else .none,
            .name = d.name,
            .cells = try arena.dupe([]const u8, &.{ d.name, link_text, age, d.room orelse "" }),
            .dev = d.dev,
        });
    }
    sortLines(lines.items);
    const summary = try std.fmt.allocPrint(arena, "{d} devices, {d} with a bad link or a sensor quiet for a day. The log reaches back to yesterday.", .{ lines.items.len, wrong });
    return .{ .summary = summary, .columns = &.{ "Name", "Link", "Last heard", "Room" }, .widths = &.{ NAME_W, 14, 16, VALUE_W }, .lines = lines.items };
}

/// "every day", "Mon Fri", or nothing for one not tied to days.
fn daysText(arena: Allocator, days: []const []const u8) ![]const u8 {
    if (days.len == 7) return "every day";
    var out: Io.Writer.Allocating = .init(arena);
    for (days, 0..) |day, i| {
        if (i > 0) try out.writer.writeByte(' ');
        try out.writer.writeByte(std.ascii.toUpper(day[0]));
        try out.writer.writeAll(day[1..@min(day.len, 3)]);
    }
    return out.written();
}

fn scheduleRows(arena: Allocator, data: Data) ![]const Row {
    return tableRows(arena, try scheduleTable(arena, data));
}

fn scheduleTable(arena: Allocator, data: Data) !Table {
    var lines: std.ArrayList(Line) = .empty;
    var enabled: usize = 0;
    for (data.schedules) |s| {
        if (s.enabled) enabled += 1;
        const times = if (s.at) |start|
            (if (s.until) |end| try std.fmt.allocPrint(arena, "{s} to {s}", .{ start, end }) else start)
        else
            "no fixed time";
        try lines.append(arena, .{
            .rank = if (s.enabled) 0 else 1,
            .name = s.name,
            .cells = try arena.dupe([]const u8, &.{ s.name, if (s.enabled) "on" else "off", times, try daysText(arena, s.days), s.kind }),
        });
    }
    sortLines(lines.items);
    const hub = if (data.hub_schedules) |n| try std.fmt.allocPrint(arena, "hub has {d}", .{n}) else "hub's couldn't be read";
    const summary = try std.fmt.allocPrint(arena, "{d} on the Bridge, {d} on. {s}. Off doesn't always mean unused: a button can still run one.", .{ data.schedules.len, enabled, hub });
    return .{ .summary = summary, .columns = &.{ "Name", "On", "When", "Days", "Kind" }, .widths = &.{ NAME_W, 4, 15, 28, VALUE_W }, .lines = lines.items };
}

/// A line of the recent log: its local time and what happened.
const Event = struct { at: []const u8, src: link.Source, text: []const u8, mark: Mark, dev: ?[]const u8 };

/// Newest first, without temperature and light level.
fn events(arena: Allocator, fleet: *const Fleet) ![]const Event {
    const lines = try fleet.recentLog(arena);
    const out = try arena.alloc(Event, lines.len);
    for (out, lines) |*e, line| {
        const t = local_time.localAt(line.at);
        const text = line.text();
        const wrong = std.mem.indexOf(u8, text, "ALARM") != null or std.mem.indexOf(u8, text, "DOWN") != null;
        e.* = .{
            .at = try std.fmt.allocPrint(arena, "{d:0>2}:{d:0>2}:{d:0>2}", .{ t.hour, t.minute, t.second }),
            .text = text,
            .src = if (line.hub) .hub else .hue,
            .mark = if (wrong) .differs else .none,
            .dev = line.dev(),
        };
    }
    return out;
}

fn eventRow(arena: Allocator, e: Event) !Row {
    return .{ .text = try std.fmt.allocPrint(arena, "{s}  {s}", .{ e.at, e.text }), .style = if (e.mark != .none) view_mod.WriteStyle.caution else null };
}

fn logRows(arena: Allocator, fleet: *const Fleet) ![]const Row {
    const list = try events(arena, fleet);
    const rows = try arena.alloc(Row, list.len + 2);
    rows[0] = .{ .text = "Newest first, without temperature and light level." };
    rows[1] = .{ .text = "" };
    for (rows[2..], list) |*row, e| row.* = try eventRow(arena, e);
    return rows;
}

/// hub's console as the screens show it: what it said, newest last, and the
/// line being typed. Either source feeds it.
const Console = struct {
    gpa: Allocator,
    lines: std.ArrayList([]u8) = .empty,
    /// null until the first try to reach it.
    up: ?bool = null,
    why_buf: [80]u8 = undefined,
    why_len: usize = 0,
    /// A command sent and not finished, which hub's output says nothing about.
    busy: bool = false,
    input: std.ArrayList(u8) = .empty,
    changed: bool = false,
    /// Lines ever added, so a reader can tell which are new after old ones go.
    added: u64 = 0,

    const KEEP = 500;

    fn deinit(self: *Console) void {
        for (self.lines.items) |l| self.gpa.free(l);
        self.lines.deinit(self.gpa);
        self.input.deinit(self.gpa);
    }

    fn add(self: *Console, text: []const u8) void {
        const copy = self.gpa.dupe(u8, text) catch return;
        if (self.lines.items.len == KEEP) self.gpa.free(self.lines.orderedRemove(0));
        self.lines.append(self.gpa, copy) catch return self.gpa.free(copy);
        self.added += 1;
        self.changed = true;
    }

    pub fn hubLine(self: *Console, text: []const u8) void {
        self.add(text);
    }
    pub fn hubDone(self: *Console) void {
        self.busy = false;
        self.changed = true;
    }
    pub fn hubUp(self: *Console) void {
        self.up = true;
        self.changed = true;
    }
    pub fn hubDown(self: *Console, why: []const u8) void {
        self.up = false;
        self.why_len = @min(why.len, self.why_buf.len);
        @memcpy(self.why_buf[0..self.why_len], why[0..self.why_len]);
        // Nothing will finish what was running.
        self.busy = false;
        self.changed = true;
    }

    fn status(self: *const Console, a: Allocator) ![]const u8 {
        const up = self.up orelse return "hub's console: not tried yet";
        if (!up) return std.fmt.allocPrint(a, "hub's console isn't answering ({s}). hub takes about 25 s to open it after a start.", .{self.why_buf[0..self.why_len]});
        return if (self.busy) "hub's console: answering, running a command" else "hub's console: answering";
    }
};

/// The hub screen: status, the line being typed, then as many of the newest
/// lines as fit, `back` lines up from the newest.
fn hubRows(a: Allocator, console: *const Console, height: usize, back: usize) ![]const Row {
    var rows: std.ArrayList(Row) = .empty;
    try rows.append(a, .{ .text = try console.status(a), .style = if (console.up == false) view_mod.WriteStyle.caution else null });
    try rows.append(a, .{ .text = try std.fmt.allocPrint(a, "hub> {s}\u{258F}", .{console.input.items}) });
    try rows.append(a, .{ .text = "" });
    const room = height -| rows.items.len;
    const lines = console.lines.items;
    const end = lines.len -| back;
    for (lines[end -| room..end]) |l| try rows.append(a, .{ .text = l });
    return rows.items;
}

/// Something on another screen that isn't as it should be, said in a line.
const Item = struct { name: []const u8, text: []const u8, mark: Mark };

const ConsoleState = struct { up: ?bool, busy: bool, text: []const u8 };

const Section = struct { key: u8, screen: Screen, label: []const u8, table: Table };

/// What every other screen marks, gathered for the home screen and the app's
/// Attention screen alike, so the two can't disagree about what needs a look.
const Attention = struct {
    /// Those that need a look; null until the link has reported any.
    services: ?[]const Item,
    console: ConsoleState,
    /// Wanted files whose last dry run would change something, or failed; null
    /// with no checkout to read them from.
    config: ?[]const Item,
    sections: []const Section,
    /// Newest first.
    events: []const Event,
};

fn attention(a: Allocator, data: Data, fleet: *const Fleet, console: *const Console, svc: *const Services, wanted: *const Wanted, now_ms: i64) !Attention {
    var services: ?[]const Item = null;
    if (svc.list.len > 0) {
        var list: std.ArrayList(Item) = .empty;
        for (svc.list) |s| {
            if (!needsLook(s)) continue;
            try list.append(a, .{
                .name = @tagName(s.unit),
                .text = try serviceText(a, s),
                .mark = if (std.mem.eql(u8, s.active, "active")) .differs else .broken,
            });
        }
        services = list.items;
    }
    var wanted_items: ?[]const Item = null;
    if (wanted.base != null) {
        var list: std.ArrayList(Item) = .empty;
        for (wanted_mod.SPECS, &wanted.slots, 0..) |spec, *slot, i| {
            const mark = configMark(slot);
            if (mark == .none) continue;
            try list.append(a, .{ .name = spec.label, .text = try wanted.status(a, i), .mark = mark });
        }
        wanted_items = list.items;
    }
    // Schedules are listed, not compared, so nothing on them needs a look.
    const all = try tables(a, data, fleet, now_ms);
    const sections = try a.dupe(Section, all[0..4]);
    return .{
        .services = services,
        .console = .{ .up = console.up, .busy = console.busy, .text = try console.status(a) },
        .config = wanted_items,
        .sections = sections,
        .events = try events(a, fleet),
    };
}

/// A wanted file that won't read or whose run failed is broken; one whose dry run
/// would change something differs.
fn configMark(slot: *const wanted_mod.Slot) Mark {
    if (slot.read_err != null) return .broken;
    const last = slot.last orelse return .none;
    if (!last.ok) return .broken;
    return if (!last.confirm and last.appliable) .differs else .none;
}

/// The home screen: each screen's summary and the first few of its marked rows.
fn homeRows(a: Allocator, att: Attention) ![]const Row {
    const SHOWN = 5;
    var rows: std.ArrayList(Row) = .empty;
    if (att.services) |list| {
        for (list) |item| try rows.append(a, .{ .text = try std.fmt.allocPrint(a, "Service {s}: {s}", .{ item.name, item.text }), .style = styleOf(item.mark) });
        if (list.len == 0) try rows.append(a, .{ .text = "Services: huelog, hub and dmain running, each on the binary on disk" });
    }
    try rows.append(a, .{ .text = att.console.text, .style = if (att.console.up == false) view_mod.WriteStyle.caution else null });
    if (att.config) |list| {
        for (list) |item| try rows.append(a, .{ .text = try std.fmt.allocPrint(a, "Config {s}: {s}", .{ item.name, item.text }), .style = styleOf(item.mark) });
    }
    for (att.sections) |section| {
        const t = section.table;
        try rows.append(a, .{ .text = "" });
        try rows.append(a, .{ .text = try std.fmt.allocPrint(a, "{s}: {s}", .{ section.label, t.summary }) });
        var marked: usize = 0;
        for (t.lines) |line| {
            if (line.mark == .none) continue;
            marked += 1;
            if (marked <= SHOWN) try rows.append(a, .{ .text = try std.fmt.allocPrint(a, "  {s}", .{try lineText(a, t, line)}), .style = view_mod.WriteStyle.caution });
        }
        if (marked > SHOWN) try rows.append(a, .{ .text = try std.fmt.allocPrint(a, "  and {d} more: press {c}", .{ marked - SHOWN, section.key }) });
    }
    try rows.append(a, .{ .text = "" });
    try rows.append(a, .{ .text = "Latest events:" });
    for (att.events[0..@min(att.events.len, SHOWN)]) |e| {
        var row = try eventRow(a, e);
        row.text = try std.fmt.allocPrint(a, "  {s}", .{row.text});
        try rows.append(a, row);
    }
    return rows.items;
}

fn styleOf(mark: Mark) ?view_mod.WriteStyle {
    return switch (mark) {
        .none => null,
        .differs => view_mod.WriteStyle.caution,
        .broken => view_mod.WriteStyle.alert,
    };
}

/// The config screen: each wanted file's state, then the chosen one's last run.
fn configRows(a: Allocator, wanted: *const Wanted, chosen: usize, prompt: ?[]const u8, note: ?[]const u8) ![]const Row {
    var rows: std.ArrayList(Row) = .empty;
    if (wanted.base) |base| {
        try rows.append(a, .{ .text = try std.fmt.allocPrint(a, "Wanted files in {s}, checked on the server as they're saved. Nothing is written without a typed confirm.", .{base}) });
    } else {
        try rows.append(a, .{ .text = "No checkout here: the wanted files are the Mac's. Run `dmain admin <server>` from app/house/dmain there.", .style = view_mod.WriteStyle.caution });
        return rows.items;
    }
    try rows.append(a, .{ .text = "" });
    for (wanted_mod.SPECS, 0..) |spec, i| {
        const mark = if (i == chosen) ">" else " ";
        const st = try wanted.status(a, i);
        const failed = std.mem.indexOf(u8, st, "FAILED") != null or std.mem.startsWith(u8, st, "can't");
        const cells = [_][]const u8{ try std.fmt.allocPrint(a, "{s} {c}  {s}", .{ mark, spec.key, spec.label }), spec.shown, st };
        try rows.append(a, .{
            .text = try view_mod.renderColumns(a, &cells, &.{ 16, 46, 60 }),
            .style = if (failed) view_mod.WriteStyle.alert else if (std.mem.indexOf(u8, st, "would change") != null) view_mod.WriteStyle.caution else null,
        });
    }
    try rows.append(a, .{ .text = "" });
    if (prompt) |p| {
        try rows.append(a, .{ .text = try std.fmt.allocPrint(a, "Type confirm and Enter to write these to {s}, Esc to leave it: {s}\u{258F}", .{ if (wanted_mod.SPECS[chosen].target == .hub) "hub" else "the Bridge", p }), .style = view_mod.WriteStyle.caution });
    } else if (note) |n| {
        try rows.append(a, .{ .text = n, .style = view_mod.WriteStyle.caution });
    } else {
        try rows.append(a, .{ .text = "" });
    }
    const slot = &wanted.slots[chosen];
    const what = if (slot.running) |c| (if (c) "applying" else "checking") else if (slot.last) |l| (if (l.confirm) "last apply" else "last dry run") else "not run yet";
    try rows.append(a, .{ .text = try std.fmt.allocPrint(a, "{s}, {s}:", .{ wanted_mod.SPECS[chosen].label, what }) });
    for (slot.lines.items) |l| try rows.append(a, .{ .text = try std.fmt.allocPrint(a, "  {s}", .{l}) });
    return rows.items;
}

/// Opens a target's files in Zed, which highlights a JSON mistake as it's typed.
fn openInZed(gpa: Allocator, io: Io, wanted: *const Wanted, i: usize) void {
    const base = wanted.base orelse return;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }
    argv.appendSlice(gpa, &.{ "open", "-a", "Zed" }) catch return;
    for (wanted_mod.SPECS[i].paths) |path| {
        const full = std.fs.path.join(gpa, &.{ base, path }) catch return;
        paths.append(gpa, full) catch {
            gpa.free(full);
            return;
        };
        argv.append(gpa, full) catch return;
    }
    var child = std.process.spawn(io, .{ .argv = argv.items, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return;
    _ = child.wait(io) catch {};
}

/// The server's services as the agent last reported them, and the chosen one's journal.
const Services = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    list: []const link.Service = &.{},
    journal: std.ArrayList([]u8) = .empty,
    following: ?link.Unit = null,
    /// What the last restart request came to.
    note_buf: [160]u8 = undefined,
    note: ?[]const u8 = null,
    /// How the last restart request came out, once it has.
    restart_ok: ?bool = null,
    changed: bool = false,
    /// Journal lines ever added.
    added: u64 = 0,

    const KEEP = 500;

    fn deinit(self: *Services) void {
        for (self.journal.items) |l| self.gpa.free(l);
        self.journal.deinit(self.gpa);
        self.arena.deinit();
    }

    fn set(self: *Services, list: []const link.Service) void {
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        const copy = a.alloc(link.Service, list.len) catch return;
        for (list, copy) |svc, *c| {
            c.* = svc;
            c.active = a.dupe(u8, svc.active) catch "";
            c.sub = a.dupe(u8, svc.sub) catch "";
            c.enabled = a.dupe(u8, svc.enabled) catch "";
        }
        self.list = copy;
        self.changed = true;
    }

    fn add(self: *Services, text: []const u8) void {
        const copy = self.gpa.dupe(u8, text) catch return;
        if (self.journal.items.len == KEEP) self.gpa.free(self.journal.orderedRemove(0));
        self.journal.append(self.gpa, copy) catch return self.gpa.free(copy);
        self.added += 1;
        self.changed = true;
    }

    fn clearJournal(self: *Services) void {
        for (self.journal.items) |l| self.gpa.free(l);
        self.journal.clearRetainingCapacity();
        self.changed = true;
    }

    fn restarted(self: *Services, unit: link.Unit, err: ?[]const u8) void {
        self.restart_ok = err == null;
        self.note = if (err) |e|
            std.fmt.bufPrint(&self.note_buf, "{t}: systemd refused the restart: {s}", .{ unit, e }) catch "systemd refused the restart"
        else
            std.fmt.bufPrint(&self.note_buf, "{t}: restart queued; its state below says how it went", .{unit}) catch "restart queued";
        self.changed = true;
    }

    fn find(self: *const Services, unit: link.Unit) ?link.Service {
        for (self.list) |svc| {
            if (svc.unit == unit) return svc;
        }
        return null;
    }
};

const UNITS = [_]struct { unit: link.Unit, key: u8, cost: []const u8 }{
    .{ .unit = .huelog, .key = 'l', .cost = "the Hue log pauses for a few seconds and today's is rebuilt" },
    .{ .unit = .hub, .key = 'h', .cost = "Zigbee and the leak alert stop for about 25 s" },
    .{ .unit = .dmain, .key = 'd', .cost = "the phone pages stop for a moment" },
};

fn needsLook(svc: link.Service) bool {
    return !std.mem.eql(u8, svc.active, "active") or svc.newer_binary;
}

/// "11-13 09:02", local, or null if systemd didn't say.
fn sinceText(a: Allocator, svc: link.Service) !?[]const u8 {
    const t = svc.since orelse return null;
    const lt = local_time.localAt(.fromNanoseconds(@as(i96, t) * std.time.ns_per_s));
    const md = lt.monthDay();
    return try std.fmt.allocPrint(a, "{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ md.month, md.day, lt.hour, lt.minute });
}

fn serviceText(a: Allocator, svc: link.Service) ![]const u8 {
    const since = if (try sinceText(a, svc)) |t| try std.fmt.allocPrint(a, "since {s}", .{t}) else "";
    const cells = [_][]const u8{
        try std.fmt.allocPrint(a, "{s}, {s}", .{ svc.active, svc.sub }),
        svc.enabled,
        since,
        try std.fmt.allocPrint(a, "{d} restarts", .{svc.restarts}),
        if (svc.newer_binary) "new binary on disk: restart to run it" else "",
    };
    return view_mod.renderColumns(a, &cells, &.{ 20, 10, 20, 12, 40 });
}

/// The services screen: each one's state, then the chosen one's journal, as much
/// of the newest as fits, `back` lines up.
fn servicesRows(a: Allocator, svc: *const Services, chosen: usize, prompt: ?[]const u8, note: ?[]const u8, height: usize, back: usize) ![]const Row {
    var rows: std.ArrayList(Row) = .empty;
    if (svc.list.len == 0) {
        try rows.append(a, .{ .text = "No state from the server yet. Services are reported over the link: `dmain admin <server>` on the Mac." });
        return rows.items;
    }
    try rows.append(a, .{ .text = "The server's services, as systemd has them. A restart needs a typed confirm." });
    try rows.append(a, .{ .text = "" });
    for (UNITS, 0..) |u, i| {
        const mark = if (i == chosen) ">" else " ";
        const state = svc.find(u.unit) orelse {
            try rows.append(a, .{ .text = try std.fmt.allocPrint(a, "{s} {c}  {t}   not reported", .{ mark, u.key, u.unit }), .style = view_mod.WriteStyle.alert });
            continue;
        };
        const healthy = std.mem.eql(u8, state.active, "active");
        try rows.append(a, .{
            .text = try std.fmt.allocPrint(a, "{s} {c}  {s}{s}", .{ mark, u.key, try view_mod.padToColumns(a, @tagName(u.unit), 8), try serviceText(a, state) }),
            .style = if (!healthy) view_mod.WriteStyle.alert else if (state.newer_binary) view_mod.WriteStyle.caution else null,
        });
    }
    try rows.append(a, .{ .text = "" });
    if (prompt) |p| {
        try rows.append(a, .{ .text = try std.fmt.allocPrint(a, "Restarting {t}: {s}. Type confirm and Enter, Esc to leave it: {s}\u{258F}", .{ UNITS[chosen].unit, UNITS[chosen].cost, p }), .style = view_mod.WriteStyle.caution });
    } else if (note orelse svc.note) |n| {
        try rows.append(a, .{ .text = n, .style = view_mod.WriteStyle.caution });
    } else {
        try rows.append(a, .{ .text = "" });
    }
    try rows.append(a, .{ .text = try std.fmt.allocPrint(a, "journal of {t}, newest last:", .{UNITS[chosen].unit}) });
    const room = height -| rows.items.len;
    const lines = svc.journal.items;
    const end = lines.len -| back;
    for (lines[end -| room..end]) |l| try rows.append(a, .{ .text = l });
    return rows.items;
}

/// A source's log: yesterday once, for how long ago a device was heard, then today
/// as it's written. Neither has to exist: a source can be new, or be stopped.
const LogFeed = struct {
    dir: ?Io.Dir,
    follower: ?reader.Follower = null,

    fn open(gpa: Allocator, io: Io, path: []const u8, fleet: *Fleet, now: Io.Timestamp) LogFeed {
        const dir = Io.Dir.cwd().openDir(io, path, .{}) catch return .{ .dir = null };
        const yesterday = Day.of(.fromNanoseconds(now.toNanoseconds() - 24 * 3600 * std.time.ns_per_s));
        _ = reader.replay(gpa, io, dir, yesterday, fleet) catch {};
        return .{ .dir = dir, .follower = reader.Follower.init(dir, Day.of(now)) };
    }

    fn poll(self: *LogFeed, gpa: Allocator, io: Io, fleet: *Fleet, now: Io.Timestamp) usize {
        if (self.follower) |*f| return f.poll(gpa, io, Day.of(now), fleet) catch 0;
        return 0;
    }

    fn close(self: *LogFeed, gpa: Allocator, io: Io) void {
        if (self.follower) |*f| f.deinit(gpa);
        if (self.dir) |d| d.close(io);
    }
};

const Update = struct { files: bool = false, logs: bool = false };

/// Where the files and log lines come from, as the app's sidebar says it: still
/// connecting, up, up but silent for too long, or gone for good.
const LinkState = enum { connecting, up, quiet, closed };

/// The files and logs in this machine's directories, as on the server.
const Local = struct {
    app: *const config.Config,
    arena: std.heap.ArenaAllocator,
    texts: Texts = undefined,
    hue_feed: LogFeed = undefined,
    hub_feed: LogFeed = undefined,
    last_load_ms: i64 = std.math.minInt(i64) / 2,
    last_follow_ms: i64 = 0,
    hub: hub_client.Client = undefined,

    fn start(self: *Local, gpa: Allocator, io: Io, fleet: *Fleet) !void {
        const now = Io.Timestamp.now(io, .real);
        self.hue_feed = .open(gpa, io, self.app.hue_log, fleet, now);
        self.hub_feed = .open(gpa, io, self.app.hub_log, fleet, now);
        self.hub = .{ .path = self.app.hub_socket };
    }

    fn sendHub(self: *Local, gpa: Allocator, io: Io, command: []const u8, console: *Console) void {
        self.hub.send(gpa, io, command, console);
    }

    fn canRun(_: *const Local) bool {
        return false;
    }

    fn sendRun(_: *Local, _: Io, _: wanted_mod.Request) void {}
    fn sendJournal(_: *Local, _: Io, _: link.Unit) void {}
    fn sendRestart(_: *Local, _: Io, _: link.Unit) void {}

    /// The Pi has no checkout: the wanted files are the Mac's.
    fn wantedBase(_: *const Local, _: Allocator, _: Io) ?[]u8 {
        return null;
    }

    fn update(self: *Local, gpa: Allocator, io: Io, fleet: *Fleet, console: *Console, _: *Wanted, _: *Services) !Update {
        var u: Update = .{};
        self.hub.tick(io, console);
        var fds = [_]posix.pollfd{.{ .fd = self.hub.fd(), .events = posix.POLL.IN, .revents = 0 }};
        while (try posix.poll(&fds, 0) > 0 and fds[0].revents != 0) {
            self.hub.readable(gpa, io, console);
            fds[0].fd = self.hub.fd();
        }
        const now_ms = Io.Timestamp.now(io, .awake).toMilliseconds();
        if (now_ms - self.last_load_ms >= RELOAD_MS) {
            _ = self.arena.reset(.retain_capacity);
            self.texts = readTexts(self.arena.allocator(), io, self.app);
            self.last_load_ms = now_ms;
            u.files = true;
        }
        if (now_ms - self.last_follow_ms >= FOLLOW_MS) {
            self.last_follow_ms = now_ms;
            const now = Io.Timestamp.now(io, .real);
            u.logs = self.hue_feed.poll(gpa, io, fleet, now) + self.hub_feed.poll(gpa, io, fleet, now) > 0;
        }
        return u;
    }

    fn status(_: *const Local) ?[]const u8 {
        return null;
    }

    fn linkState(_: *const Local) LinkState {
        return .up;
    }

    fn stop(self: *Local, gpa: Allocator, io: Io) void {
        self.hub.deinit(gpa, io);
        self.hue_feed.close(gpa, io);
        self.hub_feed.close(gpa, io);
        self.arena.deinit();
    }
};

/// `dmain agent` on another machine, over `ssh`: the same files and log lines,
/// folded here.
const Remote = struct {
    host: []const u8,
    child: std.process.Child = undefined,
    stdin_buf: [256]u8 = undefined,
    lines: link.Lines = .{},
    arenas: [@typeInfo(link.FileId).@"enum".field_names.len]std.heap.ArenaAllocator = undefined,
    texts: Texts = @splat(.{}),
    hello: bool = false,
    closed: bool = false,
    /// What's wrong with the link, or what it's waiting for.
    trouble: ?[]const u8 = "connecting",
    trouble_buf: [320]u8 = undefined,
    /// The last line `ssh` or the agent wrote to stderr, which says why a link closed.
    err_line: [200]u8 = undefined,
    err_len: usize = 0,
    err_partial: bool = false,
    last_heard_ms: i64 = 0,
    last_ping_ms: i64 = 0,
    /// How the last identify came out, once it has: null error when the Bridge took it.
    identified: ?struct { err: ?[]const u8 } = null,
    identified_buf: [240]u8 = undefined,
    /// The Bridge's facts once asked for, as the JSON the app is sent, in `bridge_arena`.
    bridge: ?struct { json: []const u8, err: ?[]const u8 } = null,
    bridge_arena: std.heap.ArenaAllocator = undefined,
    /// How the last search request came out, once it has.
    searched: ?struct { err: ?[]const u8 } = null,
    searched_buf: [240]u8 = undefined,
    /// How the last forget came out, once it has: null error when the Bridge took it.
    forgot: ?struct { err: ?[]const u8 } = null,
    forgot_buf: [240]u8 = undefined,
    /// Each Bridge room's scenes once asked for, in `scenes_arena`.
    room_scenes: ?struct { list: []const link.RoomScenes, err: ?[]const u8 } = null,
    scenes_arena: std.heap.ArenaAllocator = undefined,

    fn start(self: *Remote, gpa: Allocator, io: Io, _: *Fleet) !void {
        for (&self.arenas) |*a| a.* = .init(gpa);
        self.scenes_arena = .init(gpa);
        self.bridge_arena = .init(gpa);
        // BatchMode, because a password prompt would land in the middle of the
        // screens; ServerAlive, so a network that's gone ends the link.
        self.child = try std.process.spawn(io, .{
            .argv = &.{ "ssh", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", self.host, "cd dmain && exec ./dmain agent" },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        self.last_heard_ms = Io.Timestamp.now(io, .awake).toMilliseconds();
        self.last_ping_ms = self.last_heard_ms;
        self.send(io, .{ .admin = link.VERSION });
    }

    fn send(self: *Remote, io: Io, m: link.Message) void {
        const stdin = self.child.stdin orelse return;
        var w: Io.File.Writer = .initStreaming(stdin, io, &self.stdin_buf);
        link.write(&w.interface, m) catch return;
        w.interface.flush() catch {};
    }

    fn setTrouble(self: *Remote, comptime fmt: []const u8, args: anytype) void {
        self.trouble = std.fmt.bufPrint(&self.trouble_buf, fmt, args) catch &self.trouble_buf;
    }

    fn errText(self: *const Remote) []const u8 {
        return self.err_line[0..self.err_len];
    }

    fn readErr(self: *Remote, bytes: []const u8) void {
        for (bytes) |c| {
            if (c == '\n') {
                self.err_partial = false;
                continue;
            }
            if (!self.err_partial) {
                self.err_partial = true;
                self.err_len = 0;
            }
            if (self.err_len < self.err_line.len) {
                self.err_line[self.err_len] = c;
                self.err_len += 1;
            }
        }
    }

    fn sendHub(self: *Remote, _: Allocator, io: Io, command: []const u8, console: *Console) void {
        if (hub_client.refusal(command)) |why| {
            console.hubLine(why);
            return console.hubDone();
        }
        if (!self.hello or self.closed) {
            console.hubLine("the link to the server isn't up");
            return console.hubDone();
        }
        self.send(io, .{ .hub = command });
    }

    fn canRun(self: *const Remote) bool {
        return self.hello and !self.closed;
    }

    fn sendRun(self: *Remote, io: Io, r: wanted_mod.Request) void {
        self.send(io, .{ .run = .{ .target = r.target, .confirm = r.confirm, .files = r.files } });
    }

    fn sendJournal(self: *Remote, io: Io, unit: link.Unit) void {
        if (self.canRun()) self.send(io, .{ .journal = unit });
    }

    fn sendRestart(self: *Remote, io: Io, unit: link.Unit) void {
        if (self.canRun()) self.send(io, .{ .restart = unit });
    }

    fn sendIdentify(self: *Remote, io: Io, dev: []const u8) void {
        self.identified = null;
        if (self.canRun()) self.send(io, .{ .identify = dev });
    }

    fn sendBridge(self: *Remote, io: Io) void {
        self.bridge = null;
        if (self.canRun()) self.send(io, .bridge);
    }

    fn sendSearch(self: *Remote, io: Io) void {
        self.searched = null;
        if (self.canRun()) self.send(io, .search);
    }

    fn keepBridge(self: *Remote, info: link.BridgeInfo, err: ?[]const u8) !void {
        _ = self.bridge_arena.reset(.retain_capacity);
        const a = self.bridge_arena.allocator();
        var aw: Io.Writer.Allocating = .init(a);
        try std.json.Stringify.value(info, .{}, &aw.writer);
        self.bridge = .{ .json = aw.written(), .err = if (err) |e| try a.dupe(u8, e) else null };
    }

    fn sendForget(self: *Remote, io: Io, dev: []const u8) void {
        self.forgot = null;
        if (self.canRun()) self.send(io, .{ .forget = dev });
    }

    fn sendScenes(self: *Remote, io: Io) void {
        self.room_scenes = null;
        if (self.canRun()) self.send(io, .scenes);
    }

    fn keepScenes(self: *Remote, list: []const link.RoomScenes, err: ?[]const u8) !void {
        _ = self.scenes_arena.reset(.retain_capacity);
        const a = self.scenes_arena.allocator();
        const out = try a.alloc(link.RoomScenes, list.len);
        for (list, out) |r, *o| {
            const names = try a.alloc([]const u8, r.scenes.len);
            for (r.scenes, names) |n, *m| m.* = try a.dupe(u8, n);
            o.* = .{ .room = try a.dupe(u8, r.room), .scenes = names };
        }
        self.room_scenes = .{ .list = out, .err = if (err) |e| try a.dupe(u8, e) else null };
    }

    fn wantedBase(_: *const Remote, gpa: Allocator, io: Io) ?[]u8 {
        return wanted_mod.findBase(gpa, io);
    }

    fn update(self: *Remote, gpa: Allocator, io: Io, fleet: *Fleet, console: *Console, wanted: *Wanted, svc: *Services) !Update {
        var u: Update = .{};
        if (self.closed) return u;
        const out_fd = self.child.stdout.?.handle;
        const err_fd = self.child.stderr.?.handle;
        var buf: [64 * 1024]u8 = undefined;
        // Bounded, so keys are still read during the first day's replay.
        var budget: usize = 8 << 20;
        while (budget > 0) {
            var fds = [_]posix.pollfd{
                .{ .fd = out_fd, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = err_fd, .events = posix.POLL.IN, .revents = 0 },
            };
            if (try posix.poll(&fds, 0) == 0) break;
            if (fds[1].revents != 0) {
                const n = posix.read(err_fd, &buf) catch 0;
                self.readErr(buf[0..n]);
            }
            if (fds[0].revents == 0) continue;
            const n = posix.read(out_fd, &buf) catch 0;
            if (n == 0) {
                self.closed = true;
                break;
            }
            budget -|= n;
            self.lines.append(gpa, buf[0..n]) catch |err| {
                self.setTrouble("link broken ({t}).", .{err});
                self.closed = true;
                return u;
            };
            try self.take(gpa, io, fleet, console, wanted, svc, &u);
            if (self.closed) return u;
        }

        const now_ms = Io.Timestamp.now(io, .awake).toMilliseconds();
        if (self.closed) {
            // Whatever stderr said last is why: the agent's own refusal, or ssh's.
            var tries: usize = 0;
            while (tries < 20) : (tries += 1) {
                var fds = [_]posix.pollfd{.{ .fd = err_fd, .events = posix.POLL.IN, .revents = 0 }};
                if (try posix.poll(&fds, 50) == 0) break;
                const n = posix.read(err_fd, &buf) catch 0;
                if (n == 0) break;
                self.readErr(buf[0..n]);
            }
            if (self.hello or self.trouble == null or std.mem.eql(u8, self.trouble.?, "connecting"))
                self.setTrouble("link to {s} closed: {s}. What's shown is as it was.", .{ self.host, if (self.err_len > 0) self.errText() else "no reason given" });
            u.files = true;
            return u;
        }
        if (self.hello) {
            if (now_ms - self.last_heard_ms > link.SILENCE_MS) {
                self.setTrouble("nothing from {s} for {d} s", .{ self.host, @divTrunc(now_ms - self.last_heard_ms, 1000) });
                u.files = true;
            } else if (self.trouble != null) {
                self.trouble = null;
                u.files = true;
            }
        }
        if (now_ms - self.last_ping_ms >= link.PING_MS) {
            self.last_ping_ms = now_ms;
            self.send(io, .ping);
        }
        return u;
    }

    fn take(self: *Remote, gpa: Allocator, io: Io, fleet: *Fleet, console: *Console, wanted: *Wanted, svc: *Services, u: *Update) !void {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        while (self.lines.next()) |line| {
            _ = arena.reset(.retain_capacity);
            self.last_heard_ms = Io.Timestamp.now(io, .awake).toMilliseconds();
            const m = link.parse(arena.allocator(), line) catch {
                // An old dmain prints its usage; anything else is as foreign.
                self.setTrouble("{s} didn't answer as dmain agent: \"{s}\". Deploy dmain there.", .{ self.host, line[0..@min(line.len, 80)] });
                self.closed = true;
                u.files = true;
                return;
            };
            if (!self.hello) {
                if (m != .agent or m.agent != link.VERSION) {
                    if (m == .agent)
                        self.setTrouble("{s} speaks link v{d}, this end v{d}. Deploy both.", .{ self.host, m.agent, link.VERSION })
                    else
                        self.setTrouble("{s} didn't start with a hello.", .{self.host});
                    self.closed = true;
                    u.files = true;
                    return;
                }
                self.hello = true;
                self.trouble = null;
                u.files = true;
                continue;
            }
            switch (m) {
                .ping => {},
                .log => |l| {
                    if (houselog.parse(arena.allocator(), l.line)) |r| fleet.record(r) else |err| fleet.bad(l.line, err);
                    u.logs = true;
                },
                .file => |f| {
                    const i = @backingInt(f.id);
                    _ = self.arenas[i].reset(.retain_capacity);
                    const a = self.arenas[i].allocator();
                    self.texts[i] = .{
                        .path = try a.dupe(u8, f.path),
                        .text = if (f.text) |t| try a.dupe(u8, t) else null,
                        .err = if (f.err) |e| try a.dupe(u8, e) else null,
                    };
                    u.files = true;
                },
                .hub_line => |text| console.hubLine(text),
                .hub_done => console.hubDone(),
                .hub_up => console.hubUp(),
                .hub_down => |why| console.hubDown(why),
                .run_line => |text| wanted.runLine(text),
                .run_end => |ok| wanted.runEnd(io, ok),
                .services => |list| svc.set(list),
                .journal_line => |text| svc.add(text),
                .restarted => |r| svc.restarted(r.unit, r.err),
                .identified => |r| self.identified = .{ .err = if (r.err) |e| keep(&self.identified_buf, e) else null },
                .room_scenes => |r| try self.keepScenes(r.list, r.err),
                .forgot => |r| self.forgot = .{ .err = if (r.err) |e| keep(&self.forgot_buf, e) else null },
                .bridge_info => |r| try self.keepBridge(r.info, r.err),
                .searched => |err| self.searched = .{ .err = if (err) |e| keep(&self.searched_buf, e) else null },
                .hub, .run, .journal, .restart, .identify, .scenes, .forget, .bridge, .search => {
                    self.setTrouble("{s} sent what only admin sends.", .{self.host});
                    self.closed = true;
                    u.files = true;
                    return;
                },
                .agent, .admin => {
                    self.setTrouble("{s} sent a second hello.", .{self.host});
                    self.closed = true;
                    u.files = true;
                    return;
                },
            }
        }
    }

    fn status(self: *const Remote) ?[]const u8 {
        return self.trouble;
    }

    fn linkState(self: *const Remote) LinkState {
        if (self.closed) return .closed;
        if (!self.hello) return .connecting;
        return if (self.trouble != null) .quiet else .up;
    }

    fn stop(self: *Remote, gpa: Allocator, io: Io) void {
        // Closing its stdin is the agent's signal to stop; the kill is for ssh.
        if (self.child.stdin) |f| f.close(io);
        self.child.stdin = null;
        self.child.kill(io);
        self.lines.deinit(gpa);
        for (&self.arenas) |*a| a.deinit();
        self.scenes_arena.deinit();
        self.bridge_arena.deinit();
    }
};

/// What the app is sent, one object a line, each whole.
const Wire = struct {
    const Row_ = struct { cells: []const []const u8, mark: Mark, dev: ?[]const u8 };
    const Section_ = struct {
        screen: Screen,
        label: []const u8,
        summary: []const u8,
        columns: []const []const u8,
        /// How many rows are marked. In Attention only those are in `rows`; in a
        /// table, every row is.
        count: usize,
        rows: []const Row_,
    };
    const Attention_ = struct {
        services: ?[]const Item,
        console: ConsoleState,
        config: ?[]const Item,
        sections: []const Section_,
    };
    const Link = struct {
        state: LinkState,
        /// What's wrong with the link, or what it's waiting for.
        why: ?[]const u8,
        /// Unix ms of the newest house record, from either log.
        newest_ms: ?i64,
    };

    fn attention(a: Allocator, att: Attention) !Attention_ {
        const sections = try a.alloc(Section_, att.sections.len);
        for (att.sections, sections) |s, *w| w.* = try section(a, s, true);
        return .{ .services = att.services, .console = att.console, .config = att.config, .sections = sections };
    }

    fn section(a: Allocator, s: Section, marked_only: bool) !Section_ {
        var rows: std.ArrayList(Row_) = .empty;
        for (s.table.lines) |l| {
            if (!marked_only or l.mark != .none) try rows.append(a, .{ .cells = l.cells, .mark = l.mark, .dev = l.dev });
        }
        return .{ .screen = s.screen, .label = s.label, .summary = s.table.summary, .columns = s.table.columns, .count = s.table.marked(), .rows = rows.items };
    }
};

/// Each service as the Services screen shows it, with what a restart costs.
const ServiceRow = struct {
    unit: link.Unit,
    /// systemd's two words, "active, running", or "not reported".
    state: []const u8,
    enabled: []const u8,
    since: ?[]const u8,
    restarts: u32,
    newer_binary: bool,
    mark: Mark,
    /// What a restart stops, said before it's confirmed.
    cost: []const u8,
};

fn serviceRows(a: Allocator, svc: *const Services) !?[]const ServiceRow {
    if (svc.list.len == 0) return null;
    const rows = try a.alloc(ServiceRow, UNITS.len);
    for (UNITS, rows) |u, *r| {
        const s = svc.find(u.unit) orelse {
            r.* = .{ .unit = u.unit, .state = "not reported", .enabled = "", .since = null, .restarts = 0, .newer_binary = false, .mark = .broken, .cost = u.cost };
            continue;
        };
        const healthy = std.mem.eql(u8, s.active, "active");
        r.* = .{
            .unit = u.unit,
            .state = try std.fmt.allocPrint(a, "{s}, {s}", .{ s.active, s.sub }),
            .enabled = s.enabled,
            .since = try sinceText(a, s),
            .restarts = s.restarts,
            .newer_binary = s.newer_binary,
            .mark = if (!healthy) .broken else if (s.newer_binary) .differs else .none,
            .cost = u.cost,
        };
    }
    return rows;
}

/// Each wanted target: its last run and whether it can be applied, with the
/// hash an `apply` must be given back.
const ConfigTarget = struct {
    name: []const u8,
    /// Where it's written: "the Bridge" or "hub".
    to: []const u8,
    files: []const u8,
    /// Each file's full path, for an editor.
    paths: []const []const u8,
    status: []const u8,
    mark: Mark,
    /// "checking", "applying", "last dry run", "last apply" or "not run yet".
    what: []const u8,
    hash: ?[]const u8,
    /// Why it can't be applied now; null when it can.
    refusal: ?[]const u8,
    lines: []const []const u8,
};

fn configTargets(a: Allocator, wanted: *const Wanted) !?[]const ConfigTarget {
    const base = wanted.base orelse return null;
    const out = try a.alloc(ConfigTarget, wanted_mod.SPECS.len);
    for (wanted_mod.SPECS, &wanted.slots, out, 0..) |spec, *slot, *t, i| {
        const paths = try a.alloc([]const u8, spec.paths.len);
        for (spec.paths, paths) |p, *full| full.* = try std.fs.path.resolve(a, &.{ base, p });
        const hash = try a.create([16]u8);
        t.* = .{
            .name = spec.label,
            .to = switch (spec.target) {
                .hub => "hub",
                .rooms => "the Bridge, hub's file",
                else => "the Bridge",
            },
            .files = spec.shown,
            .paths = paths,
            .status = try wanted.status(a, i),
            .mark = configMark(slot),
            .what = if (slot.running) |c| (if (c) "applying" else "checking") else if (slot.last) |l| (if (l.confirm) "last apply" else "last dry run") else "not run yet",
            .hash = wanted.checkedHex(i, hash),
            .refusal = wanted.applyRefusal(i),
            .lines = slot.lines.items,
        };
    }
    return out;
}

/// hub's console as the app shows it: its state and its newest lines, which
/// include the replies to commands any connection sent.
fn consoleLines(console: *const Console) []const []const u8 {
    const SHOWN = 300;
    const lines = console.lines.items;
    return @ptrCast(lines[lines.len -| SHOWN..]);
}

/// Every device either network lists, for the app's device list and pages: who
/// it is, not how it's doing, which the tables carry. So it's sent only when an
/// inventory changes it.
const DeviceRow = struct {
    dev: []const u8,
    name: []const u8,
    room: ?[]const u8,
    /// `hue-bridge` or `hub`: which network it's on, so which one acts on it.
    network: []const u8,
    product: ?[]const u8,
    has: []const houselog.Service,
    /// Why it's off on purpose, from `rooms.json`; null when it isn't.
    parked: ?[]const u8,
};

fn listedDevs(a: Allocator, rooms: ?rooms_file.Wanted) ![]const []const u8 {
    const w = rooms orelse return &.{};
    const out = try a.alloc([]const u8, w.devices.len);
    for (w.devices, out) |d, *o| o.* = d.dev;
    return out;
}

fn deviceRows(a: Allocator, devices: []const fleet_mod.Device) ![]const DeviceRow {
    var rows: std.ArrayList(DeviceRow) = .empty;
    for (devices) |d| {
        if (!d.listed) continue;
        try rows.append(a, .{ .dev = d.dev, .name = d.name, .room = d.room, .network = d.src, .product = d.product, .has = d.has, .parked = d.parked });
    }
    std.mem.sort(DeviceRow, rows.items, {}, struct {
        fn lt(_: void, x: DeviceRow, y: DeviceRow) bool {
            return std.ascii.lessThanIgnoreCase(x.name, y.name);
        }
    }.lt);
    return rows.items;
}

/// The five whole-class screens, every row, for the app's tables.
fn tables(a: Allocator, data: Data, fleet: *const Fleet, now_ms: i64) ![5]Section {
    return .{
        .{ .key = '1', .screen = .power_on, .label = "Power-on", .table = try powerOnTable(a, data) },
        .{ .key = '2', .screen = .firmware, .label = "Firmware", .table = try firmwareTable(a, data) },
        .{ .key = '3', .screen = .battery, .label = "Battery", .table = try batteryTable(a, fleet.devices.items) },
        .{ .key = '4', .screen = .heard, .label = "Last heard", .table = try heardTable(a, fleet.devices.items, now_ms) },
        .{ .key = '5', .screen = .schedules, .label = "Schedules", .table = try scheduleTable(a, data) },
    };
}

/// The kinds of line the stream sends, each a slot in the outbox, in the order
/// they go when several wait: the link first, so the app always knows that.
const Slot = enum { link, attention, devices, rooms, zigbee, power_on, firmware, battery, heard, schedules, log, services, config, console };

/// The stream's lines on their way to the app: **the newest of each kind only**,
/// because each is a whole screen and an older one is worth nothing once a newer
/// exists. So an app that stops reading costs a few hundred kilobytes here, never
/// a blocked write: a blocked write once stopped this process's pings, and the
/// agent on the server, hearing nothing for a minute, closed the link.
/// A line started is always finished before another begins.
const Outbox = struct {
    gpa: Allocator,
    pending: [@typeInfo(Slot).@"enum".field_names.len]?[]u8 = @splat(null),
    /// The line being sent, with its newline, and how much of it has gone.
    sending: std.ArrayList(u8) = .empty,
    sent: usize = 0,
    /// The hash of each slot's last line, so an unchanged screen isn't sent again.
    last: [@typeInfo(Slot).@"enum".field_names.len]u64 = @splat(0),

    /// The most a write is given at once: a pipe that says it has room takes this
    /// much without waiting.
    const CHUNK = 512;

    fn deinit(self: *Outbox) void {
        for (self.pending) |p| if (p) |line| self.gpa.free(line);
        self.sending.deinit(self.gpa);
    }

    /// Queues `value` as `slot`'s line, replacing one still waiting, unless it's
    /// the same as the last one queued there.
    fn offer(self: *Outbox, slot: Slot, value: anytype) !void {
        var aw: Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        try std.json.Stringify.value(value, .{}, &aw.writer);
        const i = @backingInt(slot);
        const hash = std.hash.Wyhash.hash(0, aw.written());
        if (hash == self.last[i]) return;
        self.last[i] = hash;
        if (self.pending[i]) |old| self.gpa.free(old);
        self.pending[i] = try self.gpa.dupe(u8, aw.written());
    }

    fn idle(self: *const Outbox) bool {
        if (self.sent < self.sending.items.len) return false;
        for (self.pending) |p| if (p != null) return false;
        return true;
    }

    /// Sends what the pipe will take now, and returns. `pipe` has `ready() !bool`
    /// and `write(bytes) !usize`.
    fn pump(self: *Outbox, pipe: anytype) !void {
        while (true) {
            if (self.sent == self.sending.items.len) {
                const i = for (self.pending, 0..) |p, i| {
                    if (p != null) break i;
                } else return;
                const line = self.pending[i].?;
                self.pending[i] = null;
                defer self.gpa.free(line);
                self.sending.clearRetainingCapacity();
                try self.sending.appendSlice(self.gpa, line);
                try self.sending.append(self.gpa, '\n');
                self.sent = 0;
            }
            if (!try pipe.ready()) return;
            const rest = self.sending.items[self.sent..];
            const n = try pipe.write(rest[0..@min(rest.len, CHUNK)]);
            if (n == 0) return;
            self.sent += n;
        }
    }
};

/// The stream's stdout, written only as far as it has room.
const StdoutPipe = struct {
    fn ready(_: StdoutPipe) !bool {
        var fds = [_]posix.pollfd{.{ .fd = posix.STDOUT_FILENO, .events = posix.POLL.OUT, .revents = 0 }};
        if (try posix.poll(&fds, 0) == 0) return false;
        if (fds[0].revents & (posix.POLL.ERR | posix.POLL.HUP) != 0) return error.BrokenPipe;
        return fds[0].revents & posix.POLL.OUT != 0;
    }

    fn write(_: StdoutPipe, bytes: []const u8) !usize {
        const rc = posix.system.write(posix.STDOUT_FILENO, bytes.ptr, bytes.len);
        return switch (posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .AGAIN, .INTR => 0,
            else => error.BrokenPipe,
        };
    }
};

/// Whether stdin has closed. Anything written to it is read and ignored: the
/// stream takes no requests, and a write is a command of its own.
fn stdinClosed() bool {
    var fds = [_]posix.pollfd{.{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 }};
    const ready = posix.poll(&fds, 0) catch return true;
    if (ready == 0 or fds[0].revents == 0) return false;
    var buf: [256]u8 = undefined;
    const n = posix.read(posix.STDIN_FILENO, &buf) catch return true;
    return n == 0;
}

/// Age texts move on while nothing arrives, so Attention is rebuilt this often anyway.
const AGE_MS: i64 = 5000;

/// `dmain admin [H] --json`: what the app draws, as JSON lines. Each `link`,
/// `attention`, `table` (one per whole-class screen), `log`, `services`, `config`
/// and `console` object is whole, and sent again only when it changes. Ends when
/// stdin closes, which is how the app stopping ends it.
fn stream(gpa: Allocator, io: Io, src: anytype) !void {
    var m: Model = undefined;
    try m.init(gpa, io, src, .all);
    defer m.deinit(io, src);
    var box: Outbox = .{ .gpa = gpa };
    defer box.deinit();
    var last_build_ms: i64 = std.math.minInt(i64) / 2;
    var dirty = true;
    while (!stdinClosed()) {
        const changed = try m.step(io, src);
        if (changed.files or changed.logs or changed.svc or changed.wanted or changed.console) dirty = true;
        const now_ms = Io.Timestamp.now(io, .awake).toMilliseconds();
        if (dirty or now_ms - last_build_ms >= AGE_MS) {
            var frame = std.heap.ArenaAllocator.init(gpa);
            defer frame.deinit();
            const a = frame.allocator();
            try box.offer(.link, .{ .link = Wire.Link{ .state = src.linkState(), .why = src.status(), .newest_ms = m.fleet.newest_ms } });
            const real_ms = Io.Timestamp.now(io, .real).toMilliseconds();
            const att = try attention(a, m.data, &m.fleet, &m.console, &m.svc, &m.wanted, real_ms);
            try box.offer(.attention, .{ .attention = try Wire.attention(a, att) });
            try box.offer(.devices, .{ .devices = try deviceRows(a, m.fleet.devices.items) });
            // `devices` is what the file lists, so the app can offer to add what a network holds besides.
            try box.offer(.rooms, .{ .rooms = .{
                .list = if (m.rooms) |r| r.rooms else &.{},
                .devices = try listedDevs(a, m.rooms),
                .err = m.rooms_err,
            } });
            try box.offer(.zigbee, .{ .zigbee = .{ .network = m.data.network, .err = m.data.network_err } });
            for (try tables(a, m.data, &m.fleet, real_ms), [_]Slot{ .power_on, .firmware, .battery, .heard, .schedules }) |t, slot| {
                try box.offer(slot, .{ .table = try Wire.section(a, t, false) });
            }
            try box.offer(.log, .{ .log = .{ .events = att.events } });
            try box.offer(.services, .{ .services = try serviceRows(a, &m.svc) });
            try box.offer(.config, .{ .config = .{ .checkout = m.wanted.base, .targets = try configTargets(a, &m.wanted) } });
            try box.offer(.console, .{ .console = .{ .state = att.console, .lines = consoleLines(&m.console) } });
            dirty = false;
            last_build_ms = now_ms;
        }
        box.pump(StdoutPipe{}) catch return;
        // A closed link can't come back: the app starts another stream. Its last
        // word, why it closed, goes first, given a moment to get there.
        if (src.linkState() == .closed) {
            var tries: usize = 0;
            while (!box.idle() and tries < 20) : (tries += 1) {
                box.pump(StdoutPipe{}) catch return;
                try io.sleep(TICK, .awake);
            }
            return;
        }
        try io.sleep(TICK, .awake);
    }
}

/// `text` copied into `buf`, cut short if it must be: a line's strings don't
/// outlive the next line.
fn keep(buf: []u8, text: []const u8) []const u8 {
    const n = @min(text.len, buf.len);
    @memcpy(buf[0..n], text[0..n]);
    return buf[0..n];
}

/// One request the app makes, each a command of its own over its own link, so
/// the stream never takes input: `apply <target> <hash>`, `restart <service>`,
/// `hub <line…>`, `journal <service>`, `identify <device>`.
const Shot = union(enum) {
    apply: struct { i: usize, hash: []const u8 },
    restart: link.Unit,
    hub: []const u8,
    journal: link.Unit,
    /// A device on the Bridge; hub's own are identified through its console.
    identify: []const u8,
    /// Writes the first `rooms.json` from what both networks hold.
    rooms_init,
    /// Each Bridge room's scenes, which a default is chosen from.
    scenes,
    /// What the Bridge is and holds.
    bridge,
    /// Starts the Bridge's device search.
    search,
    /// Un-joins a device from its network, waits for it to leave the inventory,
    /// then takes it out of the checkout's files.
    remove: []const u8,
    /// One device renamed or moved, or a room's default changed, in the checkout's
    /// `rooms.json`, for Config to apply: nothing goes to the house.
    edit: RoomsEdit,
};

const RoomsEdit = union(enum) {
    device: struct { dev: []const u8, change: rooms_file.Edit },
    default: struct { room: []const u8, scene: []const u8 },
    /// A device a network holds and the file doesn't list yet.
    add: struct { dev: []const u8, name: []const u8, room: ?[]const u8 },
};

pub const shot_usage =
    \\  dmain admin <server> apply <power-on|switches|sensors|schedules|actions|rooms|hub> <hash>
    \\                         check again, then apply if the files still have the hash a dry
    \\                         run showed and it would change something; then read it back
    \\  dmain admin <server> restart <huelog|hub|dmain>
    \\  dmain admin <server> hub <line>      send a line to hub's console
    \\  dmain admin <server> journal <huelog|hub|dmain>   follow it until stdin closes
    \\  dmain admin <server> identify <ieee>   have a device on the Bridge show itself
    \\  dmain admin <server> rooms-init    write the first rooms.json from what the networks hold
    \\  dmain admin <server> rename <ieee> <name>   rename it in rooms.json, for Config to apply
    \\  dmain admin <server> room <ieee> [room]     move it to that room, or none, likewise
    \\  dmain admin <server> scenes      each Bridge room's scenes, as {"scenes":[{"room","scenes"}]}
    \\  dmain admin <server> bridge      what the Bridge is and holds, as {"bridge":{…}}
    \\  dmain admin <server> search      start the Bridge's device search
    \\  dmain admin <server> default <room> <scene>   make it the room's default, likewise;
    \\                         each name one word to the shell, quoted if it has spaces
    \\  dmain admin <server> add <ieee> <name> [room]   list a new device in rooms.json, likewise
    \\  dmain admin <server> remove <ieee>   un-join it from its network, wait for it to leave
    \\                         the inventory, then take it out of rooms.json and hub's devices.json
    \\  Each prints JSON lines: {"line"}, {"phase"}, then {"done":{"ok","why"}}.
    \\
;

fn parseShot(words: []const []const u8, buf: []u8) ?Shot {
    if (words.len == 1 and std.mem.eql(u8, words[0], "rooms-init")) return .rooms_init;
    if (words.len == 1 and std.mem.eql(u8, words[0], "scenes")) return .scenes;
    if (words.len == 1 and std.mem.eql(u8, words[0], "bridge")) return .bridge;
    if (words.len == 1 and std.mem.eql(u8, words[0], "search")) return .search;
    if ((words.len == 3 or words.len == 4) and std.mem.eql(u8, words[0], "add")) {
        if (!link.isDevice(words[1])) return null;
        return .{ .edit = .{ .add = .{ .dev = words[1], .name = words[2], .room = if (words.len == 4) words[3] else null } } };
    }
    if (words.len == 3 and std.mem.eql(u8, words[0], "default")) return .{ .edit = .{ .default = .{ .room = words[1], .scene = words[2] } } };
    if (words.len < 2) return null;
    const verb = words[0];
    if (std.mem.eql(u8, verb, "apply") and words.len == 3) {
        return .{ .apply = .{ .i = Wanted.byName(words[1]) orelse return null, .hash = words[2] } };
    }
    if (std.mem.eql(u8, verb, "restart") and words.len == 2) return .{ .restart = std.meta.stringToEnum(link.Unit, words[1]) orelse return null };
    if (std.mem.eql(u8, verb, "remove") and words.len == 2) return if (link.isDevice(words[1])) .{ .remove = words[1] } else null;
    if (std.mem.eql(u8, verb, "identify") and words.len == 2) return if (link.isDevice(words[1])) .{ .identify = words[1] } else null;
    if (std.mem.eql(u8, verb, "journal") and words.len == 2) return .{ .journal = std.meta.stringToEnum(link.Unit, words[1]) orelse return null };
    if (std.mem.eql(u8, verb, "rename") or std.mem.eql(u8, verb, "room")) {
        const dev = words[1];
        if (!link.isDevice(dev)) return null;
        const rest = joined(words[2..], buf) orelse return null;
        if (std.mem.eql(u8, verb, "rename")) {
            if (rest.len == 0) return null;
            return .{ .edit = .{ .device = .{ .dev = dev, .change = .{ .name = rest } } } };
        }
        return .{ .edit = .{ .device = .{ .dev = dev, .change = .{ .room = if (rest.len > 0) rest else null } } } };
    }
    if (std.mem.eql(u8, verb, "hub")) {
        var w: Io.Writer = .fixed(buf);
        for (words[1..], 0..) |word, i| {
            if (i > 0) w.writeByte(' ') catch return null;
            w.writeAll(word) catch return null;
        }
        return .{ .hub = w.buffered() };
    }
    return null;
}

/// Words given apart, as one name: a name's spaces survive a shell either way.
fn joined(words: []const []const u8, buf: []u8) ?[]const u8 {
    var w: Io.Writer = .fixed(buf);
    for (words, 0..) |word, i| {
        if (i > 0) w.writeByte(' ') catch return null;
        w.writeAll(word) catch return null;
    }
    return w.buffered();
}

const ShotOut = struct {
    out: *Io.Writer,
    gpa: Allocator,

    fn write(self: *ShotOut, value: anytype) !void {
        var aw: Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        try std.json.Stringify.value(value, .{}, &aw.writer);
        try self.out.writeAll(aw.written());
        try self.out.writeByte('\n');
        try self.out.flush();
    }
    fn line(self: *ShotOut, text: []const u8) !void {
        try self.write(.{ .line = text });
    }
    fn lines(self: *ShotOut, list: []const []u8) !void {
        for (list) |l| try self.line(l);
    }
    fn phase(self: *ShotOut, name: []const u8) !void {
        try self.write(.{ .phase = name });
    }
    fn done(self: *ShotOut, ok: bool, why: ?[]const u8) !bool {
        try self.write(.{ .done = .{ .ok = ok, .why = why } });
        return ok;
    }
    /// The lines added to a capped list since `printed`, which it moves on.
    fn since(self: *ShotOut, list: []const []u8, added: u64, printed: *u64) !void {
        const new: usize = @intCast(@min(added - printed.*, list.len));
        try self.lines(list[list.len - new ..]);
        printed.* = added;
    }
};

/// How long a request may take before it's given up, apart from a journal.
const SHOT_MS: i64 = 3 * 60 * 1000;

/// Runs one request against `host`. True if it did what it was asked.
pub fn runShot(gpa: Allocator, io: Io, out: *Io.Writer, host: []const u8, words: []const []const u8) !bool {
    var buf: [hub_client.MAX_COMMAND + 1]u8 = undefined;
    const shot = parseShot(words, &buf) orelse return error.BadUsage;
    var w: ShotOut = .{ .out = out, .gpa = gpa };
    if (shot == .edit) return editRooms(gpa, io, shot.edit, &w);
    var remote: Remote = .{ .host = host };
    var m: Model = undefined;
    try m.init(gpa, io, &remote, switch (shot) {
        .apply => |a| .{ .one = a.i },
        else => .none,
    });
    defer m.deinit(io, &remote);
    return drive(gpa, io, &m, &remote, shot, &w);
}

fn drive(gpa: Allocator, io: Io, m: *Model, src: anytype, shot: Shot, w: *ShotOut) !bool {
    const Phase = enum { check, apply, read_back };
    var phase: Phase = .check;
    var ends_at: u32 = 0;
    var sent = false;
    var printed: u64 = 0;
    // rooms-init: how many devices, and since when, so it waits for the inventories to settle.
    var seen_devices: usize = 0;
    var seen_since_ms: i64 = 0;
    // remove: where it's got to, and when it was un-joined.
    var removal: enum { settle, unjoin, leave } = .settle;
    var on_hub = false;
    var left_since_ms: i64 = 0;
    const start_ms = Io.Timestamp.now(io, .awake).toMilliseconds();
    if (shot == .apply) try w.phase("check");
    while (true) : (try io.sleep(TICK, .awake)) {
        if (shot == .journal and stdinClosed()) return w.done(true, null);
        _ = try m.step(io, src);
        if (src.linkState() == .closed) return w.done(false, src.status() orelse "the link closed");
        if (shot != .journal and Io.Timestamp.now(io, .awake).toMilliseconds() - start_ms > SHOT_MS)
            return w.done(false, "no answer within 3 minutes; what it did is unknown");
        if (!src.canRun()) continue;
        switch (shot) {
            .apply => |a| {
                const slot = &m.wanted.slots[a.i];
                if (slot.read_err) |e| return w.done(false, try std.fmt.allocPrint(m.run_arena.allocator(), "can't read the files ({s})", .{e}));
                if (slot.ends == ends_at) continue;
                ends_at = slot.ends;
                try w.lines(slot.lines.items);
                switch (phase) {
                    .check => {
                        // Nothing else runs until this has gone, so the read-back is this apply's.
                        m.wanted.want = .none;
                        var hb: [16]u8 = undefined;
                        const have = m.wanted.checkedHex(a.i, &hb) orelse "";
                        if (!std.mem.eql(u8, have, a.hash)) return w.done(false, "the files have changed since that dry run: look at the new one first");
                        if (m.wanted.applyRefusal(a.i)) |why| return w.done(false, why);
                        _ = m.run_arena.reset(.retain_capacity);
                        const req = try m.wanted.apply(m.run_arena.allocator(), io, a.i) orelse
                            return w.done(false, "the files changed as it started: look again");
                        src.sendRun(io, req);
                        phase = .apply;
                        try w.phase("apply");
                    },
                    .apply => {
                        if (!slot.last.?.ok) return w.done(false, "the apply failed; what it did is above");
                        m.wanted.want = .{ .one = a.i };
                        phase = .read_back;
                        try w.phase("read back");
                    },
                    .read_back => {
                        const last = slot.last.?;
                        if (!last.ok) return w.done(false, "applied, but the read-back failed");
                        if (last.appliable) return w.done(false, "applied, but the read-back still finds changes");
                        return w.done(true, null);
                    },
                }
            },
            .restart => |unit| {
                if (!sent) {
                    m.svc.restart_ok = null;
                    src.sendRestart(io, unit);
                    sent = true;
                } else if (m.svc.restart_ok) |ok| {
                    // The note's success wording points at the terminal's table; a failure's is systemd's.
                    return w.done(ok, if (ok) null else m.svc.note);
                }
            },
            .hub => |command| {
                if (!sent) {
                    if (hub_client.refusal(command)) |why| return w.done(false, why);
                    printed = m.console.added;
                    m.console.busy = true;
                    src.sendHub(gpa, io, command, &m.console);
                    sent = true;
                }
                try w.since(m.console.lines.items, m.console.added, &printed);
                if (!m.console.busy) {
                    if (m.console.up == false) return w.done(false, "hub's console isn't answering");
                    return w.done(true, null);
                }
            },
            .identify => |dev| {
                if (!sent) {
                    src.sendIdentify(io, dev);
                    sent = true;
                } else if (src.identified) |r| {
                    return w.done(r.err == null, r.err);
                }
            },
            .bridge => {
                if (!sent) {
                    src.sendBridge(io);
                    sent = true;
                } else if (src.bridge) |r| {
                    if (r.err) |why| return w.done(false, why);
                    // Already JSON: written as it is, inside the line's own object.
                    try w.out.print("{{\"bridge\":{s}}}\n", .{r.json});
                    try w.out.flush();
                    return w.done(true, null);
                }
            },
            .search => {
                if (!sent) {
                    src.sendSearch(io);
                    sent = true;
                } else if (src.searched) |r| {
                    if (r.err == null) try w.line("the Bridge is searching: a device it finds shows on Add a device");
                    return w.done(r.err == null, r.err);
                }
            },
            .scenes => {
                if (!sent) {
                    src.sendScenes(io);
                    sent = true;
                } else if (src.room_scenes) |r| {
                    if (r.err) |why| return w.done(false, why);
                    try w.write(.{ .scenes = r.list });
                    return w.done(true, null);
                }
            },
            .remove => |dev| {
                const now_ms = Io.Timestamp.now(io, .awake).toMilliseconds();
                switch (removal) {
                    .settle => {
                        const n = m.fleet.devices.items.len;
                        if (n != seen_devices) {
                            seen_devices = n;
                            seen_since_ms = now_ms;
                        }
                        if (!bothNetworks(m.fleet.devices.items) or now_ms - seen_since_ms < 4000) continue;
                        const d = m.fleet.find(dev) orelse return w.done(false, "neither network lists it");
                        if (!d.listed) return w.done(false, "neither network lists it now");
                        if (try removeRefusal(m.run_arena.allocator(), io, dev)) |why| return w.done(false, why);
                        on_hub = std.mem.eql(u8, d.src, "hub");
                        try w.phase("un-join");
                        if (on_hub) {
                            var cb: [64]u8 = undefined;
                            printed = m.console.added;
                            m.console.busy = true;
                            src.sendHub(gpa, io, try std.fmt.bufPrint(&cb, "remove {s}", .{dev}), &m.console);
                        } else src.sendForget(io, dev);
                        removal = .unjoin;
                    },
                    .unjoin => {
                        if (on_hub) {
                            try w.since(m.console.lines.items, m.console.added, &printed);
                            if (m.console.busy) continue;
                            if (m.console.up == false) return w.done(false, "hub's console isn't answering");
                        } else {
                            const r = src.forgot orelse continue;
                            if (r.err) |why| return w.done(false, why);
                            try w.line("the Bridge has deleted it");
                        }
                        try w.phase("leave");
                        left_since_ms = now_ms;
                        removal = .leave;
                    },
                    .leave => {
                        if (on_hub) try w.since(m.console.lines.items, m.console.added, &printed);
                        const gone = if (m.fleet.find(dev)) |d| !d.listed else true;
                        if (gone) return removeFromFiles(gpa, io, dev, w);
                        if (now_ms - left_since_ms > LEAVE_MS) return w.done(false, if (on_hub)
                            "it's still in hub's inventory: if hub said it's sleepy it leaves when it next wakes. The files are as they were; remove it again once it has gone"
                        else
                            "it's still in the Bridge's inventory. The files are as they were");
                    },
                }
            },
            // Made in the checkout by `runShot`, never sent.
            .edit => unreachable,
            .rooms_init => {
                const now_ms = Io.Timestamp.now(io, .awake).toMilliseconds();
                const n = m.fleet.devices.items.len;
                if (n != seen_devices) {
                    seen_devices = n;
                    seen_since_ms = now_ms;
                }
                // Both networks' inventories, and nothing new for a few seconds.
                if (!bothNetworks(m.fleet.devices.items) or now_ms - seen_since_ms < 4000) continue;
                return roomsInit(gpa, io, m, w);
            },
            .journal => |unit| {
                if (!sent) {
                    printed = m.svc.added;
                    src.sendJournal(io, unit);
                    sent = true;
                }
                try w.since(m.svc.journal.items, m.svc.added, &printed);
            },
        }
    }
}

/// How long a device has to leave its network's inventory once un-joined.
const LEAVE_MS: i64 = 90_000;

/// Why `dev` can't be removed yet: `rooms.json` names it besides its own entry,
/// and would no longer read without it. Null when it can go.
fn removeRefusal(a: Allocator, io: Io, dev: []const u8) !?[]const u8 {
    const rf = @import("rooms_file.zig");
    const base = wanted_mod.findBase(a, io) orelse return "there's no checkout here holding rooms.json";
    const path = try std.fs.path.join(a, &.{ base, rf.FILE });
    const text = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(MAX_FILE)) catch |err|
        return try std.fmt.allocPrint(a, "couldn't read {s} ({t})", .{ path, err });
    var why: ?[]const u8 = null;
    const wanted = rf.parseWhy(a, text, &why) catch |err|
        return try std.fmt.allocPrint(a, "{s} didn't read ({s}): fix it first", .{ rf.FILE, why orelse @errorName(err) });
    const uses = try rf.usesOf(a, wanted, dev);
    if (uses.len == 0) return null;
    var aw: Io.Writer.Allocating = .init(a);
    try aw.writer.writeAll("rooms.json still uses it, in ");
    for (uses, 0..) |u, i| try aw.writer.print("{s}{s}", .{ if (i == 0) "" else ", ", u });
    try aw.writer.writeAll(": take those out first");
    return aw.written();
}

/// Takes a device that has left its network out of the checkout's `rooms.json`
/// and hub's `devices.json`, and names any other wanted file that still mentions
/// it, for a hand edit: those carry it in shapes of their own.
fn removeFromFiles(gpa: Allocator, io: Io, dev: []const u8, w: *ShotOut) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const rf = @import("rooms_file.zig");
    try w.phase("files");
    const base = wanted_mod.findBase(a, io) orelse return w.done(false, "it has left, but there's no checkout here holding rooms.json");
    var dir = try Io.Dir.cwd().openDir(io, base, .{});
    defer dir.close(io);
    const rooms_text = try dir.readFileAlloc(io, rf.FILE, a, .limited(MAX_FILE));
    var wanted = try rf.parse(a, rooms_text);
    if (rf.remove(a, wanted, dev)) |next| {
        var aw: Io.Writer.Allocating = .init(a);
        try rf.render(&aw.writer, next);
        _ = try rf.parse(a, aw.written());
        try dir.writeFile(io, .{ .sub_path = rf.FILE, .data = aw.written() });
        wanted = next;
        try w.line("rooms.json no longer lists it");
    } else |err| switch (err) {
        error.UnknownDevice => try w.line("rooms.json didn't list it"),
        error.InUse => return w.done(false, "it has left, but rooms.json now uses it elsewhere: take it out by hand"),
        error.OutOfMemory => return err,
    }
    const hub_path = wanted_mod.SPECS[Wanted.byName("rooms").?].paths[1];
    if (dir.readFileAlloc(io, hub_path, a, .limited(MAX_FILE))) |hub_text| {
        const entries = try rf.parseHub(a, hub_text);
        var kept: std.ArrayList(rf.HubEntry) = .empty;
        for (entries) |e| if (!std.ascii.eqlIgnoreCase(e.ieee, dev)) try kept.append(a, e);
        if (kept.items.len < entries.len) {
            var aw: Io.Writer.Allocating = .init(a);
            try rf.renderHub(&aw.writer, wanted, kept.items);
            try dir.writeFile(io, .{ .sub_path = hub_path, .data = aw.written() });
            try w.line("hub's devices.json no longer lists it: apply the hub row to give it to hub");
        }
    } else |_| {}
    // Every other wanted file, once each.
    var seen: std.ArrayList([]const u8) = .empty;
    for (wanted_mod.SPECS) |spec| for (spec.paths) |p| {
        if (std.mem.eql(u8, p, rf.FILE) or std.mem.eql(u8, p, hub_path)) continue;
        for (seen.items) |x| {
            if (std.mem.eql(u8, x, p)) break;
        } else try seen.append(a, p);
    };
    try seen.append(a, display_cfg.CONFIG_FILE);
    for (seen.items) |p| {
        const text = dir.readFileAlloc(io, p, a, .limited(MAX_FILE)) catch continue;
        if (std.ascii.findIgnoreCase(text, dev) != null)
            try w.line(try std.fmt.allocPrint(a, "{s} still names it: edit it by hand", .{p}));
    }
    try w.line("Apply Config's rows to bring the rest of the house up to date.");
    return w.done(true, null);
}

fn bothNetworks(devices: []const fleet_mod.Device) bool {
    var hub = false;
    var other = false;
    for (devices) |d| {
        if (std.mem.eql(u8, d.src, "hub")) hub = true else other = true;
    }
    return hub and other;
}

/// Renames or moves one device, or sets a room's default, in the checkout's
/// `rooms.json`, checked by its own reader before it's written.
fn editRooms(gpa: Allocator, io: Io, e: RoomsEdit, w: *ShotOut) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const rf = @import("rooms_file.zig");
    const base = wanted_mod.findBase(a, io) orelse return w.done(false, "there's no checkout here holding rooms.json");
    const path = try std.fs.path.join(a, &.{ base, rf.FILE });
    const text = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(MAX_FILE)) catch |err|
        return w.done(false, try std.fmt.allocPrint(a, "couldn't read {s} ({t})", .{ path, err }));
    var why: ?[]const u8 = null;
    const wanted = rf.parseWhy(a, text, &why) catch |err|
        return w.done(false, try std.fmt.allocPrint(a, "{s} didn't read ({s}): fix it first", .{ rf.FILE, why orelse @errorName(err) }));
    const next = switch (e) {
        .device => |d| rf.edit(a, wanted, d.dev, d.change),
        .default => |d| rf.setDefault(a, wanted, d.room, d.scene),
        .add => |d| rf.add(a, wanted, d.dev, d.name, d.room),
    } catch |err| return w.done(false, switch (err) {
        error.UnknownDevice => "rooms.json doesn't list it yet",
        error.UnknownRoom => "rooms.json has no such room",
        error.EmptyName => "a name can't be empty",
        error.Unchanged => "rooms.json already says that",
        error.AlreadyListed => "rooms.json lists it already",
        error.GeneratedScene => "Max is made by dmain for the dimmers, and is never a default",
        error.OutOfMemory => return err,
    });
    var aw: Io.Writer.Allocating = .init(a);
    try rf.render(&aw.writer, next);
    _ = rf.parseWhy(a, aw.written(), &why) catch |err| return w.done(false, try std.fmt.allocPrint(a, "the edit didn't read back ({s})", .{why orelse @errorName(err)}));
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = aw.written() }) catch |err|
        return w.done(false, try std.fmt.allocPrint(a, "couldn't write {s} ({t})", .{ path, err }));
    switch (e) {
        .device => |d| {
            try w.line(switch (d.change) {
                .name => |n| try std.fmt.allocPrint(a, "rooms.json now calls it {s}", .{std.mem.trim(u8, n, " \t")}),
                .room => |r| try std.fmt.allocPrint(a, "rooms.json now puts it in {s}", .{r orelse "no room"}),
            });
            try w.line("Nothing is changed in the house until the rooms row on Config is applied.");
        },
        .add => |d| {
            try w.line(try std.fmt.allocPrint(a, "rooms.json now lists {s} in {s}", .{ std.mem.trim(u8, d.name, " \t"), d.room orelse "no room" }));
            try w.line("Nothing is changed in the house until the rooms row on Config is applied. A dimmer or sensor needs what it controls added to rooms.json by hand.");
        },
        .default => |d| {
            try w.line(try std.fmt.allocPrint(a, "rooms.json now makes {s} {s}'s default", .{ std.mem.trim(u8, d.scene, " \t"), d.room }));
            // The default is what the dimmers' top button, the Dial and the room's sensors recall.
            try w.line("Nothing is changed in the house until Config's rows are applied: rooms checks the scene is there, and switches, sensors and actions use it.");
        },
    }
    return w.done(true, null);
}

/// Writes `rooms.json` into the checkout from what the networks hold, never over one
/// that's there: after the first, the file is the truth and the networks are compared
/// with it.
fn roomsInit(gpa: Allocator, io: Io, m: *Model, w: *ShotOut) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const rf = @import("rooms_file.zig");
    const base = m.wanted.base orelse return w.done(false, "there's no checkout here to write rooms.json into");
    const path = try std.fs.path.join(a, &.{ base, rf.FILE });
    if (Io.Dir.cwd().access(io, path, .{})) |_| {
        return w.done(false, try std.fmt.allocPrint(a, "{s} is there already: it's the truth now. Delete it to start again", .{path}));
    } else |_| {}

    var current: std.ArrayList(rf.Current) = .empty;
    for (m.fleet.devices.items) |d| {
        if (d.listed) try current.append(a, .{ .dev = d.dev, .name = d.name, .room = d.room });
    }
    // Each room's default is chosen afterwards: the dimmers' own scenes were the
    // Hue app's, and the file is now what decides them.
    const generated = try rf.generate(a, current.items);
    var aw: Io.Writer.Allocating = .init(a);
    try rf.render(&aw.writer, generated);
    // Checked by its own reader before it's written.
    _ = rf.parse(a, aw.written()) catch |err| return w.done(false, try std.fmt.allocPrint(a, "the file made didn't read back ({t})", .{err}));
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = aw.written() }) catch |err|
        return w.done(false, try std.fmt.allocPrint(a, "couldn't write {s} ({t})", .{ path, err }));
    try w.line(try std.fmt.allocPrint(a, "wrote {s}: {d} rooms, {d} devices. Each room with lights needs a default before the dimmers can be written", .{ path, generated.rooms.len, generated.devices.len }));
    return w.done(true, null);
}

pub fn streamLocal(gpa: Allocator, io: Io, app: *const config.Config) !void {
    var local: Local = .{ .app = app, .arena = .init(gpa) };
    return stream(gpa, io, &local);
}

pub fn streamRemote(gpa: Allocator, io: Io, host: []const u8) !void {
    var remote: Remote = .{ .host = host };
    return stream(gpa, io, &remote);
}

/// On the server, from the directory holding dmain.json.
pub fn run(gpa: Allocator, io: Io, app: *const config.Config, out: *Io.Writer) !void {
    var local: Local = .{ .app = app, .arena = .init(gpa) };
    return screens(gpa, io, out, "dmain admin", &local);
}

/// Anywhere, with `host`'s dmain agent.
pub fn runRemote(gpa: Allocator, io: Io, host: []const u8, out: *Io.Writer) !void {
    var remote: Remote = .{ .host = host };
    const title = try std.fmt.allocPrint(gpa, "dmain admin: {s}", .{host});
    defer gpa.free(title);
    return screens(gpa, io, out, title, &remote);
}

/// What the screens are drawn from, whichever draws them: the terminal, or the
/// app through `--json`.
const Model = struct {
    gpa: Allocator,
    fleet: Fleet,
    data_arena: std.heap.ArenaAllocator,
    data: Data = .{ .devices = &.{}, .wanted = null, .schedules = &.{}, .hub_schedules = null, .trouble = null },
    console: Console,
    wanted: Wanted,
    svc: Services,
    run_arena: std.heap.ArenaAllocator,
    /// The power-on screen compares with the wanted file the config screen applies.
    own_arena: std.heap.ArenaAllocator,
    own_power_on: ?FileText = null,
    last_own_ms: i64 = std.math.minInt(i64) / 2,
    /// `rooms.json` from the checkout, for who's parked. Its own arena, as the fleet
    /// points into it.
    rooms_arena: std.heap.ArenaAllocator,
    rooms_hash: u64 = 0,
    rooms: ?rooms_file.Wanted = null,
    /// Why rooms.json wouldn't read, when it wouldn't.
    rooms_err: ?[]const u8 = null,

    const Changed = struct { files: bool, logs: bool, svc: bool, wanted: bool, console: bool };

    fn init(self: *Model, gpa: Allocator, io: Io, src: anytype, want: wanted_mod.Want) !void {
        self.* = .{
            .gpa = gpa,
            .fleet = try Fleet.init(gpa),
            .data_arena = .init(gpa),
            .console = .{ .gpa = gpa },
            .wanted = .{ .gpa = gpa, .base = src.wantedBase(gpa, io), .want = want },
            .svc = .{ .gpa = gpa, .arena = .init(gpa) },
            .run_arena = .init(gpa),
            .own_arena = .init(gpa),
            .rooms_arena = .init(gpa),
        };
        src.start(gpa, io, &self.fleet) catch |err| {
            self.free();
            return err;
        };
    }

    fn deinit(self: *Model, io: Io, src: anytype) void {
        src.stop(self.gpa, io);
        self.free();
    }

    fn free(self: *Model) void {
        self.svc.deinit();
        self.own_arena.deinit();
        self.rooms_arena.deinit();
        self.run_arena.deinit();
        self.wanted.deinit();
        self.console.deinit();
        self.data_arena.deinit();
        self.fleet.deinit();
    }

    /// Reads `rooms.json` again; true if it changed. A file that's gone or won't
    /// read parks nothing, and the second says why.
    fn readRooms(self: *Model, io: Io, base: []const u8) !bool {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const path = try std.fs.path.join(scratch.allocator(), &.{ base, rooms_file.FILE });
        const text = Io.Dir.cwd().readFileAlloc(io, path, scratch.allocator(), .limited(MAX_FILE)) catch "";
        const hash = std.hash.Wyhash.hash(1, text);
        if (hash == self.rooms_hash) return false;
        self.rooms_hash = hash;
        _ = self.rooms_arena.reset(.retain_capacity);
        const ra = self.rooms_arena.allocator();
        self.rooms = null;
        self.rooms_err = null;
        if (text.len > 0) {
            var why: ?[]const u8 = null;
            self.rooms = rooms_file.parseWhy(ra, try ra.dupe(u8, text), &why) catch |err| blk: {
                self.rooms_err = try std.fmt.allocPrint(ra, "{s} didn't read ({s})", .{ rooms_file.FILE, why orelse @errorName(err) });
                break :blk null;
            };
        }
        // The fleet pointed into the arena just reset.
        self.fleet.park(self, parkedReason);
        return true;
    }

    fn parkedReason(self: *Model, dev: []const u8) ?[]const u8 {
        const w = self.rooms orelse return null;
        return w.parkedReason(dev);
    }

    /// Takes what has arrived, starts any dry run that's due, and says what changed.
    fn step(self: *Model, io: Io, src: anytype) !Changed {
        var u = try src.update(self.gpa, io, &self.fleet, &self.console, &self.wanted, &self.svc);
        if (self.wanted.base) |base| {
            const now_ms = Io.Timestamp.now(io, .awake).toMilliseconds();
            if (now_ms - self.last_own_ms >= RELOAD_MS) {
                self.last_own_ms = now_ms;
                const old_hash = if (self.own_power_on) |f| std.hash.Wyhash.hash(0, f.text orelse f.err orelse "") else 0;
                _ = self.own_arena.reset(.retain_capacity);
                const oa = self.own_arena.allocator();
                const path = try std.fs.path.join(oa, &.{ base, "power-on.json" });
                self.own_power_on = if (Io.Dir.cwd().readFileAlloc(io, path, oa, .limited(MAX_FILE))) |text|
                    .{ .path = path, .text = text }
                else |err|
                    .{ .path = path, .err = @errorName(err) };
                if (std.hash.Wyhash.hash(0, self.own_power_on.?.text orelse self.own_power_on.?.err orelse "") != old_hash) u.files = true;
                if (try self.readRooms(io, base)) u.files = true;
            }
        }
        // Every time: a device the logs bring in is parked as soon as it's listed.
        if (u.files or u.logs) self.fleet.park(self, parkedReason);
        if (!src.canRun()) self.wanted.abandon(io);
        _ = self.run_arena.reset(.retain_capacity);
        if (try self.wanted.poll(self.run_arena.allocator(), io, src.canRun())) |r| src.sendRun(io, r);
        if (u.files) {
            _ = self.data_arena.reset(.retain_capacity);
            var texts = src.texts;
            if (self.own_power_on) |f| texts[@backingInt(link.FileId.power_on)] = f;
            self.data = try load(self.data_arena.allocator(), &texts);
        }
        defer {
            self.svc.changed = false;
            self.wanted.changed = false;
            self.console.changed = false;
        }
        return .{ .files = u.files, .logs = u.logs, .svc = self.svc.changed, .wanted = self.wanted.changed, .console = self.console.changed };
    }
};

fn screens(gpa: Allocator, io: Io, out: *Io.Writer, title: []const u8, src: anytype) !void {
    const raw = term.Raw.enable(.{ .signals = false }) orelse {
        try out.writeAll("dmain admin needs a terminal\n");
        return;
    };
    defer raw.restore();

    var layout = layout_mod.Layout.init(.wide_single, .{ 0, 0, 0 }, 90);
    const size = view_mod.getTerminalSize();
    layout.recalculate(size.width, size.height);
    var view = view_mod.View.init(gpa, io, &layout, out);
    defer view.deinit();
    view.title = title;
    view.headers = .{ HEADERS, "", "" };

    var m: Model = undefined;
    try m.init(gpa, io, src, .all);
    defer m.deinit(io, src);
    var chosen: usize = 0;
    // The confirm being typed, while there is one.
    var confirming: ?std.ArrayList(u8) = null;
    defer if (confirming) |*c| c.deinit(gpa);
    var note: ?[]const u8 = null;
    var unit_chosen: usize = 1;

    var screen: Screen = .home;
    var top: usize = 0;
    var dirty = true;
    while (true) {
        var key_buf: [64]u8 = undefined;
        const keys = term.poll(&key_buf);
        var i: usize = 0;
        while (i < keys.len) : (i += 1) {
            const key = keys[i];
            if (key == 0x03) return;
            dirty = true;
            // Every hub command starts with a letter, so a digit on an empty
            // line can only mean another screen.
            const hub_typing = screen == .hub and !(m.console.input.items.len == 0 and key >= '0' and key <= '9');
            if (hub_typing) {
                switch (key) {
                    0x1b => {
                        // An arrow arrives as ESC [ A, all in one read.
                        if (i + 2 < keys.len and keys[i + 1] == '[') {
                            switch (keys[i + 2]) {
                                'A' => top += 1,
                                'B' => top -|= 1,
                                else => {},
                            }
                            i += 2;
                        } else if (m.console.input.items.len > 0) {
                            m.console.input.clearRetainingCapacity();
                        } else {
                            screen = .home;
                            top = 0;
                        }
                    },
                    '\r', '\n' => if (m.console.input.items.len > 0) {
                        // hub echoes the command itself.
                        m.console.busy = true;
                        src.sendHub(gpa, io, m.console.input.items, &m.console);
                        m.console.input.clearRetainingCapacity();
                        top = 0;
                    },
                    0x7f, 0x08 => _ = m.console.input.pop(),
                    0x20...0x7e => if (m.console.input.items.len < hub_client.MAX_COMMAND) try m.console.input.append(gpa, key),
                    else => {},
                }
                continue;
            }
            if (screen == .services) {
                if (confirming) |*typed| {
                    switch (key) {
                        0x1b => {
                            typed.deinit(gpa);
                            confirming = null;
                            note = "left alone: not restarted";
                        },
                        '\r', '\n' => {
                            const yes = std.mem.eql(u8, typed.items, "confirm");
                            typed.deinit(gpa);
                            confirming = null;
                            if (yes and src.canRun()) {
                                src.sendRestart(io, UNITS[unit_chosen].unit);
                                m.svc.note = null;
                                note = null;
                            } else {
                                note = if (yes) "the link to the server isn't up: not restarted" else "that wasn't confirm: not restarted";
                            }
                        },
                        0x7f, 0x08 => _ = typed.pop(),
                        0x20...0x7e => if (typed.items.len < 16) try typed.append(gpa, key),
                        else => {},
                    }
                    continue;
                }
                var handled = true;
                switch (key) {
                    'l', 'h', 'd' => {
                        for (UNITS, 0..) |u_, n| {
                            if (u_.key == key) unit_chosen = n;
                        }
                        note = null;
                        top = 0;
                    },
                    'r' => if (m.svc.list.len == 0) {
                        note = "no state from the server yet";
                    } else {
                        confirming = .empty;
                        note = null;
                    },
                    else => handled = false,
                }
                if (handled) continue;
            }
            if (screen == .config) {
                if (confirming) |*typed| {
                    switch (key) {
                        0x1b => {
                            typed.deinit(gpa);
                            confirming = null;
                            note = "left alone: nothing written";
                        },
                        '\r', '\n' => {
                            const yes = std.mem.eql(u8, typed.items, "confirm");
                            typed.deinit(gpa);
                            confirming = null;
                            if (!yes) {
                                note = "that wasn't confirm: nothing written";
                            } else {
                                _ = m.run_arena.reset(.retain_capacity);
                                if (try m.wanted.apply(m.run_arena.allocator(), io, chosen)) |r| {
                                    src.sendRun(io, r);
                                    note = null;
                                } else {
                                    note = m.wanted.applyRefusal(chosen) orelse "it changed since the dry run, which runs again: nothing written";
                                }
                            }
                        },
                        0x7f, 0x08 => _ = typed.pop(),
                        0x20...0x7e => if (typed.items.len < 16) try typed.append(gpa, key),
                        else => {},
                    }
                    continue;
                }
                // Each wanted file's own key chooses it.
                if (for (wanted_mod.SPECS, 0..) |spec, n| {
                    if (spec.key == key) break n;
                } else null) |n| {
                    chosen = n;
                    note = null;
                    top = 0;
                    continue;
                }
                var handled = true;
                switch (key) {
                    'c' => {
                        m.wanted.recheck(chosen);
                        note = null;
                    },
                    'a' => if (m.wanted.applyRefusal(chosen)) |why| {
                        note = why;
                    } else {
                        confirming = .empty;
                        note = null;
                    },
                    'e' => openInZed(gpa, io, &m.wanted, chosen),
                    else => handled = false,
                }
                if (handled) continue;
            }
            switch (key) {
                'q' => return,
                '0'...'9' => {
                    // A half-typed confirm belongs to the screen it was typed on.
                    if (confirming) |*c| c.deinit(gpa);
                    confirming = null;
                    note = null;
                    screen = @fromBackingInt(@intCast(key - '0'));
                    top = 0;
                },
                'j' => top += 1,
                'k' => top -|= 1,
                else => {},
            }
        }
        view.headers = .{ switch (screen) {
            .hub => HUB_HEADERS,
            .config => CONFIG_HEADERS,
            .services => SERVICES_HEADERS,
            else => HEADERS,
        }, "", "" };

        const changed = try m.step(io, src);
        // The journal follows the chosen service while the screen is open.
        if (screen == .services and m.svc.following != UNITS[unit_chosen].unit and src.canRun()) {
            m.svc.clearJournal();
            m.svc.following = UNITS[unit_chosen].unit;
            src.sendJournal(io, UNITS[unit_chosen].unit);
        }
        if (changed.svc and (screen == .services or screen == .home)) dirty = true;
        if (changed.wanted and (screen == .config or screen == .home)) dirty = true;
        if (changed.console and (screen == .hub or screen == .home)) dirty = true;
        if (changed.files or changed.logs) dirty = true;

        const redrawn = try view.redrawFrameIfNeeded();
        if (dirty or redrawn) {
            var frame = std.heap.ArenaAllocator.init(gpa);
            defer frame.deinit();
            const a = frame.allocator();
            const now_real_ms = Io.Timestamp.now(io, .real).toMilliseconds();
            const rows = switch (screen) {
                .home => try homeRows(a, try attention(a, m.data, &m.fleet, &m.console, &m.svc, &m.wanted, now_real_ms)),
                .services => try servicesRows(a, &m.svc, unit_chosen, if (confirming) |c| c.items else null, note, layout.sec_height -| @as(usize, @intFromBool(src.status() != null)) -| @intFromBool(m.data.trouble != null), top),
                .config => try configRows(a, &m.wanted, chosen, if (confirming) |c| c.items else null, note),
                .hub => try hubRows(a, &m.console, layout.sec_height -| @as(usize, @intFromBool(src.status() != null)) -| @intFromBool(m.data.trouble != null), top),
                .power_on => try powerOnRows(a, m.data),
                .firmware => try firmwareRows(a, m.data),
                .battery => try batteryRows(a, m.fleet.devices.items),
                .heard => try heardRows(a, m.fleet.devices.items, now_real_ms),
                .schedules => try scheduleRows(a, m.data),
                .log => try logRows(a, &m.fleet),
            };
            top = @min(top, switch (screen) {
                .hub => m.console.lines.items.len,
                .services => m.svc.journal.items.len,
                else => rows.len -| 1,
            });
            var alerts: std.ArrayList(Row) = .empty;
            if (src.status()) |s| try alerts.append(a, .{
                .text = if (src.linkState() == .closed) try std.fmt.allocPrint(a, "{s} q quits", .{s}) else s,
                .style = view_mod.WriteStyle.alert,
            });
            if (m.data.trouble) |t| try alerts.append(a, .{ .text = t, .style = view_mod.WriteStyle.alert });
            try alerts.appendSlice(a, rows);
            const from = if (screen == .hub or screen == .services) 0 else @min(top, alerts.items.len - 1);
            try view.renderRows(alerts.items[from..]);
            dirty = false;
        }
        try io.sleep(TICK, .awake);
    }
}

const testing = std.testing;

const wanted_file: power_on.Wanted = .{ .default = .{ .power_on = .previous, .bri_previous = true } };

test "the power-on screen puts what differs first, and doesn't judge a hub light" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const devices = [_]Device{
        .{ .hub = false, .entry = .{ .dev = "a", .name = "Alpha", .power_on = .previous, .power_on_bri_previous = true } },
        .{ .hub = false, .entry = .{ .dev = "b", .name = "Spot", .power_on = .on, .power_on_bri = 100 } },
        .{ .hub = true, .entry = .{ .dev = "c", .name = "panel", .power_on = .on, .power_on_bri = 100 } },
        .{ .hub = false, .entry = .{ .dev = "d", .name = "Sensor" } },
    };
    const rows = try powerOnRows(a, .{ .devices = &devices, .wanted = wanted_file, .schedules = &.{}, .hub_schedules = 0, .trouble = null });
    try testing.expectEqualStrings("3 lights, 1 differ from power-on.json. Now, then wanted:", rows[0].text);
    try testing.expectEqual(@as(usize, 5), rows.len);
    try testing.expect(std.mem.startsWith(u8, rows[2].text, "Spot"));
    try testing.expect(rows[2].style != null);
    try testing.expect(std.mem.startsWith(u8, rows[3].text, "Alpha"));
    try testing.expect(rows[3].style == null);
    try testing.expect(std.mem.indexOf(u8, rows[4].text, "not compared") != null);
    try testing.expect(rows[4].style == null);
}

test "the power-on screen still shows the house with no wanted file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const devices = [_]Device{.{ .hub = false, .entry = .{ .dev = "a", .name = "Alpha", .power_on = .on } }};
    const rows = try powerOnRows(a, .{ .devices = &devices, .wanted = null, .schedules = &.{}, .hub_schedules = 0, .trouble = null });
    try testing.expectEqualStrings("1 lights. No power-on.json to compare with.", rows[0].text);
    try testing.expect(rows[2].style == null);
}

test "the firmware screen compares a device with its own model, and owns up to what it hasn't read" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const devices = [_]Device{
        .{ .hub = false, .entry = .{ .dev = "a", .name = "A", .model = "X", .firmware = "1.0" } },
        .{ .hub = false, .entry = .{ .dev = "b", .name = "B", .model = "X", .firmware = "1.0" } },
        .{ .hub = false, .entry = .{ .dev = "c", .name = "C", .model = "X", .firmware = "0.9" } },
        .{ .hub = false, .entry = .{ .dev = "d", .name = "D", .model = "Y", .firmware = "5.0" } },
        .{ .hub = true, .entry = .{ .dev = "e", .name = "E" } },
    };
    const rows = try firmwareRows(a, .{ .devices = &devices, .wanted = null, .schedules = &.{}, .hub_schedules = 0, .trouble = null });
    try testing.expectEqualStrings("5 devices, 1 on other firmware than their model's commonest, 1 not read yet.", rows[0].text);
    try testing.expect(std.mem.startsWith(u8, rows[2].text, "C"));
    try testing.expect(rows[2].style != null);
    try testing.expect(std.mem.indexOf(u8, rows[6].text, "not read yet") != null);
}

test "the battery screen puts the lowest first, and says what hasn't reported" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const devices = [_]fleet_mod.Device{
        .{ .dev = "a", .name = "Full", .room = null, .src = "hub", .has_battery = true, .battery = 90 },
        .{ .dev = "b", .name = "Low", .room = null, .src = "hub", .has_battery = true, .battery = 12 },
        .{ .dev = "c", .name = "Half", .room = null, .src = "hub", .has_battery = true, .battery = 50 },
        .{ .dev = "d", .name = "Silent", .room = null, .src = "hub", .has_battery = true },
        .{ .dev = "e", .name = "Mains", .room = null, .src = "hub" },
        .{ .dev = "f", .name = "Gone", .room = null, .src = "hub", .has_battery = true, .battery = 1, .listed = false },
    };
    const rows = try batteryRows(a, &devices);
    try testing.expectEqualStrings("4 on battery, 1 at 20% or below, 1 not reported. Lowest first.", rows[0].text);
    try testing.expectEqual(@as(usize, 6), rows.len);
    try testing.expect(std.mem.startsWith(u8, rows[2].text, "Low"));
    try testing.expect(rows[2].style != null);
    try testing.expect(std.mem.startsWith(u8, rows[3].text, "Half"));
    try testing.expect(std.mem.startsWith(u8, rows[4].text, "Full"));
    try testing.expect(std.mem.startsWith(u8, rows[5].text, "Silent"));
}

test "the last-heard screen flags a bad link, not a quiet dimmer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const day = @import("fleet.zig").SENSOR_QUIET_MS;
    const devices = [_]fleet_mod.Device{
        .{ .dev = "a", .name = "Dimmer", .room = null, .src = "hub", .link = .connected },
        .{ .dev = "b", .name = "Sensor", .room = "Hall", .src = "hub", .link = .connected, .reports_steadily = true, .last_heard_ms = 0 },
        .{ .dev = "c", .name = "Lost", .room = null, .src = "hub", .link = .disconnected },
    };
    const rows = try heardRows(a, &devices, day * 2);
    try testing.expect(std.mem.startsWith(u8, rows[0].text, "3 devices, 2 with"));
    try testing.expect(std.mem.startsWith(u8, rows[2].text, "Lost"));
    try testing.expect(std.mem.startsWith(u8, rows[3].text, "Sensor"));
    try testing.expect(std.mem.indexOf(u8, rows[3].text, "2 d ago") != null);
    try testing.expect(std.mem.startsWith(u8, rows[4].text, "Dimmer"));
    try testing.expect(rows[4].style == null);
}

test "the device list names each listed device's network, by name, leaving out what's gone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const devices = [_]fleet_mod.Device{
        .{ .dev = "b", .name = "porch", .room = "Porch", .src = "hue", .product = "SML001", .has = &.{ .motion, .temperature } },
        .{ .dev = "a", .name = "Bulb", .room = null, .src = "hub" },
        .{ .dev = "c", .name = "Gone", .room = null, .src = "hub", .listed = false },
    };
    const rows = try deviceRows(a, &devices);
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("Bulb", rows[0].name);
    try testing.expectEqualStrings("hub", rows[0].network);
    var aw: Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(.{ .devices = rows }, .{}, &aw.writer);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"network\":\"hue\",\"product\":\"SML001\",\"has\":[\"motion\",\"temperature\"]") != null);
}

test "the schedules screen says when each one runs, with those that are on first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const all = [_][]const u8{ "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday" };
    const list = [_]houselog.schedules.Entry{
        .{ .name = "Fan", .kind = "Sleep", .enabled = false, .days = &.{ "monday", "friday" }, .at = "23:00" },
        .{ .name = "Pump", .kind = "Schedule", .enabled = true, .days = &all, .at = "06:30", .until = "08:00" },
        .{ .name = "Dusk", .kind = "Schedule", .enabled = true },
    };
    const rows = try scheduleRows(a, .{ .devices = &.{}, .wanted = null, .schedules = &list, .hub_schedules = 0, .trouble = null });
    try testing.expect(std.mem.startsWith(u8, rows[0].text, "3 on the Bridge, 2 on. hub has 0."));
    try testing.expect(std.mem.startsWith(u8, rows[2].text, "Dusk"));
    try testing.expect(std.mem.indexOf(u8, rows[2].text, "no fixed time") != null);
    try testing.expect(std.mem.indexOf(u8, rows[3].text, "06:30 to 08:00") != null);
    try testing.expect(std.mem.indexOf(u8, rows[3].text, "every day") != null);
    try testing.expect(std.mem.indexOf(u8, rows[4].text, "Mon Fri") != null);
}

test "Attention marks a lost link as broken and a quiet sensor as differing, and the app gets every marked row" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fleet = try Fleet.init(testing.allocator);
    defer fleet.deinit();
    const day = @import("fleet.zig").SENSOR_QUIET_MS;
    try fleet.devices.appendSlice(testing.allocator, &.{
        .{ .dev = "b", .name = "Sensor", .room = "Hall", .src = "hub", .link = .connected, .reports_steadily = true, .last_heard_ms = 0 },
        .{ .dev = "c", .name = "Lost", .room = null, .src = "hub", .link = .disconnected },
    });
    var console: Console = .{ .gpa = testing.allocator };
    defer console.deinit();
    var svc: Services = .{ .gpa = testing.allocator, .arena = .init(testing.allocator) };
    defer svc.deinit();
    var wanted: Wanted = .{ .gpa = testing.allocator, .base = null };
    defer wanted.deinit();
    const devices = [_]Device{
        .{ .hub = false, .entry = .{ .dev = "a", .name = "Alpha", .power_on = .previous, .power_on_bri_previous = true } },
        .{ .hub = false, .entry = .{ .dev = "s", .name = "Spot", .power_on = .on, .power_on_bri = 100 } },
    };
    const data: Data = .{ .devices = &devices, .wanted = wanted_file, .schedules = &.{}, .hub_schedules = 0, .trouble = null };
    const att = try attention(a, data, &fleet, &console, &svc, &wanted, day * 2);
    try testing.expect(att.services == null);
    try testing.expect(att.config == null);

    const heard = att.sections[3].table;
    try testing.expectEqual(Mark.broken, heard.lines[0].mark);
    try testing.expectEqualStrings("Lost", heard.lines[0].name);
    try testing.expectEqual(Mark.differs, heard.lines[1].mark);

    var aw: Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(.{ .attention = try Wire.attention(a, att) }, .{}, &aw.writer);
    const text = aw.written();
    try testing.expect(std.mem.indexOf(u8, text, "\"screen\":\"power_on\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"columns\":[\"Name\",\"Now\",\"Wanted\"]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "{\"cells\":[\"Spot\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"Alpha\"") == null);
    try testing.expect(std.mem.indexOf(u8, text, "\"mark\":\"broken\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"services\":null") != null);

    // A table carries every row, each with its device, for the app's tables and inspector.
    aw.clearRetainingCapacity();
    try std.json.Stringify.value(try Wire.section(a, att.sections[0], false), .{}, &aw.writer);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"cells\":[\"Alpha\",") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"dev\":\"a\"") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"count\":1") != null);

    // The terminal's home screen is drawn from the same gathering.
    const rows = try homeRows(a, att);
    var saw_lost = false;
    for (rows) |r| {
        if (std.mem.indexOf(u8, r.text, "Lost") != null) saw_lost = r.style != null;
    }
    try testing.expect(saw_lost);
}

/// A pipe that takes `room` bytes, then nothing until given more.
const TestPipe = struct {
    room: usize,
    got: std.ArrayList(u8) = .empty,

    fn ready(self: *TestPipe) !bool {
        return self.room > 0;
    }
    fn write(self: *TestPipe, bytes: []const u8) !usize {
        const n = @min(bytes.len, self.room);
        try self.got.appendSlice(testing.allocator, bytes[0..n]);
        self.room -= n;
        return n;
    }
};

test "an unchanged screen isn't sent again, and a full pipe never blocks" {
    var box: Outbox = .{ .gpa = testing.allocator };
    defer box.deinit();
    var pipe: TestPipe = .{ .room = 0 };
    defer pipe.got.deinit(testing.allocator);
    try box.offer(.link, .{ .link = Wire.Link{ .state = .up, .why = null, .newest_ms = 5 } });
    try box.offer(.link, .{ .link = Wire.Link{ .state = .up, .why = null, .newest_ms = 5 } });
    // Nothing fits: it returns rather than waits.
    try box.pump(&pipe);
    try testing.expect(!box.idle());
    pipe.room = 1000;
    try box.pump(&pipe);
    try testing.expect(box.idle());
    try testing.expectEqualStrings("{\"link\":{\"state\":\"up\",\"why\":null,\"newest_ms\":5}}\n", pipe.got.items);
}

test "while the app is behind, only the newest of each kind waits, and a started line is finished first" {
    var box: Outbox = .{ .gpa = testing.allocator };
    defer box.deinit();
    var pipe: TestPipe = .{ .room = 10 };
    defer pipe.got.deinit(testing.allocator);
    try box.offer(.log, .{ .log = "first" });
    try box.pump(&pipe); // ten bytes of the first log line go
    try box.offer(.log, .{ .log = "second" });
    try box.offer(.log, .{ .log = "third" });
    try box.offer(.link, .{ .link = "up" });
    pipe.room = 1000;
    try box.pump(&pipe);
    // The started line completes; "second" never goes; the link jumps the queue.
    try testing.expectEqualStrings(
        \\{"log":"first"}
        \\{"link":"up"}
        \\{"log":"third"}
        \\
    , pipe.got.items);
}

test "a request names its target, service or hub line, and anything else is refused" {
    var buf: [hub_client.MAX_COMMAND + 1]u8 = undefined;
    const apply = parseShot(&.{ "apply", "switches", "b35f28688e1a8641" }, &buf).?;
    try testing.expectEqual(@as(usize, 1), apply.apply.i);
    try testing.expectEqualStrings("b35f28688e1a8641", apply.apply.hash);
    try testing.expectEqual(@as(usize, 0), parseShot(&.{ "apply", "power_on", "x" }, &buf).?.apply.i);
    try testing.expectEqual(link.Unit.hub, parseShot(&.{ "restart", "hub" }, &buf).?.restart);
    try testing.expectEqualStrings("ack moisture", parseShot(&.{ "hub", "ack", "moisture" }, &buf).?.hub);
    try testing.expect(parseShot(&.{ "restart", "sshd" }, &buf) == null);
    try testing.expect(parseShot(&.{ "apply", "switches" }, &buf) == null);
    try testing.expect(parseShot(&.{ "apply", "fstab", "x" }, &buf) == null);
    try testing.expect(parseShot(&.{"hub"}, &buf) == null);
    try testing.expectEqualStrings("00:17:88:01:0e:7d:d5:ad", parseShot(&.{ "identify", "00:17:88:01:0e:7d:d5:ad" }, &buf).?.identify);
    try testing.expect(parseShot(&.{ "identify", "panel" }, &buf) == null);
    try testing.expect(parseShot(&.{"rooms-init"}, &buf).? == .rooms_init);
    try testing.expect(parseShot(&.{ "rooms-init", "x" }, &buf) == null);
    const d = "00:17:88:01:0e:7d:d5:ad";
    try testing.expectEqualStrings("Desk lamp", parseShot(&.{ "rename", d, "Desk", "lamp" }, &buf).?.edit.device.change.name);
    try testing.expectEqualStrings("TV Room", parseShot(&.{ "room", d, "TV Room" }, &buf).?.edit.device.change.room.?);
    try testing.expect(parseShot(&.{ "room", d }, &buf).?.edit.device.change.room == null);
    try testing.expect(parseShot(&.{"scenes"}, &buf).? == .scenes);
    try testing.expect(parseShot(&.{"bridge"}, &buf).? == .bridge);
    try testing.expect(parseShot(&.{"search"}, &buf).? == .search);
    const dflt = parseShot(&.{ "default", "Bedroom 2", "Relax" }, &buf).?.edit.default;
    try testing.expectEqualStrings("Bedroom 2", dflt.room);
    try testing.expectEqualStrings("Relax", dflt.scene);
    try testing.expect(parseShot(&.{ "default", "Bedroom", "2", "Relax" }, &buf) == null);
    const added = parseShot(&.{ "add", d, "Desk lamp", "Study" }, &buf).?.edit.add;
    try testing.expectEqualStrings("Desk lamp", added.name);
    try testing.expectEqualStrings("Study", added.room.?);
    try testing.expect(parseShot(&.{ "add", d, "Desk lamp" }, &buf).?.edit.add.room == null);
    try testing.expect(parseShot(&.{ "add", "panel", "x" }, &buf) == null);
    try testing.expectEqualStrings(d, parseShot(&.{ "remove", d }, &buf).?.remove);
    try testing.expect(parseShot(&.{ "remove", "panel" }, &buf) == null);
    try testing.expect(parseShot(&.{ "rename", d }, &buf) == null);
    try testing.expect(parseShot(&.{ "rename", "panel", "x" }, &buf) == null);
}
