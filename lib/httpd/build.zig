//! httpd — a small HTTP/1.1 server for a LAN page. One module, `httpd`.
//!
//! L1, host-only: sockets, `poll` and an operating system. No dependencies.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const httpd = b.addModule("httpd", .{
        .root_source_file = b.path("src/httpd.zig"),
        .target = target,
        .optimize = optimize,
    });

    const host = b.createModule(.{
        .root_source_file = b.path("src/httpd.zig"),
        .target = b.graph.host,
        .optimize = .debug,
    });
    const test_step = b.step("test", "Run httpd's unit tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = host })).step);

    const check_step = b.step("check", "Quickly check if everything compiles");
    check_step.dependOn(&b.addObject(.{ .name = "httpd-check", .root_module = httpd }).step);
}
