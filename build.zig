//! dmain — one command across every package.
//!
//!     zig build           build everything, examples and apps included
//!     zig build test      run every package's host tests
//!     zig build check     typecheck everything, for the device as well
//!     zig build list      print the packages and what each supports
//!
//! Each package is independent, with its own `build.zig` and `build.zig.zon`,
//! and builds and tests on its own: `cd lib/hue && zig build test`. This
//! file only runs each one's own `zig build`, so it holds no build logic of its
//! own and deleting it breaks nothing.

const std = @import("std");

/// Every package, libraries before the programs that use them, so a failure
/// reports at its cause rather than downstream. The macOS admin app is a Swift
/// package and builds with `swift build` in `app/house/admin`.
const packages = [_]Package{
    .{ .path = "lib/util", .tests = true },
    .{ .path = "lib/houselog", .tests = true },
    .{ .path = "lib/httpd", .tests = true },
    .{ .path = "lib/tui", .tests = true },
    .{ .path = "lib/zigbee", .tests = true },
    .{ .path = "lib/hue", .tests = true },
    .{ .path = "app/house/hub", .tests = true },
    .{ .path = "app/house/huelog", .tests = true },
    .{ .path = "app/house/dmain", .tests = true },
};

/// The programs that run on a house server, checked for the two Linux targets
/// `app/house/deploy.sh` builds for. A Mac build proves nothing about Linux's
/// libc, and a 32-bit ARM board (a Raspberry Pi 3) has no 64-bit atomics: a
/// package can pass every host check and still not compile there.
const server_packages = [_][]const u8{ "app/house/huelog", "app/house/hub", "app/house/dmain" };

const linux_targets = [_][]const []const u8{
    &.{"-Dtarget=x86_64-linux-gnu"},
    &.{ "-Dtarget=arm-linux-gnueabihf", "-Dcpu=cortex_a53" },
};

const Package = struct {
    path: []const u8,
    /// Whether `zig build test` means anything here.
    tests: bool,
};

pub fn build(b: *std.Build) void {
    const all_step = b.getInstallStep();
    const test_step = b.step("test", "Run every package's tests");
    const check_step = b.step("check", "Typecheck every package");

    for (packages) |pkg| {
        all_step.dependOn(subBuild(b, pkg.path, &.{}));
        check_step.dependOn(subBuild(b, pkg.path, &.{"check"}));
        if (pkg.tests) test_step.dependOn(subBuild(b, pkg.path, &.{"test"}));
    }
    for (server_packages) |path| {
        for (linux_targets) |target| {
            const args = b.allocator.alloc([]const u8, target.len + 1) catch @panic("OOM");
            args[0] = "check";
            @memcpy(args[1..], target);
            const step = subBuild(b, path, args);
            step.name = b.fmt("{s}: zig build check {s}", .{ path, target[0] });
            check_step.dependOn(step);
        }
    }

    var listing: std.ArrayList(u8) = .empty;
    listing.appendSlice(b.allocator, "packages (dependency order):\n") catch @panic("OOM");
    for (packages) |pkg| {
        listing.appendSlice(b.allocator, b.fmt(
            "  {s: <28} {s}\n",
            .{ pkg.path, if (pkg.tests) "build check test" else "build check" },
        )) catch @panic("OOM");
    }
    const list = b.addSystemCommand(&.{ "printf", "%s" });
    list.addArg(listing.items);
    list.has_side_effects = true;
    b.step("list", "List the packages").dependOn(&list.step);
}

/// Runs `zig build [args...]` inside `path`, with the same zig that is running
/// this build, so a sub-build can never be compiled by a different toolchain.
fn subBuild(b: *std.Build, path: []const u8, args: []const []const u8) *std.Build.Step {
    const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    run.addArgs(args);
    run.setCwd(b.path(path));
    // A sub-build's own cache decides what is up to date; this wrapper cannot
    // know, so it must not claim the result is cacheable.
    run.has_side_effects = true;
    run.setName(b.fmt("{s}: zig build {s}", .{ path, if (args.len > 0) args[0] else "" }));
    return &run.step;
}
