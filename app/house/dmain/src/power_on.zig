//! What each light should do when power returns, and where it differs.
//!
//! The wanted file is a default and its exceptions, so the file says what is
//! special about the house rather than listing 53 identical lines. Generated from
//! what the devices hold now, edited by hand and kept in git. Pure: it compares
//! `lib/houselog`'s settings with the file, and says nothing about any network.

const std = @import("std");
const Allocator = std.mem.Allocator;
const settings = @import("houselog").settings;

pub const version = 1;
pub const FILE = "power-on.json";

pub const Want = struct {
    power_on: settings.PowerOn,
    /// Brightness percent, when it's a set value.
    bri: ?f64 = null,
    bri_previous: bool = false,
    ct_k: ?u32 = null,
};

pub const Except = struct {
    dev: []const u8,
    ch: u8 = 0,
    /// For the person reading the file. `dev` and `ch` are what count, so a rename
    /// in the Hue app doesn't move the setting.
    name: []const u8,
    power_on: settings.PowerOn,
    bri: ?f64 = null,
    bri_previous: bool = false,
    ct_k: ?u32 = null,

    fn want(self: Except) Want {
        return .{ .power_on = self.power_on, .bri = self.bri, .bri_previous = self.bri_previous, .ct_k = self.ct_k };
    }
};

pub const Wanted = struct {
    v: u32 = version,
    default: Want,
    except: []const Except = &.{},
};

/// Strings in the result live in `arena`. Unknown fields are refused, as a setting
/// silently ignored is one that doesn't mean what it says.
pub fn parse(arena: Allocator, text: []const u8) !Wanted {
    const wanted = try std.json.parseFromSliceLeaky(Wanted, arena, text, .{ .allocate = .alloc_always });
    if (wanted.v != version) return error.UnknownVersion;
    try checkWant(wanted.default);
    for (wanted.except, 0..) |e, i| {
        try checkWant(e.want());
        for (wanted.except[0..i]) |earlier| {
            if (earlier.ch == e.ch and std.mem.eql(u8, earlier.dev, e.dev)) return error.DuplicateDevice;
        }
    }
    return wanted;
}

fn checkWant(w: Want) !void {
    if (w.bri != null and w.bri_previous) return error.BrightnessTwice;
    if (w.bri) |bri| if (bri < 0 or bri > 100) return error.BadBrightness;
    // The range the API takes, 50 to 1000 mirek.
    if (w.ct_k) |k| if (k < 1000 or k > 20_000) return error.BadColourTemperature;
    if (w.power_on == .off and (w.bri != null or w.ct_k != null)) return error.OffWithLevel;
}

pub fn render(gpa: Allocator, wanted: Wanted) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, wanted, .{ .emit_null_optional_fields = false, .whitespace = .indent_2 });
}

/// A plug reports no brightness, so one can't differ from the default's.
fn canDim(e: settings.Entry) bool {
    return e.power_on_bri != null or e.power_on_bri_previous;
}

pub fn wantFrom(e: settings.Entry) ?Want {
    const power_on = e.power_on orelse return null;
    return .{ .power_on = power_on, .bri = e.power_on_bri, .bri_previous = e.power_on_bri_previous, .ct_k = e.power_on_ct_k };
}

/// What this light should do, as far as it can: the default's brightness means
/// nothing to a plug, and a request carrying one would be refused.
pub fn wantFor(wanted: Wanted, e: settings.Entry) Want {
    var want = wanted.default;
    for (wanted.except) |x| {
        if (x.ch == e.ch and std.mem.eql(u8, x.dev, e.dev)) want = x.want();
    }
    if (!canDim(e)) {
        want.bri = null;
        want.bri_previous = false;
        want.ct_k = null;
    }
    return want;
}

fn near(a: ?f64, b: ?f64) bool {
    if (a == null or b == null) return a == null and b == null;
    return @abs(a.? - b.?) < 0.5;
}

/// A colour temperature comes back through mirek, which is a coarse unit at the
/// warm end, so it's near rather than equal.
fn nearKelvin(a: ?u32, b: ?u32) bool {
    if (a == null or b == null) return a == null and b == null;
    const x: i64 = a.?;
    const y: i64 = b.?;
    return @abs(x - y) * 100 <= y;
}

pub fn matches(e: settings.Entry, want: Want) bool {
    const now = wantFrom(e) orelse return true;
    if (now.power_on != want.power_on) return false;
    if (!canDim(e)) return true;
    return now.bri_previous == want.bri_previous and near(now.bri, want.bri) and nearKelvin(now.ct_k, want.ct_k);
}

pub const Difference = struct { entry: settings.Entry, want: Want };

pub const Report = struct {
    differences: []const Difference,
    /// Exceptions naming a device the settings don't have: most likely removed, or
    /// a mistake in the file.
    unknown: []const Except,
    lights: usize,
};

pub fn compare(arena: Allocator, entries: []const settings.Entry, wanted: Wanted) !Report {
    var differences: std.ArrayList(Difference) = .empty;
    var lights: usize = 0;
    for (entries) |e| {
        if (e.power_on == null) continue;
        lights += 1;
        const want = wantFor(wanted, e);
        if (!matches(e, want)) try differences.append(arena, .{ .entry = e, .want = want });
    }
    var unknown: std.ArrayList(Except) = .empty;
    for (wanted.except) |x| {
        var found = false;
        for (entries) |e| {
            if (e.ch == x.ch and std.mem.eql(u8, e.dev, x.dev)) found = true;
        }
        if (!found) try unknown.append(arena, x);
    }
    return .{ .differences = differences.items, .unknown = unknown.items, .lights = lights };
}

fn sameWant(a: Want, b: Want) bool {
    return a.power_on == b.power_on and a.bri_previous == b.bri_previous and near(a.bri, b.bri) and nearKelvin(a.ct_k, b.ct_k);
}

/// The file that says the house should stay exactly as it is: the commonest
/// setting among lights that can dim as the default, and the rest as exceptions.
pub fn generate(arena: Allocator, entries: []const settings.Entry) !Wanted {
    var best: ?Want = null;
    var best_count: usize = 0;
    for (entries) |e| {
        if (!canDim(e)) continue;
        const w = wantFrom(e) orelse continue;
        var count: usize = 0;
        for (entries) |other| {
            if (!canDim(other)) continue;
            const o = wantFrom(other) orelse continue;
            if (sameWant(w, o)) count += 1;
        }
        if (count > best_count) {
            best = w;
            best_count = count;
        }
    }
    const default: Want = best orelse .{ .power_on = .previous, .bri_previous = true };

    var except: std.ArrayList(Except) = .empty;
    for (entries) |e| {
        const w = wantFrom(e) orelse continue;
        if (matches(e, default)) continue;
        try except.append(arena, .{
            .dev = e.dev,
            .ch = e.ch,
            .name = e.name,
            .power_on = w.power_on,
            .bri = w.bri,
            .bri_previous = w.bri_previous,
            .ct_k = w.ct_k,
        });
    }
    return .{ .default = default, .except = except.items };
}

/// In the words a person reads: "previous, last level" or "on, 100%, 2732 K".
pub fn describe(arena: Allocator, want: Want) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.print("{t}", .{want.power_on});
    if (want.bri) |bri| try out.writer.print(", {d:.0}%", .{bri});
    if (want.bri_previous) try out.writer.writeAll(", last level");
    if (want.ct_k) |k| try out.writer.print(", {d} K", .{k});
    return out.written();
}

const testing = std.testing;

const lamp: settings.Entry = .{ .dev = "a", .name = "Lamp", .power_on = .previous, .power_on_bri_previous = true };
const plug: settings.Entry = .{ .dev = "b", .name = "Plug", .power_on = .previous };
const spot: settings.Entry = .{ .dev = "c", .name = "Spot", .power_on = .on, .power_on_bri = 100, .power_on_ct_k = 2732 };
const sensor: settings.Entry = .{ .dev = "d", .name = "Sensor" };

test "generate takes the commonest as the default, and matches the house as it is" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = [_]settings.Entry{ lamp, lamp, spot, plug, sensor };
    const wanted = try generate(a, &entries);
    try testing.expect(wanted.default.bri_previous);
    try testing.expectEqual(@as(usize, 1), wanted.except.len);
    try testing.expectEqualStrings("Spot", wanted.except[0].name);

    const report = try compare(a, &entries, wanted);
    try testing.expectEqual(@as(usize, 0), report.differences.len);
    try testing.expectEqual(@as(usize, 4), report.lights);
}

test "a generated file survives its own strict reader" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = [_]settings.Entry{ lamp, spot };
    const wanted = try parse(a, try render(a, try generate(a, &entries)));
    try testing.expectEqual(@as(usize, 1), wanted.except.len);
    try testing.expectEqual(@as(?u32, 2732), wanted.except[0].ct_k);
}

test "removing an exception makes that light differ from the default" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = [_]settings.Entry{ lamp, spot, plug, sensor };
    const report = try compare(a, &entries, .{ .default = .{ .power_on = .previous, .bri_previous = true } });
    try testing.expectEqual(@as(usize, 1), report.differences.len);
    try testing.expectEqualStrings("Spot", report.differences[0].entry.name);
    try testing.expect(report.differences[0].want.bri_previous);
}

test "an exception for a device the settings don't have is reported" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = [_]settings.Entry{lamp};
    const report = try compare(a, &entries, .{
        .default = .{ .power_on = .previous, .bri_previous = true },
        .except = &.{.{ .dev = "gone", .name = "Gone", .power_on = .on }},
    });
    try testing.expectEqual(@as(usize, 1), report.unknown.len);
}

test "a plug can't differ over a brightness it doesn't have" {
    try testing.expect(matches(plug, .{ .power_on = .previous, .bri_previous = true }));
    try testing.expect(!matches(plug, .{ .power_on = .on, .bri_previous = true }));
}

test "wantFor asks a plug only for what it has" {
    const wanted: Wanted = .{ .default = .{ .power_on = .previous, .bri_previous = true } };
    const want = wantFor(wanted, plug);
    try testing.expectEqual(settings.PowerOn.previous, want.power_on);
    try testing.expect(!want.bri_previous);
    try testing.expect(wantFor(wanted, lamp).bri_previous);
}

test "a colour temperature back through mirek still matches" {
    const back: settings.Entry = .{ .dev = "c", .name = "Spot", .power_on = .on, .power_on_bri = 100, .power_on_ct_k = 2725 };
    try testing.expect(matches(back, .{ .power_on = .on, .bri = 100, .ct_k = 2732 }));
    try testing.expect(!matches(back, .{ .power_on = .on, .bri = 100, .ct_k = 4000 }));
}

test "parse refuses a file that can't mean what it says" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = "\"default\":{\"power_on\":\"previous\",\"bri_previous\":true}";
    _ = try parse(a, "{\"v\":1," ++ d ++ "}");
    try testing.expectError(error.UnknownVersion, parse(a, "{\"v\":9," ++ d ++ "}"));
    try testing.expectError(error.UnknownField, parse(a, "{\"v\":1," ++ d ++ ",\"oops\":1}"));
    try testing.expectError(error.BadBrightness, parse(a, "{\"v\":1,\"default\":{\"power_on\":\"on\",\"bri\":101}}"));
    try testing.expectError(error.BrightnessTwice, parse(a, "{\"v\":1,\"default\":{\"power_on\":\"on\",\"bri\":50,\"bri_previous\":true}}"));
    try testing.expectError(error.BadColourTemperature, parse(a, "{\"v\":1,\"default\":{\"power_on\":\"on\",\"ct_k\":100}}"));
    try testing.expectError(error.OffWithLevel, parse(a, "{\"v\":1,\"default\":{\"power_on\":\"off\",\"bri\":50}}"));
    try testing.expectError(error.DuplicateDevice, parse(a, "{\"v\":1," ++ d ++ ",\"except\":[" ++
        "{\"dev\":\"a\",\"name\":\"A\",\"power_on\":\"on\"},{\"dev\":\"a\",\"name\":\"B\",\"power_on\":\"on\"}]}"));
}

test "describe says it in a person's words" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("previous, last level", try describe(a, .{ .power_on = .previous, .bri_previous = true }));
    try testing.expectEqualStrings("on, 100%, 2732 K", try describe(a, .{ .power_on = .on, .bri = 100, .ct_k = 2732 }));
}
