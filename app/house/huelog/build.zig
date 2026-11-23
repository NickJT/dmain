const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const util = b.dependency("util", .{ .target = target, .optimize = optimize });
    const hue = b.dependency("hue", .{ .target = target, .optimize = optimize });
    const houselog = b.dependency("houselog", .{ .target = target, .optimize = optimize });

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "event_stream", .module = hue.module("event_stream") },
        .{ .name = "capture", .module = hue.module("capture") },
        .{ .name = "translate", .module = hue.module("translate") },
        .{ .name = "light_ids", .module = hue.module("light_ids") },
        .{ .name = "houselog", .module = houselog.module("houselog") },
        .{ .name = "sse_events", .module = hue.module("sse_events") },
        .{ .name = "resources", .module = hue.module("resources") },
        .{ .name = "maps", .module = hue.module("maps") },
        .{ .name = "local_time", .module = util.module("local_time") },
        .{ .name = "day_file", .module = util.module("day_file") },
        .{ .name = "atomic_file", .module = util.module("atomic_file") },
    };

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // local_time's localtime_r
        .imports = imports,
    });

    const exe = b.addExecutable(.{ .name = "huelog", .root_module = root_mod });
    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);

    const run_step = b.step("run", "Run huelog against the configured bridge");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(&install.step);
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run huelog's unit tests");
    const check_step = b.step("check", "Quickly check if everything compiles");
    for ([_][]const u8{"src/config.zig"}) |path| {
        const m = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = imports,
        });
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = m })).step);
        check_step.dependOn(&b.addObject(.{ .name = "huelog-check", .root_module = m }).step);
    }
    check_step.dependOn(&b.addExecutable(.{ .name = "huelog-exe-check", .root_module = root_mod }).step);
}
