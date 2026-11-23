const std = @import("std");

// ZDO (Zigbee Device Objects) request/response frames, verified against
// zigpy's zdo/types.py schemas. ZDO messages are ordinary APS unicasts on
// profile 0x0000, endpoint 0, with the cluster ID selecting the operation
// (responses are request cluster | 0x8000). Every frame starts with a
// 1-byte transaction sequence that the responder echoes back — match on it
// to pair responses with requests. All multi-byte fields little-endian.

pub const PROFILE_ID: u16 = 0x0000;
pub const ENDPOINT: u8 = 0;

pub const CLUSTER_NWK_ADDR_REQ: u16 = 0x0000;
pub const CLUSTER_IEEE_ADDR_REQ: u16 = 0x0001;
pub const CLUSTER_SIMPLE_DESC_REQ: u16 = 0x0004;
pub const CLUSTER_DEVICE_ANNOUNCE: u16 = 0x0013;
pub const CLUSTER_ACTIVE_EP_REQ: u16 = 0x0005;
pub const CLUSTER_BIND_REQ: u16 = 0x0021;
pub const CLUSTER_UNBIND_REQ: u16 = 0x0022;
pub const CLUSTER_MGMT_LEAVE_REQ: u16 = 0x0034;
pub const CLUSTER_NWK_ADDR_RSP: u16 = 0x8000;
pub const CLUSTER_IEEE_ADDR_RSP: u16 = 0x8001;
pub const CLUSTER_SIMPLE_DESC_RSP: u16 = 0x8004;
pub const CLUSTER_ACTIVE_EP_RSP: u16 = 0x8005;
pub const CLUSTER_BIND_RSP: u16 = 0x8021;
pub const CLUSTER_UNBIND_RSP: u16 = 0x8022;
pub const CLUSTER_MGMT_LEAVE_RSP: u16 = 0x8034;

pub const STATUS_SUCCESS: u8 = 0x00;

/// Active_EP_req: asks a device which endpoints it has.
pub fn buildActiveEpReq(zdo_seq: u8, nwk_addr: u16, out: *[3]u8) []const u8 {
    out[0] = zdo_seq;
    out[1] = @truncate(nwk_addr & 0xFF);
    out[2] = @truncate(nwk_addr >> 8);
    return out[0..3];
}

/// Simple_Desc_req: asks a device to describe one endpoint (profile,
/// device type, cluster lists).
pub fn buildSimpleDescReq(zdo_seq: u8, nwk_addr: u16, endpoint: u8, out: *[4]u8) []const u8 {
    out[0] = zdo_seq;
    out[1] = @truncate(nwk_addr & 0xFF);
    out[2] = @truncate(nwk_addr >> 8);
    out[3] = endpoint;
    return out[0..4];
}

/// NWK_addr_req (0x0000): "who currently holds this IEEE?" — sent as a
/// BROADCAST (the whole point is we don't know the nwk address), any node
/// that knows answers with NWK_addr_rsp. RequestType 0x00 = single device
/// response (no associated-device list).
pub fn buildNwkAddrReq(zdo_seq: u8, ieee: [8]u8, out: *[11]u8) []const u8 {
    out[0] = zdo_seq;
    std.mem.copyForwards(u8, out[1..9], &ieee);
    out[9] = 0x00; // RequestType: single device response
    out[10] = 0x00; // StartIndex
    return out[0..11];
}

/// IEEE_addr_req (0x0001): the inverse — unicast to a nwk address we've
/// seen traffic from, asking for its IEEE. Same trailing fields as
/// NWK_addr_req.
pub fn buildIeeeAddrReq(zdo_seq: u8, nwk_addr: u16, out: *[5]u8) []const u8 {
    out[0] = zdo_seq;
    out[1] = @truncate(nwk_addr & 0xFF);
    out[2] = @truncate(nwk_addr >> 8);
    out[3] = 0x00; // RequestType: single device response
    out[4] = 0x00; // StartIndex
    return out[0..5];
}

/// NWK_addr_rsp (0x8000) and IEEE_addr_rsp (0x8001) share one layout:
/// seq + status + IEEEAddrRemoteDev(8) + NWKAddrRemoteDev(u16 LE), then an
/// optional associated-device list we never request (RequestType 0x00).
pub const AddrRsp = struct {
    zdo_seq: u8,
    status: u8,
    ieee: [8]u8, // wire order
    nwk_addr: u16,
};

pub fn parseAddrRsp(payload: []const u8) !AddrRsp {
    if (payload.len < 2) return error.FrameTooShort;
    var rsp: AddrRsp = undefined;
    rsp.zdo_seq = payload[0];
    rsp.status = payload[1];
    if (rsp.status != STATUS_SUCCESS) {
        rsp.ieee = @splat(0);
        rsp.nwk_addr = 0xFFFF;
        return rsp;
    }
    if (payload.len < 12) return error.FrameTooShort;
    std.mem.copyForwards(u8, &rsp.ieee, payload[2..10]);
    rsp.nwk_addr = @as(u16, payload[10]) | (@as(u16, payload[11]) << 8);
    return rsp;
}

/// Bind_req (0x0021): creates a binding-table entry ON THE SOURCE device so
/// it sends its cluster traffic (attribute reports, controller commands
/// like dimmer button presses) to the destination, which may be the
/// coordinator or another device. Without a binding, sensors and
/// controllers send their events nowhere — this is the step ZHA performs at
/// join time that makes devices "just report". Layout per zigpy zdo/types:
/// seq + SrcAddress(EUI64, the device) + SrcEndpoint + ClusterId(u16 LE) +
/// DstAddrMode(0x03 = 64-bit + endpoint) + DstAddress(EUI64) +
/// DstEndpoint. Response Bind_rsp (0x8021) = seq + status.
pub fn buildBindReq(
    zdo_seq: u8,
    src_ieee: [8]u8,
    src_endpoint: u8,
    cluster_id: u16,
    dst_ieee: [8]u8,
    dst_endpoint: u8,
    out: *[22]u8,
) []const u8 {
    out[0] = zdo_seq;
    std.mem.copyForwards(u8, out[1..9], &src_ieee);
    out[9] = src_endpoint;
    out[10] = @truncate(cluster_id & 0xFF);
    out[11] = @truncate(cluster_id >> 8);
    out[12] = 0x03; // DstAddrMode: unicast, 64-bit address + endpoint
    std.mem.copyForwards(u8, out[13..21], &dst_ieee);
    out[21] = dst_endpoint;
    return out[0..22];
}

/// Unbind_req (0x0022) removes the entry Bind_req made. Same fields in the
/// same order (R23.2 Table 2-56 against Table 2-55), so the same bytes; only
/// the cluster differs. Unbind_rsp (0x8022) has Bind_rsp's shape.
pub const buildUnbindReq = buildBindReq;

pub const BindRsp = struct {
    zdo_seq: u8,
    status: u8,
};

pub fn parseBindRsp(payload: []const u8) !BindRsp {
    if (payload.len < 2) return error.FrameTooShort;
    return .{ .zdo_seq = payload[0], .status = payload[1] };
}

/// Mgmt_Leave_req (0x0034): tells a device to leave the network cleanly —
/// the courteous alternative to orphaning it (orphaned Hue devices go
/// dormant and need the Hue-bridge revival ritual; a told-to-leave device
/// resumes scanning for open networks). Layout per zigpy zdo/types: seq +
/// DeviceAddress(EUI64, 8) + options bitmap (bit7 0x80 = rejoin after
/// leaving, bit6 0x40 = also remove children; we send 0x00 — leave for
/// real, keep children). Response Mgmt_Leave_rsp (0x8034) = seq + status,
/// same shape as Bind_rsp (`parseBindRsp` works for both).
pub fn buildMgmtLeaveReq(zdo_seq: u8, device_ieee: [8]u8, out: *[10]u8) []const u8 {
    out[0] = zdo_seq;
    std.mem.copyForwards(u8, out[1..9], &device_ieee);
    out[9] = 0x00; // options: no rejoin, keep children
    return out[0..10];
}

/// Device_annce (0x0013), broadcast by a device after joining, rejoining,
/// OR simply powering back up while already joined — which makes it the
/// way to (re)learn a resumed router's address: no join event fires for a
/// power cycle, but the announce always carries nwk + IEEE.
pub const DeviceAnnounce = struct {
    zdo_seq: u8,
    nwk_addr: u16,
    ieee: [8]u8, // wire order
    capability: u8,
};

pub fn parseDeviceAnnounce(payload: []const u8) !DeviceAnnounce {
    if (payload.len < 12) return error.FrameTooShort;
    var ann: DeviceAnnounce = undefined;
    ann.zdo_seq = payload[0];
    ann.nwk_addr = @as(u16, payload[1]) | (@as(u16, payload[2]) << 8);
    std.mem.copyForwards(u8, &ann.ieee, payload[3..11]);
    ann.capability = payload[11];
    return ann;
}

pub const MAX_ENDPOINTS = 16;
pub const MAX_CLUSTERS = 24;

pub const ActiveEpRsp = struct {
    zdo_seq: u8,
    status: u8,
    nwk_addr: u16,
    endpoint_count: u8,
    endpoints: [MAX_ENDPOINTS]u8,
};

pub fn parseActiveEpRsp(payload: []const u8) !ActiveEpRsp {
    if (payload.len < 5) return error.FrameTooShort;
    var rsp: ActiveEpRsp = undefined;
    rsp.zdo_seq = payload[0];
    rsp.status = payload[1];
    rsp.nwk_addr = @as(u16, payload[2]) | (@as(u16, payload[3]) << 8);
    rsp.endpoint_count = payload[4];
    if (rsp.status != STATUS_SUCCESS) {
        rsp.endpoint_count = 0;
        return rsp;
    }
    if (rsp.endpoint_count > MAX_ENDPOINTS) return error.TooManyEndpoints;
    if (payload.len < 5 + @as(usize, rsp.endpoint_count)) return error.FrameTooShort;
    std.mem.copyForwards(u8, rsp.endpoints[0..rsp.endpoint_count], payload[5 .. 5 + @as(usize, rsp.endpoint_count)]);
    return rsp;
}

pub const SimpleDescriptor = struct {
    endpoint: u8,
    profile_id: u16,
    device_id: u16,
    device_version: u8, // low 4 bits meaningful
    input_cluster_count: u8,
    input_clusters: [MAX_CLUSTERS]u16,
    output_cluster_count: u8,
    output_clusters: [MAX_CLUSTERS]u16,

    pub fn hasInputCluster(self: *const SimpleDescriptor, cluster_id: u16) bool {
        for (self.input_clusters[0..self.input_cluster_count]) |c| {
            if (c == cluster_id) return true;
        }
        return false;
    }

    /// Clusters this endpoint DRIVES rather than serves: a dimmer carries
    /// On/Off and Level as outputs, which is what makes it a controller
    /// (see `engine.zig`'s `.controller` capability). `setupDevice` has
    /// always bound these; nothing ever read them for classification.
    pub fn hasOutputCluster(self: *const SimpleDescriptor, cluster_id: u16) bool {
        for (self.output_clusters[0..self.output_cluster_count]) |c| {
            if (c == cluster_id) return true;
        }
        return false;
    }
};

pub const SimpleDescRsp = struct {
    zdo_seq: u8,
    status: u8,
    nwk_addr: u16,
    descriptor: SimpleDescriptor,
};

pub fn parseSimpleDescRsp(payload: []const u8) !SimpleDescRsp {
    if (payload.len < 5) return error.FrameTooShort;
    var rsp: SimpleDescRsp = undefined;
    rsp.zdo_seq = payload[0];
    rsp.status = payload[1];
    rsp.nwk_addr = @as(u16, payload[2]) | (@as(u16, payload[3]) << 8);
    if (rsp.status != STATUS_SUCCESS) return rsp;

    // payload[4] is the descriptor length; the descriptor follows.
    const desc_len: usize = payload[4];
    if (payload.len < 5 + desc_len or desc_len < 8) return error.FrameTooShort;
    const d = payload[5 .. 5 + desc_len];

    var desc: SimpleDescriptor = undefined;
    desc.endpoint = d[0];
    desc.profile_id = @as(u16, d[1]) | (@as(u16, d[2]) << 8);
    desc.device_id = @as(u16, d[3]) | (@as(u16, d[4]) << 8);
    desc.device_version = d[5] & 0x0F;

    desc.input_cluster_count = d[6];
    if (desc.input_cluster_count > MAX_CLUSTERS) return error.TooManyClusters;
    var idx: usize = 7;
    if (d.len < idx + 2 * @as(usize, desc.input_cluster_count) + 1) return error.FrameTooShort;
    for (0..desc.input_cluster_count) |i| {
        desc.input_clusters[i] = @as(u16, d[idx]) | (@as(u16, d[idx + 1]) << 8);
        idx += 2;
    }

    desc.output_cluster_count = d[idx];
    idx += 1;
    if (desc.output_cluster_count > MAX_CLUSTERS) return error.TooManyClusters;
    if (d.len < idx + 2 * @as(usize, desc.output_cluster_count)) return error.FrameTooShort;
    for (0..desc.output_cluster_count) |i| {
        desc.output_clusters[i] = @as(u16, d[idx]) | (@as(u16, d[idx + 1]) << 8);
        idx += 2;
    }

    rsp.descriptor = desc;
    return rsp;
}

test "parseDeviceAnnounce decodes nwk + ieee + capability" {
    const payload = [_]u8{ 0x81, 0x14, 0xD7, 0xdd, 0x40, 0xd1, 0x08, 0x01, 0x88, 0x17, 0x00, 0x8E };
    const ann = try parseDeviceAnnounce(&payload);
    try std.testing.expectEqual(@as(u16, 0xD714), ann.nwk_addr);
    try std.testing.expectEqualSlices(u8, &.{ 0xdd, 0x40, 0xd1, 0x08, 0x01, 0x88, 0x17, 0x00 }, &ann.ieee);
    try std.testing.expectEqual(@as(u8, 0x8E), ann.capability);
}

test "buildNwkAddrReq / buildIeeeAddrReq byte layouts" {
    var buf11: [11]u8 = undefined;
    const ieee = [8]u8{ 0xdd, 0x40, 0xd1, 0x08, 0x01, 0x88, 0x17, 0x00 };
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x5A, 0xdd, 0x40, 0xd1, 0x08, 0x01, 0x88, 0x17, 0x00, 0x00, 0x00 },
        buildNwkAddrReq(0x5A, ieee, &buf11),
    );

    var buf5: [5]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{ 0x5B, 0x4E, 0x65, 0x00, 0x00 }, buildIeeeAddrReq(0x5B, 0x654E, &buf5));
}

test "parseAddrRsp decodes success and failure responses" {
    const ok = [_]u8{ 0x5A, 0x00, 0xdd, 0x40, 0xd1, 0x08, 0x01, 0x88, 0x17, 0x00, 0x14, 0xD7 };
    const rsp = try parseAddrRsp(&ok);
    try std.testing.expectEqual(@as(u8, 0x5A), rsp.zdo_seq);
    try std.testing.expectEqual(@as(u8, 0x00), rsp.status);
    try std.testing.expectEqualSlices(u8, &.{ 0xdd, 0x40, 0xd1, 0x08, 0x01, 0x88, 0x17, 0x00 }, &rsp.ieee);
    try std.testing.expectEqual(@as(u16, 0xD714), rsp.nwk_addr);

    // 0x81 = DEVICE_NOT_FOUND: short frame is legal, no address fields
    const not_found = [_]u8{ 0x5A, 0x81 };
    const nf = try parseAddrRsp(&not_found);
    try std.testing.expectEqual(@as(u8, 0x81), nf.status);
}

test "buildActiveEpReq / buildSimpleDescReq byte layouts" {
    var buf3: [3]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{ 0x2A, 0x4E, 0x65 }, buildActiveEpReq(0x2A, 0x654E, &buf3));

    var buf4: [4]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{ 0x2B, 0x4E, 0x65, 0x0B }, buildSimpleDescReq(0x2B, 0x654E, 0x0B, &buf4));
}

test "buildBindReq byte layout" {
    var buf: [22]u8 = undefined;
    const src = [8]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const dst = [8]u8{ 9, 10, 11, 12, 13, 14, 15, 16 };
    try std.testing.expectEqualSlices(u8, &.{
        0x77, // seq
        1, 2, 3, 4, 5, 6, 7, 8, // src IEEE
        0x02, // src endpoint
        0x00, 0xFC, // cluster 0xFC00
        0x03, // dst addr mode
        9, 10, 11, 12, 13, 14, 15, 16, // dst IEEE
        0x01, // dst endpoint
    }, buildBindReq(0x77, src, 0x02, 0xFC00, dst, 0x01, &buf));
}

test "Unbind_req sends the same bytes as Bind_req on its own cluster" {
    const src = [8]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const dst = [8]u8{ 9, 10, 11, 12, 13, 14, 15, 16 };
    var bind_buf: [22]u8 = undefined;
    var unbind_buf: [22]u8 = undefined;
    try std.testing.expectEqualSlices(
        u8,
        buildBindReq(0x42, src, 0x01, 0x0006, dst, 0x0B, &bind_buf),
        buildUnbindReq(0x42, src, 0x01, 0x0006, dst, 0x0B, &unbind_buf),
    );
    try std.testing.expectEqual(@as(u16, 0x0022), CLUSTER_UNBIND_REQ);
    try std.testing.expectEqual(CLUSTER_UNBIND_REQ | 0x8000, CLUSTER_UNBIND_RSP);
}

test "parseBindRsp decodes seq + status" {
    const rsp = try parseBindRsp(&.{ 0x77, 0x00 });
    try std.testing.expectEqual(@as(u8, 0x77), rsp.zdo_seq);
    try std.testing.expectEqual(@as(u8, 0x00), rsp.status);
}

test "buildMgmtLeaveReq byte layout" {
    var buf: [10]u8 = undefined;
    const ieee = [8]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x78, 1, 2, 3, 4, 5, 6, 7, 8, 0x00 },
        buildMgmtLeaveReq(0x78, ieee, &buf),
    );
}

test "parseActiveEpRsp decodes a two-endpoint response" {
    const payload = [_]u8{ 0x2A, 0x00, 0x4E, 0x65, 0x02, 0x0B, 0xF2 };
    const rsp = try parseActiveEpRsp(&payload);
    try std.testing.expectEqual(@as(u8, 0x2A), rsp.zdo_seq);
    try std.testing.expectEqual(@as(u8, 0x00), rsp.status);
    try std.testing.expectEqual(@as(u16, 0x654E), rsp.nwk_addr);
    try std.testing.expectEqualSlices(u8, &.{ 0x0B, 0xF2 }, rsp.endpoints[0..rsp.endpoint_count]);
}

test "parseSimpleDescRsp decodes a Hue-bulb-shaped descriptor" {
    // Endpoint 11, profile 0x0104 (HA), device 0x010D (extended color light),
    // inputs Basic/OnOff/Level/Touchlink, outputs OTA.
    const payload = [_]u8{
        0x2B, 0x00, 0x4E, 0x65, // seq, status, nwk
        0x12, // descriptor length (18)
        0x0B, // endpoint
        0x04, 0x01, // profile 0x0104
        0x0D, 0x01, // device 0x010D
        0x02, // version
        0x04, // input count
        0x00, 0x00, 0x06, 0x00, 0x08, 0x00, 0x00, 0x10, // Basic, OnOff, Level, Touchlink
        0x01, // output count
        0x19, 0x00, // OTA
    };
    const rsp = try parseSimpleDescRsp(&payload);
    try std.testing.expectEqual(@as(u8, 0x00), rsp.status);
    try std.testing.expectEqual(@as(u8, 0x0B), rsp.descriptor.endpoint);
    try std.testing.expectEqual(@as(u16, 0x0104), rsp.descriptor.profile_id);
    try std.testing.expectEqual(@as(u16, 0x010D), rsp.descriptor.device_id);
    try std.testing.expectEqual(@as(u8, 4), rsp.descriptor.input_cluster_count);
    try std.testing.expect(rsp.descriptor.hasInputCluster(0x0006));
    try std.testing.expect(!rsp.descriptor.hasInputCluster(0x0300));
    try std.testing.expectEqual(@as(u16, 0x0019), rsp.descriptor.output_clusters[0]);
}

test "parseSimpleDescRsp returns non-success status without parsing descriptor" {
    const payload = [_]u8{ 0x2B, 0x81, 0x4E, 0x65, 0x00 }; // 0x81 = ZDO INVALID_EP
    const rsp = try parseSimpleDescRsp(&payload);
    try std.testing.expectEqual(@as(u8, 0x81), rsp.status);
}
