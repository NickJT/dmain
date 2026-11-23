//! `dmain power-on generate | check | apply [confirm]`: the wanted file, from the
//! settings `huelog` writes to what the Bridge holds. Bare `apply` only shows what
//! would change, and nothing here reports a write as done: the settings file does
//! that when the Bridge says so, which is what `check` reads.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const houselog = @import("houselog");
const bridge_write = @import("bridge_write");
const light_ids = @import("light_ids");
const config = @import("config.zig");

const power_on = @import("power_on.zig");
const MAX_FILE = 1 << 20;
/// Well inside the Bridge's rate limit, because nothing here is in a hurry and each
/// write also reaches the light over Zigbee.
const PAUSE = Io.Duration.fromMilliseconds(1000);

pub const usage =
    \\  dmain power-on generate        print a wanted file matching the house as it is now
    \\  dmain power-on check           validate power-on.json and show what differs
    \\  dmain power-on apply           show what would change
    \\  dmain power-on apply confirm   write those changes to the Bridge
    \\  ... check|apply [confirm] -   the same, with the wanted file on stdin
    \\
;

pub fn readSettings(arena: Allocator, io: Io, path: []const u8) !houselog.settings.File {
    const text = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(MAX_FILE));
    return houselog.settings.parse(arena, text);
}

/// `given` is the wanted file's text when it came from elsewhere, such as the Mac's
/// copy through `dmain agent`.
pub fn run(gpa: Allocator, arena: Allocator, io: Io, app: *const config.Config, args: []const []const u8, given: ?[]const u8, out: *Io.Writer) !void {
    const sub = if (args.len > 0) args[0] else "";
    const confirm = args.len == 2 and std.mem.eql(u8, args[1], "confirm");
    const generate = std.mem.eql(u8, sub, "generate");
    const check = std.mem.eql(u8, sub, "check");
    const apply = std.mem.eql(u8, sub, "apply");
    if (!(generate or check or apply) or (args.len != 1 and !(apply and confirm))) {
        try out.writeAll(usage);
        return error.BadUsage;
    }

    const file = readSettings(arena, io, app.hue_settings) catch |err| {
        try out.print("dmain: cannot read {s} ({t})\n", .{ app.hue_settings, err });
        return err;
    };

    if (generate) {
        const text = try power_on.render(arena, try power_on.generate(arena, file.devices));
        try out.print("{s}\n", .{text});
        return;
    }

    const name = if (given != null) "the power-on file given" else app.power_on;
    const wanted_text = given orelse Io.Dir.cwd().readFileAlloc(io, app.power_on, arena, .limited(MAX_FILE)) catch |err| {
        try out.print("dmain: cannot read {s} ({t}). `dmain power-on generate > {s}` makes one\n", .{ app.power_on, err, app.power_on });
        return err;
    };
    const wanted = power_on.parse(arena, wanted_text) catch |err| {
        try out.print("dmain: {s} is not right ({t})\n", .{ name, err });
        return err;
    };

    const report = try power_on.compare(arena, file.devices, wanted);
    try printReport(arena, report, file.t, out);
    if (!apply or report.differences.len == 0) return;
    if (!confirm) {
        try out.writeAll("Nothing written. `dmain power-on apply confirm` writes these to the Bridge.\n");
        return;
    }
    try applyAll(gpa, arena, io, app, report, out);
}

fn printReport(arena: Allocator, report: power_on.Report, settings_t: []const u8, out: *Io.Writer) !void {
    try out.print("{d} lights, {d} differ. Settings last changed {s}.\n", .{ report.lights, report.differences.len, settings_t });
    for (report.differences) |d| {
        const now = power_on.wantFrom(d.entry).?;
        try out.print("  {s}: {s} -> {s}\n", .{
            d.entry.name,
            try power_on.describe(arena, now),
            try power_on.describe(arena, d.want),
        });
    }
    for (report.unknown) |x| {
        try out.print("  in the file but not the house: {s} ({s})\n", .{ x.name, x.dev });
    }
}

fn applyAll(gpa: Allocator, arena: Allocator, io: Io, app: *const config.Config, report: power_on.Report, out: *Io.Writer) !void {
    const bridge_text = Io.Dir.cwd().readFileAlloc(io, app.bridge_file, arena, .limited(MAX_FILE)) catch |err| {
        try out.print("dmain: cannot read {s} ({t})\n", .{ app.bridge_file, err });
        return err;
    };
    // By name only: this file holds the Bridge's key.
    const bridge = bridge_write.parseCredentials(arena, bridge_text) catch |err| {
        try out.print("dmain: {s} is not right ({t})\n", .{ app.bridge_file, err });
        return err;
    };
    const ids_text = Io.Dir.cwd().readFileAlloc(io, app.bridge_ids, arena, .limited(MAX_FILE)) catch |err| {
        try out.print("dmain: cannot read {s} ({t})\n", .{ app.bridge_ids, err });
        return err;
    };
    const ids = light_ids.parse(arena, ids_text) catch |err| {
        try out.print("dmain: {s} is not right ({t})\n", .{ app.bridge_ids, err });
        return err;
    };

    var accepted: usize = 0;
    var failed: usize = 0;
    for (report.differences) |d| {
        const id = light_ids.find(ids.lights, d.entry.dev, d.entry.ch) orelse {
            try out.print("  {s}: no Bridge id for it, skipped\n", .{d.entry.name});
            failed += 1;
            continue;
        };
        const body = try bridge_write.powerUpBody(arena, .{
            .power_on = d.want.power_on,
            .bri = d.want.bri,
            .bri_previous = d.want.bri_previous,
            .ct_k = d.want.ct_k,
        });
        var reply: bridge_write.Reply = .{};
        if (bridge_write.setLight(gpa, io, bridge, id, body, &reply)) {
            try out.print("  {s}: the Bridge accepted it\n", .{d.entry.name});
            accepted += 1;
        } else |err| {
            try refusedLine(out, d.entry.name, err, &reply);
            failed += 1;
        }
        try out.flush();
        try io.sleep(PAUSE, .awake);
    }
    try out.print("{d} accepted, {d} failed. `dmain power-on check` in about a minute shows what the lights now hold.\n", .{ accepted, failed });
    if (failed > 0) return error.SomeWritesFailed;
}

/// A write the Bridge refused, with its reason when it gave one. Shared with
/// `switches`, so both say a refusal the same way.
pub fn refusedLine(out: *Io.Writer, name: []const u8, err: anyerror, reply: *const bridge_write.Reply) !void {
    try out.print("  {s}: refused or failed ({t}", .{ name, err });
    if (err == error.HttpError and reply.status != 0) {
        try out.writeAll(", ");
        try reply.describe(out);
    }
    try out.writeAll(")\n");
}
