//! Generic deep-ownership helpers, extracted from an earlier Hue monitor (its
//! `deepClone`, `deepFree` and `commitOptionalString`, which live on in
//! `lib/hue`'s `maps.zig` and `resources/common.zig`). They are comptime-recursive mirror images:
//! `deepFree` walks any struct/optional/slice shape freeing every owned
//! slice; `deepClone` walks the same shape duplicating them. Model structs
//! written to the "stage → commit" convention get correct destructors and
//! cloners for free — no hand-written per-struct code.
//!
// What deepFree does NOT replace: the errdefer rollback blocks inside a
// struct's own update functions that free *staged* locals before they are
// committed — those were never part of self's shape, so they stay explicit.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Inspects any value at compile time and performs a deep heap-allocation
/// clone of all slices, strings, and optional fields into the provided
/// allocator. Single-item pointers (e.g. Allocator.ptr/vtable) are copied
/// by value, not followed — they are not owned by the holding struct.
pub fn deepClone(allocator: Allocator, value: anytype) !@TypeOf(value) {
    const T = @TypeOf(value);

    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            var cloned = value;
            inline for (info.field_names) |field_name| {
                const original_field = @field(value, field_name);
                @field(cloned, field_name) = try deepClone(allocator, original_field);
            }
            return cloned;
        },
        .optional => {
            if (value) |payload| {
                return try deepClone(allocator, payload);
            } else {
                return null;
            }
        },
        .pointer => |info| {
            if (info.size == .slice) {
                const cloned_slice = try allocator.alloc(info.child, value.len);
                for (value, 0..) |item, i| {
                    cloned_slice[i] = try deepClone(allocator, item);
                }
                return cloned_slice;
            }
            return value;
        },
        // Primitives, enums, and unowned handles copy directly by value.
        else => return value,
    }
}

/// Mirror image of deepClone: frees every owned slice reachable through
/// struct fields, optionals, and slice elements.
pub fn deepFree(allocator: Allocator, value: anytype) void {
    const T = @TypeOf(value);

    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            inline for (info.field_names) |field_name| {
                deepFree(allocator, @field(value, field_name));
            }
        },
        .optional => {
            if (value) |payload| {
                deepFree(allocator, payload);
            }
        },
        .pointer => |info| {
            if (info.size == .slice) {
                // Free what each element owns before freeing the slice
                // itself. For slices of scalars (e.g. []const u8) the per
                // element call falls through to `else => {}` below.
                for (value) |item| {
                    deepFree(allocator, item);
                }
                allocator.free(value);
            }
            // Single-item pointers are not owned by the holder — leave alone.
        },
        else => {},
    }
}

/// Collapses "free the old value, take ownership of the new one" into one
/// call. Only for the commit phase, after all fallible allocation has
/// already happened — this function itself cannot fail.
pub fn commitOptionalString(gpa: Allocator, current: *?[]const u8, staged: ?[]const u8) void {
    if (staged) |v| {
        if (current.*) |old| gpa.free(old);
        current.* = v;
    }
}

test "deepClone/deepFree round-trip a nested owning struct" {
    const gpa = std.testing.allocator;
    const Inner = struct { name: []const u8, level: ?u8 };
    const Outer = struct { id: []const u8, label: ?[]const u8, members: []const Inner };

    const original: Outer = .{
        .id = "light-1",
        .label = "kitchen",
        .members = &.{ .{ .name = "a", .level = 3 }, .{ .name = "b", .level = null } },
    };

    const cloned = try deepClone(gpa, original);
    defer deepFree(gpa, cloned);

    try std.testing.expectEqualStrings(original.id, cloned.id);
    try std.testing.expectEqualStrings(original.label.?, cloned.label.?);
    try std.testing.expectEqual(@as(usize, 2), cloned.members.len);
    try std.testing.expectEqualStrings("b", cloned.members[1].name);
    // Cloned slices must be distinct allocations, not aliases.
    try std.testing.expect(original.id.ptr != cloned.id.ptr);
    try std.testing.expect(original.members.ptr != cloned.members.ptr);
}

test "commitOptionalString frees old and takes new; null stage is a no-op" {
    const gpa = std.testing.allocator;
    var current: ?[]const u8 = try gpa.dupe(u8, "old");
    defer if (current) |c| gpa.free(c);

    const staged = try gpa.dupe(u8, "new");
    commitOptionalString(gpa, &current, staged);
    try std.testing.expectEqualStrings("new", current.?);

    commitOptionalString(gpa, &current, null);
    try std.testing.expectEqualStrings("new", current.?);
}

test "Semantic Check" {
    std.testing.refAllDecls(@This());
}
