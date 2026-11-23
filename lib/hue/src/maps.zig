const std = @import("std");
const Io = std.Io;
const json_get = @import("json_get").json_get;
const Allocator = std.mem.Allocator;
const Resources = @import("resources");
const EventUpdate = Resources.EventUpdate;
const Resource = Resources.Resource;
const ResourceType = Resources.ResourceType;
const RMap = std.StringHashMapUnmanaged(Resource);

/// A repository for fast changing status data.
pub const ResourceRegistry = struct {
    resources: RMap,
    gpa: Allocator,

    pub fn init(gpa: Allocator) ResourceRegistry {
        return .{
            .resources = RMap.empty,
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *ResourceRegistry) void {
        var it = self.resources.iterator();
        while (it.next()) |entry| {
            switch (entry.value_ptr.*) {
                inline else => |*resource| {
                    resource.deinit();
                },
            }
        }
        // 3. Finally, destroy the map container itself
        self.resources.deinit(self.gpa);
    }

    pub fn populate(self: *ResourceRegistry, json_raw: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.gpa, json_raw, .{});
        defer parsed.deinit();

        const data_array = try json_get.Array(parsed.value.object, "data");

        for (data_array.items) |item| {
            const obj = item.object;
            const type_str = try json_get.string(obj, "type");
            const resource = self.dispatch(type_str, obj) catch |err| {
                switch (err) {
                    error.UnknownType => continue,
                    else => return err,
                }
            };
            try self.resources.put(self.gpa, resource.Id(), resource);
        }
    }

    pub fn dispatch(self: *ResourceRegistry, type_str: []const u8, obj: std.json.ObjectMap) !Resource {
        inline for (@typeInfo(Resource).@"union".field_names, @typeInfo(Resource).@"union".field_types) |field_name, field_type| {
            if (std.mem.eql(u8, field_name, type_str)) {
                return @unionInit(Resource, field_name, try field_type.fromJson(self.gpa, obj));
            }
        }
        return error.UnknownType;
    }

    pub fn handleEvent(self: *ResourceRegistry, event: EventUpdate) !bool {
        const resource_ptr = self.resources.getPtr(event.id) orelse return false;
        switch (resource_ptr.*) {
            inline else => |*r| try r.*.applyUpdate(event),
        }
        return true;
    }

    pub fn getTypedResourceList(self: *ResourceRegistry, arena_allocator: std.mem.Allocator, comptime tag: ResourceType) !std.ArrayList(ResourcePayloadType(tag)) {
        // Determine the exact struct target type at compile time (e.g., Temperature)
        const T = ResourcePayloadType(tag);

        var list = std.ArrayList(T).empty;

        var it = self.resources.valueIterator();
        while (it.next()) |resource| {
            // Check if the runtime variant matches our desired tag type
            if (@as(ResourceType, resource.*) == tag) {
                // Unpack the inner payload struct dynamically using @field
                const raw_payload = @field(resource.*, @tagName(tag));

                // Deep clone the payload strings directly into the frame arena
                const cloned_snapshot = try deepClone(arena_allocator, raw_payload);

                try list.append(arena_allocator, cloned_snapshot);
            }
        }

        return list;
    }

    /// Inspects the Resource union at compile time to find the true type associated with a tag.
    fn ResourcePayloadType(comptime tag: ResourceType) type {
        inline for (@typeInfo(Resource).@"union".field_names, @typeInfo(Resource).@"union".field_types) |f_name, f_type| {
            if (std.mem.eql(u8, f_name, @tagName(tag))) return f_type;
        }
        @compileError("Tag name does not match any variant field in the Resource union.");
    }

    /// Inspects any value at compile time and performs a deep heap-allocation clone
    /// of all slices, strings, and optional fields into the provided allocator.
    fn deepClone(allocator: std.mem.Allocator, value: anytype) !@TypeOf(value) {
        const T = @TypeOf(value);

        switch (@typeInfo(T)) {
            // 'struct' is a keyword, so its type tag must be escaped with @"..."
            .@"struct" => |info| {
                var cloned = value;
                // Compile-time unrolled loop over every field in the structure
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
                // Pointer sizes are also lowercase (.one, .many, .slice, .c)
                if (info.size == .slice) {
                    const cloned_slice = try allocator.alloc(info.child, value.len);
                    for (value, 0..) |item, i| {
                        cloned_slice[i] = try deepClone(allocator, item);
                    }
                    return cloned_slice;
                }
                return value;
            },
            // Primitives, Enums, and Allocator handles copy directly by value
            else => return value,
        }
    }
};

test "Semantic Check" {
    std.testing.refAllDecls(@This());
}
