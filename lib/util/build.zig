//! util — the small things two applications genuinely share.
//!
//!   ansi       terminal escape sequences
//!   json_get   tolerant getters over `std.json.Value`
//!
//! Both import nothing but `std`, and both are **freestanding-safe** — no
//! allocator unless handed one, no OS, no `std.fs`.
//!
//! ## Why this package exists, and why it is only two files
//!
//! The workspace rule is not to extract a shared abstraction until there is real
//! duplication, and then that duplication moves into a library. Both halves of
//! that rule are being obeyed here, on measurement rather than intuition.
//!
//! When an earlier Hue monitor and `app/house/hub` were compared, hub's files
//! having been copied from the monitor's, they measured:
//!
//!     ansi.zig       byte-identical, 161 lines
//!     json_get.zig   byte-identical, 145 lines
//!     layout.zig     15 differing lines
//!     time.zig       82
//!     view.zig       287
//!     screens.zig    841
//!
//! **Only the first two were duplication.** The rest had genuinely diverged —
//! hub corrected and improved them — so pulling them in here would be a redesign
//! wearing a migration's clothes, and it would silently pick a winner between
//! two versions where one is known to be better. They are handled the other way
//! round: hub's versions get ported into the other copy first, and only then is sharing
//! worth reconsidering.
//!
//! So this package is deliberately small, and should stay that way. It is not a
//! home for things that have nowhere else to go — that is what makes a `util`
//! rot. A file arrives here when two callers already have the same copy of it.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Freestanding-safe: no libc, no OS, no allocator except one handed in.
    // These are checked against a thumb-freestanding target below, which is
    // what stops the promise quietly lapsing.
    //
    // `crc` is CRC-8/SMBUS. It arrived as two copies of the same bit loop
    // inside a signal generator's frame decoder, and a second application framing
    // its own messages made a third. A named checksum with a published check
    // value is about as safe as a shared file gets: there is no design in it
    // to get wrong, only a polynomial to keep in one place.
    const modules = [_][]const u8{ "ansi", "crc", "json_get", "time" };

    var public: [modules.len]*std.Build.Module = undefined;
    for (modules, 0..) |name, i| {
        public[i] = b.addModule(name, .{
            .root_source_file = b.path(b.fmt("src/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
        });
    }

    // ------------------------------------------------------------------
    // local_time — the one host-only module, and the reason for the split
    // ------------------------------------------------------------------
    // Converting an instant to local wall-clock time needs libc's
    // `localtime_r`, which a freestanding target does not have. Keeping it in
    // `time.zig` would have meant every caller of `formatTimestamp` dragging in
    // libc to get it — including a future Pico frontend that only wanted to
    // print a duration. So it is a separate module, taken only by callers that
    // genuinely need a wall clock, and **deliberately absent from the
    // freestanding check below**: it would not compile there, and should not.
    _ = b.addModule("local_time", .{
        .root_source_file = b.path("src/local_time.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // ------------------------------------------------------------------
    // serial and term — the host's two terminal devices
    // ------------------------------------------------------------------
    // Both arrived here by this package's own admission rule: a file comes to
    // `util` when two callers already have the same copy of it.
    //
    // **`serial` had two callers and lived in neither's territory.** It was
    // `lib/zigbee/src/serial.zig`, which made a signal generator reach sideways into
    // a Zigbee package for a `/dev/cu.*`. It knows nothing about Zigbee — it is
    // a raw 8N1 character device, and the reason it is worth sharing rather
    // than rewriting is the one thing in it that is not obvious: **Zig's macOS
    // `speed_t` stops at `B230400`, so any rate above that needs the
    // `IOSSIOSPEED` ioctl.**
    //
    // **`term` had four**, in four applications, each a slightly different
    // `enableRawMode`.
    //
    // Host-only and **deliberately absent from the freestanding check below**,
    // for the same reason as `local_time`: they are termios and ioctls, and a
    // freestanding target has neither.
    //
    // `serial`'s OS-specific halves are gated on `builtin.target.os.tag`, so each host
    // skips the other's tests. Cross-compiling the check is what keeps the
    // skipped half honest, and is worth running after any change to it:
    //
    //     zig build check -Dtarget=x86_64-linux-gnu
    // ------------------------------------------------------------------
    // day_file — one append-only file per local day
    // ------------------------------------------------------------------
    // Two callers had the same appender: a dashboard's CSV and huelog's capture,
    // with the house log about to be a third. Host-only because it names
    // files by local date, which is `local_time`'s libc.
    const local_time = b.modules.get("local_time").?;
    _ = b.addModule("day_file", .{
        .root_source_file = b.path("src/day_file.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "local_time", .module = local_time }},
    });

    // hub and huelog both replace whole files, and half of one is never acceptable.
    _ = b.addModule("atomic_file", .{
        .root_source_file = b.path("src/atomic_file.zig"),
        .target = target,
        .optimize = optimize,
    });

    for ([_][]const u8{ "serial", "term" }) |name| {
        _ = b.addModule(name, .{
            .root_source_file = b.path(b.fmt("src/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
            // termios and the OS-specific ioctls.
            .link_libc = true,
        });
    }

    // ------------------------------------------------------------------
    // Standalone verification, host and freestanding
    // ------------------------------------------------------------------
    // Nothing consumes these from a freestanding target today. They are checked
    // for one anyway because they cost nothing to keep portable and everything
    // to make portable later — a device frontend is the likely first
    // caller, and an `ansi` that had quietly acquired an OS assumption would be
    // found at the worst moment.
    const freestanding = b.resolveTargetQuery(.{
        .cpu_arch = .thumb,
        .os_tag = .freestanding,
        .abi = .eabi,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m33 },
        .cpu_features_sub = std.Target.arm.featureSet(&.{.fpregs}),
    });

    const check_step = b.step("check", "Typecheck for host and freestanding");
    const test_step = b.step("test", "Run util's unit tests");

    for (modules) |name| {
        const src = b.path(b.fmt("src/{s}.zig", .{name}));

        const fs_mod = b.createModule(.{
            .root_source_file = src,
            .target = freestanding,
            .optimize = .small,
        });
        const obj = b.addObject(.{
            .name = b.fmt("{s}-freestanding", .{name}),
            .root_module = fs_mod,
        });
        b.getInstallStep().dependOn(&obj.step);
        check_step.dependOn(&obj.step);

        const host_mod = b.createModule(.{
            .root_source_file = src,
            .target = b.graph.host,
            .optimize = .debug,
        });
        const t = b.addTest(.{ .root_module = host_mod });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    const atomic_file_host = b.createModule(.{
        .root_source_file = b.path("src/atomic_file.zig"),
        .target = b.graph.host,
        .optimize = .debug,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = atomic_file_host })).step);

    // The host-only three are host-tested only — see above for why none of them
    // has a freestanding half. They are still *checked* for the host, which for
    // `serial` is the point of the cross-compile note above: a mac-only build
    // never compiles the Linux ioctl paths at all.
    for ([_][]const u8{ "local_time", "serial", "term" }) |name| {
        const host_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/{s}.zig", .{name})),
            .target = target,
            .optimize = .debug,
            .link_libc = true,
        });
        const t = b.addTest(.{ .root_module = host_mod });
        test_step.dependOn(&b.addRunArtifact(t).step);
        check_step.dependOn(&t.step);
    }
    {
        const host_local_time = b.createModule(.{
            .root_source_file = b.path("src/local_time.zig"),
            .target = target,
            .optimize = .debug,
            .link_libc = true,
        });
        const host_mod = b.createModule(.{
            .root_source_file = b.path("src/day_file.zig"),
            .target = target,
            .optimize = .debug,
            .link_libc = true,
            .imports = &.{.{ .name = "local_time", .module = host_local_time }},
        });
        const t = b.addTest(.{ .root_module = host_mod });
        test_step.dependOn(&b.addRunArtifact(t).step);
        check_step.dependOn(&t.step);
    }

    // ------------------------------------------------------------------
    // example/ansi-demo — the half of this package a test cannot check
    // ------------------------------------------------------------------
    // `json_get` is pure logic and is asserted by the tests above. `ansi` emits
    // escape sequences, and whether a terminal *honours* them is not something
    // any test can answer — so that half gets a demo to be judged by eye
    // instead. Run it in whatever terminal a TUI is headed for.
    const example_mod = b.createModule(.{
        .root_source_file = b.path("example/ansi-demo/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ansi", .module = public[0] }},
    });
    const example = b.addExecutable(.{ .name = "ansi-demo", .root_module = example_mod });
    b.installArtifact(example);
    check_step.dependOn(&example.step);

    const run_example = b.addRunArtifact(example);
    const run_step = b.step("ansi-demo", "Render every escape sequence ansi.zig emits");
    run_step.dependOn(&run_example.step);
}
