//! Parsing of Hue SSE `data:` payloads into EventUpdates.
//!
//! Pure functions over std.json.Value + an arena. No I/O, no sockets,
//! no filesystem. This is the easiest module to unit test: feed it
//! literal JSON strings, assert on the resulting EventUpdates.
//!
//! Depends on: std, json_get helper, resources.EventUpdate/ResourceType.
//! Nothing else — in particular, no tls_http, no state_store, no Model.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json_get = @import("json_get").json_get;
const Time = @import("time");
const Resources = @import("resources");
const ResourceType = Resources.ResourceType;
const EventUpdate = Resources.EventUpdate;

// ── Public types ──────────────────────────────────────────────

pub const ContainerType = enum {
    update,
    add,
    delete,
    err,

    pub fn fromString(str: []const u8) !ContainerType {
        if (std.meta.stringToEnum(ContainerType, str)) |typ| {
            return typ;
        } else {
            return error.InvalidContainerType;
        }
    }

    pub fn label(self: ContainerType) []const u8 {
        return switch (self) {
            .update => "update",
            .add => "add",
            .delete => "delete",
            .err => "err",
        };
    }
};

pub const Container = struct {
    id: []const u8,
    timestamp: std.Io.Timestamp,
    ctnrType: ContainerType,
    data: std.json.Array,
};

pub const TimestampedArray = struct {
    timestamp: std.Io.Timestamp,
    data: std.json.Array,
};

// ── Public functions ──────────────────────────────────────────

/// Parse the raw SSE message text into a list of Containers.
pub fn parseContainers(arena: Allocator, message: []const u8) !std.ArrayList(Container) {
    var list = std.ArrayList(Container).empty;
    const containerObj = try std.json.parseFromSlice(std.json.Value, arena, message, .{});
    switch (containerObj.value) {
        .array => |c| {
            for (c.items) |cnt| {
                const obj = cnt.object;
                const id = try json_get.string(obj, "id");
                const dt = try json_get.string(obj, "creationtime");
                const timestamp = try Time.ISO2Timestamp(dt);
                const ct = try ContainerType.fromString(try json_get.string(obj, "type"));
                const data = try json_get.Array(obj, "data");
                try list.append(arena, .{
                    .id = id,
                    .timestamp = timestamp,
                    .ctnrType = ct,
                    .data = data,
                });
            }
        },
        else => return error.InvalidJson,
    }
    return list;
}

/// Filter containers down to "update"-type data arrays with timestamps.
pub fn extractUpdateArrays(arena: Allocator, containers: std.ArrayList(Container)) !std.ArrayList(TimestampedArray) {
    var updateDataObjects = std.ArrayList(TimestampedArray).empty;
    for (containers.items) |c| {
        switch (c.ctnrType) {
            .update => {
                try updateDataObjects.append(arena, .{ .data = c.data, .timestamp = c.timestamp });
            },
            else => {},
        }
    }
    return updateDataObjects;
}

/// Flatten timestamped data arrays into concrete EventUpdates.
pub fn buildUpdateEvents(arena: Allocator, arrays: std.ArrayList(TimestampedArray)) !std.ArrayList(EventUpdate) {
    var updateEvents = std.ArrayList(EventUpdate).empty;
    for (arrays.items) |da| {
        for (da.data.items) |item| {
            const obj = item.object;
            if (ResourceType.fromString(try json_get.string(obj, "type"))) |resType| {
                const event = EventUpdate{
                    .id = try json_get.string(obj, "id"),
                    .timestamp = da.timestamp,
                    .updateType = resType,
                    .data = obj,
                };
                try updateEvents.append(arena, event);
            }
        }
    }
    return updateEvents;
}

/// Convenience wrapper: raw SSE message -> EventUpdates in one call.
/// This is what Model.processEvent will call.
pub fn parseMessage(arena: Allocator, message: []const u8) !std.ArrayList(EventUpdate) {
    const containers = try parseContainers(arena, message);
    const arrays = try extractUpdateArrays(arena, containers);
    return buildUpdateEvents(arena, arrays);
}
