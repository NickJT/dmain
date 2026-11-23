//! zigbee — the protocol stack: serial → ASH → EZSP → ZDO/ZCL.
//!
//! L2 domain library, **host-only**. A Pico has no reason to speak to a ZBT-2,
//! so unlike the firmware drivers this package is free to assume an allocator,
//! an operating system and a filesystem.
//!
//! The six modules, bottom to top. The serial device under them is
//! `util.serial`, which moved out of here once a second application wanted it —
//! it knows nothing about Zigbee.
//!
//!   ash      ASH framing, CRC, randomisation, reliable transport
//!   link     util.serial + ash + the handshake, owned together so they can be
//!            rebuilt mid-session when the radio vanishes
//!   ezsp     EZSP client over ash
//!   zdo      pure ZDO builders/parsers — discovery, bind, leave, addr req
//!   zcl      pure ZCL framing/parsing — On/Off, Level, reporting, IAS, colour
//!   ieee     wire-order ⇄ display-order colon-hex EUI64 conversions
//!
//! `zdo`, `zcl` and `ieee` are pure codecs with no I/O at all, which is why the
//! protocol tests need no radio.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mods = addModules(b, target, optimize, .public);

    const check_step = b.step("check", "Quickly check if everything compiles");
    // A library has no entry point; `addObject` type-checks a module fully and
    // emits an object nobody installs. `link` transitively covers serial+ash,
    // and `ezsp` covers ash again, so between them and the pure codecs every
    // file is compiled.
    const roots = [_]struct { name: []const u8, mod: *std.Build.Module }{
        .{ .name = "link", .mod = mods.link },
        .{ .name = "ezsp", .mod = mods.ezsp },
        .{ .name = "zdo", .mod = mods.zdo },
        .{ .name = "zcl", .mod = mods.zcl },
        .{ .name = "ieee", .mod = mods.ieee },
    };
    for (roots) |r| {
        const obj = b.addObject(.{ .name = r.name, .root_module = r.mod });
        b.getInstallStep().dependOn(&obj.step);
        check_step.dependOn(&obj.step);
    }

    // ------------------------------------------------------------------
    // example/ncp-info — the bottom three layers, against a real radio
    // ------------------------------------------------------------------
    // Built on every host so it cannot rot; meaningful only where a ZBT-2 is
    // plugged in. It reads and reports, and runs no command that changes NCP
    // state — see its header for why `networkInit` is deliberately absent.
    const example_mod = b.createModule(.{
        .root_source_file = b.path("example/ncp-info/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "link", .module = mods.link },
            .{ .name = "ezsp", .module = mods.ezsp },
            .{ .name = "ieee", .module = mods.ieee },
        },
    });
    const example = b.addExecutable(.{ .name = "ncp-info", .root_module = example_mod });
    b.installArtifact(example);
    check_step.dependOn(&example.step);

    const run_example = b.addRunArtifact(example);
    run_example.addPassthruArgs();
    const run_step = b.step("ncp-info", "Report on an attached ZBT-2 (-- [device-path] [baud])");
    run_step.dependOn(&run_example.step);

    // ------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------
    // `serial`'s own tests moved to `lib/util` with the file, including the
    // cross-compile note that keeps its OS-gated halves honest.
    const test_step = b.step("test", "Run the protocol stack's unit tests");
    const host = addModules(b, b.graph.host, .debug, .private);
    for ([_]*std.Build.Module{
        host.ash, host.link, host.ezsp,
        host.zdo, host.zcl,  host.ieee,
    }) |mod| {
        const t = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}

const Modules = struct {
    /// `util`'s, re-exposed so `link` and its dependents resolve one instance.
    serial: *std.Build.Module,
    ash: *std.Build.Module,
    link: *std.Build.Module,
    ezsp: *std.Build.Module,
    zdo: *std.Build.Module,
    zcl: *std.Build.Module,
    ieee: *std.Build.Module,
};

/// Only the `.public` call may register names — `addModule` puts a module in the
/// package namespace, so registering twice would hand a dependent whichever
/// instance came last, quite possibly the host-targeted one built for the tests.
const Visibility = enum { public, private };

fn addModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    visibility: Visibility,
) Modules {
    // The serial device is `util`'s, and is taken at this package's own target
    // so the host-built test instance and the public one cannot be confused.
    const serial = b.dependency("util", .{ .target = target, .optimize = optimize })
        .module("serial");

    const make = struct {
        fn f(
            bb: *std.Build,
            vis: Visibility,
            name: []const u8,
            options: std.Build.Module.CreateOptions,
        ) *std.Build.Module {
            return switch (vis) {
                .public => bb.addModule(name, options),
                .private => bb.createModule(options),
            };
        }
    }.f;

    const ash = make(b, visibility, "ash", .{
        .root_source_file = b.path("src/ash.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zdo = make(b, visibility, "zdo", .{
        .root_source_file = b.path("src/zdo.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zcl = make(b, visibility, "zcl", .{
        .root_source_file = b.path("src/zcl.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ieee = make(b, visibility, "ieee", .{
        .root_source_file = b.path("src/ieee.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ezsp = make(b, visibility, "ezsp", .{
        .root_source_file = b.path("src/ezsp.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ash", .module = ash }},
    });

    const link = make(b, visibility, "link", .{
        .root_source_file = b.path("src/link.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "serial", .module = serial },
            .{ .name = "ash", .module = ash },
        },
    });

    return .{
        .serial = serial,
        .ash = ash,
        .link = link,
        .ezsp = ezsp,
        .zdo = zdo,
        .zcl = zcl,
        .ieee = ieee,
    };
}
