//! dmain: the house under direct control. The folds and pages are pure: records and the clock in, JSON out.
//!
//!   dmain serve     the combined state and the phone pages, as dmain.json describes
//!   dmain admin     whole-class screens across every device, for a terminal
//!   dmain admin H   the same, anywhere, from host H's `dmain agent` over ssh
//!   dmain admin [H] --json   what the admin app draws, as JSON lines
//!   dmain agent     the far end of `dmain admin H`, not for running by hand
//!   dmain power-on  what each light should do when power returns, as a JSON file
//!   dmain switches  what each wall dimmer should do, from rooms.json
//!   dmain sensors   what each motion sensor should do, from rooms.json
//!   dmain schedules the Bridge's timed automations, from rooms.json
//!   dmain actions   the Dial's buttons and ring, from rooms.json's actions

const std = @import("std");
const Io = std.Io;
const display_cfg = @import("display.zig");
const config = @import("config.zig");
const serve = @import("serve.zig");
const admin = @import("admin.zig");
const agent = @import("agent.zig");
const power_on_cmd = @import("power_on_cmd.zig");
const switches_cmd = @import("switches_cmd.zig");
const sensors_cmd = @import("sensors_cmd.zig");
const schedules_cmd = @import("schedules_cmd.zig");
const actions_cmd = @import("actions_cmd.zig");
const rooms_cmd = @import("rooms_cmd.zig");
const history_cmd = @import("history_cmd.zig");

const usage =
    \\usage, from the directory holding dmain.json:
    \\  dmain serve
    \\  dmain admin
    \\usage, from anywhere:
    \\  dmain admin <server>      the same screens, from the server over ssh
    \\  dmain admin <server> --json   what the admin app draws, as JSON lines
    \\  dmain admin <server> <request>   one request, as the app makes it; `dmain admin x help`
    \\
++ power_on_cmd.usage ++ switches_cmd.usage ++ sensors_cmd.usage ++ schedules_cmd.usage ++ actions_cmd.usage ++ rooms_cmd.usage;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    var dba: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer _ = dba.deinit();
    const gpa = dba.allocator();

    var out_buf: [1024]u8 = undefined;
    var fw: Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
    const out = &fw.interface;
    defer out.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    const command = if (args.len >= 2) args[1] else "";
    const is_serve = std.mem.eql(u8, command, "serve") and args.len == 2;
    const is_admin = std.mem.eql(u8, command, "admin") and args.len == 2;
    const is_agent = std.mem.eql(u8, command, "agent") and args.len == 2;
    const json_flag = args.len >= 3 and std.mem.eql(u8, args[args.len - 1], "--json");
    const is_admin_json = std.mem.eql(u8, command, "admin") and args.len == 3 and json_flag;
    // Before dmain.json, which the far end reads: this end needs nothing local.
    if (std.mem.eql(u8, command, "admin") and args.len == 4 and json_flag) return admin.streamRemote(gpa, io, args[2]);
    if (std.mem.eql(u8, command, "admin") and args.len == 3 and !json_flag) return admin.runRemote(gpa, io, args[2], out);
    if (std.mem.eql(u8, command, "admin") and args.len >= 4 and !json_flag and history_cmd.isRequest(args[3])) {
        // The mirror's paths and the labels come from the checkout this runs in.
        var app = config.load(gpa, io, Io.Dir.cwd(), out) catch |err| {
            try out.flush();
            return err;
        };
        defer app.deinit();
        const ok = history_cmd.run(gpa, arena, io, out, args[2], args[3..], init.environ_map.get("HOME"), &app) catch |err| {
            if (err != error.BadUsage) return err;
            try out.writeAll("usage:\n" ++ history_cmd.usage);
            try out.flush();
            std.process.exit(2);
        };
        try out.flush();
        if (!ok) std.process.exit(1);
        return;
    }
    if (std.mem.eql(u8, command, "admin") and args.len >= 4 and !json_flag) {
        const ok = admin.runShot(gpa, io, out, args[2], args[3..]) catch |err| {
            if (err != error.BadUsage) return err;
            try out.writeAll("usage:\n" ++ admin.shot_usage ++ history_cmd.usage);
            try out.flush();
            std.process.exit(2);
        };
        try out.flush();
        if (!ok) std.process.exit(1);
        return;
    }
    const is_power_on = std.mem.eql(u8, command, "power-on");
    const is_switches = std.mem.eql(u8, command, "switches");
    const is_rooms = std.mem.eql(u8, command, "rooms");
    const is_sensors = std.mem.eql(u8, command, "sensors");
    const is_schedules = std.mem.eql(u8, command, "schedules");
    const is_actions = std.mem.eql(u8, command, "actions");
    if (!(is_serve or is_admin or is_admin_json or is_agent or is_power_on or is_switches or is_rooms or is_sensors or is_schedules or is_actions)) {
        try out.writeAll(usage);
        return;
    }
    const cwd = Io.Dir.cwd();
    var app = config.load(gpa, io, cwd, out) catch |err| {
        try out.flush();
        return err;
    };
    defer app.deinit();
    if (is_admin) return admin.run(gpa, io, &app, out);
    if (is_admin_json) return admin.streamLocal(gpa, io, &app);
    if (is_agent) return agent.run(gpa, io, &app, out);
    if (is_power_on or is_switches or is_rooms or is_sensors or is_schedules or is_actions) {
        var rest = try arena.alloc([]const u8, args.len - 2);
        for (args[2..], rest) |arg, *slot| slot.* = arg;
        // A trailing `-` on check or apply: the wanted file is on stdin.
        var given: ?[]const u8 = null;
        if (rest.len >= 2 and std.mem.eql(u8, rest[rest.len - 1], "-") and
            (std.mem.eql(u8, rest[0], "check") or std.mem.eql(u8, rest[0], "apply")))
        {
            rest = rest[0 .. rest.len - 1];
            var in_buf: [4096]u8 = undefined;
            var in: Io.File.Reader = .initStreaming(.stdin(), io, &in_buf);
            given = try in.interface.allocRemaining(arena, .limited(1 << 20));
        }
        const result = if (is_power_on)
            power_on_cmd.run(gpa, arena, io, &app, rest, given, out)
        else if (is_rooms)
            rooms_cmd.run(gpa, arena, io, &app, rest, given, out)
        else if (is_sensors)
            sensors_cmd.run(gpa, arena, io, &app, rest, given, out)
        else if (is_schedules)
            schedules_cmd.run(gpa, arena, io, &app, rest, given, out)
        else if (is_actions)
            actions_cmd.run(gpa, arena, io, &app, rest, given, out)
        else
            switches_cmd.run(gpa, arena, io, &app, rest, given, out);
        result catch |err| {
            try out.flush();
            if (err == error.BadUsage) std.process.exit(2);
            std.process.exit(1);
        };
        return;
    }
    var display = display_cfg.load(gpa, io, cwd, app.display_config, out) catch |err| {
        try out.flush();
        return err;
    };
    defer display.deinit();
    return serve.run(gpa, io, &app, &display, out);
}

test {
    _ = config;
    _ = admin;
    _ = agent;
    _ = @import("hub_client.zig");
    _ = @import("job.zig");
    _ = @import("wanted.zig");
    _ = @import("services.zig");
    _ = power_on_cmd;
    _ = switches_cmd;
    _ = sensors_cmd;
    _ = schedules_cmd;
    _ = actions_cmd;
    _ = rooms_cmd;
    _ = history_cmd;
    _ = @import("table.zig");
    _ = @import("motion.zig");
    _ = @import("live.zig");
    _ = @import("display.zig");
    _ = @import("rooms.zig");
    _ = @import("pages.zig");
    _ = @import("power_on.zig");
    _ = @import("fleet.zig");
    _ = @import("switch_layout.zig");
    _ = @import("sensor_layout.zig");
    _ = @import("schedule_layout.zig");
    _ = @import("action_layout.zig");
    _ = @import("room_scenes.zig");
    _ = @import("rooms_file.zig");
    _ = @import("link.zig");
    _ = @import("history.zig");
}
