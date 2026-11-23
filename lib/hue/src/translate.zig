//! The Hue bridge's capture, translated into the house log.
//!
//! Every CLIP v2 quirk is settled here, once, and none reaches a house record:
//!
//! - **A device is its IEEE address**, taken from its `zigbee_connectivity`
//!   service; one with none is `hue:<device uuid>`.
//! - **Light level becomes lux.** The bridge reports `10000·log10(lux) + 1`.
//! - **Colour temperature becomes kelvin.** The bridge reports mirek.
//! - **Names are trimmed.** Several on this bridge end in a space.
//! - **Button and link vocabularies are the house's own**: `initial_press` is
//!   `press`, `connectivity_issue` is `issue`, and so on.
//!
//! **Values come from lib/hue's resource model**, which the translator keeps
//! current by applying each event, so the shape of a temperature report is
//! still read in exactly one place. Only what the model does not carry — a
//! button's number, a light's channel, a rotary dial's step — is read from the
//! JSON here.
//!
//! **A state record carries the service's whole state, and is written only
//! when an event touched that state.** A light event that only changed its
//! effect list writes nothing.
//!
//! Not carried, and left to the raw capture: light colour (xy), scenes,
//! grouped services, and everything that is not a device's own service.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json_get = @import("json_get").json_get;
const houselog = @import("houselog");
const light_ids = @import("light_ids");
const capture = @import("capture");
const sse_events = @import("sse_events");
const Resources = @import("resources");
const Registry = @import("maps").ResourceRegistry;

const Service = houselog.Service;
const Body = houselog.Body;

pub const source = capture.source;

const Binding = struct {
    dev: []const u8,
    service: Service,
    /// A button's number, or a light's channel.
    n: u8 = 0,
};

/// A `time_point`'s fixed time as "HH:MM", if it has one: a sunset has none.
fn timeOf(arena: Allocator, holder: std.json.ObjectMap) !?[]const u8 {
    const point = json_get.optionalObject(holder, "time_point") orelse return null;
    const t = json_get.optionalObject(point, "time") orelse return null;
    const hour = json_get.optionalInt(t, "hour") orelse return null;
    const minute = json_get.optionalInt(t, "minute") orelse 0;
    return try std.fmt.allocPrint(arena, "{d:0>2}:{d:0>2}", .{ @as(u64, @intCast(hour)), @as(u64, @intCast(minute)) });
}

/// When an automation runs. Scripts say it in two shapes: `when_extended` with a
/// start and end, or `when` with one time.
fn applyWhen(arena: Allocator, entry: *houselog.schedules.Entry, config: std.json.ObjectMap) !void {
    const when = json_get.optionalObject(config, "when_extended") orelse json_get.optionalObject(config, "when") orelse return;
    if (json_get.optionalArray(when, "recurrence_days")) |days| {
        var list: std.ArrayList([]const u8) = .empty;
        for (days.items) |d| if (d == .string) try list.append(arena, d.string);
        entry.days = list.items;
    }
    if (json_get.optionalObject(when, "start_at")) |start| entry.at = try timeOf(arena, start);
    if (entry.at == null) entry.at = try timeOf(arena, when);
    if (json_get.optionalObject(when, "end_at")) |end| entry.until = try timeOf(arena, end);
}

/// A Hue light's `powerup`, in the house's words.
fn applyPowerUp(entry: *houselog.settings.Entry, light: *const Resources.Light) void {
    const eql = std.mem.eql;
    if (light.pu_mode) |mode| {
        if (eql(u8, mode, "previous")) entry.power_on = .previous;
        if (eql(u8, mode, "toggle")) entry.power_on = .toggle;
        if (eql(u8, mode, "on")) entry.power_on = if (light.pu_on orelse true) .on else .off;
    }
    if (light.pu_dimming) |mode| {
        if (eql(u8, mode, "previous")) entry.power_on_bri_previous = true;
        if (eql(u8, mode, "dimming")) entry.power_on_bri = light.pu_brightness;
    }
    if (light.pu_mirek) |mirek| {
        if (mirek > 0) entry.power_on_ct_k = @intCast(@divTrunc(1_000_000 + @divTrunc(mirek, 2), mirek));
    }
}

pub const Translator = struct {
    gpa: Allocator,
    registry: ?Registry = null,
    /// Everything derived from the current resource list.
    arena: std.heap.ArenaAllocator,
    bindings: std.StringHashMapUnmanaged(Binding) = .empty,
    /// Service ids in inventory order, for the `init` records.
    order: std.ArrayList([]const u8) = .empty,
    schedule_entries: std.ArrayList(houselog.schedules.Entry) = .empty,
    /// Beside `schedule_entries`: each one's id on the Bridge.
    schedule_ids: std.ArrayList([]const u8) = .empty,
    devices: std.ArrayList(houselog.Device) = .empty,
    /// Hue device uuid → index into `devices`, so a rename finds its entry.
    device_index: std.StringHashMapUnmanaged(usize) = .empty,

    pub fn init(gpa: Allocator) Translator {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(self: *Translator) void {
        if (self.registry) |*r| r.deinit();
        self.arena.deinit();
    }

    /// One capture record in; zero or more house records out, each through
    /// `out.emit(record)`. A record's strings live until the next `feed`.
    pub fn feed(self: *Translator, rec: capture.Record, out: anytype) !void {
        const at = rec.at;
        switch (rec.kind) {
            .start => out.emit(.{ .at = at, .src = source, .body = .start }),
            .up => out.emit(.{ .at = at, .src = source, .body = .up }),
            .down => out.emit(.{ .at = at, .src = source, .body = .{ .down = rec.note orelse "" } }),
            .heartbeat => out.emit(.{ .at = at, .src = source, .body = .heartbeat }),
            .unparseable => {},
            .resources => try self.resources(at, rec.data orelse return error.BadCapture, out),
            .message => try self.message(at, rec.data orelse return error.BadCapture, out),
        }
    }

    fn resources(self: *Translator, at: std.Io.Timestamp, data: []const u8, out: anytype) !void {
        if (self.registry) |*r| r.deinit();
        self.registry = null;
        var registry = Registry.init(self.gpa);
        errdefer registry.deinit();
        try registry.populate(data);
        self.registry = registry;

        _ = self.arena.reset(.retain_capacity);
        self.bindings = .empty;
        self.order = .empty;
        self.schedule_entries = .empty;
        self.schedule_ids = .empty;
        self.devices = .empty;
        self.device_index = .empty;
        try self.bind(data);

        out.emit(.{ .at = at, .src = source, .body = .{ .inventory = self.devices.items } });
        for (self.order.items) |id| {
            if (self.state(id, null)) |body| out.emit(.{ .at = at, .src = source, .init = true, .body = body });
        }
    }

    /// Walk the raw resource list once for what the model does not keep —
    /// IEEE addresses, rooms, button numbers, light channels — and bind every
    /// service the house log carries to its device.
    fn bind(self: *Translator, data: []const u8) !void {
        const a = self.arena.allocator();
        const root = try std.json.parseFromSliceLeaky(std.json.Value, a, data, .{});
        const items = (try json_get.Array(root.object, "data")).items;

        var ieee: std.StringHashMapUnmanaged([]const u8) = .empty;
        var room_of: std.StringHashMapUnmanaged([]const u8) = .empty;
        for (items) |item| {
            const o = item.object;
            const t = json_get.optionalString(o, "type") orelse continue;
            if (std.mem.eql(u8, t, "zigbee_connectivity")) {
                const mac = json_get.optionalString(o, "mac_address") orelse continue;
                try ieee.put(a, try ownerOf(o), try std.ascii.allocLowerString(a, mac));
            } else if (std.mem.eql(u8, t, "room")) {
                const name = nameOf(o) orelse continue;
                const children = json_get.optionalArray(o, "children") orelse continue;
                for (children.items) |c| {
                    const rid = json_get.optionalString(c.object, "rid") orelse continue;
                    try room_of.put(a, rid, name);
                }
            }
        }

        // Devices first, sorted by name, so the inventory and the `init`
        // records that follow it come out in the same order every day.
        var uuids: std.ArrayList([]const u8) = .empty;
        for (items) |item| {
            const o = item.object;
            if (!std.mem.eql(u8, json_get.optionalString(o, "type") orelse "", "device")) continue;
            const uuid = json_get.optionalString(o, "id") orelse continue;
            const dev = ieee.get(uuid) orelse try std.fmt.allocPrint(a, "hue:{s}", .{uuid});
            const product = if (json_get.optionalObject(o, "product_data")) |p| json_get.optionalString(p, "product_name") else null;
            try self.devices.append(a, .{
                .dev = dev,
                .name = nameOf(o) orelse uuid,
                .room = room_of.get(uuid),
                .product = product,
            });
            try uuids.append(a, uuid);
        }
        const Ctx = struct {
            devices: []houselog.Device,
            fn lt(ctx: @This(), x: usize, y: usize) bool {
                return std.mem.lessThan(u8, ctx.devices[x].name, ctx.devices[y].name);
            }
        };
        const perm = try a.alloc(usize, self.devices.items.len);
        for (perm, 0..) |*p, i| p.* = i;
        std.mem.sort(usize, perm, Ctx{ .devices = self.devices.items }, Ctx.lt);
        const sorted = try a.alloc(houselog.Device, perm.len);
        for (perm, sorted) |p, *d| d.* = self.devices.items[p];
        for (perm, 0..) |p, i| try self.device_index.put(a, uuids.items[p], i);
        self.devices.clearRetainingCapacity();
        try self.devices.appendSlice(a, sorted);

        try self.bindSchedules(items);

        // Then every service, bound to its device's id.
        var per_device = try a.alloc(std.ArrayList(Service), sorted.len);
        for (per_device) |*l| l.* = .empty;
        var ids_per_device = try a.alloc(std.ArrayList([]const u8), sorted.len);
        for (ids_per_device) |*l| l.* = .empty;
        for (items) |item| {
            const o = item.object;
            const service = serviceOf(json_get.optionalString(o, "type") orelse continue) orelse continue;
            const id = json_get.optionalString(o, "id") orelse continue;
            const idx = self.device_index.get(ownerOf(o) catch continue) orelse continue;
            var n: u8 = 0;
            switch (service) {
                .button => if (json_get.optionalObject(o, "metadata")) |m| {
                    n = @intCast(std.math.clamp(json_get.optionalInt(m, "control_id") orelse 0, 0, 255));
                },
                .light => n = @intCast(std.math.clamp(json_get.optionalInt(o, "service_id") orelse 0, 0, 255)),
                else => {},
            }
            try self.bindings.put(a, id, .{ .dev = sorted[idx].dev, .service = service, .n = n });
            if (std.mem.indexOfScalar(Service, per_device[idx].items, service) == null) try per_device[idx].append(a, service);
            try ids_per_device[idx].append(a, id);
        }
        for (self.devices.items, per_device, ids_per_device) |*d, *has, ids| {
            std.mem.sort(Service, has.items, {}, struct {
                fn lt(_: void, x: Service, y: Service) bool {
                    return @backingInt(x) < @backingInt(y);
                }
            }.lt);
            d.has = has.items;
            try self.order.appendSlice(a, ids.items);
        }
    }

    /// The automations on the Bridge, from the resource list. A switch's behaviour is
    /// an accessory rather than something that runs by the clock, so it isn't one.
    fn bindSchedules(self: *Translator, items: []const std.json.Value) !void {
        const a = self.arena.allocator();
        var kinds: std.StringHashMapUnmanaged([]const u8) = .empty;
        for (items) |item| {
            const o = item.object;
            if (!std.mem.eql(u8, json_get.optionalString(o, "type") orelse "", "behavior_script")) continue;
            const metadata = json_get.optionalObject(o, "metadata") orelse continue;
            if (!std.mem.eql(u8, json_get.optionalString(metadata, "category") orelse "", "automation")) continue;
            const id = json_get.optionalString(o, "id") orelse continue;
            try kinds.put(a, id, json_get.optionalString(metadata, "name") orelse "automation");
        }
        for (items) |item| {
            const o = item.object;
            if (!std.mem.eql(u8, json_get.optionalString(o, "type") orelse "", "behavior_instance")) continue;
            const kind = kinds.get(json_get.optionalString(o, "script_id") orelse continue) orelse continue;
            const id = json_get.optionalString(o, "id") orelse continue;
            const metadata = json_get.optionalObject(o, "metadata");
            const raw_name = if (metadata) |m| json_get.optionalString(m, "name") orelse kind else kind;

            var entry: houselog.schedules.Entry = .{
                .name = std.mem.trim(u8, raw_name, " "),
                .kind = kind,
                .enabled = false,
            };
            if (json_get.optionalObject(o, "configuration")) |config| {
                try applyWhen(a, &entry, config);
            }
            try self.schedule_ids.append(a, id);
            try self.schedule_entries.append(a, entry);
        }
    }

    /// What runs by the clock on the Bridge, in resource-list order. `enabled` comes
    /// from the model, which follows events, and the rest from the last resource
    /// list. Strings are valid until the next `feed`.
    pub fn schedules(self: *Translator, arena: Allocator) ![]houselog.schedules.Entry {
        const registry = if (self.registry) |*r| r else return &.{};
        const out = try arena.dupe(houselog.schedules.Entry, self.schedule_entries.items);
        for (out, self.schedule_ids.items) |*entry, id| {
            if (registry.resources.get(id)) |res| switch (res) {
                .behavior_instance => |b| entry.enabled = b.enabled orelse false,
                else => {},
            };
        }
        return out;
    }

    /// Every device's settings as the bridge holds them now, in inventory order,
    /// or nothing until a resource list has arrived. Strings are valid until the
    /// next `feed`, so a caller sharing this across tasks must hold its lock.
    pub fn settings(self: *Translator, arena: Allocator) ![]houselog.settings.Entry {
        const registry = if (self.registry) |*r| r else return &.{};
        var uuids = try arena.alloc([]const u8, self.devices.items.len);
        var indices = self.device_index.iterator();
        while (indices.next()) |e| uuids[e.value_ptr.*] = e.key_ptr.*;

        var out: std.ArrayList(houselog.settings.Entry) = .empty;
        for (self.devices.items, uuids) |d, uuid| {
            var base: houselog.settings.Entry = .{ .dev = d.dev, .name = d.name };
            if (registry.resources.get(uuid)) |res| switch (res) {
                .device => |device| {
                    base.model = device.model_id;
                    base.firmware = device.software_version;
                },
                else => {},
            };

            const first = out.items.len;
            for (self.order.items) |id| {
                const binding = self.bindings.get(id) orelse continue;
                if (binding.service != .light or !std.mem.eql(u8, binding.dev, d.dev)) continue;
                const res = registry.resources.get(id) orelse continue;
                if (res != .light) continue;
                var entry = base;
                entry.ch = binding.n;
                applyPowerUp(&entry, &res.light);
                try out.append(arena, entry);
            }
            if (out.items.len == first) try out.append(arena, base);
        }
        return out.items;
    }

    /// Which Bridge light each of the house's lights is.
    pub fn lightIds(self: *Translator, arena: Allocator) ![]light_ids.Light {
        var out: std.ArrayList(light_ids.Light) = .empty;
        for (self.order.items) |id| {
            const binding = self.bindings.get(id) orelse continue;
            if (binding.service != .light) continue;
            try out.append(arena, .{ .dev = binding.dev, .ch = binding.n, .id = id });
        }
        return out.items;
    }

    fn message(self: *Translator, at: std.Io.Timestamp, data: []const u8, out: anytype) !void {
        const registry = if (self.registry) |*r| r else return; // no resource list yet: nothing can be bound
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const events = sse_events.parseMessage(arena.allocator(), data) catch return;

        var renamed = false;
        for (events.items) |ev| {
            _ = registry.handleEvent(ev) catch continue;
            if (ev.updateType == .device) {
                if (try self.rename(ev)) renamed = true;
                continue;
            }
            // A move is the room's news, not the device's: its children change.
            if (ev.updateType == .room) {
                if (try self.rehome(registry)) renamed = true;
                continue;
            }
            if (self.state(ev.id, ev)) |body| out.emit(.{ .at = at, .src = source, .body = body });
        }
        if (renamed) out.emit(.{ .at = at, .src = source, .body = .{ .inventory = self.devices.items } });
    }

    /// Every device's room again, from the rooms as the model now holds them.
    /// True if any changed, a room renamed included.
    fn rehome(self: *Translator, registry: *Registry) !bool {
        const a = self.arena.allocator();
        const now = try a.alloc(?[]const u8, self.devices.items.len);
        @memset(now, null);
        var it = registry.resources.valueIterator();
        while (it.next()) |res| {
            const room = switch (res.*) {
                .room => |*r| r,
                else => continue,
            };
            const name = room.name orelse continue;
            for (room.children orelse continue) |c| {
                if (c.rtype != .device) continue;
                if (self.device_index.get(c.rid)) |i| now[i] = name;
            }
        }
        var changed = false;
        for (self.devices.items, now) |*d, n| {
            const same = if (d.room) |r| (n != null and std.mem.eql(u8, r, n.?)) else n == null;
            if (same) continue;
            d.room = if (n) |x| try a.dupe(u8, x) else null;
            changed = true;
        }
        return changed;
    }

    fn rename(self: *Translator, ev: Resources.EventUpdate) !bool {
        const name = nameOf(ev.data) orelse return false;
        const idx = self.device_index.get(ev.id) orelse return false;
        const d = &self.devices.items[idx];
        if (std.mem.eql(u8, d.name, name)) return false;
        d.name = try self.arena.allocator().dupe(u8, name);
        return true;
    }

    /// The house record for service `id`: its whole current state from the
    /// model, or for buttons and dials the event itself. With an event, null
    /// unless the event touched what the record carries.
    fn state(self: *Translator, id: []const u8, ev: ?Resources.EventUpdate) ?Body {
        const b = self.bindings.get(id) orelse return null;
        const registry = if (self.registry) |*r| r else return null;
        const res = registry.resources.get(id) orelse return null;
        const data = if (ev) |e| e.data else null;
        const touched = struct {
            fn f(d: ?std.json.ObjectMap, keys: []const []const u8) bool {
                const m = d orelse return true;
                for (keys) |k| if (m.get(k) != null) return true;
                return false;
            }
        }.f;
        switch (b.service) {
            .temperature => if (res == .temperature and touched(data, &.{"temperature"})) {
                const c = res.temperature.temperature orelse return null;
                return .{ .temperature = .{ .dev = b.dev, .c = c } };
            },
            .motion => if (res == .motion and touched(data, &.{"motion"})) {
                const on = res.motion.motion orelse return null;
                // With no event this is a snapshot: the one place the house log
                // has no other way to learn when the state began.
                return .{ .motion = .{ .dev = b.dev, .on = on, .since = if (ev == null) res.motion.changed else null } };
            },
            .light_level => if (res == .light_level and touched(data, &.{"light"})) {
                const level = res.light_level.light_level orelse return null;
                const lux = std.math.pow(f64, 10, (@as(f64, @floatFromInt(level)) - 1) / 10000);
                return .{ .light_level = .{ .dev = b.dev, .lux = houselog.sig3(lux) } };
            },
            .battery => if (res == .device_power and touched(data, &.{"power_state"})) {
                const pct = res.device_power.battery_level orelse return null;
                return .{ .battery = .{ .dev = b.dev, .pct = @intCast(std.math.clamp(pct, 0, 100)) } };
            },
            .link => if (res == .zigbee_connectivity and touched(data, &.{"status"})) {
                const s = res.zigbee_connectivity.status orelse return null;
                return .{ .link = .{ .dev = b.dev, .status = switch (s) {
                    .connected => .connected,
                    .disconnected => .disconnected,
                    .connectivity_issue => .issue,
                    .unidirectional_incoming => .unidirectional,
                    .pending_discovery => .pending,
                    .unknown => .unknown,
                } } };
            },
            .light => if (res == .light and touched(data, &.{ "on", "dimming", "color_temperature" })) {
                const l = res.light;
                const ct_k: ?u32 = if (l.mirek) |m| (if (m > 0 and l.mirek_valid != false) @intCast(@divTrunc(1_000_000 + @divTrunc(m, 2), m)) else null) else null;
                return .{ .light = .{ .dev = b.dev, .ch = b.n, .on = l.on, .bri = l.brightness, .ct_k = ct_k } };
            },
            .button => {
                const d = data orelse return null; // an event, never a state
                const btn = json_get.optionalObject(d, "button") orelse return null;
                const report = json_get.optionalObject(btn, "button_report");
                const raw = (if (report) |r| json_get.optionalString(r, "event") else null) orelse
                    json_get.optionalString(btn, "last_event") orelse return null;
                const event: houselog.ButtonEvent = if (std.mem.eql(u8, raw, "initial_press")) .press else if (std.mem.eql(u8, raw, "long_press")) .hold else if (std.mem.eql(u8, raw, "repeat")) .repeat else if (std.mem.eql(u8, raw, "short_release")) .release else if (std.mem.eql(u8, raw, "long_release")) .long_release else if (std.mem.eql(u8, raw, "double_short_release")) .double_release else return null;
                return .{ .button = .{ .dev = b.dev, .n = b.n, .event = event } };
            },
            .rotary => {
                const d = data orelse return null;
                const rr = json_get.optionalObject(d, "relative_rotary") orelse return null;
                const report = json_get.optionalObject(rr, "rotary_report") orelse json_get.optionalObject(rr, "last_event") orelse return null;
                const action = std.meta.stringToEnum(houselog.RotaryAction, json_get.optionalString(report, "action") orelse return null) orelse return null;
                const rot = json_get.optionalObject(report, "rotation") orelse return null;
                const dir_s = json_get.optionalString(rot, "direction") orelse return null;
                const dir: houselog.Direction = if (std.mem.eql(u8, dir_s, "clock_wise")) .cw else if (std.mem.eql(u8, dir_s, "counter_clock_wise")) .ccw else return null;
                const steps = json_get.optionalInt(rot, "steps") orelse return null;
                return .{ .rotary = .{ .dev = b.dev, .dir = dir, .steps = @intCast(std.math.clamp(steps, 0, std.math.maxInt(u32))), .action = action } };
            },
            // The bridge hosts no safety sensors, which are the reason hub has its
            // own, and no Hue device measures humidity.
            .alarm, .humidity => {},
        }
        return null;
    }
};

fn serviceOf(t: []const u8) ?Service {
    const map = .{
        .{ "temperature", Service.temperature },
        .{ "motion", Service.motion },
        .{ "light_level", Service.light_level },
        .{ "device_power", Service.battery },
        .{ "zigbee_connectivity", Service.link },
        .{ "light", Service.light },
        .{ "button", Service.button },
        .{ "relative_rotary", Service.rotary },
    };
    inline for (map) |m| if (std.mem.eql(u8, t, m[0])) return m[1];
    return null;
}

fn ownerOf(o: std.json.ObjectMap) ![]const u8 {
    const owner = json_get.optionalObject(o, "owner") orelse return error.NoOwner;
    return json_get.optionalString(owner, "rid") orelse error.NoOwner;
}

fn nameOf(o: std.json.ObjectMap) ?[]const u8 {
    const m = json_get.optionalObject(o, "metadata") orelse return null;
    return std.mem.trim(u8, json_get.optionalString(m, "name") orelse return null, " \t");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
// Shapes trimmed from this bridge's own resource list and event stream,
// captured 2026-11-04.

const testing = std.testing;
const time = @import("time");

const resources_json =
    \\{"errors":[],"data":[
    \\ {"id":"dev-k","type":"device","metadata":{"name":"Kitchen ","archetype":"unknown_archetype"},
    \\  "product_data":{"model_id":"SML001","manufacturer_name":"Signify","product_name":"Hue motion sensor",
    \\   "product_archetype":"unknown_archetype","certified":true,"software_version":"1.1"},
    \\  "services":[{"rid":"tmp-k","rtype":"temperature"}]},
    \\ {"id":"dev-d","type":"device","metadata":{"name":"Dimmer","archetype":"unknown_archetype"},
    \\  "product_data":{"model_id":"RWL021","manufacturer_name":"Signify","product_name":"Hue dimmer switch",
    \\   "product_archetype":"unknown_archetype","certified":true,"software_version":"1.1"},
    \\  "services":[{"rid":"btn-4","rtype":"button"}]},
    \\ {"id":"room-k","type":"room","metadata":{"name":"Kitchen","archetype":"kitchen"},
    \\  "children":[{"rid":"dev-k","rtype":"device"}],"services":[]},
    \\ {"id":"zig-k","type":"zigbee_connectivity","owner":{"rid":"dev-k","rtype":"device"},
    \\  "status":"connected","mac_address":"00:17:88:01:0B:2C:4D:1E"},
    \\ {"id":"tmp-k","type":"temperature","owner":{"rid":"dev-k","rtype":"device"},"enabled":true,
    \\  "temperature":{"temperature":18.22,"temperature_valid":true,
    \\   "temperature_report":{"changed":"2026-11-04T10:18:02.755Z","temperature":18.22}}},
    \\ {"id":"lvl-k","type":"light_level","owner":{"rid":"dev-k","rtype":"device"},"enabled":true,
    \\  "light":{"light_level":26150,"light_level_valid":true,
    \\   "light_level_report":{"changed":"2026-11-04T10:20:28.730Z","light_level":26150}}},
    \\ {"id":"pwr-k","type":"device_power","owner":{"rid":"dev-k","rtype":"device"},
    \\  "power_state":{"battery_state":"normal","battery_level":61}},
    \\ {"id":"btn-4","type":"button","owner":{"rid":"dev-d","rtype":"device"},"metadata":{"control_id":4},
    \\  "button":{"last_event":"short_release","button_report":{"updated":"2026-10-30T14:19:34.198Z","event":"short_release"}}}
    \\]}
;

const Collect = struct {
    lines: std.ArrayList(u8) = .empty,

    fn emit(self: *Collect, r: houselog.Record) void {
        var w: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &self.lines);
        houselog.format(&w.writer, r) catch unreachable;
        self.lines = w.toArrayList();
    }
};

fn capLine(a: Allocator, kind: capture.Kind, data: ?[]const u8) !capture.Record {
    var buf: std.Io.Writer.Allocating = .init(a);
    try capture.write(&buf.writer, try time.ISO2Timestamp("2026-11-04T10:00:00Z"), kind, null, data);
    const line = buf.written();
    return capture.parse(a, line[0 .. line.len - 1]);
}

test "a resource list becomes an inventory and the state it opens with" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var tr = Translator.init(testing.allocator);
    defer tr.deinit();
    var out: Collect = .{};
    defer out.lines.deinit(testing.allocator);

    try tr.feed(try capLine(arena.allocator(), .resources, resources_json), &out);
    try testing.expectEqualStrings(
        \\{"v":4,"src":"hue-bridge","t":"2026-11-04T10:00:00.000Z","kind":"inventory","devices":[{"dev":"hue:dev-d","name":"Dimmer","product":"Hue dimmer switch","has":["button"]},{"dev":"00:17:88:01:0b:2c:4d:1e","name":"Kitchen","room":"Kitchen","product":"Hue motion sensor","has":["temperature","light_level","battery","link"]}]}
        \\{"v":4,"src":"hue-bridge","t":"2026-11-04T10:00:00.000Z","kind":"link","init":true,"dev":"00:17:88:01:0b:2c:4d:1e","status":"connected"}
        \\{"v":4,"src":"hue-bridge","t":"2026-11-04T10:00:00.000Z","kind":"temperature","init":true,"dev":"00:17:88:01:0b:2c:4d:1e","c":18.22}
        \\{"v":4,"src":"hue-bridge","t":"2026-11-04T10:00:00.000Z","kind":"light_level","init":true,"dev":"00:17:88:01:0b:2c:4d:1e","lux":412}
        \\{"v":4,"src":"hue-bridge","t":"2026-11-04T10:00:00.000Z","kind":"battery","init":true,"dev":"00:17:88:01:0b:2c:4d:1e","pct":61}
        \\
    , out.lines.items);
}

test "events become records; a button is an event; a rename re-issues the inventory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = Translator.init(testing.allocator);
    defer tr.deinit();
    var out: Collect = .{};
    defer out.lines.deinit(testing.allocator);

    try tr.feed(try capLine(a, .resources, resources_json), &out);
    out.lines.clearRetainingCapacity();

    try tr.feed(try capLine(a, .message,
        \\[{"creationtime":"2026-11-04T10:22:18Z","id":"e1","type":"update","data":[
        \\ {"id":"tmp-k","type":"temperature","owner":{"rid":"dev-k","rtype":"device"},
        \\  "temperature":{"temperature":18.5,"temperature_valid":true,"temperature_report":{"changed":"2026-11-04T10:22:18Z","temperature":18.5}}},
        \\ {"id":"btn-4","type":"button","owner":{"rid":"dev-d","rtype":"device"},
        \\  "button":{"button_report":{"updated":"2026-11-04T10:22:18Z","event":"initial_press"}}},
        \\ {"id":"pwr-k","type":"device_power","owner":{"rid":"dev-k","rtype":"device"},"enabled":true},
        \\ {"id":"dev-k","type":"device","metadata":{"name":"Kitchen sensor"}}
        \\]}]
    ), &out);
    try testing.expectEqualStrings(
        \\{"v":4,"src":"hue-bridge","t":"2026-11-04T10:00:00.000Z","kind":"temperature","dev":"00:17:88:01:0b:2c:4d:1e","c":18.5}
        \\{"v":4,"src":"hue-bridge","t":"2026-11-04T10:00:00.000Z","kind":"button","dev":"hue:dev-d","n":4,"event":"press"}
        \\{"v":4,"src":"hue-bridge","t":"2026-11-04T10:00:00.000Z","kind":"inventory","devices":[{"dev":"hue:dev-d","name":"Dimmer","product":"Hue dimmer switch","has":["button"]},{"dev":"00:17:88:01:0b:2c:4d:1e","name":"Kitchen sensor","room":"Kitchen","product":"Hue motion sensor","has":["temperature","light_level","battery","link"]}]}
        \\
    , out.lines.items);
}

test "a device moving between rooms re-issues the inventory, and nothing else does" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = Translator.init(testing.allocator);
    defer tr.deinit();
    var out: Collect = .{};
    defer out.lines.deinit(testing.allocator);

    try tr.feed(try capLine(a, .resources, resources_json), &out);
    out.lines.clearRetainingCapacity();

    // The Kitchen room gives up its sensor: out of every room.
    try tr.feed(try capLine(a, .message,
        \\[{"creationtime":"2026-11-04T10:22:18Z","id":"e1","type":"update","data":[
        \\ {"id":"room-k","type":"room","children":[]}]}]
    ), &out);
    try testing.expect(std.mem.indexOf(u8, out.lines.items, "\"kind\":\"inventory\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.lines.items, "\"room\":\"Kitchen\"") == null);
    out.lines.clearRetainingCapacity();

    // The same again changes nothing, so says nothing.
    try tr.feed(try capLine(a, .message,
        \\[{"creationtime":"2026-11-04T10:22:19Z","id":"e2","type":"update","data":[
        \\ {"id":"room-k","type":"room","children":[]}]}]
    ), &out);
    try testing.expectEqualStrings("", out.lines.items);

    // Back in, under the room's new name.
    try tr.feed(try capLine(a, .message,
        \\[{"creationtime":"2026-11-04T10:22:20Z","id":"e3","type":"update","data":[
        \\ {"id":"room-k","type":"room","metadata":{"name":"Galley"},"children":[{"rid":"dev-k","rtype":"device"}]}]}]
    ), &out);
    try testing.expect(std.mem.indexOf(u8, out.lines.items, "\"room\":\"Galley\"") != null);
}

test "a motion snapshot says when the state began; a reported change does not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = Translator.init(testing.allocator);
    defer tr.deinit();
    var out: Collect = .{};
    defer out.lines.deinit(testing.allocator);

    try tr.feed(try capLine(a, .resources,
        \\{"errors":[],"data":[
        \\ {"id":"dev-m","type":"device","metadata":{"name":"Wall","archetype":"unknown_archetype"},
        \\  "product_data":{"model_id":"SML002","manufacturer_name":"Signify","product_name":"Hue outdoor motion sensor",
        \\   "product_archetype":"unknown_archetype","certified":true,"software_version":"1.1"},
        \\  "services":[{"rid":"mot-m","rtype":"motion"},{"rid":"zig-m","rtype":"zigbee_connectivity"}]},
        \\ {"id":"zig-m","type":"zigbee_connectivity","owner":{"rid":"dev-m","rtype":"device"},
        \\  "status":"connected","mac_address":"00:17:88:01:06:44:35:A4"},
        \\ {"id":"mot-m","type":"motion","owner":{"rid":"dev-m","rtype":"device"},"enabled":true,
        \\  "motion":{"motion":false,"motion_valid":true,
        \\   "motion_report":{"changed":"2026-11-03T15:58:44.400Z","motion":false}}}
        \\]}
    ), &out);
    try testing.expect(std.mem.indexOf(u8, out.lines.items,
        \\"kind":"motion","init":true,"dev":"00:17:88:01:06:44:35:a4","on":false,"since":"2026-11-03T15:58:44.400Z"}
    ) != null);
    out.lines.clearRetainingCapacity();

    try tr.feed(try capLine(a, .message,
        \\[{"creationtime":"2026-11-04T10:00:00Z","id":"e1","type":"update","data":[
        \\ {"id":"mot-m","type":"motion","owner":{"rid":"dev-m","rtype":"device"},
        \\  "motion":{"motion":true,"motion_valid":true,"motion_report":{"changed":"2026-11-04T10:00:00Z","motion":true}}}
        \\]}]
    ), &out);
    try testing.expectEqualStrings(
        \\{"v":4,"src":"hue-bridge","t":"2026-11-04T10:00:00.000Z","kind":"motion","dev":"00:17:88:01:06:44:35:a4","on":true}
        \\
    , out.lines.items);
}

test "a message before any resource list is ignored, not an error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var tr = Translator.init(testing.allocator);
    defer tr.deinit();
    var out: Collect = .{};
    defer out.lines.deinit(testing.allocator);
    try tr.feed(try capLine(arena.allocator(), .message, "[]"), &out);
    try tr.feed(try capLine(arena.allocator(), .heartbeat, null), &out);
    try testing.expect(std.mem.indexOf(u8, out.lines.items, "\"kind\":\"heartbeat\"") != null);
}

const settings_json =
    \\{"errors":[],"data":[
    \\ {"id":"dev-s","type":"device","metadata":{"name":"Hall spot ","archetype":"spot_bulb"},
    \\  "product_data":{"model_id":"LTG002","manufacturer_name":"Signify","product_name":"Hue spot","product_archetype":"spot_bulb","certified":true,"software_version":"1.2.3"},
    \\  "services":[{"rid":"lit-s","rtype":"light"},{"rid":"zb-s","rtype":"zigbee_connectivity"}]},
    \\ {"id":"zb-s","type":"zigbee_connectivity","owner":{"rid":"dev-s","rtype":"device"},"status":"connected","mac_address":"00:17:88:01:AA:BB:CC:01"},
    \\ {"id":"lit-s","type":"light","owner":{"rid":"dev-s","rtype":"device"},"service_id":0,"on":{"on":false},"mode":"normal",
    \\  "powerup":{"preset":"safety","configured":true,"on":{"mode":"on","on":{"on":true}},
    \\   "dimming":{"mode":"dimming","dimming":{"brightness":100.0}},
    \\   "color":{"mode":"color_temperature","color_temperature":{"mirek":366}}}},
    \\ {"id":"dev-d2","type":"device","metadata":{"name":"Hall switch","archetype":"unknown_archetype"},
    \\  "product_data":{"model_id":"RWL022","manufacturer_name":"Signify","product_name":"Hue dimmer","product_archetype":"unknown_archetype","certified":true,"software_version":"2.85.1"},
    \\  "services":[{"rid":"zb-d2","rtype":"zigbee_connectivity"}]},
    \\ {"id":"zb-d2","type":"zigbee_connectivity","owner":{"rid":"dev-d2","rtype":"device"},"status":"connected","mac_address":"00:17:88:01:AA:BB:CC:02"}
    \\]}
;

test "settings say what the bridge holds, in the house's words, and follow events" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = Translator.init(testing.allocator);
    defer tr.deinit();
    var out: Collect = .{};
    defer out.lines.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), (try tr.settings(a)).len);

    try tr.feed(try capLine(a, .resources, settings_json), &out);
    const entries = try tr.settings(a);
    try testing.expectEqual(@as(usize, 2), entries.len);

    const spot = entries[0];
    try testing.expectEqualStrings("Hall spot", spot.name);
    try testing.expectEqualStrings("00:17:88:01:aa:bb:cc:01", spot.dev);
    try testing.expectEqualStrings("LTG002", spot.model.?);
    try testing.expectEqualStrings("1.2.3", spot.firmware.?);
    try testing.expectEqual(houselog.settings.PowerOn.on, spot.power_on.?);
    try testing.expectEqual(@as(f64, 100), spot.power_on_bri.?);
    try testing.expectEqual(@as(u32, 2732), spot.power_on_ct_k.?);
    try testing.expect(!spot.power_on_bri_previous);

    const dimmer = entries[1];
    try testing.expectEqualStrings("RWL022", dimmer.model.?);
    try testing.expect(dimmer.power_on == null);

    try tr.feed(try capLine(a, .message,
        \\[{"creationtime":"2026-11-04T10:22:18Z","id":"e1","type":"update","data":[
        \\ {"id":"lit-s","type":"light","owner":{"rid":"dev-s","rtype":"device"},
        \\  "powerup":{"preset":"powerfail","configured":true,"on":{"mode":"previous"},"dimming":{"mode":"previous"},"color":{"mode":"previous"}}}
        \\]}]
    ), &out);
    const ids = try tr.lightIds(a);
    try testing.expectEqual(@as(usize, 1), ids.len);
    try testing.expectEqualStrings("lit-s", ids[0].id);
    try testing.expectEqualStrings((try tr.settings(a))[0].dev, ids[0].dev);

    const after = (try tr.settings(a))[0];
    try testing.expectEqual(houselog.settings.PowerOn.previous, after.power_on.?);
    try testing.expect(after.power_on_bri_previous);
    try testing.expect(after.power_on_ct_k == null);
    try testing.expect(after.power_on_bri == null);
}

test "the Bridge's automations become schedules, and a switch's behaviour doesn't" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = Translator.init(testing.allocator);
    defer tr.deinit();
    var out: Collect = .{};
    defer out.lines.deinit(testing.allocator);

    try tr.feed(try capLine(a, .resources,
        \\{"errors":[],"data":[
        \\{"id":"s-sched","type":"behavior_script","description":"d","configuration_schema":{},"version":"1.0.0",
        \\ "metadata":{"name":"Schedule","category":"automation"}},
        \\{"id":"s-acc","type":"behavior_script","description":"d","configuration_schema":{},"version":"1.0.0",
        \\ "metadata":{"name":"Hue Accessories","category":"accessory"}},
        \\{"id":"i-pump","type":"behavior_instance","script_id":"s-sched","enabled":true,"status":"running","last_error":"",
        \\ "dependees":[],"metadata":{"name":"Pump "},"configuration":{"when_extended":{
        \\  "recurrence_days":["monday","friday"],
        \\  "start_at":{"time_point":{"type":"time","time":{"hour":6,"minute":5}}},
        \\  "end_at":{"time_point":{"type":"time","time":{"hour":8,"minute":0}}}}}},
        \\{"id":"i-sleep","type":"behavior_instance","script_id":"s-sched","enabled":false,"status":"running","last_error":"",
        \\ "dependees":[],"metadata":{"name":"Fan"},"configuration":{"when":{
        \\  "recurrence_days":["monday"],"time_point":{"type":"time","time":{"hour":23,"minute":0}}}}},
        \\{"id":"i-sun","type":"behavior_instance","script_id":"s-sched","enabled":true,"status":"running","last_error":"",
        \\ "dependees":[],"metadata":{"name":"Dusk"},"configuration":{"when_extended":{
        \\  "start_at":{"time_point":{"type":"sunset"}}}}},
        \\{"id":"i-dim","type":"behavior_instance","script_id":"s-acc","enabled":true,"status":"running","last_error":"",
        \\ "dependees":[],"metadata":{"name":"Dimmer"},"configuration":{}}
        \\]}
    ), &out);

    const list = try tr.schedules(a);
    try testing.expectEqual(@as(usize, 3), list.len);
    try testing.expectEqualStrings("Pump", list[0].name);
    try testing.expectEqualStrings("Schedule", list[0].kind);
    try testing.expect(list[0].enabled);
    try testing.expectEqualStrings("06:05", list[0].at.?);
    try testing.expectEqualStrings("08:00", list[0].until.?);
    try testing.expectEqualStrings("friday", list[0].days[1]);
    try testing.expect(!list[1].enabled);
    try testing.expectEqualStrings("23:00", list[1].at.?);
    try testing.expect(list[1].until == null);
    try testing.expect(list[2].at == null);
}
