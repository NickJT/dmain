//! houselog — what the house's devices did, in a vocabulary no source owns.
//!
//!   houselog   the records, and their one-line JSON form (pure)
//!   reader     a day's file replayed, then followed across midnight
//!
//! L2 domain library, **host-only** because the reader names files by local
//! date. Sources write it through a translator of their own — `lib/hue` for the
//! Hue bridge today — and consumers read only this.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const util = b.dependency("util", .{ .target = target, .optimize = optimize });

    const houselog = b.addModule("houselog", .{
        .root_source_file = b.path("src/houselog.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "time", .module = util.module("time") },
            .{ .name = "atomic_file", .module = util.module("atomic_file") },
        },
    });
    const reader = b.addModule("reader", .{
        .root_source_file = b.path("src/reader.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "houselog", .module = houselog },
            .{ .name = "day_file", .module = util.module("day_file") },
        },
    });

    // Tests on the host at Debug whatever the caller asked for: logic tests,
    // and a cross-compiled test binary cannot be run.
    const host_util = b.dependency("util", .{ .target = b.graph.host, .optimize = .debug });
    const host_houselog = b.createModule(.{
        .root_source_file = b.path("src/houselog.zig"),
        .target = b.graph.host,
        .optimize = .debug,
        .imports = &.{
            .{ .name = "time", .module = host_util.module("time") },
            .{ .name = "atomic_file", .module = host_util.module("atomic_file") },
        },
    });
    const host_reader = b.createModule(.{
        .root_source_file = b.path("src/reader.zig"),
        .target = b.graph.host,
        .optimize = .debug,
        .link_libc = true,
        .imports = &.{
            .{ .name = "houselog", .module = host_houselog },
            .{ .name = "day_file", .module = host_util.module("day_file") },
        },
    });

    const test_step = b.step("test", "Run houselog's unit tests");
    for ([_]*std.Build.Module{ host_houselog, host_reader }) |m| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = m })).step);
    }

    const check_step = b.step("check", "Quickly check if everything compiles");
    for ([_]*std.Build.Module{ houselog, reader }) |m| {
        check_step.dependOn(&b.addObject(.{ .name = "houselog-check", .root_module = m }).step);
    }
}
