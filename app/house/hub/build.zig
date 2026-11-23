const std = @import("std");

// hub is a host application only: no picozig, and no radio but the Zigbee one.

const ZooModules = struct {
    local_time: *std.Build.Module,
    ansi: *std.Build.Module,
    layout: *std.Build.Module,
    deep: *std.Build.Module,
    ieee: *std.Build.Module,
    persist: *std.Build.Module,
    serial: *std.Build.Module,
    ash: *std.Build.Module,
    link: *std.Build.Module,
    zdo: *std.Build.Module,
    zcl: *std.Build.Module,
    ezsp: *std.Build.Module,
    view: *std.Build.Module,
    config: *std.Build.Module,
    model: *std.Build.Module,
    engine: *std.Build.Module,
    sched: *std.Build.Module,
    screens: *std.Build.Module,
    web: *std.Build.Module,
    ctl: *std.Build.Module,
    house_log: *std.Build.Module,
    leak_alert: *std.Build.Module,
    bridge_sender: *std.Build.Module,
    humidity_run: *std.Build.Module,
    root: *std.Build.Module,
};

// The whole module graph, parameterized on target/optimize so it can be built
// once for the host (native/-Dtarget) and again for a fixed cross target (the
// `pi` step below) without either build's modules leaking into the other's.
fn buildModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) ZooModules {
    // ------------------------------------------------------------------
    // Leaf modules (no internal deps)
    // ------------------------------------------------------------------

    // ansi and json_get moved to lib/util on 2026-07-25: hub's copies were
    // byte-identical to an earlier Hue monitor's, which is the duplication that must move into
    // a library. layout, time, view and screens did NOT move —
    // hub's versions have diverged from the monitor's by correcting them, so they
    // are ported the other way first.
    //
    // Only `ansi` is taken. **hub does not use `json_get`** — it talks to the
    // NCP in binary, not to the Hue REST API, so there is no JSON to be
    // tolerant about; the monitor was the caller. It was wired in here anyway until
    // 2026-07-26, an import nothing imported.
    const util = b.dependency("util", .{
        .target = target,
        .optimize = optimize,
    });
    const ansi_mod = util.module("ansi");

    // Local wall-clock time — `src/time.zig` until 2026-07-26, now util's.
    // hub uses **only** the libc half (`localNow`, `formatLocalTime`,
    // `timeNow`), so it takes `local_time` and not util's freestanding-safe
    // `time`. The other six helpers the old file carried were the monitor's,
    // inherited back when the two applications held byte-identical copies.
    const local_time_mod = util.module("local_time");
    const serial_mod = util.module("serial");
    // Raw, non-blocking stdin for watch mode. One of six copies of this before
    // it moved to `util`.
    const term_mod = util.module("term");

    // The TUI display layer — `src/ui/layout.zig` and `src/ui/view.zig` until
    // 2026-07-26, now lib/tui. They were extracted once the monitor had been brought
    // up to hub's versions and the two applications' copies were byte-identical
    // — the same measured duplication that moved ansi and json_get into util.
    // `screens.zig` stays here: what a row says is this application's business.
    const tui = b.dependency("tui", .{ .target = target, .optimize = optimize });
    const httpd_dep = b.dependency("httpd", .{ .target = target, .optimize = optimize });
    const layout_mod = tui.module("layout");
    const view_mod = tui.module("view");

    const deep_mod = b.createModule(.{
        .root_source_file = b.path("src/deep.zig"),
        .target = target,
        .optimize = optimize,
    });

    const persist_mod = b.createModule(.{
        .root_source_file = b.path("src/persist.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "atomic_file", .module = util.module("atomic_file") }},
    });

    // ------------------------------------------------------------------
    // The Zigbee protocol stack — lib/zigbee
    // ------------------------------------------------------------------
    // ash → ezsp → zdo/zcl, plus link (which owns the serial device and ash
    // together so they can be rebuilt mid-session when the radio vanishes) and
    // ieee. Host-only: a Pico has no reason to speak to a ZBT-2.
    //
    // **The serial device is `util`'s, not this stack's** — see `serial_mod`
    // below. It moved once a second application wanted it, and taking it from
    // `util` here rather than through `zigbee` is what keeps one instance of it
    // in the graph.
    const zigbee = b.dependency("zigbee", .{
        .target = target,
        .optimize = optimize,
    });
    const ash_mod = zigbee.module("ash");
    const link_mod = zigbee.module("link");
    const ezsp_mod = zigbee.module("ezsp");
    const zdo_mod = zigbee.module("zdo");
    const zcl_mod = zigbee.module("zcl");
    const ieee_mod = zigbee.module("ieee");

    // ------------------------------------------------------------------
    // Composite modules
    // ------------------------------------------------------------------

    const hue_dep = b.dependency("hue", .{ .target = target, .optimize = optimize });
    const config_mod = b.createModule(.{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ieee", .module = ieee_mod },
            .{ .name = "light_ids", .module = hue_dep.module("light_ids") },
        },
    });

    const model_mod = b.createModule(.{
        .root_source_file = b.path("src/model.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ieee", .module = ieee_mod },
            .{ .name = "persist", .module = persist_mod },
            .{ .name = "local_time", .module = local_time_mod },
        },
    });

    const houselog_dep = b.dependency("houselog", .{ .target = target, .optimize = optimize });
    const house_log_mod = b.createModule(.{
        .root_source_file = b.path("src/house_log.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "houselog", .module = houselog_dep.module("houselog") },
            .{ .name = "day_file", .module = util.module("day_file") },
            .{ .name = "ieee", .module = ieee_mod },
            .{ .name = "config", .module = config_mod },
            .{ .name = "model", .module = model_mod },
        },
    });

    const bridge_sender_mod = b.createModule(.{
        .root_source_file = b.path("src/bridge_sender.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "bridge_write", .module = hue_dep.module("bridge_write") },
        },
    });
    const leak_alert_mod = b.createModule(.{
        .root_source_file = b.path("src/leak_alert.zig"),
        .target = target,
        .optimize = optimize,
    });
    const humidity_run_mod = b.createModule(.{
        .root_source_file = b.path("src/humidity_run.zig"),
        .target = target,
        .optimize = optimize,
    });

    const engine_mod = b.createModule(.{
        .root_source_file = b.path("src/engine.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "house_log", .module = house_log_mod },
            .{ .name = "ezsp", .module = ezsp_mod },
            .{ .name = "zdo", .module = zdo_mod },
            .{ .name = "zcl", .module = zcl_mod },
            .{ .name = "ieee", .module = ieee_mod },
            .{ .name = "config", .module = config_mod },
            .{ .name = "model", .module = model_mod },
            .{ .name = "persist", .module = persist_mod },
            .{ .name = "humidity_run", .module = humidity_run_mod },
        },
    });

    const sched_mod = b.createModule(.{
        .root_source_file = b.path("src/sched.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "config", .module = config_mod },
            .{ .name = "local_time", .module = local_time_mod },
        },
    });

    const screens_mod = b.createModule(.{
        .root_source_file = b.path("src/ui/screens.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "model", .module = model_mod },
            .{ .name = "config", .module = config_mod },
            .{ .name = "layout", .module = layout_mod },
            .{ .name = "view", .module = view_mod },
            .{ .name = "ieee", .module = ieee_mod },
            .{ .name = "ansi", .module = ansi_mod },
        },
    });

    const web_mod = b.createModule(.{
        .root_source_file = b.path("src/web.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "config", .module = config_mod },
            .{ .name = "model", .module = model_mod },
            .{ .name = "ieee", .module = ieee_mod },
            .{ .name = "httpd", .module = httpd_dep.module("httpd") },
        },
    });

    const ctl_mod = b.createModule(.{
        .root_source_file = b.path("src/ctl.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "model", .module = model_mod },
        },
    });

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "local_time", .module = local_time_mod },
            .{ .name = "ansi", .module = ansi_mod },
            .{ .name = "layout", .module = layout_mod },
            .{ .name = "deep", .module = deep_mod },
            .{ .name = "serial", .module = serial_mod },
            .{ .name = "term", .module = term_mod },
            .{ .name = "ash", .module = ash_mod },
            .{ .name = "link", .module = link_mod },
            .{ .name = "ezsp", .module = ezsp_mod },
            .{ .name = "zdo", .module = zdo_mod },
            .{ .name = "zcl", .module = zcl_mod },
            .{ .name = "view", .module = view_mod },
            .{ .name = "ieee", .module = ieee_mod },
            .{ .name = "config", .module = config_mod },
            .{ .name = "model", .module = model_mod },
            .{ .name = "engine", .module = engine_mod },
            .{ .name = "persist", .module = persist_mod },
            .{ .name = "screens", .module = screens_mod },
            .{ .name = "sched", .module = sched_mod },
            .{ .name = "web", .module = web_mod },
            .{ .name = "httpd", .module = httpd_dep.module("httpd") },
            .{ .name = "ctl", .module = ctl_mod },
            .{ .name = "house_log", .module = house_log_mod },
            .{ .name = "leak_alert", .module = leak_alert_mod },
            .{ .name = "bridge_sender", .module = bridge_sender_mod },
        },
    });

    return .{
        .local_time = local_time_mod,
        .ansi = ansi_mod,
        .layout = layout_mod,
        .deep = deep_mod,
        .ieee = ieee_mod,
        .persist = persist_mod,
        .serial = serial_mod,
        .ash = ash_mod,
        .link = link_mod,
        .zdo = zdo_mod,
        .zcl = zcl_mod,
        .ezsp = ezsp_mod,
        .view = view_mod,
        .config = config_mod,
        .model = model_mod,
        .engine = engine_mod,
        .sched = sched_mod,
        .screens = screens_mod,
        .web = web_mod,
        .ctl = ctl_mod,
        .house_log = house_log_mod,
        .leak_alert = leak_alert_mod,
        .bridge_sender = bridge_sender_mod,
        .humidity_run = humidity_run_mod,
        .root = root_mod,
    };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mods = buildModules(b, target, optimize);

    const exe = b.addExecutable(.{
        .name = "hub",
        .root_module = mods.root,
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run hub");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    run_step.dependOn(&run_cmd.step);
    run_cmd.addPassthruArgs();

    // ------------------------------------------------------------------
    // Raspberry Pi cross build: arm-linux-gnueabihf, cortex_a53 — the Pi 3B
    // this project is deployed to. Fixed target, independent of -Dtarget/-Dcpu, so `zig build pi`
    // needs no flags; the exe is named "hub-pi" so it lands in zig-out/bin/
    // alongside the native "hub" without overwriting it.
    // ------------------------------------------------------------------
    const pi_target = b.resolveTargetQuery(.{
        .cpu_arch = .arm,
        .os_tag = .linux,
        .abi = .gnueabihf,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_a53 },
    });
    const pi_mods = buildModules(b, pi_target, optimize);
    const pi_exe = b.addExecutable(.{ .name = "hub-pi", .root_module = pi_mods.root });
    const pi_step = b.step("pi", "Cross-compile hub for the Raspberry Pi 3 (arm-linux-gnueabihf, cortex_a53)");
    pi_step.dependOn(&b.addInstallArtifact(pi_exe, .{}).step);

    // ------------------------------------------------------------------
    // Fedora (PC) cross build: x86_64-linux-gnu, baseline CPU — this is the
    // `-Dtarget=x86_64-linux-gnu` build for the Fedora rig, packaged as its own
    // step. Baseline
    // (not a specific -mcpu) deliberately, since "the Fedora rig" names no
    // particular CPU model and a generic x86_64 baseline runs on any of
    // them, unlike the Pi's fixed-hardware cortex_a53 above. Exe named
    // "hub-fedora" so it lands in zig-out/bin/ alongside "hub"/"hub-pi"
    // without overwriting either.
    // ------------------------------------------------------------------
    const fedora_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .gnu,
    });
    const fedora_mods = buildModules(b, fedora_target, optimize);
    const fedora_exe = b.addExecutable(.{ .name = "hub-fedora", .root_module = fedora_mods.root });
    const fedora_step = b.step("fedora", "Cross-compile hub for the Fedora Linux PC (x86_64-linux-gnu)");
    fedora_step.dependOn(&b.addInstallArtifact(fedora_exe, .{}).step);

    // ------------------------------------------------------------------
    // Check step (ZLS integration): typecheck without running anything
    // ------------------------------------------------------------------
    const check_step = b.step("check", "Quickly check if everything compiles");
    const exe_check = b.addExecutable(.{
        .name = "check",
        .root_module = mods.root,
    });
    check_step.dependOn(&exe_check.step);

    // ------------------------------------------------------------------
    // Tests: one addTest per module, same pattern as both PoCs
    // ------------------------------------------------------------------
    const test_step = b.step("test", "Run deep checks and unit tests");
    // The protocol stack's own tests (serial, ash, link, ezsp, zdo, zcl, ieee)
    // moved to lib/zigbee with the code they exercise:
    // `cd ../lib/zigbee && zig build test`.
    // `time` is absent because it moved to lib/util, and `layout`/`view`
    // because they moved to lib/tui (both 2026-07-26) — each is tested in the
    // package that owns it: `cd ../../../lib/{util,tui} && zig build test`.
    const test_mods = [_]*std.Build.Module{
        // zig fmt: off
        mods.deep,
        mods.config, mods.model, mods.engine,      mods.screens,
        mods.sched,   mods.web,   mods.persist, mods.ctl,
        mods.house_log, mods.leak_alert, mods.bridge_sender,
        mods.humidity_run, mods.root,
        // zig fmt: on
    };
    for (test_mods) |mod| {
        const t = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // The UF2 packer, the chip layer and the board layer are all picozig's now,
    // and their tests moved with them, into picozig.
    // Duplicating them here would mean two places to update and one of them
    // silently rotting.
}
