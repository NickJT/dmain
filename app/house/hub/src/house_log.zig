//! hub's half of the house log: what its devices did, in `lib/houselog`'s
//! vocabulary, in `data/house/YYYY-MM-DD.jsonl`.
//!
//! **hub keeps no second model for this.** Its registry is already first-hand
//! truth, so this module only maps that state into records.
//!
//! **A write can't stop the house.** `DayFile` is best-effort: a full card
//! disables the file with one warning, and everything else carries on.

const std = @import("std");
const Io = std.Io;
const houselog = @import("houselog");
const day_file = @import("day_file");
const Ieee = @import("ieee");
const ConfigMod = @import("config");
const Model = @import("model");

const Body = houselog.Body;
const Service = houselog.Service;
const Device = Model.Device;
const Reading = Model.Reading;

const SERVICE_COUNT = @typeInfo(Service).@"enum".field_names.len;

pub const SOURCE = "hub";
pub const DATA_DIR = "data";
pub const HOUSE_DIR = "house";

/// The same cadence as `huelog`, so a consumer can judge both logs alike.
const HEARTBEAT_S: i64 = 5 * 60;

/// How often to compare settings with the last file.
const SETTINGS_CHECK_S: i64 = 60;

/// IAS zone type "Motion sensor" (ZCL, Zone Types table).
const ZONE_TYPE_MOTION: u16 = 0x000D;

/// Colon-separated lower-case hex, display order.
pub const DEV_LEN = 23;

pub fn devString(ieee: [8]u8, buf: *[DEV_LEN]u8) []const u8 {
    var w = Io.Writer.fixed(buf);
    Ieee.printReversed(&w, &ieee) catch unreachable; // exactly DEV_LEN bytes
    return w.buffered();
}

/// An IAS sensor reports only "alarm", so its enrolment decides what that means.
/// With no zone type known, it stays an alarm: logging a motion sensor as an
/// alarm is a nuisance, and logging a leak as motion could hide one.
fn isMotionZone(zone_type: ?u16) bool {
    return zone_type == ZONE_TYPE_MOTION;
}

/// Zigbee's MeasuredValue is `10000·log10(lux) + 1`, with 0 for too dark to measure.
fn luxFromRaw(raw: u32) f64 {
    if (raw == 0) return 0;
    const exponent = (@as(f64, @floatFromInt(raw)) - 1.0) / 10000.0;
    return houselog.sig3(std.math.pow(f64, 10.0, exponent));
}

/// The record for one reading. `dev` must outlive the result.
pub fn bodyFor(dev: []const u8, zone_type: ?u16, reading: Reading) Body {
    return switch (reading) {
        .battery_pct => |pct| .{ .battery = .{ .dev = dev, .pct = pct } },
        .temperature_centi => |centi| .{ .temperature = .{ .dev = dev, .c = @as(f64, @floatFromInt(centi)) / 100.0 } },
        .humidity_centi => |centi| .{ .humidity = .{ .dev = dev, .rh = @as(f64, @floatFromInt(centi)) / 100.0 } },
        .illuminance_raw => |raw| .{ .light_level = .{ .dev = dev, .lux = luxFromRaw(raw) } },
        .occupancy => |on| .{ .motion = .{ .dev = dev, .on = on } },
        .on => |on| .{ .light = .{ .dev = dev, .on = on } },
        .alert => |on| if (isMotionZone(zone_type))
            .{ .motion = .{ .dev = dev, .on = on } }
        else
            .{ .alarm = .{ .dev = dev, .on = on } },
    };
}

/// A Hue button report's type: 0 press, 1 hold, 2 short release, 3 long release.
pub fn buttonEvent(event_type: u8) ?houselog.ButtonEvent {
    return switch (event_type) {
        0 => .press,
        1 => .hold,
        2 => .release,
        3 => .long_release,
        else => null,
    };
}

/// What a device has proven it can do. The most it can list is every service.
pub fn servicesOf(device: *const Device, buf: *[SERVICE_COUNT]Service) []const Service {
    var n: usize = 0;
    const add = struct {
        fn f(b: []Service, i: *usize, s: Service) void {
            b[i.*] = s;
            i.* += 1;
        }
    }.f;
    if (device.onoff_endpoint != null) add(buf, &n, .light);
    if (device.occupancy_endpoint != null or (device.ias_zone_endpoint != null and isMotionZone(device.zone_type))) add(buf, &n, .motion);
    if (device.ias_zone_endpoint != null and !isMotionZone(device.zone_type)) add(buf, &n, .alarm);
    if (device.controller_endpoint != null) add(buf, &n, .button);
    if (device.temperature_centi != null) add(buf, &n, .temperature);
    if (device.humidity_centi != null) add(buf, &n, .humidity);
    if (device.illuminance_raw != null) add(buf, &n, .light_level);
    if (device.battery_pct != null) add(buf, &n, .battery);
    add(buf, &n, .link);
    return buf[0..n];
}

fn serviceCount(model: *const Model.Registry) usize {
    var total: usize = 0;
    var buf: [SERVICE_COUNT]Service = undefined;
    for (model.devices.items) |*d| total += servicesOf(d, &buf).len;
    return total;
}

pub fn inventoryOf(arena: std.mem.Allocator, devices: []const Device, config: *const ConfigMod.Config) ![]houselog.Device {
    const out = try arena.alloc(houselog.Device, devices.len);
    for (devices, out) |*d, *o| {
        var dev_buf: [DEV_LEN]u8 = undefined;
        const dev = try arena.dupe(u8, devString(d.ieee, &dev_buf));
        var service_buf: [SERVICE_COUNT]Service = undefined;
        const room = config.roomFor(d.ieee);
        o.* = .{
            .dev = dev,
            .name = config.nameFor(d.ieee) orelse dev,
            .room = if (room.len > 0) room else null,
            .has = try arena.dupe(Service, servicesOf(d, &service_buf)),
        };
    }
    return out;
}

// ZCL attributes behind the settings file.
pub const CLUSTER_BASIC: u16 = 0x0000;
pub const CLUSTER_ON_OFF: u16 = 0x0006;
pub const CLUSTER_LEVEL: u16 = 0x0008;
pub const ATTR_MODEL: u16 = 0x0005;
pub const ATTR_FIRMWARE: u16 = 0x4000;
pub const ATTR_STARTUP_ON_OFF: u16 = 0x4003;
pub const ATTR_STARTUP_LEVEL: u16 = 0x4000;

pub const SettingsQuery = struct { index: u8, count: u8, cluster: u16, attr: u16, endpoint: u8 };

/// A sleeping device only hears a request while it's awake, which is just after
/// it spoke. The parent holds a request for about 7.68 s, so this is well inside.
const AWAKE_WINDOW_MS: i64 = 4_000;
/// Between asks on a device's first pass, then afterwards. An attribute it doesn't
/// have is never answered, so without the long gap it would be asked forever.
const FIRST_PASS_GAP_MS: i64 = 15_000;
const LATER_GAP_MS: i64 = 60 * 60 * 1000;

/// What to ask a device next, if anything is due. Pure, so the pacing is testable.
pub fn settingsQuery(device: *const Device, now_ms: i64) ?SettingsQuery {
    if (!device.joined) return null;
    const endpoint = device.onoff_endpoint orelse device.ias_zone_endpoint orelse
        device.occupancy_endpoint orelse device.controller_endpoint orelse return null;
    const is_light = device.onoff_endpoint != null;
    if (!is_light and now_ms - device.last_seen_ms > AWAKE_WINDOW_MS) return null;

    const gap = if (device.settings_rounds == 0) FIRST_PASS_GAP_MS else LATER_GAP_MS;
    if (device.settings_polled_ms != 0 and now_ms - device.settings_polled_ms < gap) return null;

    const Candidate = struct { cluster: u16, attr: u16, known: bool };
    const candidates = [_]Candidate{
        .{ .cluster = CLUSTER_BASIC, .attr = ATTR_MODEL, .known = device.model_id != null },
        .{ .cluster = CLUSTER_BASIC, .attr = ATTR_FIRMWARE, .known = device.firmware != null },
        .{ .cluster = CLUSTER_ON_OFF, .attr = ATTR_STARTUP_ON_OFF, .known = device.startup_on_off != null },
        .{ .cluster = CLUSTER_LEVEL, .attr = ATTR_STARTUP_LEVEL, .known = device.startup_level != null },
    };
    const count: u8 = if (is_light) 4 else 2;
    var offset: u8 = 0;
    while (offset < count) : (offset += 1) {
        const i: u8 = (device.settings_next + offset) % count;
        if (candidates[i].known) continue;
        return .{ .index = i, .count = count, .cluster = candidates[i].cluster, .attr = candidates[i].attr, .endpoint = endpoint };
    }
    return null;
}

/// A device that has come back gets its first pass again, so one that missed it
/// isn't left on the slow gap with up to four questions to go.
pub fn restartSettingsPass(device: *Device) void {
    device.settings_rounds = 0;
    device.settings_next = 0;
    device.settings_polled_ms = 0;
}

/// Long enough for ten polled on/off answers to have gone missing.
const LIGHT_LOST_MS: i64 = 5 * 60 * 1000;

/// A light is polled about every 30 s, so a long silence means it has gone: most
/// likely its power. A sensor can't be judged this way, as it sleeps for hours.
pub fn lightLooksLost(device: *const Device, now_ms: i64) bool {
    if (device.onoff_endpoint == null or !device.joined or device.reported_lost) return false;
    return now_ms - device.last_seen_ms > LIGHT_LOST_MS;
}

/// `model` and `firmware` borrow from `devices`, and the rest from `arena`.
pub fn settingsOf(arena: std.mem.Allocator, devices: []const Device, config: *const ConfigMod.Config) ![]const houselog.settings.Entry {
    const out = try arena.alloc(houselog.settings.Entry, devices.len);
    for (devices, out) |*d, *o| {
        var dev_buf: [DEV_LEN]u8 = undefined;
        const dev = try arena.dupe(u8, devString(d.ieee, &dev_buf));
        o.* = .{
            .dev = dev,
            .name = config.nameFor(d.ieee) orelse dev,
            .model = if (d.model_id) |*t| t.slice() else null,
            .firmware = if (d.firmware) |*t| t.slice() else null,
        };
        if (d.startup_on_off) |raw| o.power_on = switch (raw) {
            0 => .off,
            1 => .on,
            2 => .toggle,
            0xFF => .previous,
            else => null,
        };
        if (d.startup_level) |raw| {
            if (raw == 0xFF) {
                o.power_on_bri_previous = true;
            } else {
                o.power_on_bri = @round(@as(f64, @floatFromInt(raw)) / 254.0 * 100.0);
            }
        }
    }
    return out;
}

/// What the coordinator says of its network, for `network.json`. Null where the
/// radio didn't answer.
pub const NetFacts = struct {
    up: bool,
    channel: ?u8 = null,
    pan: ?u16 = null,
    children: houselog.network.Use = .{},
    neighbours: houselog.network.Use = .{},
    /// Unix ms; 0 when no permit has been opened.
    permit_until_ms: i64 = 0,
};

/// `network.json` from the facts and the device table. A permit that has closed
/// isn't written. Nor is when a device was last heard: a loaded table stamps every
/// device as seen at start, and the house log already says it truly.
pub fn networkFile(arena: std.mem.Allocator, devices: []const Device, facts: NetFacts, now_real_ms: i64) !houselog.network.File {
    const out = try arena.alloc(houselog.network.Device, devices.len);
    for (devices, out) |d, *o| {
        const dev = try arena.alloc(u8, DEV_LEN);
        _ = devString(d.ieee, dev[0..DEV_LEN]);
        o.* = .{
            .dev = dev,
            .nwk = try std.fmt.allocPrint(arena, "0x{x:0>4}", .{d.nwk}),
            .lqi = d.lqi,
            .rssi = d.rssi,
        };
    }
    return .{
        .src = SOURCE,
        .t = "",
        .up = facts.up,
        .channel = facts.channel,
        .pan = if (facts.pan) |p| try std.fmt.allocPrint(arena, "0x{x:0>4}", .{p}) else null,
        .children = facts.children,
        .neighbours = facts.neighbours,
        .permit_until_ms = if (facts.permit_until_ms > now_real_ms) facts.permit_until_ms else null,
        .devices = out,
    };
}

pub const Writer = struct {
    gpa: std.mem.Allocator,
    io: Io,
    file: day_file.DayFile,
    data_dir: Io.Dir,
    settings: houselog.settings.Publisher,
    next_settings_s: i64 = 0,
    /// The local day whose file has had its opening written.
    opened: ?day_file.Day = null,
    /// The last inventory written, because one is only worth a record if it changed.
    last_inventory: []u8 = &.{},
    seen_saves: usize = 0,
    seen_config: ?*const ConfigMod.Config = null,
    /// How many services the devices have proven. A device's first reading of a
    /// kind adds one without any save, and a page choosing rows by service must
    /// hear of it from an inventory.
    seen_services: usize = 0,
    next_heartbeat_s: i64 = 0,

    pub fn init(gpa: std.mem.Allocator, io: Io, data_dir: Io.Dir, house_dir: Io.Dir) Writer {
        return .{
            .gpa = gpa,
            .io = io,
            .data_dir = data_dir,
            .settings = .{ .gpa = gpa },
            .file = day_file.DayFile.init(io, house_dir, "jsonl", null),
        };
    }

    pub fn deinit(self: *Writer) void {
        self.gpa.free(self.last_inventory);
        self.last_inventory = &.{};
        self.settings.deinit();
        self.file.close();
    }

    pub fn emit(self: *Writer, body: Body) void {
        self.write(body, false);
    }

    fn write(self: *Writer, body: Body, is_init: bool) void {
        const at = Io.Timestamp.now(self.io, .real);
        var line: Io.Writer.Allocating = .init(self.gpa);
        defer line.deinit();
        houselog.format(&line.writer, .{ .at = at, .src = SOURCE, .init = is_init, .body = body }) catch return;
        self.file.append(at, line.writer.buffered());
    }

    pub fn reading(self: *Writer, device: *const Device, value: Reading) void {
        var dev_buf: [DEV_LEN]u8 = undefined;
        self.emit(bodyFor(devString(device.ieee, &dev_buf), device.zone_type, value));
    }

    pub fn link(self: *Writer, ieee: [8]u8, status: houselog.Link) void {
        var dev_buf: [DEV_LEN]u8 = undefined;
        self.emit(.{ .link = .{ .dev = devString(ieee, &dev_buf), .status = status } });
    }

    pub fn button(self: *Writer, ieee: [8]u8, n: u8, event: houselog.ButtonEvent) void {
        var dev_buf: [DEV_LEN]u8 = undefined;
        self.emit(.{ .button = .{ .dev = devString(ieee, &dev_buf), .n = n, .event = event } });
    }

    /// Called every engine tick, radio up or down. With the radio down there's
    /// nothing current to report, so a day's opening waits until it's back.
    pub fn tick(self: *Writer, model: *const Model.Registry, config: *const ConfigMod.Config, link_up: bool) void {
        const now = Io.Timestamp.now(self.io, .real);
        const seconds = now.toSeconds();
        if (seconds >= self.next_heartbeat_s) {
            if (self.next_heartbeat_s != 0) self.emit(.heartbeat);
            self.next_heartbeat_s = seconds - @mod(seconds, HEARTBEAT_S) + HEARTBEAT_S;
        }
        if (seconds >= self.next_settings_s) {
            self.next_settings_s = seconds + SETTINGS_CHECK_S;
            self.publishSettings(model, config, now);
        }
        if (!link_up) return;

        const today = day_file.Day.of(now);
        if (self.opened == null or !self.opened.?.eql(today)) {
            self.opened = today;
            self.writeInventory(model, config, true);
            self.writeInitialState(model);
        } else if (model.save_count != self.seen_saves or self.seen_config != config or serviceCount(model) != self.seen_services) {
            self.writeInventory(model, config, false);
        }
        self.seen_saves = model.save_count;
        self.seen_config = config;
        self.seen_services = serviceCount(model);
    }

    /// Writes `network.json` beside the settings file.
    pub fn network(self: *Writer, model: *const Model.Registry, facts: NetFacts) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const now = Io.Timestamp.now(self.io, .real);
        const file = networkFile(arena.allocator(), model.devices.items, facts, now.toMilliseconds()) catch return;
        houselog.network.write(self.gpa, self.io, self.data_dir, SOURCE, now, file) catch |err| {
            std.log.warn("{s}: cannot write: {t}", .{ houselog.network.FILE, err });
        };
    }

    fn publishSettings(self: *Writer, model: *const Model.Registry, config: *const ConfigMod.Config, now: Io.Timestamp) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const entries = settingsOf(arena.allocator(), model.devices.items, config) catch return;
        _ = self.settings.publish(self.io, self.data_dir, SOURCE, now, entries) catch |err| {
            std.log.warn("{s}: cannot write: {t}", .{ houselog.settings.FILE, err });
        };
    }

    fn writeInventory(self: *Writer, model: *const Model.Registry, config: *const ConfigMod.Config, force: bool) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const devices = inventoryOf(arena.allocator(), model.devices.items, config) catch return;

        // Compared as text, because that's what a reader would see differ.
        var text: Io.Writer.Allocating = .init(self.gpa);
        defer text.deinit();
        houselog.format(&text.writer, .{ .at = .{ .nanoseconds = 0 }, .src = SOURCE, .body = .{ .inventory = devices } }) catch return;
        if (!force and std.mem.eql(u8, text.writer.buffered(), self.last_inventory)) return;

        const copy = self.gpa.dupe(u8, text.writer.buffered()) catch return;
        self.gpa.free(self.last_inventory);
        self.last_inventory = copy;
        self.emit(.{ .inventory = devices });
    }

    /// So each day's file can be read alone, and a reader who starts here knows
    /// the state of anything that won't report again today.
    fn writeInitialState(self: *Writer, model: *const Model.Registry) void {
        for (model.devices.items) |*d| {
            var dev_buf: [DEV_LEN]u8 = undefined;
            const dev = devString(d.ieee, &dev_buf);
            if (d.on) |v| self.write(bodyFor(dev, d.zone_type, .{ .on = v }), true);
            if (d.occupancy) |v| self.write(bodyFor(dev, d.zone_type, .{ .occupancy = v }), true);
            if (d.alert) |v| self.write(bodyFor(dev, d.zone_type, .{ .alert = v }), true);
            if (d.temperature_centi) |v| self.write(bodyFor(dev, d.zone_type, .{ .temperature_centi = v }), true);
            if (d.humidity_centi) |v| self.write(bodyFor(dev, d.zone_type, .{ .humidity_centi = v }), true);
            if (d.illuminance_raw) |v| self.write(bodyFor(dev, d.zone_type, .{ .illuminance_raw = v }), true);
            if (d.battery_pct) |v| self.write(bodyFor(dev, d.zone_type, .{ .battery_pct = v }), true);
        }
    }
};

const testing = std.testing;

fn testIo() Io {
    const S = struct {
        var threaded: Io.Threaded = .init_single_threaded;
    };
    return S.threaded.io();
}

const test_wire: [8]u8 = .{ 0x57, 0x38, 0x29, 0xfe, 0xff, 0xda, 0x73, 0x8c };

test "network.json takes each device's short address and link, and only an open permit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const devices = [_]Device{
        .{ .ieee = .{ 0x57, 0x38, 0x29, 0xfe, 0xff, 0xda, 0x73, 0x8c }, .nwk = 0x1a2b, .lqi = 180, .rssi = -61 },
        .{ .ieee = .{ 1, 2, 3, 4, 5, 6, 7, 8 }, .nwk = 2 },
    };
    const f = try networkFile(a, &devices, .{ .up = true, .channel = 15, .pan = 0xcb2c, .permit_until_ms = 1_030_000 }, 1_000_000);
    try std.testing.expectEqualStrings("8c:73:da:ff:fe:29:38:57", f.devices[0].dev);
    try std.testing.expectEqualStrings("0x1a2b", f.devices[0].nwk);
    try std.testing.expectEqual(@as(?i8, -61), f.devices[0].rssi);
    try std.testing.expect(f.devices[1].lqi == null);
    try std.testing.expectEqualStrings("0xcb2c", f.pan.?);
    try std.testing.expectEqual(@as(?i64, 1_030_000), f.permit_until_ms);
    // Closed by the time it's written.
    const closed = try networkFile(a, &devices, .{ .up = true, .permit_until_ms = 999_999 }, 1_000_000);
    try std.testing.expect(closed.permit_until_ms == null);
}

test "devString is the display form devices.json and huelog use" {
    var buf: [DEV_LEN]u8 = undefined;
    try testing.expectEqualStrings("8c:73:da:ff:fe:29:38:57", devString(test_wire, &buf));
}

test "a leak is an alarm, a motion zone is motion, and unknown stays an alarm" {
    const leak = bodyFor("d", 0x002A, .{ .alert = true });
    try testing.expectEqual(true, leak.alarm.on);
    const unknown = bodyFor("d", null, .{ .alert = true });
    try testing.expectEqual(true, unknown.alarm.on);
    const motion = bodyFor("d", ZONE_TYPE_MOTION, .{ .alert = false });
    try testing.expectEqual(false, motion.motion.on);
}

test "units are the world's, not Zigbee's" {
    try testing.expectEqual(@as(f64, 18.22), bodyFor("d", null, .{ .temperature_centi = 1822 }).temperature.c);
    try testing.expectEqual(@as(f64, -3.5), bodyFor("d", null, .{ .temperature_centi = -350 }).temperature.c);
    try testing.expectEqual(@as(f64, 61.8), bodyFor("d", null, .{ .humidity_centi = 6180 }).humidity.rh);
    try testing.expectEqual(@as(f64, 100), bodyFor("d", null, .{ .illuminance_raw = 20001 }).light_level.lux);
    try testing.expectEqual(@as(f64, 0), bodyFor("d", null, .{ .illuminance_raw = 0 }).light_level.lux);
    try testing.expectEqual(@as(u8, 61), bodyFor("d", null, .{ .battery_pct = 61 }).battery.pct);
    try testing.expectEqual(true, bodyFor("d", null, .{ .on = true }).light.on.?);
    try testing.expectEqual(true, bodyFor("d", null, .{ .occupancy = true }).motion.on);
}

test "buttonEvent maps the four reports, and refuses anything else" {
    try testing.expectEqual(houselog.ButtonEvent.press, buttonEvent(0).?);
    try testing.expectEqual(houselog.ButtonEvent.hold, buttonEvent(1).?);
    try testing.expectEqual(houselog.ButtonEvent.release, buttonEvent(2).?);
    try testing.expectEqual(houselog.ButtonEvent.long_release, buttonEvent(3).?);
    try testing.expect(buttonEvent(4) == null);
}

test "servicesOf lists what a device has proven, and always a link" {
    var buf: [SERVICE_COUNT]Service = undefined;

    const light: Device = .{ .ieee = test_wire, .nwk = 1, .onoff_endpoint = 11 };
    try testing.expectEqualSlices(Service, &.{ .light, .link }, servicesOf(&light, &buf));

    const leak: Device = .{ .ieee = test_wire, .nwk = 1, .ias_zone_endpoint = 1, .zone_type = 0x002A, .battery_pct = 100 };
    try testing.expectEqualSlices(Service, &.{ .alarm, .battery, .link }, servicesOf(&leak, &buf));

    const motion: Device = .{ .ieee = test_wire, .nwk = 1, .ias_zone_endpoint = 1, .zone_type = ZONE_TYPE_MOTION };
    try testing.expectEqualSlices(Service, &.{ .motion, .link }, servicesOf(&motion, &buf));

    const dimmer: Device = .{ .ieee = test_wire, .nwk = 1, .controller_endpoint = 1 };
    try testing.expectEqualSlices(Service, &.{ .button, .link }, servicesOf(&dimmer, &buf));
}

test "a light that stops answering looks lost once, and a sensor never does" {
    var light: Device = .{ .ieee = test_wire, .nwk = 1, .onoff_endpoint = 11, .last_seen_ms = 1000 };
    try testing.expect(!lightLooksLost(&light, 1000 + LIGHT_LOST_MS));
    try testing.expect(lightLooksLost(&light, 1000 + LIGHT_LOST_MS + 1));
    light.reported_lost = true;
    try testing.expect(!lightLooksLost(&light, 1000 + LIGHT_LOST_MS + 1));

    const sensor: Device = .{ .ieee = test_wire, .nwk = 1, .ias_zone_endpoint = 1, .last_seen_ms = 1000 };
    try testing.expect(!lightLooksLost(&sensor, 1000 + 100 * LIGHT_LOST_MS));

    const gone: Device = .{ .ieee = test_wire, .nwk = 1, .onoff_endpoint = 11, .joined = false, .last_seen_ms = 1000 };
    try testing.expect(!lightLooksLost(&gone, 1000 + 100 * LIGHT_LOST_MS));
}

test "settingsQuery asks a light for all four, then backs off what it won't answer" {
    var light: Device = .{ .ieee = test_wire, .nwk = 1, .onoff_endpoint = 11 };
    const first = settingsQuery(&light, 1000).?;
    try testing.expectEqual(CLUSTER_BASIC, first.cluster);
    try testing.expectEqual(ATTR_MODEL, first.attr);
    try testing.expectEqual(@as(u8, 11), first.endpoint);
    try testing.expectEqual(@as(u8, 4), first.count);

    light.settings_polled_ms = 1000;
    try testing.expect(settingsQuery(&light, 2000) == null); // too soon

    light.model_id = Model.ShortText.of("LTA001");
    light.firmware = Model.ShortText.of("1.2.3");
    const third = settingsQuery(&light, 1000 + FIRST_PASS_GAP_MS).?;
    try testing.expectEqual(ATTR_STARTUP_ON_OFF, third.attr);
    try testing.expectEqual(CLUSTER_ON_OFF, third.cluster);

    light.settings_rounds = 1;
    try testing.expect(settingsQuery(&light, 1000 + FIRST_PASS_GAP_MS) == null);
    try testing.expect(settingsQuery(&light, 1000 + LATER_GAP_MS) != null);

    light.startup_on_off = 0xFF;
    light.startup_level = 0xFF;
    try testing.expect(settingsQuery(&light, 1000 + 10 * LATER_GAP_MS) == null); // all known
}

test "restartSettingsPass asks a returning light at once, then at the first-pass pace" {
    var light: Device = .{
        .ieee = test_wire,
        .nwk = 1,
        .onoff_endpoint = 11,
        .settings_rounds = 1,
        .settings_next = 2,
        .settings_polled_ms = 5000,
    };
    try testing.expect(settingsQuery(&light, 5000 + FIRST_PASS_GAP_MS) == null); // on the slow gap

    restartSettingsPass(&light);
    const q = settingsQuery(&light, 5000 + 1).?;
    try testing.expectEqual(ATTR_MODEL, q.attr);

    light.settings_polled_ms = 5001;
    try testing.expect(settingsQuery(&light, 5002) == null);
    try testing.expect(settingsQuery(&light, 5001 + FIRST_PASS_GAP_MS) != null);
}

test "settingsQuery only asks a sleeping device just after it spoke" {
    var sensor: Device = .{ .ieee = test_wire, .nwk = 1, .ias_zone_endpoint = 1, .last_seen_ms = 10_000 };
    try testing.expect(settingsQuery(&sensor, 10_000 + AWAKE_WINDOW_MS + 1) == null);
    const q = settingsQuery(&sensor, 10_000 + 100).?;
    try testing.expectEqual(ATTR_MODEL, q.attr);
    try testing.expectEqual(@as(u8, 2), q.count); // no startup attributes on a sensor

    sensor.joined = false;
    try testing.expect(settingsQuery(&sensor, 10_000 + 100) == null);
}

test "settingsQuery moves past an attribute a device hasn't answered" {
    var light: Device = .{ .ieee = test_wire, .nwk = 1, .onoff_endpoint = 1, .settings_next = 3 };
    try testing.expectEqual(ATTR_STARTUP_LEVEL, settingsQuery(&light, 1000).?.attr);
    light.settings_next = 0;
    try testing.expectEqual(ATTR_MODEL, settingsQuery(&light, 1000).?.attr);
}

test "settingsOf says power-on in the house's words" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var config = ConfigMod.Config.init(gpa);
    defer config.deinit();
    const named = [_]ConfigMod.DeviceEntry{.{ .name = "panel", .ieee = "8c:73:da:ff:fe:29:38:57" }};
    config.devices = @constCast(&named);

    const devices = [_]Device{
        .{ .ieee = test_wire, .nwk = 1, .startup_on_off = 0xFF, .startup_level = 0xFF, .model_id = Model.ShortText.of("LTA001") },
        .{ .ieee = .{ 1, 2, 3, 4, 5, 6, 7, 8 }, .nwk = 2, .startup_on_off = 1, .startup_level = 254 },
        .{ .ieee = .{ 9, 2, 3, 4, 5, 6, 7, 8 }, .nwk = 3, .startup_on_off = 0, .startup_level = 0 },
        .{ .ieee = .{ 8, 2, 3, 4, 5, 6, 7, 8 }, .nwk = 4 },
    };
    const entries = try settingsOf(arena.allocator(), &devices, &config);

    try testing.expectEqualStrings("panel", entries[0].name);
    try testing.expectEqualStrings("LTA001", entries[0].model.?);
    try testing.expectEqual(houselog.settings.PowerOn.previous, entries[0].power_on.?);
    try testing.expect(entries[0].power_on_bri_previous);
    try testing.expectEqual(houselog.settings.PowerOn.on, entries[1].power_on.?);
    try testing.expectEqual(@as(f64, 100), entries[1].power_on_bri.?);
    try testing.expectEqual(houselog.settings.PowerOn.off, entries[2].power_on.?);
    try testing.expectEqual(@as(f64, 0), entries[2].power_on_bri.?);
    try testing.expect(entries[3].power_on == null); // not known isn't "off"
    try testing.expect(entries[3].model == null);
}

test "every record this writes survives houselog's strict reader, and each day opens" {
    const gpa = testing.allocator;
    const io = testIo();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var model = Model.Registry.init(gpa);
    defer model.deinit();
    var config = ConfigMod.Config.init(gpa);
    defer config.deinit();
    const named = [_]ConfigMod.DeviceEntry{.{ .name = "moisture", .ieee = "8c:73:da:ff:fe:29:38:57", .room = "Garage" }};
    config.devices = @constCast(&named);

    try model.devices.append(gpa, .{
        .ieee = test_wire,
        .nwk = 1,
        .ias_zone_endpoint = 1,
        .zone_type = 0x002A,
        .battery_pct = 100,
        .alert = false,
    });

    var w = Writer.init(gpa, io, tmp.dir, tmp.dir);
    defer w.deinit();
    w.emit(.start);
    w.tick(&model, &config, false); // radio down: no opening yet
    w.emit(.{ .down = "FileNotFound" });
    w.tick(&model, &config, true); // opening: inventory and state
    w.tick(&model, &config, true); // nothing changed: nothing written
    w.emit(.up);
    w.reading(&model.devices.items[0], .{ .alert = true });
    w.link(test_wire, .disconnected);
    w.button(test_wire, 4, .release);
    model.save_count += 1;
    w.tick(&model, &config, true); // a save, but the same inventory: nothing written
    model.devices.items[0].onoff_endpoint = 1;
    model.save_count += 1;
    w.tick(&model, &config, true); // a real change: a new inventory
    model.devices.items[0].temperature_centi = 1890;
    w.tick(&model, &config, true); // a first reading, with no save: it now has a temperature
    w.file.close();

    var name_buf: [32]u8 = undefined;
    const name = try day_file.Day.of(Io.Timestamp.now(io, .real)).fileName(&name_buf, "jsonl");
    const text = try tmp.dir.readFileAlloc(io, name, gpa, .limited(1 << 20));
    defer gpa.free(text);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var kinds: std.ArrayList(houselog.Kind) = .empty;
    defer kinds.deinit(gpa);
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    var inits: usize = 0;
    while (lines.next()) |line| {
        const r = try houselog.parse(arena.allocator(), line);
        try testing.expectEqualStrings(SOURCE, r.src);
        if (r.init) inits += 1;
        try kinds.append(gpa, std.meta.activeTag(r.body));
    }
    try testing.expectEqualSlices(houselog.Kind, &.{
        .start, .down, .inventory, .alarm, .battery, .up, .alarm, .link, .button, .inventory, .inventory,
    }, kinds.items);
    try testing.expectEqual(@as(usize, 2), inits);
}
