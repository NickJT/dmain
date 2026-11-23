//! Per-ViewMode screen definitions for the TUI: what layout geometry a
//! mode wants, and how to turn live `model.Registry` + `config.Config`
//! state into `Row`s for that mode. Ported from an earlier Hue monitor's `screens.zig`
//! pattern (`ViewSpec`/`RenderPlan`/collate-table) — the table itself
//! (`view_specs`) is new, sized to hub's much simpler per-device model
//! rather than the monitor's per-resource-type one.
//!
//! Unlike the monitor (which had a genuinely 3-column overview: lights/temp/
//! motion as separate resource lists), every hub screen is a single wide
//! table, so they all use `.wide_single` and `RenderPlan.single`. The
//! overview does group by role, but stacked vertically
//! within the one table rather than side by side. The
//! `three_col`/`splitThreeCol` machinery the monitor needed isn't ported; add it
//! back if a future screen genuinely needs side-by-side columns.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Model = @import("model");
const Registry = Model.Registry;
const Device = Model.Device;
const Config = @import("config").Config;
const Layout = @import("layout").Layout;
const LayoutMode = @import("layout").LayoutMode;
const ViewMod = @import("view");
const Row = ViewMod.Row;
const WriteStyle = ViewMod.WriteStyle;
const Ieee = @import("ieee");
const Ansi = @import("ansi");

/// The cursor bar for watch-mode's selectable overview list. It was added
/// for single-key `setup`/`remove`/`permit`; the command line retired those in
/// favour of a command line, so it is now purely a reading aid — a place to
/// keep your eye while typing a command that names its own target. Not one of
/// `view.zig`'s own presets
/// (`alarm`/`alert`/`highlight`) — those carry domain meaning (not-joined,
/// occupied, unconfigured); this is a pure interaction-state color with
/// no domain meaning, so it's defined here rather than added to `view.zig`
/// (kept an unmodified copy of the monitor's). Takes precedence over a row's own
/// `style()` when selected.
const SELECTED_STYLE: WriteStyle = .{ .bold = true, .fg_color = Ansi.fg.black, .bg_color = Ansi.bg.bright_cyan };

/// Section/column-header rows on the grouped screens. Same
/// reasoning as `SELECTED_STYLE`: "this row labels the ones below it" is
/// presentation with no domain meaning, so it belongs here rather than in
/// `view.zig`'s `alarm`/`alert`/`highlight` presets, which all mean something
/// about a device.
const SECTION_STYLE: WriteStyle = .{ .bold = true, .fg_color = Ansi.fg.bright_cyan };

/// Which content is currently being drawn in the top panel, selected by
/// digit key (see main.zig's watch-mode key handler).
pub const ViewMode = enum {
    overview, // `screen overview` — every device seen this session, grouped
    // by role (lights / sensors / controllers / unclassified), each group
    // carrying only the columns that mean something for it.
    config, // `screen config` — devices.json cross-referenced with the live
    // table: allocated (configured + seen), unallocated (configured,
    // never seen), and unconfigured (seen, no devices.json entry) —
    // the "configuration" screen.
    help, // `screen help` — the command list, readable WITH the command line
    // still live underneath. Typing `help` used to dump
    // ~30 lines into the log, which scrolled all but the last few away and
    // left the user staring at a JSON fragment — "looks like something has
    // crashed", as the first live run put it.
};

pub const RenderPlan = union(enum) {
    single: []const Row,
};

/// `now_ms` is a single wall-clock reading the caller takes once per
/// tick (`Io.Timestamp.now(io, .awake).toMilliseconds()`) — passed in
/// rather than plumbing `Io` through every collate fn, so this module
/// stays IO-free like the rest of the pure-formatting layer (`layout`,
/// `ansi`, `view`'s row-drawing). `selected` is the watch-mode cursor
/// row index (`.overview` only) — `null` means no selection (any other
/// screen, or an empty device list). It counts **devices in the order they
/// are drawn**, which since grouping is no longer the
/// order of `model.devices.items`; only `collateOverview` knows the mapping,
/// and nothing outside it needs to.
pub const CollateFn = *const fn (model: *Registry, config: *const Config, now_ms: i64, selected: ?usize, arena: Allocator, lyt: *Layout) anyerror!RenderPlan;

pub const ViewSpec = struct {
    layout_mode: LayoutMode,
    columns: [3]u8,
    headers: [3][]const u8,
    collate: CollateFn,
    /// How much of the window the top panel gets. Default matches what every
    /// screen used before the help screen needed most of the window — a table is fine sharing with the log; a wall of text is not.
    top_pct: u8 = 55,
};

pub const view_specs = std.EnumArray(ViewMode, ViewSpec).init(.{
    .overview = .{
        .layout_mode = .wide_single,
        .columns = .{ 0, 0, 0 },
        .headers = .{ "Devices", "Devices", "Devices" },
        .collate = collateOverview,
    },
    .config = .{
        .layout_mode = .wide_single,
        .columns = .{ 0, 0, 0 },
        .headers = .{ "Configuration", "Configuration", "Configuration" },
        .collate = collateConfig,
    },
    .help = .{
        .layout_mode = .wide_single,
        .columns = .{ 0, 0, 0 },
        .headers = .{ "Help — type any of these on the command line below", "Help", "Help" },
        .collate = collateHelp,
        // Nearly the whole window: the point is reading the commands while
        // typing them, and `renderRows` silently stops at `sec_height`.
        .top_pct = 85,
    },
});

// ── help ──────────────────────────────────────────────────────────

/// The command list — shown on the help SCREEN and as the first half of the
/// console's `help`. One source, so they can't drift.
pub const COMMANDS_HELP =
    \\  status                  network parameters + device count
    \\  list                    devices seen this session
    \\  on|off|toggle <target>  ZCL On/Off — a device OR a group name
    \\  brightness <0-100> <target>  absolute brightness (0 = off)
    \\  colour <#RRGGBB> <target>    set an RGB bulb's colour
    \\  identify <device> [secs=10]  flash it to find it (0 stops)
    \\  permit [secs=60]        open the network for joining
    \\  discover <target>       ZDO endpoint/cluster discovery
    \\  colorcaps <device>      what colour commands a bulb supports (RGB vs white)
    \\  setup <target>          bind + configure reporting (a device sends
    \\                          nothing until this has run once)
    \\  bind <switch> <light>   send the switch's on/off and level commands
    \\                          straight to the light, not through hub
    \\  unbind <switch> <light> undo `bind`
    \\  remove <target>         ZDO Mgmt_Leave: cleanly un-join a device
    \\  ack <device>            clear a latched sensor alert
    \\  group <name>            join every groups.json member to its group_id
    \\  tables                  the table sizes the radio really settled on
    \\  reload [confirm]        check the config files and show what would
    \\                          change; `confirm` applies it, no restart
    \\  adopt <dir> [confirm]   the same with the files in <dir>; `confirm`
    \\                          also puts them in place of hub's own
    \\  backup [force]          export network key/PAN/channel
    \\  restore [file] [confirm]  rebuild a saved network (DESTRUCTIVE)
    \\  form                    leave + form a fresh network (DESTRUCTIVE)
    \\  screen [overview|config|help]   switch dashboard screen
    \\  terminal                leave the dashboard, back to the console
    \\  (over `hub console`, everything above but `screen` and `terminal`)
    \\  quit                    exit hub (the network stays on the NCP)
    \\
    \\<target> = a devices.json name, a groups.json name, an IEEE
    \\           (00:17:88:..), or a nwk (0x1234)
    \\
    \\↑/↓ move the selection bar (a reading aid — commands name their own
    \\     target) · ESC clears the command line · `terminal` leaves
    \\
    \\overview groups devices by what they have PROVEN they can do, so a
    \\device that has never spoken sits under UNCLASSIFIED rather than being
    \\guessed at. `discover <name>` asks it; a sleepy one may need waking.
;

/// Static text, one Row per line. No model access at all — the only screen
/// that ignores every argument it's given.
fn collateHelp(model: *Registry, config: *const Config, now_ms: i64, selected: ?usize, arena: Allocator, lyt: *Layout) anyerror!RenderPlan {
    _ = model;
    _ = config;
    _ = now_ms;
    _ = selected;
    var rows = std.ArrayList(Row).empty;
    var it = std.mem.splitScalar(u8, COMMANDS_HELP, '\n');
    while (it.next()) |line| {
        try rows.append(arena, .{ .text = try ViewMod.padToColumns(arena, line, lyt.sec_widths[0]), .style = null });
    }
    return .{ .single = try rows.toOwnedSlice(arena) };
}

// ── overview ──────────────────────────────────────────────────────

/// Right-pads a row to the section width so it fully overwrites whatever
/// occupied that screen position last: `View.writeTo`
/// positions the cursor and writes exactly these bytes — no clear-to-EOL —
/// so a row that shrinks (a screen switch, "occupied" becoming "clear")
/// would otherwise leave the previous row's tail on screen.
/// What a device is FOR, decided only from capabilities it has actually
/// proven — discovered from its descriptor or learned from its own traffic.
/// Nothing here is inferred from a device's name or
/// guessed from silence: a device that has never told us anything lands in
/// `.unclassified` and says so, rather than being quietly filed as a
/// controller because it happens to look like one.
const Role = enum { light, sensor, controller, unclassified };

fn roleOf(d: Device) Role {
    if (d.onoff_endpoint != null) return .light;
    if (d.occupancy_endpoint != null or d.ias_zone_endpoint != null) return .sensor;
    if (d.controller_endpoint != null) return .controller;
    return .unclassified;
}

// One width array per section, used for BOTH the column header and every
// row under it — so a header can't drift out of alignment with its own
// columns, which is the state this screen was in for six build steps (there
// were no headers at all: a bare `11` in an unlabelled column).
const W_LIGHT = [_]usize{ 12, 10, 8, 7, 6 };
const W_SENSOR = [_]usize{ 12, 10, 30, 7, 5, 6 };
const W_CONTROL = [_]usize{ 12, 10, 7, 5, 6 };
const W_OTHER = [_]usize{ 12, 10, 7, 6 };

/// Compact units, because raw seconds outgrow the column: a device last
/// heard from yesterday is "+86400s" (7 chars in a 6-wide column), which
/// pushed every column right of it out of line. Also just easier to read —
/// "+2h" answers "is this thing alive?" faster than "+7204s" does.
fn ageStr(arena: Allocator, now_ms: i64, dev: Device) ![]const u8 {
    const s_ago = @divTrunc(now_ms - dev.last_seen_ms, 1000);
    if (s_ago < 0) return "+0s"; // clock went backwards; not worth a lie
    if (s_ago < 60) return arena.print("+{d}s", .{s_ago});
    if (s_ago < 3600) return arena.print("+{d}m", .{@divTrunc(s_ago, 60)});
    if (s_ago < 86400) return arena.print("+{d}h", .{@divTrunc(s_ago, 3600)});
    return arena.print("+{d}d", .{@divTrunc(s_ago, 86400)});
}

fn battStr(arena: Allocator, dev: Device) ![]const u8 {
    const b = dev.battery_pct orelse return "-";
    return arena.print("{d}%", .{b});
}

fn linkStr(dev: Device) []const u8 {
    return if (dev.joined) "joined" else "left";
}

/// `null` (never heard) is deliberately "unknown", not "off" — the whole
/// point of attribute polling is that this is now rare rather than
/// permanent, and a light we haven't heard from is not a light that is off.
fn stateStr(dev: Device) []const u8 {
    const on = dev.on orelse return "unknown";
    return if (on) "on" else "off";
}

/// Everything this sensor has actually told us, joined into one column —
/// a real sensor reports several things (the motion sensor sends occupancy,
/// temperature AND illuminance) and one column per reading meant four
/// columns of "-" for every device that isn't that sensor.
fn readingStr(arena: Allocator, dev: Device) ![]const u8 {
    var parts = std.ArrayList([]const u8).empty;
    // A latched-but-live-clear alert reads LATCHED —
    // a trip that came and went, still awaiting `ack`. A live alert reads
    // ALERT regardless of the latch.
    if (dev.alert) |a| {
        if (a) {
            try parts.append(arena, "ALERT");
        } else if (dev.alert_latched) {
            try parts.append(arena, "LATCHED");
        } else {
            try parts.append(arena, "OK");
        }
    } else if (dev.alert_latched) {
        try parts.append(arena, "LATCHED");
    }
    if (dev.occupancy) |o| try parts.append(arena, if (o) "occupied" else "clear");
    if (dev.temperature_centi) |t| try parts.append(arena, try arena.print("{d}.{d:0>2}C", .{ @divTrunc(t, 100), @as(u16, @intCast(@abs(@rem(t, 100)))) }));
    if (dev.illuminance_raw) |raw| {
        // Zigbee's MeasuredValue is 10000*log10(lux)+1 — the model keeps the
        // raw attribute and this is the only place that has ever converted it.
        const lux = std.math.pow(f64, 10.0, (@as(f64, @floatFromInt(raw)) - 1.0) / 10000.0);
        try parts.append(arena, try arena.print("~{d:.0} lux", .{lux}));
    }
    if (parts.items.len == 0) return "— nothing reported yet";
    return std.mem.join(arena, " · ", parts.items);
}

fn rowStyle(dev: Device) ?WriteStyle {
    if (!dev.joined) return WriteStyle.alert;
    if (dev.alert orelse false) return WriteStyle.alarm;
    if (dev.occupancy orelse false) return WriteStyle.alarm;
    return null;
}

/// Grouped by role, each section carrying only the columns that mean
/// something for that kind of device (designed with the
/// user against the real screen). The flat table this replaces gave every
/// device every column, so a light showed "-" under BATT/TEMP/MOTION and a
/// dimmer showed "-" under EP/TEMP/MOTION — and none of the columns were
/// labelled at all.
///
/// `selected` indexes devices in DISPLAY order (the Nth device row drawn),
/// not into `model.devices.items`: grouping means the two orders differ, and
/// the bar has to move down the screen the way the arrow key points. Callers
/// need no knowledge of the ordering — `main.zig` only clamps it to the
/// device count, which grouping doesn't change. Safe because the command line
/// retired the single-key actions: the bar is a reading aid now, so it
/// doesn't have to identify a device to anything else.
fn collateOverview(model: *Registry, config: *const Config, now_ms: i64, selected: ?usize, arena: Allocator, lyt: *Layout) anyerror!RenderPlan {
    var rows = std.ArrayList(Row).empty;
    const width = lyt.sec_widths[0];
    var ordinal: usize = 0;

    const sections = [_]struct { role: Role, label: []const u8 }{
        .{ .role = .light, .label = "LIGHTS" },
        .{ .role = .sensor, .label = "SENSORS" },
        .{ .role = .controller, .label = "CONTROLLERS" },
        .{ .role = .unclassified, .label = "UNCLASSIFIED" },
    };

    for (sections) |sec| {
        var any = false;
        for (model.devices.items) |dev| {
            if (roleOf(dev) != sec.role) continue;

            if (!any) {
                any = true;
                if (rows.items.len > 0) try rows.append(arena, .{ .text = try ViewMod.padToColumns(arena, "", width) });
                const head = switch (sec.role) {
                    .light => try ViewMod.renderColumns(arena, &.{ sec.label, "ROOM", "STATE", "LINK", "AGE" }, &W_LIGHT),
                    .sensor => try ViewMod.renderColumns(arena, &.{ sec.label, "ROOM", "READING", "LINK", "BATT", "AGE" }, &W_SENSOR),
                    .controller => try ViewMod.renderColumns(arena, &.{ sec.label, "ROOM", "LINK", "BATT", "AGE" }, &W_CONTROL),
                    .unclassified => try ViewMod.renderColumns(arena, &.{ sec.label, "ROOM", "LINK", "AGE" }, &W_OTHER),
                };
                try rows.append(arena, .{ .text = try ViewMod.padToColumns(arena, head, width), .style = SECTION_STYLE });
            }

            const name = config.nameFor(dev.ieee) orelse "-";
            const room_raw = config.roomFor(dev.ieee);
            const room = if (room_raw.len > 0) room_raw else "-";
            const age = try ageStr(arena, now_ms, dev);
            const text = switch (sec.role) {
                .light => try ViewMod.renderColumns(arena, &.{ name, room, stateStr(dev), linkStr(dev), age }, &W_LIGHT),
                .sensor => try ViewMod.renderColumns(arena, &.{ name, room, try readingStr(arena, dev), linkStr(dev), try battStr(arena, dev), age }, &W_SENSOR),
                .controller => try ViewMod.renderColumns(arena, &.{ name, room, linkStr(dev), try battStr(arena, dev), age }, &W_CONTROL),
                .unclassified => try ViewMod.renderColumns(arena, &.{ name, room, linkStr(dev), age }, &W_OTHER),
            };
            const style = if (selected == ordinal) SELECTED_STYLE else rowStyle(dev);
            try rows.append(arena, .{ .text = try ViewMod.padToColumns(arena, text, width), .style = style });
            ordinal += 1;
        }
    }

    if (rows.items.len == 0) {
        try rows.append(arena, .{ .text = try ViewMod.padToColumns(arena, "no devices seen yet — `permit` opens the network for joining", width) });
    }
    return .{ .single = rows.items };
}

// ── config ───────────────────────────────────────────────────────

/// Everything a device has proven it can do, in one column. `-` means it has
/// never been discovered AND never spoken — which for a sleepy sensor is a
/// real, long-lived state, not a momentary gap.
fn capabilityStr(arena: Allocator, dev: Device) ![]const u8 {
    var parts = std.ArrayList([]const u8).empty;
    if (dev.onoff_endpoint) |e| try parts.append(arena, try arena.print("on/off ep{d}", .{e}));
    if (dev.occupancy_endpoint) |e| try parts.append(arena, try arena.print("occupancy ep{d}", .{e}));
    if (dev.ias_zone_endpoint) |e| try parts.append(arena, try arena.print("IAS zone ep{d}", .{e}));
    if (dev.controller_endpoint) |e| try parts.append(arena, try arena.print("controller ep{d}", .{e}));
    if (parts.items.len == 0) return "— none discovered";
    return std.mem.join(arena, " · ", parts.items);
}

// Shared by the header and every row, same anti-drift reasoning as the
// overview's. This screen is where identity/plumbing lives now: nwk and IEEE moved off the overview, because you read an IEEE
// when editing devices.json or chasing an unknown joiner — both jobs done
// here — and you read on/off at a glance, which is the overview's job.
const W_CONFIG = [_]usize{ 12, 10, 24, 7, 28, 23 };

fn collateConfig(model: *Registry, config: *const Config, now_ms: i64, selected: ?usize, arena: Allocator, lyt: *Layout) anyerror!RenderPlan {
    _ = now_ms;
    _ = selected; // no selectable list on this screen (yet)
    var rows = std.ArrayList(Row).empty;
    const width = lyt.sec_widths[0];

    try rows.append(arena, .{
        .text = try ViewMod.padToColumns(arena, try ViewMod.renderColumns(arena, &.{ "CONFIGURED", "ROOM", "STATUS", "NWK", "CAPABILITIES", "IEEE" }, &W_CONFIG), width),
        .style = SECTION_STYLE,
    });
    for (config.devices) |d| {
        const ieee = Ieee.parseReversed(d.ieee) catch continue;
        const seen = model.findByIeee(ieee);
        const status: []const u8 = if (seen) |dev| (if (dev.joined) "allocated (joined)" else "allocated (left)") else "unallocated — never seen";
        var nwk_buf: [8]u8 = undefined;
        const nwk: []const u8 = if (seen) |dev| std.fmt.bufPrint(&nwk_buf, "0x{X:0>4}", .{dev.nwk}) catch "?" else "-";
        const caps: []const u8 = if (seen) |dev| try capabilityStr(arena, dev.*) else "-";
        const text = try ViewMod.renderColumns(arena, &.{ d.name, if (d.room.len > 0) d.room else "-", status, nwk, caps, d.ieee }, &W_CONFIG);
        try rows.append(arena, .{ .text = try ViewMod.padToColumns(arena, text, width), .style = if (seen == null) WriteStyle.alert else null });
    }

    var any_unconfigured = false;
    for (model.devices.items) |dev| {
        if (config.nameFor(dev.ieee) != null) continue;
        if (!any_unconfigured) {
            try rows.append(arena, .{ .text = try ViewMod.padToColumns(arena, "", width) });
            try rows.append(arena, .{
                .text = try ViewMod.padToColumns(arena, try ViewMod.renderColumns(arena, &.{ "UNCONFIGURED", "ROOM", "STATUS", "NWK", "CAPABILITIES", "IEEE   (add these to devices.json to name them)" }, &W_CONFIG), width),
                .style = SECTION_STYLE,
            });
            any_unconfigured = true;
        }
        var buf: [24]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        Ieee.printReversed(&w, &dev.ieee) catch {};
        var nwk_buf: [8]u8 = undefined;
        const nwk = std.fmt.bufPrint(&nwk_buf, "0x{X:0>4}", .{dev.nwk}) catch "?";
        const text = try ViewMod.renderColumns(arena, &.{ "-", "-", if (dev.joined) "joined" else "left", nwk, try capabilityStr(arena, dev), w.buffered() }, &W_CONFIG);
        try rows.append(arena, .{ .text = try ViewMod.padToColumns(arena, text, width), .style = WriteStyle.highlight });
    }

    return .{ .single = rows.items };
}

fn testIo() std.Io {
    const S = struct {
        var threaded: std.Io.Threaded = .init_single_threaded;
    };
    return S.threaded.io();
}

const ConfigMod = @import("config");

/// The four roles, one device each, deliberately inserted in an order that
/// does NOT match display order (see the selection test below).
fn fourRoleModel(io: std.Io, model: *Registry) !void {
    _ = try model.upsert(io, try Ieee.parseReversed("00:17:88:01:0e:dd:d8:34"), 0x1111); // dimmer
    model.findByIeee(try Ieee.parseReversed("00:17:88:01:0e:dd:d8:34")).?.controller_endpoint = 1;
    _ = try model.upsert(io, try Ieee.parseReversed("00:17:88:01:08:d1:40:dd"), 0xD714); // bulb1
    model.findByIeee(try Ieee.parseReversed("00:17:88:01:08:d1:40:dd")).?.onoff_endpoint = 11;
    _ = try model.upsert(io, try Ieee.parseReversed("00:17:88:01:09:f1:22:03"), 0x2222); // motion
    model.findByIeee(try Ieee.parseReversed("00:17:88:01:09:f1:22:03")).?.occupancy_endpoint = 1;
    _ = try model.upsert(io, .{ 9, 9, 9, 9, 9, 9, 9, 9 }, 0x3333); // never said what it is
}

fn overviewText(gpa: Allocator, plan: RenderPlan, out: *std.ArrayList(u8)) !void {
    for (plan.single) |row| {
        try out.appendSlice(gpa, row.text);
        try out.append(gpa, '\n');
    }
}

test "collateOverview groups devices by proven capability, under labelled columns" {
    const io = testIo();
    const gpa = std.testing.allocator;

    var model = Registry.init(gpa);
    defer model.deinit();
    try fourRoleModel(io, &model);
    try model.recordReading(io, try Ieee.parseReversed("00:17:88:01:08:d1:40:dd"), .{ .on = true });
    try model.recordReading(io, try Ieee.parseReversed("00:17:88:01:09:f1:22:03"), .{ .occupancy = false });
    try model.recordReading(io, try Ieee.parseReversed("00:17:88:01:09:f1:22:03"), .{ .battery_pct = 87 });

    var config = ConfigMod.Config.init(gpa);
    defer config.deinit();
    const configured = [_]ConfigMod.DeviceEntry{
        .{ .name = "bulb1", .ieee = "00:17:88:01:08:d1:40:dd", .room = "kitchen" },
        .{ .name = "motion", .ieee = "00:17:88:01:09:f1:22:03" },
        .{ .name = "dimmer", .ieee = "00:17:88:01:0e:dd:d8:34" },
    };
    config.devices = @constCast(&configured);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var layout = Layout.init(.wide_single, .{ 0, 0, 0 }, 55);
    const plan = try collateOverview(&model, &config, 0, null, arena.allocator(), &layout);

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(gpa);
    try overviewText(gpa, plan, &buf);
    const all = buf.items;

    // Every section is present and labelled — the flat table had no headers
    // at all, which is what made a bare "11" unreadable.
    for ([_][]const u8{ "LIGHTS", "SENSORS", "CONTROLLERS", "UNCLASSIFIED", "STATE", "READING", "BATT", "AGE", "ROOM" }) |label| {
        try std.testing.expect(std.mem.indexOf(u8, all, label) != null);
    }
    // Each device sits under its own section's header, in order.
    const lights = std.mem.indexOf(u8, all, "LIGHTS").?;
    const sensors = std.mem.indexOf(u8, all, "SENSORS").?;
    const controllers = std.mem.indexOf(u8, all, "CONTROLLERS").?;
    const unclassified = std.mem.indexOf(u8, all, "UNCLASSIFIED").?;
    try std.testing.expect(lights < std.mem.indexOf(u8, all, "bulb1").?);
    try std.testing.expect(std.mem.indexOf(u8, all, "bulb1").? < sensors);
    try std.testing.expect(sensors < std.mem.indexOf(u8, all, "motion").?);
    try std.testing.expect(std.mem.indexOf(u8, all, "motion").? < controllers);
    try std.testing.expect(controllers < std.mem.indexOf(u8, all, "dimmer").?);
    try std.testing.expect(std.mem.indexOf(u8, all, "dimmer").? < unclassified);

    // Readings land in the right places, and a light carries no sensor
    // columns to fill with "-" (the point of grouping).
    try std.testing.expect(std.mem.indexOf(u8, all, "kitchen") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "clear") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "87%") != null);
    const bulb_row = plan.single[1].text;
    try std.testing.expect(std.mem.indexOf(u8, bulb_row, "on") != null);
    try std.testing.expect(std.mem.indexOf(u8, bulb_row, "%") == null);
    // The IEEE and nwk moved to the config screen.
    try std.testing.expect(std.mem.indexOf(u8, all, "0xD714") == null);
    try std.testing.expect(std.mem.indexOf(u8, all, "00:17:88") == null);
}

test "collateOverview: the selection bar counts devices in DISPLAY order, not registry order" {
    // The bar must move down the screen the way the arrow key points. Grouping
    // makes display order differ from `model.devices.items` order, so a
    // collate that used the raw index would scatter the bar around the screen.
    // Here `dimmer` is registry index 0 but drawn LAST (controllers), and
    // `bulb1` is registry index 1 but drawn FIRST (lights).
    const io = testIo();
    const gpa = std.testing.allocator;

    var model = Registry.init(gpa);
    defer model.deinit();
    try fourRoleModel(io, &model);

    var config = ConfigMod.Config.init(gpa);
    defer config.deinit();
    const configured = [_]ConfigMod.DeviceEntry{
        .{ .name = "bulb1", .ieee = "00:17:88:01:08:d1:40:dd" },
        .{ .name = "dimmer", .ieee = "00:17:88:01:0e:dd:d8:34" },
    };
    config.devices = @constCast(&configured);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var layout = Layout.init(.wide_single, .{ 0, 0, 0 }, 55);

    // Selection 0 = the first device DRAWN (bulb1), not devices.items[0] (dimmer).
    const first = try collateOverview(&model, &config, 0, 0, arena.allocator(), &layout);
    for (first.single) |row| {
        const selected = row.style != null and row.style.?.bg_color != null;
        if (std.mem.indexOf(u8, row.text, "bulb1") != null) {
            try std.testing.expect(selected);
        } else if (std.mem.indexOf(u8, row.text, "dimmer") != null) {
            try std.testing.expect(!selected);
        }
    }

    // ...and the LAST index lands on the last device drawn (the unclassified one).
    const last = try collateOverview(&model, &config, 0, 3, arena.allocator(), &layout);
    const last_row = last.single[last.single.len - 1];
    try std.testing.expect(last_row.style != null and last_row.style.?.bg_color != null);
}

test "collateOverview: a light that has never reported says 'unknown', not 'off'" {
    const io = testIo();
    const gpa = std.testing.allocator;
    var model = Registry.init(gpa);
    defer model.deinit();
    const ieee = try Ieee.parseReversed("00:17:88:01:08:d1:40:dd");
    _ = try model.upsert(io, ieee, 0xD714);
    model.findByIeee(ieee).?.onoff_endpoint = 11;

    var config = ConfigMod.Config.init(gpa);
    defer config.deinit();
    const configured = [_]ConfigMod.DeviceEntry{.{ .name = "bulb1", .ieee = "00:17:88:01:08:d1:40:dd" }};
    config.devices = @constCast(&configured);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var layout = Layout.init(.wide_single, .{ 0, 0, 0 }, 55);
    const plan = try collateOverview(&model, &config, 0, null, arena.allocator(), &layout);
    try std.testing.expect(std.mem.indexOf(u8, plan.single[1].text, "unknown") != null);
}

test "collateConfig: allocated, unallocated, unconfigured — with capabilities, nwk and IEEE" {
    const io = testIo();
    const gpa = std.testing.allocator;

    var model = Registry.init(gpa);
    defer model.deinit();
    const bulb1_ieee = try Ieee.parseReversed("00:17:88:01:08:d1:40:dd");
    _ = try model.upsert(io, bulb1_ieee, 0xD714); // "bulb1" — configured AND seen
    model.findByIeee(bulb1_ieee).?.onoff_endpoint = 11;
    _ = try model.upsert(io, .{ 9, 9, 9, 9, 9, 9, 9, 9 }, 0x4242); // seen, not in devices.json

    var config = ConfigMod.Config.init(gpa);
    defer config.deinit();
    const configured_devices = [_]ConfigMod.DeviceEntry{
        .{ .name = "bulb1", .ieee = "00:17:88:01:08:d1:40:dd" },
        .{ .name = "dimmer", .ieee = "00:17:88:01:0e:dd:d8:34" },
    };
    config.devices = @constCast(&configured_devices);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var layout = Layout.init(.wide_single, .{ 0, 0, 0 }, 55);
    const plan = try collateConfig(&model, &config, 0, null, arena.allocator(), &layout);

    var joined_text = std.ArrayList(u8).empty;
    defer joined_text.deinit(gpa);
    try overviewText(gpa, plan, &joined_text);
    const all = joined_text.items;

    try std.testing.expect(std.mem.indexOf(u8, all, "bulb1") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "allocated (joined)") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "dimmer") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "unallocated") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "0x4242") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "UNCONFIGURED") != null);
    // Identity and plumbing live here now, not on the overview.
    try std.testing.expect(std.mem.indexOf(u8, all, "0xD714") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "on/off ep11") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "00:17:88:01:08:d1:40:dd") != null);
    // A configured-but-never-seen device has nothing to say about capability.
    try std.testing.expect(std.mem.indexOf(u8, all, "CAPABILITIES") != null);
}

test "rows stay column-aligned when a reading contains multi-byte UTF-8" {
    // The regression this locks down: `{s:<26}`-style padding counts BYTES,
    // and a real sensor reading is full of "·" (2 bytes, 1 column). The
    // motion sensor's own row — occupancy AND temperature AND illuminance,
    // joined by separators — shifted every column right of it out of line
    // against its own header. Same root cause as an earlier `writeScroll` bug,
    // found the same way (rendering the real fleet and looking at it).
    const io = testIo();
    const gpa = std.testing.allocator;

    var model = Registry.init(gpa);
    defer model.deinit();
    const ieee = try Ieee.parseReversed("00:17:88:01:09:f1:22:03");
    _ = try model.upsert(io, ieee, 0x3CCD);
    model.findByIeee(ieee).?.occupancy_endpoint = 1;
    try model.recordReading(io, ieee, .{ .occupancy = true });
    try model.recordReading(io, ieee, .{ .temperature_centi = 2320 });
    try model.recordReading(io, ieee, .{ .illuminance_raw = 21204 });
    try model.recordReading(io, ieee, .{ .battery_pct = 87 });

    var config = ConfigMod.Config.init(gpa);
    defer config.deinit();
    const configured = [_]ConfigMod.DeviceEntry{.{ .name = "motion", .ieee = "00:17:88:01:09:f1:22:03" }};
    config.devices = @constCast(&configured);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var layout = Layout.init(.wide_single, .{ 0, 0, 0 }, 55);
    layout.recalculate(110, 40);
    const plan = try collateOverview(&model, &config, 0, null, arena.allocator(), &layout);

    const header = plan.single[0].text;
    const row = plan.single[1].text;
    // The reading really does contain the multi-byte separators this is about.
    try std.testing.expect(std.mem.indexOf(u8, row, "·") != null);
    try std.testing.expect(row.len > ViewMod.displayColumns(row)); // multi-byte present

    // "LINK" in the header starts at the same DISPLAY column as "joined" does
    // in the row — the assertion that fails on byte-padding.
    const link_col = ViewMod.displayColumns(header[0..std.mem.indexOf(u8, header, "LINK").?]);
    const joined_col = ViewMod.displayColumns(row[0..std.mem.indexOf(u8, row, "joined").?]);
    try std.testing.expectEqual(link_col, joined_col);

    // And every row pads to the same display width, so a shrinking row can't
    // leave the previous one's tail on screen (padRow's whole purpose).
    try std.testing.expectEqual(ViewMod.displayColumns(header), ViewMod.displayColumns(row));
}

test "ageStr keeps long absences inside their column" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("+5s", try ageStr(a, 5_000, .{ .ieee = undefined, .nwk = 0 }));
    try std.testing.expectEqualStrings("+2m", try ageStr(a, 120_000, .{ .ieee = undefined, .nwk = 0 }));
    try std.testing.expectEqualStrings("+2h", try ageStr(a, 7_204_000, .{ .ieee = undefined, .nwk = 0 }));
    // The case that actually broke the layout: a device last heard from
    // yesterday is "+86400s" — 7 chars in a 6-wide column.
    try std.testing.expectEqualStrings("+1d", try ageStr(a, 86_400_000, .{ .ieee = undefined, .nwk = 0 }));
}

test "Semantic Check" {
    std.testing.refAllDecls(@This());
}
