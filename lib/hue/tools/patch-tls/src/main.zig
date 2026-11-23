//! patch-tls — teach Zig's TLS client the cipher suite a Hue bridge requires.
//!
//! Run by `lib/hue/build.zig`, never by a person. Reads
//! `std/crypto/tls/Client.zig` out of the *current* Zig installation, applies
//! the diff below, and writes the result somewhere the `tls_client` module can
//! be rooted at. Nothing is vendored into the repository, so the patch always
//! tracks whichever compiler is in use rather than a copy frozen at the moment
//! someone pasted it.
//!
//! ## Why this exists
//!
//! A Philips Hue bridge accepts **exactly one** cipher suite,
//! `ECDHE-ECDSA-AES128-GCM-SHA256` (0xC02B), and no TLS 1.3. Its certificate is
//! ECDSA P-256, signed by Signify's private root `C=NL, O=Philips Hue,
//! CN=root-bridge`.
//!
//! `std.crypto.tls.Client` *defines* that suite in `CipherSuite` but never
//! **offers** it: both `cipher_suites` lists carry only the ECDHE_RSA TLS 1.2
//! suites. The handshake therefore dies with a fatal `handshake_failure` alert
//! before a single byte of HTTP is exchanged.
//!
//! **Everything else needed is already in std** — it advertises
//! `ecdsa_secp256r1_sha256`, verifies P-256 signatures, and
//! `CipherSuite.with()` already maps the ECDSA suites onto the right `With`
//! variant. Only the offer lists and two dispatch switches omit them, which is
//! why this is an edit of three names in four places and not a fork.
//!
//! This is a gap in Zig rather than a Hue quirk: as shipped, std cannot speak
//! TLS 1.2 to *any* server presenting an ECDSA certificate. Worth upstreaming;
//! until it lands and ships, this step carries the project.
//!
//! It also adds one check std lacks: that a certificate which signed another
//! says `cA` in `basicConstraints`. See `src/cert_issuer.zig`.
//!
//! ## When it fails
//!
//! Every edit is anchored to exact text and asserted. If a Zig upgrade moves
//! those lines the build **stops with a diagnostic naming the anchor**, which
//! is the entire point of doing it here: a silently-unapplied security patch
//! would leave a connection that fails at runtime on the server, in the dark, with
//! no clue why.

const std = @import("std");

/// The three suites to add, in `with()`-equivalent order. Each has an
/// ECDHE_RSA counterpart already present in std, and each edit below inserts
/// the ECDSA name immediately before its RSA twin — so the resulting
/// preference order stays exactly std's, with ECDSA preferred at equal
/// strength. That ordering is deliberate: the bridge offers only ECDSA, and
/// every other host we might talk to keeps the behaviour it had.
const suites = [_][]const u8{
    "AES_128_GCM_SHA256",
    "AES_256_GCM_SHA384",
    "CHACHA20_POLY1305_SHA256",
};

/// One anchored text substitution, asserted to apply exactly `count` times.
const Edit = struct {
    what: []const u8,
    needle: []const u8,
    replacement: []const u8,
    count: usize,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);

    var err_buf: [1024]u8 = undefined;
    var ew: std.Io.File.Writer = .init(.stderr(), io, &err_buf);
    const err = &ew.interface;

    if (args.len != 3) {
        try err.print("usage: patch-tls <in:Client.zig> <out:TlsClient.zig>\n", .{});
        try err.flush();
        return error.BadUsage;
    }

    const cwd = std.Io.Dir.cwd();
    const source = cwd.readFileAlloc(io, args[1], gpa, .limited(4 << 20)) catch |e| {
        try err.print("patch-tls: cannot read {s}: {t}\n", .{ args[1], e });
        try err.flush();
        return e;
    };

    var edits: std.ArrayList(Edit) = .empty;

    // Edits 1 and 2: the two `switch (cipher_suite_tag)` prongs that decide
    // which suites the client will actually drive. Anchored on the whole
    // three-line ECDHE_RSA run at its exact indentation, which is what makes
    // the two switches distinguishable from each other and from the offer
    // lists below.
    for ([_]usize{ 28, 32 }) |indent| {
        const pad = try gpa.alloc(u8, indent);
        @memset(pad, ' ');
        var needle: std.ArrayList(u8) = .empty;
        var repl: std.ArrayList(u8) = .empty;
        for (suites) |s| {
            try needle.print(gpa, "{s}.ECDHE_RSA_WITH_{s},\n", .{ pad, s });
            try repl.print(gpa, "{s}.ECDHE_ECDSA_WITH_{s},\n", .{ pad, s });
        }
        try repl.appendSlice(gpa, needle.items);
        try edits.append(gpa, .{
            .what = try gpa.print("cipher_suite_tag switch at indent {d}", .{indent}),
            .needle = needle.items,
            .replacement = repl.items,
            .count = 1,
        });
    }

    // Edit 3: the offer lists themselves — `cipher_suites`, which exists twice,
    // once for CPUs with AES hardware and once without. **Both must be
    // patched**: an armv7 Raspberry Pi takes the `else` branch, so patching
    // only the first would work on this Mac and fail on the target.
    //
    // The leading newline is load-bearing. Without it the 8-space pattern also
    // matches inside the 28- and 32-space switch lines above, and the count
    // assertion fires with 4 instead of 2.
    for (suites) |s| {
        try edits.append(gpa, .{
            .what = try gpa.print("cipher_suites offer lists for {s}", .{s}),
            .needle = try gpa.print("\n        .ECDHE_RSA_WITH_{s},\n", .{s}),
            .replacement = try gpa.print(
                "\n        .ECDHE_ECDSA_WITH_{s},\n        .ECDHE_RSA_WITH_{s},\n",
                .{ s, s },
            ),
            .count = 2,
        });
    }

    // Edit 4: retarget std's internal self-import. Client.zig lives inside the
    // std tree and reaches the root as a relative path; from a generated file
    // it has to go through the normal module graph instead.
    try edits.append(gpa, .{
        .what = "std self-import",
        .needle = "const std = @import(\"../../std.zig\");",
        .replacement = "const std = @import(\"std\");",
        .count = 1,
    });

    // Edit 5: refuse a chain that passes through a certificate not allowed to
    // sign. std verifies each link's signature and never reads basicConstraints,
    // so without this one device's certificate could sign for any other. The
    // check is ordinary tested source; only the call is spliced in.
    try edits.append(gpa, .{
        .what = "intermediate certificate verification",
        .needle = "try prev_cert.verify(subject, now_sec);",
        .replacement = "try @import(\"cert_issuer\").requireCa(subject);\n" ++
            "                                try prev_cert.verify(subject, now_sec);",
        .count = 1,
    });

    var text = source;
    for (edits.items) |e| {
        const found = std.mem.count(u8, text, e.needle);
        if (found != e.count) {
            try err.print(
                \\patch-tls: anchor not found as expected — {s}
                \\  expected {d} occurrence(s), found {d}
                \\  in: {s}
                \\
                \\This almost always means the Zig standard library changed.
                \\Re-derive the patch against the new std/crypto/tls/Client.zig:
                \\the goal is to add ECDHE_ECDSA_WITH_{{AES_128_GCM_SHA256,
                \\AES_256_GCM_SHA384,CHACHA20_POLY1305_SHA256}} to both
                \\`cipher_suites` lists and both `cipher_suite_tag` switches.
                \\See this file's doc comment for why each edit is needed.
                \\
            , .{ e.what, e.count, found, args[1] });
            try err.flush();
            return error.PatchDidNotApply;
        }
        text = try std.mem.replaceOwned(u8, gpa, text, e.needle, e.replacement);
    }

    try cwd.writeFile(io, .{ .sub_path = args[2], .data = text });
}
