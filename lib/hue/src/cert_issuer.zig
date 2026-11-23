//! Whether a certificate may sign other certificates.
//!
//! std's TLS client checks that each certificate in a chain was signed by the
//! next, and never reads `basicConstraints`. So a device certificate could sign
//! another: anyone holding one Bridge's private key could present "any id, signed
//! by me, signed by the root" and pass. `tools/patch-tls` calls `requireCa` on
//! every certificate that signed the one before it.
//!
//! Its own reader rather than `Certificate.der`: that one indexes past the end of
//! a malformed length, and these bytes come off the network.

const std = @import("std");
const Certificate = std.crypto.Certificate;

/// Named as std's client names a certificate it cannot trust, because `init`
/// has a closed error set and this is the same refusal.
pub fn requireCa(subject: Certificate.Parsed) error{TlsCertificateNotVerified}!void {
    if (!isCa(subject.certificate)) return error.TlsCertificateNotVerified;
}

/// True only when `basicConstraints` is present and says `cA`. RFC 5280 makes
/// that the default of false, and anything unreadable is false too.
pub fn isCa(cert: Certificate) bool {
    const tag_sequence = 0x30;
    const tag_extensions = 0xA3; // [3] EXPLICIT
    const basic_constraints = [_]u8{ 0x55, 0x1D, 0x13 }; // 2.5.29.19

    var outer: Der = .{ .bytes = cert.buffer[cert.index..] };
    var certificate = outer.enter(tag_sequence) orelse return false;
    var tbs = certificate.enter(tag_sequence) orelse return false;

    while (tbs.next()) |field| {
        if (field.tag != tag_extensions) continue;

        var wrapper: Der = .{ .bytes = field.body };
        var extensions = wrapper.enter(tag_sequence) orelse return false;
        while (extensions.enter(tag_sequence)) |ext_const| {
            var ext = ext_const;
            const oid = ext.next() orelse return false;
            if (oid.tag != 0x06) return false;
            if (!std.mem.eql(u8, oid.body, &basic_constraints)) continue;

            // critical BOOLEAN is optional; the value is the OCTET STRING.
            var value = ext.next() orelse return false;
            if (value.tag == 0x01) value = ext.next() orelse return false;
            if (value.tag != 0x04) return false;

            var octets: Der = .{ .bytes = value.body };
            var constraints = octets.enter(tag_sequence) orelse return false;
            const first = constraints.next() orelse return false; // empty: cA defaults false
            return first.tag == 0x01 and first.body.len == 1 and first.body[0] != 0;
        }
        return false;
    }
    return false;
}

/// A bounds-checked walk over DER elements: anything malformed reads as the end.
const Der = struct {
    bytes: []const u8,
    i: usize = 0,

    const Tlv = struct { tag: u8, body: []const u8 };

    fn next(self: *Der) ?Tlv {
        const b = self.bytes;
        if (b.len - self.i < 2) return null;
        const tag = b[self.i];
        const first = b[self.i + 1];
        var at = self.i + 2;

        var len: usize = first;
        if (first & 0x80 != 0) {
            const count = first & 0x7F;
            if (count == 0 or count > 4 or b.len - at < count) return null;
            len = 0;
            for (b[at..][0..count]) |byte| len = len << 8 | byte;
            at += count;
        }
        if (b.len - at < len) return null;
        self.i = at + len;
        return .{ .tag = tag, .body = b[at..][0..len] };
    }

    fn enter(self: *Der, tag: u8) ?Der {
        const element = self.next() orelse return null;
        if (element.tag != tag) return null;
        return .{ .bytes = element.body };
    }
};

const testing = std.testing;

fn fixture(der: []const u8) Certificate {
    return .{ .buffer = der, .index = 0 };
}

test "isCa: reads basicConstraints from real certificates" {
    try testing.expect(isCa(fixture(@embedFile("testdata/intermediate.der"))));

    // Marked CA:FALSE outright.
    try testing.expect(!isCa(fixture(@embedFile("testdata/not-a-ca.der"))));
    // A Bridge's real device certificate: what must not be able to sign.
    try testing.expect(!isCa(fixture(@embedFile("testdata/bridge-leaf.der"))));
    // keyCertSign set, but no basicConstraints: the default is false.
    try testing.expect(!isCa(fixture(@embedFile("testdata/no-constraints.der"))));
}

test "isCa: agrees with the certificate at any index in a buffer" {
    // std's client hands over a record buffer with the certificate partway in.
    const der = @embedFile("testdata/intermediate.der");
    var buf: [der.len + 7]u8 = undefined;
    @memset(buf[0..7], 0xFF);
    @memcpy(buf[7..], der);
    try testing.expect(isCa(.{ .buffer = &buf, .index = 7 }));
}

test "isCa: a truncated certificate is false at every length, and does not panic" {
    const der = @embedFile("testdata/intermediate.der");
    for (0..der.len) |n| try testing.expect(!isCa(fixture(der[0..n])));
}

test "isCa: hostile lengths read as false" {
    // SEQUENCE claiming 4 GiB, a five-byte length, and the indefinite form.
    for ([_][]const u8{
        &.{ 0x30, 0x84, 0xFF, 0xFF, 0xFF, 0xFF },
        &.{ 0x30, 0x85, 0x01, 0x00, 0x00, 0x00, 0x00 },
        &.{ 0x30, 0x80, 0x00, 0x00 },
    }) |der| try testing.expect(!isCa(fixture(der)));
}

test "requireCa: refuses in the error std's client already has" {
    const not_ca = try fixture(@embedFile("testdata/not-a-ca.der")).parse();
    try testing.expectError(error.TlsCertificateNotVerified, requireCa(not_ca));
    try requireCa(try fixture(@embedFile("testdata/intermediate.der")).parse());
}
