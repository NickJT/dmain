//! tui — the terminal display both applications draw with.
//!
//!   layout   pure geometry: columns, sections, row offsets, resize detection
//!   view     cursor-addressed writes, the scrolling log, the command line
//!
//! L1, **host-only**: `view` writes ANSI to a terminal and reads a wall clock,
//! neither of which a Pico has. Sits above `util` rather than inside it —
//! util's rule is small freestanding-safe files with no dependencies, and
//! `view` needs `ansi` and `local_time`.
//!
//! ## Why this is a library and `screens.zig` is not
//!
//! Extracted 2026-07-26, when hub's versions had been ported into an earlier Hue monitor and the
//! two applications' copies became **byte-identical** — the same measured
//! duplication that moved `ansi` and `json_get` into `util`, not a framework
//! anyone set out to build.
//!
//! Everything here is domain-agnostic by construction: `Row`, `Section`,
//! geometry, escape sequences. Nothing knows what a Zigbee device or a Hue
//! light is, and nothing should.
//!
//! **`screens.zig` stays in each application, deliberately.** The two share a
//! pattern — a `ViewSpec` table, a `RenderPlan`, one collate function per mode
//! — and nothing else: hub collated devices from a `Registry`, the retired monitor
//! resources from a `Model`, and their collate signatures differed accordingly.
//! Unifying them would mean generic over the model type, the config type and
//! the collate signature: a parameterised framework serving two callers, where
//! every future screen pays a generality tax to fit an interface neither asked
//! for. A pattern is cheaper to re-type than to abstract. The shared part is the
//! display, and what a row *says* is the application's business.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const util = b.dependency("util", .{ .target = target, .optimize = optimize });

    // Pure geometry — no I/O, no escape sequences, no dependencies. It is the
    // single source of truth for every row and column offset: `view` used to
    // keep its own copies, they drifted one row apart, and the log spent six
    // build steps overwriting the command line.
    const layout = b.addModule("layout", .{
        .root_source_file = b.path("src/layout.zig"),
        .target = target,
        .optimize = optimize,
    });

    const view = b.addModule("view", .{
        .root_source_file = b.path("src/view.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "layout", .module = layout },
            .{ .name = "ansi", .module = util.module("ansi") },
            // The corner clock, and the only reason this package is host-only.
            .{ .name = "local_time", .module = util.module("local_time") },
        },
    });

    // ------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------
    // Both modules are worth testing and both are testable without a terminal:
    // `layout` is arithmetic, and `view` writes into a fixed buffer that the
    // tests then read back. The display-column tests are the valuable ones —
    // they pin the byte-vs-column bug this repo diagnosed twice from
    // screenshots before understanding it.
    const test_step = b.step("test", "Run tui's unit tests");
    const host_layout = b.createModule(.{
        .root_source_file = b.path("src/layout.zig"),
        .target = b.graph.host,
        .optimize = .debug,
    });
    const host_util = b.dependency("util", .{ .target = b.graph.host, .optimize = .debug });
    const host_view = b.createModule(.{
        .root_source_file = b.path("src/view.zig"),
        .target = b.graph.host,
        .optimize = .debug,
        .imports = &.{
            .{ .name = "layout", .module = host_layout },
            .{ .name = "ansi", .module = host_util.module("ansi") },
            .{ .name = "local_time", .module = host_util.module("local_time") },
        },
    });
    for ([_]*std.Build.Module{ host_layout, host_view }) |mod| {
        const t = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // ------------------------------------------------------------------
    // example/tui-demo — the whole render loop, with the domain taken out
    // ------------------------------------------------------------------
    // A library with two modules needs to say which does what, and pointing at
    // `hub` or `dmain` means picking the loop out of several hundred lines of
    // Zigbee or house collation first. This is that loop against fake data.
    const example_mod = b.createModule(.{
        .root_source_file = b.path("example/tui-demo/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "layout", .module = layout },
            .{ .name = "view", .module = view },
        },
    });
    const example = b.addExecutable(.{ .name = "tui-demo", .root_module = example_mod });
    b.installArtifact(example);

    const run_example = b.addRunArtifact(example);
    run_example.addPassthruArgs();
    const run_step = b.step("tui-demo", "Run a self-driving dashboard (-- [seconds])");
    run_step.dependOn(&run_example.step);

    // ------------------------------------------------------------------
    // Check step (ZLS integration)
    // ------------------------------------------------------------------
    const check_step = b.step("check", "Quickly check if everything compiles");
    check_step.dependOn(&example.step);
    for ([_]*std.Build.Module{ host_layout, host_view }) |mod| {
        const obj = b.addObject(.{ .name = "tui-check", .root_module = mod });
        check_step.dependOn(&obj.step);
        b.getInstallStep().dependOn(&obj.step);
    }
}
