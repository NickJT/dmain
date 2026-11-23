const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const util = b.dependency("util", .{ .target = target, .optimize = optimize });
    const houselog = b.dependency("houselog", .{ .target = target, .optimize = optimize });
    const httpd = b.dependency("httpd", .{ .target = target, .optimize = optimize });
    const hue = b.dependency("hue", .{ .target = target, .optimize = optimize });
    const tui = b.dependency("tui", .{ .target = target, .optimize = optimize });

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // local dates, through day_file
        .imports = &.{
            .{ .name = "houselog", .module = houselog.module("houselog") },
            .{ .name = "reader", .module = houselog.module("reader") },
            .{ .name = "day_file", .module = util.module("day_file") },
            .{ .name = "local_time", .module = util.module("local_time") },
            .{ .name = "httpd", .module = httpd.module("httpd") },
            .{ .name = "bridge_write", .module = hue.module("bridge_write") },
            .{ .name = "bridge_switches", .module = hue.module("bridge_switches") },
            .{ .name = "bridge_sensors", .module = hue.module("bridge_sensors") },
            .{ .name = "bridge_schedules", .module = hue.module("bridge_schedules") },
            .{ .name = "bridge_dial", .module = hue.module("bridge_dial") },
            .{ .name = "bridge_info", .module = hue.module("bridge_info") },
            .{ .name = "light_ids", .module = hue.module("light_ids") },
            .{ .name = "term", .module = util.module("term") },
            .{ .name = "layout", .module = tui.module("layout") },
            .{ .name = "view", .module = tui.module("view") },
        },
    });

    const exe = b.addExecutable(.{ .name = "dmain", .root_module = root_mod });
    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);

    const run_step = b.step("run", "Run dmain");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(&install.step);
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run dmain's unit tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = root_mod })).step);

    const check_step = b.step("check", "Quickly check if everything compiles");
    check_step.dependOn(&b.addExecutable(.{ .name = "dmain-check", .root_module = root_mod }).step);
}
