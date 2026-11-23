const std = @import("std");
/// ---------------------------------------------------------------------------
/// JSON field extraction helpers
/// ---------------------------------------------------------------------------
/// A namespace of typed accessor functions for std.json.ObjectMap.
/// Functions without an `Or` suffix return an error when the field is absent
/// or has the wrong JSON type.  The `*Or` variants return a caller-supplied
// default instead, and `optional*` variants return a Zig optional.
pub const json_get = struct {
    pub fn string(obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
        const val = obj.get(key) orelse return error.MissingField;
        return switch (val) {
            .string => |s| s,
            else => error.WrongType,
        };
    }

    pub fn stringOr(obj: std.json.ObjectMap, key: []const u8, default: []const u8) []const u8 {
        const val = obj.get(key) orelse return default;
        return switch (val) {
            .string => |s| s,
            else => default,
        };
    }

    pub fn boolean(obj: std.json.ObjectMap, key: []const u8) !bool {
        const val = obj.get(key) orelse return error.MissingField;
        return switch (val) {
            .bool => |b| b,
            else => error.WrongType,
        };
    }

    pub fn int(obj: std.json.ObjectMap, key: []const u8) !i64 {
        const val = obj.get(key) orelse return error.MissingField;
        return switch (val) {
            .integer => |i| i,
            else => error.WrongType,
        };
    }

    pub fn intOr(obj: std.json.ObjectMap, key: []const u8, default: i64) i64 {
        const val = obj.get(key) orelse return default;
        return switch (val) {
            .integer => |i| i,
            else => default,
        };
    }

    pub fn boolOr(obj: std.json.ObjectMap, key: []const u8, default: bool) bool {
        const val = obj.get(key) orelse return default;
        return switch (val) {
            .bool => |i| i,
            else => default,
        };
    }

    pub fn optionalInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
        const val = obj.get(key) orelse return null;
        return switch (val) {
            .integer => |i| i,
            else => null,
        };
    }

    // Accepts both .float and .integer so callers never have to special-case
    // JSON integers that appear in float-typed fields.
    pub fn floatOr(obj: std.json.ObjectMap, key: []const u8, default: f64) f64 {
        const val = obj.get(key) orelse return default;
        return switch (val) {
            .float => |f| f,
            .integer => |i| @as(f64, @floatFromInt(i)),
            else => default,
        };
    }

    pub fn object(obj: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
        const val = obj.get(key) orelse return error.MissingField;
        return switch (val) {
            .object => |o| o,
            else => error.WrongType,
        };
    }

    // Returns null when the key is absent or not a boolean.
    pub fn optionalBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
        const val = obj.get(key) orelse return null;
        return switch (val) {
            .bool => |b| b,
            else => null,
        };
    }

    // Returns null when the key is absent or not a number.
    // Accepts both .float and .integer (same rule as floatOr).
    pub fn optionalFloat(obj: std.json.ObjectMap, key: []const u8) ?f64 {
        const val = obj.get(key) orelse return null;
        return switch (val) {
            .float => |f| f,
            .integer => |i| @as(f64, @floatFromInt(i)),
            else => null,
        };
    }

    // Returns null when the key is absent or not a string.
    pub fn optionalString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
        const val = obj.get(key) orelse return null;
        return switch (val) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn Array(obj: std.json.ObjectMap, key: []const u8) !std.json.Array {
        const val = obj.get(key) orelse return error.MissingField;
        return switch (val) {
            .array => |s| s,
            else => error.WrongType,
        };
    }

    // Returns null when the key is absent or not a string.
    pub fn optionalArray(obj: std.json.ObjectMap, key: []const u8) ?std.json.Array {
        const val = obj.get(key) orelse return null;
        return switch (val) {
            .array => |s| s,
            else => null,
        };
    }

    pub fn optionalObject(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
        const val = obj.get(key) orelse return null;
        return switch (val) {
            .object => |o| o,
            else => null,
        };
    }
};

test "Force Semantic Check" {
    // This built-in function forces the compiler to look at
    // EVERY single struct, function, and variable in this file,
    // completely bypassing lazy analysis during 'zig build test'.
    std.testing.refAllDecls(@This());
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
//
// **The tolerance is the whole product here**, and until these existed nothing
// asserted it: the only test in this file was a `refAllDecls`, which proves the
// code compiles and nothing about what it does. Every accessor has three
// behaviours — present and right, present and wrong-typed, absent — and the
// difference between the three families is precisely how each reacts to the
// last two. That is what is pinned below.

const testing = std.testing;

/// One fixture covering every JSON type these accessors switch on, including a
/// deliberately wrong-typed field for each family to be asked for.
const fixture =
    \\{
    \\  "name": "hub",
    \\  "count": 42,
    \\  "ratio": 0.5,
    \\  "enabled": true,
    \\  "nested": {"inner": 1},
    \\  "list": [1, 2, 3],
    \\  "nothing": null
    \\}
;

fn withFixture(comptime check: fn (std.json.ObjectMap) anyerror!void) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        fixture,
        .{},
    );
    try check(parsed.object);
}

test "json_get: the strict accessors distinguish absent from wrong-typed" {
    try withFixture(struct {
        fn f(obj: std.json.ObjectMap) !void {
            try testing.expectEqualStrings("hub", try json_get.string(obj, "name"));
            try testing.expectEqual(@as(i64, 42), try json_get.int(obj, "count"));
            try testing.expect(try json_get.boolean(obj, "enabled"));
            try testing.expectEqual(@as(usize, 1), (try json_get.object(obj, "nested")).count());
            try testing.expectEqual(@as(usize, 3), (try json_get.Array(obj, "list")).items.len);

            // Absent and wrong-typed are different errors on purpose: one means
            // the config omitted a field, the other means it got it wrong, and
            // a caller may well want to treat them differently.
            try testing.expectError(error.MissingField, json_get.string(obj, "absent"));
            try testing.expectError(error.MissingField, json_get.int(obj, "absent"));
            try testing.expectError(error.WrongType, json_get.string(obj, "count"));
            try testing.expectError(error.WrongType, json_get.int(obj, "name"));
            try testing.expectError(error.WrongType, json_get.boolean(obj, "count"));
            try testing.expectError(error.WrongType, json_get.object(obj, "list"));
            try testing.expectError(error.WrongType, json_get.Array(obj, "nested"));

            // JSON null is a value, not an absence — so it is a type error, not
            // a missing field. Worth pinning: the two are easy to conflate and
            // a caller checking only for MissingField would miss it.
            try testing.expectError(error.WrongType, json_get.string(obj, "nothing"));
        }
    }.f);
}

test "json_get: the Or accessors fall back on absent AND on wrong-typed" {
    try withFixture(struct {
        fn f(obj: std.json.ObjectMap) !void {
            try testing.expectEqualStrings("hub", json_get.stringOr(obj, "name", "fallback"));
            try testing.expectEqual(@as(i64, 42), json_get.intOr(obj, "count", 7));
            try testing.expect(json_get.boolOr(obj, "enabled", false));

            // Absent.
            try testing.expectEqualStrings("fallback", json_get.stringOr(obj, "absent", "fallback"));
            try testing.expectEqual(@as(i64, 7), json_get.intOr(obj, "absent", 7));
            try testing.expectEqual(false, json_get.boolOr(obj, "absent", false));

            // Present but the wrong type — the same fallback, and this is the
            // half that makes these "tolerant" rather than merely "defaulted".
            try testing.expectEqualStrings("fallback", json_get.stringOr(obj, "count", "fallback"));
            try testing.expectEqual(@as(i64, 7), json_get.intOr(obj, "name", 7));
            try testing.expectEqual(true, json_get.boolOr(obj, "name", true));
        }
    }.f);
}

test "json_get: the optional accessors return null for both failures" {
    try withFixture(struct {
        fn f(obj: std.json.ObjectMap) !void {
            try testing.expectEqual(@as(?i64, 42), json_get.optionalInt(obj, "count"));
            try testing.expectEqual(@as(?bool, true), json_get.optionalBool(obj, "enabled"));
            try testing.expectEqualStrings("hub", json_get.optionalString(obj, "name").?);
            try testing.expectEqual(@as(usize, 3), json_get.optionalArray(obj, "list").?.items.len);
            try testing.expectEqual(@as(usize, 1), json_get.optionalObject(obj, "nested").?.count());

            try testing.expectEqual(@as(?i64, null), json_get.optionalInt(obj, "absent"));
            try testing.expectEqual(@as(?i64, null), json_get.optionalInt(obj, "name"));
            try testing.expectEqual(@as(?bool, null), json_get.optionalBool(obj, "count"));
            try testing.expectEqual(@as(?[]const u8, null), json_get.optionalString(obj, "count"));
            try testing.expect(json_get.optionalArray(obj, "nested") == null);
            try testing.expect(json_get.optionalObject(obj, "list") == null);
        }
    }.f);
}

test "json_get: the float accessors accept a JSON integer" {
    // The one asymmetry in this file, and the reason it exists: JSON has no
    // float/int distinction a config author can see, so `"ratio": 1` and
    // `"ratio": 1.0` must mean the same thing. Without this, a value that
    // happened to land on a round number would silently take the default.
    try withFixture(struct {
        fn f(obj: std.json.ObjectMap) !void {
            try testing.expectEqual(@as(f64, 0.5), json_get.floatOr(obj, "ratio", 9.9));
            try testing.expectEqual(@as(f64, 42.0), json_get.floatOr(obj, "count", 9.9));
            try testing.expectEqual(@as(?f64, 42.0), json_get.optionalFloat(obj, "count"));

            try testing.expectEqual(@as(f64, 9.9), json_get.floatOr(obj, "absent", 9.9));
            try testing.expectEqual(@as(f64, 9.9), json_get.floatOr(obj, "name", 9.9));
            try testing.expectEqual(@as(?f64, null), json_get.optionalFloat(obj, "name"));
        }
    }.f);
}
