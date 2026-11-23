//! CRC-8/SMBUS.
//!
//! Polynomial `0x07`, initial value 0, no reflection, no final XOR. This is a
//! **named** algorithm rather than an invented one, which is why the test
//! checks it against the standard's own check value: verifying it against its
//! own output would prove only that it is stable, not that it is the CRC
//! everyone else means by the name.
//!
//! Bitwise rather than table-driven. A 256-byte table would save roughly 900
//! cycles on a 31-byte frame, at a few frames a second — a fraction of a
//! percent of a core, for a quarter of a kilobyte and a second copy of the
//! polynomial to keep right.

const std = @import("std");

/// Continue a CRC over a further run of bytes.
///
/// **The seeded form is the primitive**, because a frame decoder usually holds
/// its header and its payload in two places, and making them contiguous purely
/// so they can be checksummed together would be the only reason to keep a
/// buffer at all.
pub fn crc8Continue(seed: u8, bytes: []const u8) u8 {
    var crc = seed;
    for (bytes) |b| {
        crc ^= b;
        var bit: u8 = 0;
        while (bit < 8) : (bit += 1) {
            crc = if (crc & 0x80 != 0) (crc << 1) ^ 0x07 else crc << 1;
        }
    }
    return crc;
}

/// CRC over one run of bytes.
pub fn crc8(bytes: []const u8) u8 {
    return crc8Continue(0, bytes);
}

const testing = std.testing;

test "crc8 is the value the standard names" {
    // CRC-8/SMBUS's published check value: the CRC of the ASCII digits
    // "123456789". Checked against the standard, not against this code.
    try testing.expectEqual(@as(u8, 0xF4), crc8("123456789"));
    try testing.expectEqual(@as(u8, 0x00), crc8(""));
}

test "continuing in pieces is the same as doing it at once" {
    // The property the decoder relies on, and the reason the seeded form is
    // public at all.
    const whole = "the quick brown fox";
    for (0..whole.len + 1) |split| {
        const seeded = crc8Continue(crc8(whole[0..split]), whole[split..]);
        try testing.expectEqual(crc8(whole), seeded);
    }
}

test "a seed of zero is the unseeded form" {
    try testing.expectEqual(crc8("abc"), crc8Continue(0, "abc"));
}
