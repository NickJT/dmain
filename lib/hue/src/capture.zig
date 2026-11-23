//! The raw capture: what a Hue bridge said, verbatim, one JSON object a line.
//!
//!   {"v":1,"src":"hue-bridge","t":"2026-11-04T09:20:04.067Z","kind":"message","data":[…]}
//!
//! **Evidence, not the record.** The house log is the record, in a vocabulary
//! of its own; this file exists so the house log can be regenerated when its
//! translation was wrong, or a field nobody thought to keep can be filled in
//! for past days. It is CLIP v2 through and through, and it goes when the
//! bridge does.
//!
//! **The envelope is fixed and `data` is always last.** A reader recovers the
//! bridge's bytes by position — `registry.populate` wants the resource list as
//! text, and re-serialising a parsed tree would stop it being what the bridge
//! said. A line from a writer that broke the order is rejected, not guessed at.
//!
//! | kind | data | note |
//! |---|---|---|
//! | `start` | — | the capturing process started |
//! | `resources` | `/clip/v2/resource`, whole | every (re)connect |
//! | `up` | — | the event stream answered |
//! | `message` | one SSE message's JSON | |
//! | `unparseable` | — | the bridge's text, which was not a message (as `note`) |
//! | `down` | — | the stream ended (the reason as `note`) |
//! | `heartbeat` | — | the process is alive, whatever the bridge is doing |

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const time = @import("time");

pub const version = 1;
pub const source = "hue-bridge";

pub const Kind = enum { start, resources, up, message, unparseable, down, heartbeat };

/// One capture line, newline included.
///
/// `data` is written verbatim apart from CR and LF, which become spaces: JSON
/// cannot carry a raw newline inside a string, so outside one it is only
/// whitespace, and a line must stay a line. `note` is escaped as a JSON string.
pub fn write(w: *Io.Writer, at: Io.Timestamp, kind: Kind, note: ?[]const u8, data: ?[]const u8) !void {
    try w.print("{{\"v\":{d},\"src\":\"{s}\",\"t\":\"", .{ version, source });
    try time.formatIsoUtcMillis(at, w);
    try w.print("\",\"kind\":\"{t}\"", .{kind});
    if (note) |n| {
        try w.writeAll(",\"note\":");
        try std.json.Stringify.value(n, .{}, w);
    }
    if (data) |d| {
        try w.writeAll(",\"data\":");
        for (d) |ch| try w.writeByte(if (ch == '\n' or ch == '\r') ' ' else ch);
    }
    try w.writeAll("}\n");
}

pub const Record = struct {
    at: Io.Timestamp,
    kind: Kind,
    note: ?[]const u8 = null,
    /// The bridge's bytes, exactly as captured.
    data: ?[]const u8 = null,
};

const Head = struct {
    v: u32,
    src: []const u8,
    t: []const u8,
    kind: []const u8,
    note: ?[]const u8 = null,
};

/// Parse one line (without its newline). Strings in the result point into
/// `line` or into `arena`.
pub fn parse(arena: Allocator, line: []const u8) !Record {
    const marker = ",\"data\":";
    const cut = std.mem.indexOf(u8, line, marker);
    const head_text = if (cut) |c| try std.mem.concat(arena, u8, &.{ line[0..c], "}" }) else line;
    const head = std.json.parseFromSliceLeaky(Head, arena, head_text, .{}) catch return error.BadCapture;
    if (head.v != version) return error.UnknownVersion;

    var data: ?[]const u8 = null;
    if (cut) |c| {
        const rest = std.mem.trimEnd(u8, line[c + marker.len ..], " \r");
        if (rest.len == 0 or rest[rest.len - 1] != '}') return error.BadCapture;
        data = rest[0 .. rest.len - 1];
    }
    return .{
        .at = time.ISO2Timestamp(head.t) catch return error.BadCapture,
        .kind = std.meta.stringToEnum(Kind, head.kind) orelse return error.BadCapture,
        .note = head.note,
        .data = data,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "write then parse gives the bridge's bytes back" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [512]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    const at = try time.ISO2Timestamp("2026-11-04T09:20:04.067Z");

    try write(&w, at, .message, null, "[{\"id\":\"x\",\n\"data\":[{\"a\":\"}\"}]}]");
    const line = w.buffered();
    try testing.expectEqualStrings(
        "{\"v\":1,\"src\":\"hue-bridge\",\"t\":\"2026-11-04T09:20:04.067Z\",\"kind\":\"message\",\"data\":[{\"id\":\"x\", \"data\":[{\"a\":\"}\"}]}]}\n",
        line,
    );
    const r = try parse(arena.allocator(), line[0 .. line.len - 1]);
    try testing.expectEqual(Kind.message, r.kind);
    try testing.expectEqual(at.toMilliseconds(), r.at.toMilliseconds());
    // The embedded `"data":` inside the payload does not confuse the reader:
    // it splits at the first, which is the envelope's.
    try testing.expectEqualStrings("[{\"id\":\"x\", \"data\":[{\"a\":\"}\"}]}]", r.data.?);
}

test "a note is escaped, and a record without data parses" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [256]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    try write(&w, try time.ISO2Timestamp("2026-11-04T00:00:00Z"), .down, "said \"no\"", null);
    const line = w.buffered();
    const r = try parse(arena.allocator(), line[0 .. line.len - 1]);
    try testing.expectEqual(Kind.down, r.kind);
    try testing.expectEqualStrings("said \"no\"", r.note.?);
    try testing.expectEqual(@as(?[]const u8, null), r.data);
}

test "a line from another version or a broken one is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.UnknownVersion, parse(a, "{\"v\":2,\"src\":\"hue-bridge\",\"t\":\"2026-11-04T00:00:00Z\",\"kind\":\"up\"}"));
    try testing.expectError(error.BadCapture, parse(a, "{\"v\":1,\"src\":\"hue-bridge\",\"t\":\"2026-11-04T00:00:00Z\",\"kind\":\"message\",\"data\":[1,2"));
    try testing.expectError(error.BadCapture, parse(a, "not json"));
}
