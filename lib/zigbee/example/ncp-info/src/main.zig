//! ncp-info — open the ZBT-2, complete the ASH handshake, and report what the
//! radio is.
//!
//! ```
//! zig build ncp-info                          # this rig's radio
//! zig build ncp-info -- /dev/ttyACM0 460800
//! ```
//!
//! ## What it is for
//!
//! "Is the radio there, and does it talk to us?" — asked without starting
//! `hub`. It exercises the bottom three layers of this package in the order
//! they stack, and each step is a place the answer can be no:
//!
//!   1. **The port opens.** Exclusive (`TIOCEXCL`), so a running `hub` will
//!      make this fail — which is itself the answer to "why won't hub start".
//!   2. **The NCP resets and speaks ASH.** The handshake reports the protocol
//!      version and *why* the chip reset; a power-on code when you expected a
//!      software reset says something yanked the USB.
//!   3. **EZSP negotiates a version.** The first real command, and the one
//!      that must succeed before any other will.
//!
//! Then it reads identity and a few configuration values, all of which are
//! read-only commands.
//!
//! ## What it deliberately does not do
//!
//! **No `networkInit`.** That brings the stack up on the network stored in the
//! NCP's NVM, which is `hub`'s job and changes state this tool has no business
//! changing. The consequence is that node id reads as unjoined and there are no
//! network parameters to report — the price of a tool that is safe to run
//! against production hardware. For the network's own state, ask `hub`.
//!
//! **No forming, joining or leaving**, for the same reason and more so.

const std = @import("std");
const builtin = @import("builtin");
const Link = @import("link").Link;
const Ezsp = @import("ezsp");
const ieee = @import("ieee");

/// This rig's radio, named by its USB serial number rather than by enumeration
/// order — `/dev/ttyACM<n>` is positional, so a replug can renumber it. Same
/// default as `app/house/hub`, deliberately: a tool for diagnosing hub's radio should
/// look where hub looks.
const default_path = switch (builtin.target.os.tag) {
    .linux => "/dev/serial/by-id/usb-Nabu_Casa_ZBT-2_E072A1D9E42C-if00",
    else => "/dev/cu.usbmodemE072A1D9E42C1",
};

const default_baud: u32 = 460_800;

const usage =
    \\ncp-info — report what Zigbee radio is attached, and how it is configured
    \\
    \\usage: ncp-info [device-path] [baud]
    \\
    \\defaults: this rig's ZBT-2, 460800
    \\
    \\Read-only: no networkInit, no form, no join, no leave.
    \\
;

/// The configuration values worth seeing. All reads; `getConfigurationValue`
/// cannot change anything.
const interesting_config = [_]struct { id: u16, name: []const u8 }{
    .{ .id = Ezsp.CONFIG_PACKET_BUFFER_COUNT, .name = "packet buffers" },
    .{ .id = Ezsp.CONFIG_ADDRESS_TABLE_SIZE, .name = "address table" },
    .{ .id = Ezsp.CONFIG_KEY_TABLE_SIZE, .name = "key table" },
    .{ .id = Ezsp.CONFIG_MAX_END_DEVICE_CHILDREN, .name = "max children" },
    .{ .id = Ezsp.CONFIG_STACK_PROFILE, .name = "stack profile" },
    .{ .id = Ezsp.CONFIG_SECURITY_LEVEL, .name = "security level" },
    .{ .id = Ezsp.CONFIG_SUPPORTED_NETWORKS, .name = "supported networks" },
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    var out_buf: [2048]u8 = undefined;
    var fw: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &fw.interface;

    if (args.len > 1 and (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help"))) {
        try out.writeAll(usage);
        try out.flush();
        return;
    }

    const path = if (args.len > 1) args[1] else default_path;
    const baud: u32 = if (args.len > 2) try std.fmt.parseInt(u32, args[2], 10) else default_baud;

    // `Link` must be initialised in place: its ASH transport points into its
    // own reader and writer, so the struct has to be at its final address
    // before `open` wires them together. Returning one by value would leave
    // the transport pointing at the temporary.
    var link: Link = undefined;
    link.open(io, path, baud) catch |err| {
        try out.print("cannot open {s} at {d} baud: {t}\n", .{ path, baud, err });
        try out.print(
            \\
            \\The port is opened exclusively, so the usual cause is that `hub`
            \\already holds it. Otherwise: check the cable, and that the path
            \\names this radio by serial number rather than by ttyACM number.
            \\
        , .{});
        try out.flush();
        return err;
    };
    defer link.close();

    // The reset code says *why* the NCP restarted. `power_on` where a software
    // reset was expected means the device was physically re-enumerated, which
    // is the difference between a wedged stack and a loose cable.
    try out.print("port       {s} at {d} baud\n", .{ path, baud });
    try out.print("ASH        v{d}, NCP reset: {s}{s}\n", .{
        link.hs.version,
        link.hs.reset_code.name(),
        if (link.hs.is_error_frame) "  (ERROR frame, not RSTACK)" else "",
    });

    var client = Ezsp.Client.init(&link.transport);

    // The first EZSP command, and mandatory: the NCP answers nothing else
    // until host and NCP agree a protocol version.
    const version = try client.negotiateVersion();
    try out.print("\n-- NCP -----------------------------------------------\n", .{});
    try out.print("EZSP       protocol v{d}, stack type {d}{s}\n", .{
        version.protocol_version,
        version.stack_type,
        if (version.stack_type == 2) " (mesh / EmberZNet)" else "",
    });
    // Raw first, because the nibble split below is the conventional reading
    // (the one zigpy uses) rather than something this package's own tests pin.
    try out.print("stack      0x{x:0>4} = {d}.{d}.{d}.{d}\n", .{
        version.stack_version,
        version.stack_version >> 12,
        (version.stack_version >> 8) & 0xf,
        (version.stack_version >> 4) & 0xf,
        version.stack_version & 0xf,
    });

    const eui = try client.getEui64();
    try out.writeAll("EUI64      ");
    // Wire order is little-endian; `printReversed` shows it the way every tool
    // and label prints it, MSB first.
    try ieee.printReversed(out, &eui);
    try out.writeByte('\n');

    // Without networkInit the stack is not on a network, so this reads as the
    // unjoined 0xffff. Printed anyway: seeing it is what makes the absence of
    // networkInit legible rather than a silent omission.
    const node_id = try client.getNodeId();
    try out.print("node id    0x{x:0>4}{s}\n", .{
        node_id,
        if (node_id == 0xffff) "  (unjoined — this tool does not run networkInit)" else "",
    });

    try out.print("\n-- configuration -------------------------------------\n", .{});
    for (interesting_config) |cfg| {
        const got = try client.getConfigurationValue(cfg.id);
        if (got.status == Ezsp.EZSP_STATUS_SUCCESS) {
            try out.print("{s:<20} {d}\n", .{ cfg.name, got.value });
        } else {
            // An id this firmware does not implement answers with a status
            // rather than failing the call — worth showing rather than hiding,
            // since it says something about the firmware.
            try out.print("{s:<20} unavailable (status 0x{x:0>2})\n", .{ cfg.name, got.status });
        }
    }

    try out.flush();
}
