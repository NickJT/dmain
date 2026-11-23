//! hue — the Philips Hue bridge, as a library.
//!
//!   resources    the typed resource model: lights, sensors, devices, rooms
//!   maps         ResourceRegistry and Directory — the live in-memory model
//!   sse_events   pure parsing of an SSE `data:` payload into EventUpdates
//!   tls_client   std's TLS client, patched to offer the suite a bridge needs
//!   tls_http     the transport: a validated connect, request, chunked/SSE reading
//!   event_stream the event stream followed forever: snapshot, SSE, reconnect
//!   capture      the raw capture's line format: what the bridge said, verbatim
//!   translate    the capture → the house log, where every CLIP quirk stops
//!
//! L2 domain library, **host-only**: it allocates, opens sockets and assumes an
//! operating system. Nothing here will ever run on a Pico.
//!
//! ## Why this is a library
//!
//! Extracted 2026-08-18, when a second program needed the same resource model
//! an earlier Hue monitor already had. The three model files moved across **byte-identical** — the
//! measured duplication the workspace requires before extracting, and the same
//! route `ansi`/`json_get` took into `util` and `layout`/`view` took into `tui`.
//! The alternative was a 4,500-line copy in a second application.
//!
//! **The transport did not move with them.** The monitor kept its own over Apple's
//! SecureTransport, which can't leave macOS; this package's `tls_http` is pure
//! Zig over the patched std client and runs anywhere. The monitor retired on
//! 2026-11-11, so this one is the only transport now.
//!
//! The split follows util's `time`/`local_time` precedent: **a dependency that
//! only part of a file needs belongs only to that part.** Every consumer of
//! `sse_events` would otherwise inherit a TLS stack it may not want.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const util = b.dependency("util", .{ .target = target, .optimize = optimize });
    const houselog = b.dependency("houselog", .{ .target = target, .optimize = optimize });

    // ------------------------------------------------------------------
    // tls_client — std's TLS client, patched at build time
    // ------------------------------------------------------------------
    // See tools/patch-tls for the whole story. In one line: a Hue bridge
    // accepts only ECDHE-ECDSA-AES128-GCM-SHA256 and std never offers it, so
    // the handshake fails before any HTTP happens.
    //
    // Generated rather than vendored so the patch tracks whichever compiler is
    // in use. `b.graph.zig_lib_directory` is that compiler's own lib/, so this
    // cannot drift from the `zig` being run.
    const patch_tls = b.addExecutable(.{
        .name = "patch-tls",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/patch-tls/src/main.zig"),
            .target = b.graph.host, // a build-time tool: always runs here
            .optimize = .debug,
        }),
    });

    const run_patch = b.addRunArtifact(patch_tls);
    run_patch.addFileArg(std.Build.LazyPath.zig_lib.path(b, "std/crypto/tls/Client.zig"));
    const patched_client = run_patch.addOutputFileArg("TlsClient.zig");

    // The one check the patch adds rather than enables. A real file, so it has
    // tests of its own and nothing but the call lives in the patch.
    const cert_issuer = b.createModule(.{
        .root_source_file = b.path("src/cert_issuer.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tls_client = b.addModule("tls_client", .{
        .root_source_file = patched_client,
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cert_issuer", .module = cert_issuer },
        },
    });

    // ------------------------------------------------------------------
    // The model — pure, and the reason this package exists
    // ------------------------------------------------------------------
    const resources = b.addModule("resources", .{
        .root_source_file = b.path("src/resources.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "json_get", .module = util.module("json_get") },
            .{ .name = "ansi", .module = util.module("ansi") },
            .{ .name = "time", .module = util.module("time") },
        },
    });

    const maps = b.addModule("maps", .{
        .root_source_file = b.path("src/maps.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "json_get", .module = util.module("json_get") },
            .{ .name = "resources", .module = resources },
        },
    });

    // No I/O, no sockets, no filesystem: literal JSON in, EventUpdates out.
    // The cheapest thing in the package to test and the first place to look
    // when the bridge sends something unexpected.
    const sse_events = b.addModule("sse_events", .{
        .root_source_file = b.path("src/sse_events.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "json_get", .module = util.module("json_get") },
            .{ .name = "time", .module = util.module("time") },
            .{ .name = "resources", .module = resources },
        },
    });

    const tls_http = b.addModule("tls_http", .{
        .root_source_file = b.path("src/tls_http.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tls_client", .module = tls_client },
        },
    });

    // Separate from tls_http so a consumer of the translator takes no TLS with it.
    const light_ids = b.addModule("light_ids", .{
        .root_source_file = b.path("src/light_ids.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Pure, so a test needs no TLS.
    const bridge_switches = b.addModule("bridge_switches", .{
        .root_source_file = b.path("src/bridge_switches.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "json_get", .module = util.module("json_get") }},
    });

    const bridge_sensors = b.addModule("bridge_sensors", .{
        .root_source_file = b.path("src/bridge_sensors.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "json_get", .module = util.module("json_get") }},
    });
    const bridge_schedules = b.addModule("bridge_schedules", .{
        .root_source_file = b.path("src/bridge_schedules.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "json_get", .module = util.module("json_get") }},
    });
    const bridge_dial = b.addModule("bridge_dial", .{
        .root_source_file = b.path("src/bridge_dial.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "json_get", .module = util.module("json_get") }},
    });
    const bridge_info = b.addModule("bridge_info", .{
        .root_source_file = b.path("src/bridge_info.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "json_get", .module = util.module("json_get") }},
    });

    const bridge_write = b.addModule("bridge_write", .{
        .root_source_file = b.path("src/bridge_write.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tls_http", .module = tls_http },
            .{ .name = "houselog", .module = houselog.module("houselog") },
        },
    });

    // Every consumer's reconnect loop, written once. Handler-driven, so what
    // an event means stays in the application.
    const event_stream = b.addModule("event_stream", .{
        .root_source_file = b.path("src/event_stream.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tls_http", .module = tls_http },
            .{ .name = "sse_events", .module = sse_events },
            .{ .name = "maps", .module = maps },
            .{ .name = "resources", .module = resources },
        },
    });

    // Pure: an envelope around the bridge's own bytes, and back.
    const capture = b.addModule("capture", .{
        .root_source_file = b.path("src/capture.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "time", .module = util.module("time") }},
    });

    const translate = b.addModule("translate", .{
        .root_source_file = b.path("src/translate.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "json_get", .module = util.module("json_get") },
            .{ .name = "time", .module = util.module("time") },
            .{ .name = "houselog", .module = houselog.module("houselog") },
            .{ .name = "capture", .module = capture },
            .{ .name = "sse_events", .module = sse_events },
            .{ .name = "resources", .module = resources },
            .{ .name = "maps", .module = maps },
            .{ .name = "light_ids", .module = light_ids },
        },
    });

    // ------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------
    // Always on the host at Debug regardless of what the caller asked for:
    // these are logic tests, and a cross-compiled test binary cannot be run.
    const test_step = b.step("test", "Run hue's unit tests");
    const host_util = b.dependency("util", .{ .target = b.graph.host, .optimize = .debug });

    const host_resources = b.createModule(.{
        .root_source_file = b.path("src/resources.zig"),
        .target = b.graph.host,
        .optimize = .debug,
        .imports = &.{
            .{ .name = "json_get", .module = host_util.module("json_get") },
            .{ .name = "ansi", .module = host_util.module("ansi") },
            .{ .name = "time", .module = host_util.module("time") },
        },
    });
    const host_maps = b.createModule(.{
        .root_source_file = b.path("src/maps.zig"),
        .target = b.graph.host,
        .optimize = .debug,
        .imports = &.{
            .{ .name = "json_get", .module = host_util.module("json_get") },
            .{ .name = "resources", .module = host_resources },
        },
    });
    const host_sse = b.createModule(.{
        .root_source_file = b.path("src/sse_events.zig"),
        .target = b.graph.host,
        .optimize = .debug,
        .imports = &.{
            .{ .name = "json_get", .module = host_util.module("json_get") },
            .{ .name = "time", .module = host_util.module("time") },
            .{ .name = "resources", .module = host_resources },
        },
    });
    const host_tls_http = b.createModule(.{
        .root_source_file = b.path("src/tls_http.zig"),
        .target = b.graph.host,
        .optimize = .debug,
        .imports = &.{
            .{ .name = "tls_client", .module = tls_client },
        },
    });

    const host_event_stream = b.createModule(.{
        .root_source_file = b.path("src/event_stream.zig"),
        .target = b.graph.host,
        .optimize = .debug,
        .imports = &.{
            .{ .name = "tls_http", .module = host_tls_http },
            .{ .name = "sse_events", .module = host_sse },
            .{ .name = "maps", .module = host_maps },
            .{ .name = "resources", .module = host_resources },
        },
    });

    const host_capture = b.createModule(.{
        .root_source_file = b.path("src/capture.zig"),
        .target = b.graph.host,
        .optimize = .debug,
        .imports = &.{.{ .name = "time", .module = host_util.module("time") }},
    });

    const host_houselog = b.dependency("houselog", .{ .target = b.graph.host, .optimize = .debug });
    const host_light_ids = b.createModule(.{
        .root_source_file = b.path("src/light_ids.zig"),
        .target = b.graph.host,
        .optimize = .debug,
    });
    const host_bridge_switches = b.createModule(.{
        .root_source_file = b.path("src/bridge_switches.zig"),
        .target = b.graph.host,
        .optimize = .debug,
        .imports = &.{.{ .name = "json_get", .module = host_util.module("json_get") }},
    });
    const host_bridge_sensors = b.createModule(.{
        .root_source_file = b.path("src/bridge_sensors.zig"),
        .target = b.graph.host,
        .optimize = .debug,
        .imports = &.{.{ .name = "json_get", .module = host_util.module("json_get") }},
    });
    const host_bridge_schedules = b.createModule(.{
        .root_source_file = b.path("src/bridge_schedules.zig"),
        .target = b.graph.host,
        .optimize = .debug,
        .imports = &.{.{ .name = "json_get", .module = host_util.module("json_get") }},
    });
    const host_bridge_dial = b.createModule(.{
        .root_source_file = b.path("src/bridge_dial.zig"),
        .target = b.graph.host,
        .optimize = .debug,
        .imports = &.{.{ .name = "json_get", .module = host_util.module("json_get") }},
    });
    const host_bridge_info = b.createModule(.{
        .root_source_file = b.path("src/bridge_info.zig"),
        .target = b.graph.host,
        .optimize = .debug,
        .imports = &.{.{ .name = "json_get", .module = host_util.module("json_get") }},
    });
    const host_bridge_write = b.createModule(.{
        .root_source_file = b.path("src/bridge_write.zig"),
        .target = b.graph.host,
        .optimize = .debug,
        .imports = &.{
            .{ .name = "tls_http", .module = host_tls_http },
            .{ .name = "houselog", .module = host_houselog.module("houselog") },
        },
    });
    const host_translate = b.createModule(.{
        .root_source_file = b.path("src/translate.zig"),
        .target = b.graph.host,
        .optimize = .debug,
        .imports = &.{
            .{ .name = "json_get", .module = host_util.module("json_get") },
            .{ .name = "time", .module = host_util.module("time") },
            .{ .name = "houselog", .module = host_houselog.module("houselog") },
            .{ .name = "capture", .module = host_capture },
            .{ .name = "sse_events", .module = host_sse },
            .{ .name = "resources", .module = host_resources },
            .{ .name = "maps", .module = host_maps },
            .{ .name = "light_ids", .module = host_light_ids },
        },
    });

    const host_cert_issuer = b.createModule(.{
        .root_source_file = b.path("src/cert_issuer.zig"),
        .target = b.graph.host,
        .optimize = .debug,
    });

    for ([_]*std.Build.Module{ host_light_ids, host_bridge_switches, host_bridge_sensors, host_bridge_schedules, host_bridge_dial, host_bridge_info, host_bridge_write, host_resources, host_maps, host_sse, host_cert_issuer, host_tls_http, host_event_stream, host_capture, host_translate }) |mod| {
        const t = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // ------------------------------------------------------------------
    // Check step (ZLS integration)
    // ------------------------------------------------------------------
    const check_step = b.step("check", "Quickly check if everything compiles");
    for ([_]*std.Build.Module{ light_ids, bridge_switches, bridge_sensors, bridge_schedules, bridge_dial, bridge_info, bridge_write, resources, maps, sse_events, cert_issuer, tls_http, event_stream, capture, translate }) |mod| {
        const obj = b.addObject(.{ .name = "hue-check", .root_module = mod });
        check_step.dependOn(&obj.step);
    }
}
