const std = @import("std");

// Minimal ZCL (Zigbee Cluster Library) framing — outbound cluster-specific
// commands (On/Off), plus decoding of the frames devices send US: Default
// Responses (delivery confirmation), attribute reports (sensor readings),
// cluster commands from controllers (dimmer buttons), and Philips'
// manufacturer-specific button notifications. Verified against zigpy's
// zcl/foundation.py and zigbee-herdsman's cluster definitions.

pub const PROFILE_HA: u16 = 0x0104;
/// ZigBee Light Link — some older Hue hardware (pre-HA-profile-compliance
/// generations, e.g. the original LCT001-era bulbs) advertises its main
/// application endpoint under this profile instead of PROFILE_HA, even
/// though it speaks the same clusters (On/Off, Level, etc.) the same way.
/// `engine.zig`'s `setupDevice` accepts either profile for exactly this
/// reason — a device's *clusters* are what matter, not which of these two
/// profile IDs it happened to register under.
pub const PROFILE_ZLL: u16 = 0xC05E;
pub const CLUSTER_POWER_CONFIG: u16 = 0x0001;
pub const CLUSTER_IDENTIFY: u16 = 0x0003;
pub const CLUSTER_ON_OFF: u16 = 0x0006;
pub const CLUSTER_BASIC: u16 = 0x0000;
pub const CLUSTER_LEVEL_CONTROL: u16 = 0x0008;
pub const CLUSTER_ILLUMINANCE: u16 = 0x0400;
pub const CLUSTER_TEMPERATURE: u16 = 0x0402;
/// Relative Humidity Measurement (ZCL 4.7): `MeasuredValue` is 100 × percent,
/// a `uint16`, and 0xFFFF means unknown.
pub const CLUSTER_HUMIDITY: u16 = 0x0405;
pub const HUMIDITY_UNKNOWN: u16 = 0xFFFF;
pub const CLUSTER_OCCUPANCY: u16 = 0x0406;
/// Color Control — full-colour and colour-temperature lamps. A white-only or non-colour device simply doesn't implement
/// it, and ignores a cluster-specific command for a cluster it doesn't
/// have (ZCL's own rule), which is why a rule colour on a plain socket is
/// harmless rather than needing a guard everywhere.
pub const CLUSTER_COLOR_CONTROL: u16 = 0x0300;
/// IAS Zone — the security-sensor cluster (contact/motion/smoke/water-leak
/// sensors), distinct from CLUSTER_OCCUPANCY (0x0406) which Hue motion uses.
pub const CLUSTER_IAS_ZONE: u16 = 0x0500;
/// Philips manufacturer-specific cluster carrying Hue dimmer/Tap button
/// notifications (manufacturer code 0x100B).
pub const CLUSTER_PHILIPS_BUTTON: u16 = 0xFC00;

/// IAS Zone cluster-specific commands, server→client (device→us) — a
/// sensor is the "server" holding zone status; we (the CIE/coordinator)
/// are the "client". Zone Status Change Notification is sent whenever the
/// alarm/tamper/battery bits change (and, empirically, sometimes resent
/// while a trigger condition persists).
pub const IAS_CMD_ZONE_STATUS_CHANGE_NOTIFICATION: u8 = 0x00;
pub const IAS_CMD_ZONE_ENROLL_REQUEST: u8 = 0x01;
/// IAS Zone command in the OTHER direction — client→server (us→device):
/// the coordinator's reply to a Zone Enroll Request, granting enrollment.
/// Same numeric id (0x00) as the server→client Status Change Notification
/// — ZCL command-id spaces are per-direction (see the Groups cluster note),
/// distinguished by the frame-control direction bit, not the number.
pub const IAS_CMD_ZONE_ENROLL_RESPONSE: u8 = 0x00;
/// IAS Zone attribute holding the CIE (coordinator) EUI64 the sensor sends
/// its notifications to. A factory-fresh sensor won't report until this is
/// written — the enrollment step hub was missing.
pub const ATTR_IAS_CIE_ADDRESS: u16 = 0x0010;
/// ZCL data type for an 8-byte IEEE address attribute value.
pub const TYPE_IEEE_ADDRESS: u8 = 0xF0;

pub const ONOFF_CMD_OFF: u8 = 0x00;
pub const ONOFF_CMD_ON: u8 = 0x01;
pub const ONOFF_CMD_TOGGLE: u8 = 0x02;
/// On/Off extended commands, seen live from Hue devices: the dimmer's off
/// button sends Off With Effect; the motion sensor drives lights with
/// On With Timed Off (occupancy auto-off).
pub const ONOFF_CMD_OFF_WITH_EFFECT: u8 = 0x40;
pub const ONOFF_CMD_ON_WITH_RECALL_GLOBAL_SCENE: u8 = 0x41;
pub const ONOFF_CMD_ON_WITH_TIMED_OFF: u8 = 0x42;

/// Off With Effect payload: effect id (0 = delayed all off, 1 = dying
/// light) + effect variant.
pub const OffWithEffect = struct { effect_id: u8, effect_variant: u8 };

pub fn parseOffWithEffect(payload: []const u8) ?OffWithEffect {
    if (payload.len < 2) return null;
    return .{ .effect_id = payload[0], .effect_variant = payload[1] };
}

/// On With Timed Off payload: control bitmap (bit0 = only act when
/// already on) + on time + off wait time, both in tenths of a second.
pub const OnWithTimedOff = struct { control: u8, on_time_tenths: u16, off_wait_tenths: u16 };

pub fn parseOnWithTimedOff(payload: []const u8) ?OnWithTimedOff {
    if (payload.len < 5) return null;
    return .{
        .control = payload[0],
        .on_time_tenths = @as(u16, payload[1]) | (@as(u16, payload[2]) << 8),
        .off_wait_tenths = @as(u16, payload[3]) | (@as(u16, payload[4]) << 8),
    };
}

pub const LEVEL_CMD_MOVE_TO_LEVEL: u8 = 0x00;
pub const LEVEL_CMD_MOVE: u8 = 0x01;
pub const LEVEL_CMD_STEP: u8 = 0x02;
pub const LEVEL_CMD_STOP: u8 = 0x03;
pub const LEVEL_CMD_MOVE_TO_LEVEL_WITH_ONOFF: u8 = 0x04;
pub const LEVEL_CMD_MOVE_WITH_ONOFF: u8 = 0x05;
pub const LEVEL_CMD_STEP_WITH_ONOFF: u8 = 0x06;
pub const LEVEL_CMD_STOP_WITH_ONOFF: u8 = 0x07;

/// ZCL global command ids (frame type 00).
pub const CMD_READ_ATTRIBUTES: u8 = 0x00;
pub const CMD_READ_ATTRIBUTES_RSP: u8 = 0x01;
pub const CMD_WRITE_ATTRIBUTES: u8 = 0x02;
pub const CMD_WRITE_ATTRIBUTES_RSP: u8 = 0x04;
pub const CMD_CONFIGURE_REPORTING: u8 = 0x06;
pub const CMD_CONFIGURE_REPORTING_RSP: u8 = 0x07;
pub const CMD_REPORT_ATTRIBUTES: u8 = 0x0A;
pub const CMD_DEFAULT_RESPONSE: u8 = 0x0B;

/// Builds a cluster-specific, client→server ZCL command with no payload.
/// Frame control 0x01 = frame type "cluster-specific", not manufacturer-
/// specific, client→server, default response ENABLED — the target replies
/// with a Default Response carrying our sequence, which is our
/// end-to-end delivery confirmation.
pub fn buildClusterCommand(zcl_seq: u8, command_id: u8, out: *[3]u8) []const u8 {
    out[0] = 0x01;
    out[1] = zcl_seq;
    out[2] = command_id;
    return out[0..3];
}

/// Builds a Level Control "Step (with On/Off)" command (0x06): the target
/// changes brightness by `step_size` (0-254) over `transition_tenths`
/// tenths of a second, turning ON first if it was off (that's the "with
/// On/Off" variant — so dimming up from off just works). `up` selects
/// step_mode 0=up / 1=down. Same frame control (0x01) as buildClusterCommand
/// so the target sends a Default Response we can confirm on.
pub fn buildLevelStep(zcl_seq: u8, up: bool, step_size: u8, transition_tenths: u16, out: *[7]u8) []const u8 {
    out[0] = 0x01; // cluster-specific, client→server, default response enabled
    out[1] = zcl_seq;
    out[2] = LEVEL_CMD_STEP_WITH_ONOFF;
    out[3] = if (up) 0x00 else 0x01; // step_mode
    out[4] = step_size;
    out[5] = @truncate(transition_tenths & 0xFF);
    out[6] = @truncate(transition_tenths >> 8);
    return out[0..7];
}

/// Builds a Level Control "Move (with On/Off)" command (0x05): the target
/// ramps brightness continuously at `rate` units/second in the given
/// direction until a Stop (0x07) arrives — the hold-to-dim primitive. "With
/// On/Off" turns the light on if a move-up starts from off.
pub fn buildLevelMove(zcl_seq: u8, up: bool, rate: u8, out: *[5]u8) []const u8 {
    out[0] = 0x01; // cluster-specific, client→server, default response enabled
    out[1] = zcl_seq;
    out[2] = LEVEL_CMD_MOVE_WITH_ONOFF;
    out[3] = if (up) 0x00 else 0x01; // move_mode
    out[4] = rate;
    return out[0..5];
}

/// Identify cluster's Identify command (0x00): the target sets IdentifyTime to
/// `seconds` and shows itself (a light flashes) until it counts down; 0 stops it.
pub const IDENTIFY_CMD_IDENTIFY: u8 = 0x00;

/// Builds an Identify command for `seconds` (little-endian uint16), with the
/// default response enabled so delivery can be confirmed.
pub fn buildIdentify(zcl_seq: u8, seconds: u16, out: *[5]u8) []const u8 {
    out[0] = 0x01; // cluster-specific, client→server, default response enabled
    out[1] = zcl_seq;
    out[2] = IDENTIFY_CMD_IDENTIFY;
    out[3] = @truncate(seconds & 0xFF);
    out[4] = @truncate(seconds >> 8);
    return out[0..5];
}

// Level Stop (with On/Off, 0x07) has no payload, so it's just
// `buildClusterCommand(seq, LEVEL_CMD_STOP_WITH_ONOFF)` — no dedicated
// builder needed. It ends a Move.

/// Builds a Level Control "Move to Level (with On/Off)" command (0x04):
/// the target goes to absolute brightness `level` (0-254) over
/// `transition_tenths` tenths of a second. "With On/Off" means an off
/// bulb turns on first (so `brightness 40` from off just works, matching
/// the dimmer's own ramps) and level 0 turns it off — both per the ZCL
/// spec, not side effects.
pub fn buildMoveToLevel(zcl_seq: u8, level: u8, transition_tenths: u16, out: *[6]u8) []const u8 {
    out[0] = 0x01; // cluster-specific, client→server, default response enabled
    out[1] = zcl_seq;
    out[2] = LEVEL_CMD_MOVE_TO_LEVEL_WITH_ONOFF;
    out[3] = level;
    out[4] = @truncate(transition_tenths & 0xFF);
    out[5] = @truncate(transition_tenths >> 8);
    return out[0..6];
}

/// Color Control "Move to Color" (0x07): the target moves to CIE 1931
/// chromaticity (`x`, `y`, each a u16 = the fraction × 65536, clamped to
/// 0xFEFF per the spec's max) over `transition_tenths`. This is the
/// colour-space Hue bulbs speak natively; `config.zig`'s `rgbToXy`
/// converts an sRGB hex there. Same frame control (0x01) as the others.
/// Note colour is independent of brightness — a Move to Color doesn't
/// turn a bulb on, so a rule applies it alongside the On/Off send, not
/// instead of it.
pub const COLOR_CMD_MOVE_TO_COLOR: u8 = 0x07;
pub fn buildMoveToColor(zcl_seq: u8, x: u16, y: u16, transition_tenths: u16, out: *[9]u8) []const u8 {
    out[0] = 0x01; // cluster-specific, client→server, default response enabled
    out[1] = zcl_seq;
    out[2] = COLOR_CMD_MOVE_TO_COLOR;
    out[3] = @truncate(x & 0xFF);
    out[4] = @truncate(x >> 8);
    out[5] = @truncate(y & 0xFF);
    out[6] = @truncate(y >> 8);
    out[7] = @truncate(transition_tenths & 0xFF);
    out[8] = @truncate(transition_tenths >> 8);
    return out[0..9];
}

/// Groups cluster — lets a coordinator make a device a member of a group,
/// after which a single group-addressed command (EZSP `sendMulticast`,
/// not a per-device unicast) reaches every member at once. Frame IDs and
/// payload layout confirmed against the EZSP host serial protocol
/// reference (read 2026-07); the group name field is always sent empty
/// (length 0) since only `devices.json`/`groups.json`'s names matter to
/// us — the ZCL-level name is a Zigbee Light Link leftover we don't use.
pub const CLUSTER_GROUPS: u16 = 0x0004;
pub const GROUPS_CMD_ADD_GROUP: u8 = 0x00;
/// Same numeric ID as the request — ZCL cluster-specific commands share
/// one ID space per direction (client→server request, server→client
/// response), distinguished by `Frame.frame_control`'s direction bit, not
/// by a different number. Kept as a separate named constant for clarity
/// at call sites, not because the value differs.
pub const GROUPS_CMD_ADD_GROUP_RESPONSE: u8 = 0x00;

/// ZCL general status codes seen on an Add Group Response. SUCCESS is the
/// first join; DUPLICATE_EXISTS (0x8A) is what a device already in the
/// group returns to a re-add — which hub's startup auto-setup triggers
/// on every boot, so it must read as "already a member", not a failure.
pub const STATUS_SUCCESS: u8 = 0x00;
pub const STATUS_DUPLICATE_EXISTS: u8 = 0x8A;

/// Builds an Add Group command: the target device becomes a member of
/// `group_id`, and starts answering group-addressed frames sent to it.
/// The binding this creates lives on the TARGET device and persists
/// there (same durability as ZDO bindings) — not something we track or
/// re-apply every session.
pub fn buildAddGroup(zcl_seq: u8, group_id: u16, out: *[6]u8) []const u8 {
    out[0] = 0x01; // cluster-specific, client→server, default response enabled
    out[1] = zcl_seq;
    out[2] = GROUPS_CMD_ADD_GROUP;
    out[3] = @truncate(group_id & 0xFF);
    out[4] = @truncate(group_id >> 8);
    out[5] = 0; // group name: empty string (1-byte length prefix, no bytes)
    return out[0..6];
}

pub const AddGroupResponse = struct { status: u8, group_id: u16 };

/// Parses an Add Group Response. `payload` is the frame's payload (i.e.
/// what `Frame.payload` gives you after `parseFrame` — the ZCL header
/// already stripped), and the caller is expected to have already checked
/// `frame.isClusterSpecific()` and `frame.command_id ==
/// GROUPS_CMD_ADD_GROUP_RESPONSE` on cluster `CLUSTER_GROUPS`, mirroring
/// how `parseIasZoneStatusChange`/`parseOffWithEffect` are used.
pub fn parseAddGroupResponse(payload: []const u8) ?AddGroupResponse {
    if (payload.len < 3) return null;
    return .{ .status = payload[0], .group_id = @as(u16, payload[1]) | (@as(u16, payload[2]) << 8) };
}

/// Scenes (ZCL 3.7): stored values for the other clusters on one endpoint, recalled
/// together. Group 0 is a scene with no group, which can only be unicast.
pub const CLUSTER_SCENES: u16 = 0x0005;
pub const SCENES_CMD_ADD: u8 = 0x00;
pub const SCENES_CMD_VIEW: u8 = 0x01;
pub const SCENES_CMD_STORE: u8 = 0x04;
pub const SCENES_CMD_RECALL: u8 = 0x05;

/// A scene's values, as its extension field sets carry them: On/Off's `OnOff`
/// (3.8.2.6) and Level Control's `CurrentLevel` (3.10.2.5), each optional.
pub const SceneValues = struct { on: ?bool = null, level: ?u8 = null };

/// Add Scene (3.7.2.4.2): a scene with these values, written without changing the
/// light. No name, as Store Scene would keep it but nothing here reads it.
pub fn buildAddScene(zcl_seq: u8, group_id: u16, scene_id: u8, transition_s: u16, values: SceneValues, out: *[17]u8) []const u8 {
    out[0] = 0x01; // cluster-specific, client→server, default response enabled
    out[1] = zcl_seq;
    out[2] = SCENES_CMD_ADD;
    std.mem.writeInt(u16, out[3..5], group_id, .little);
    out[5] = scene_id;
    std.mem.writeInt(u16, out[6..8], transition_s, .little);
    out[8] = 0; // name: empty string
    var n: usize = 9;
    if (values.on) |on| {
        std.mem.writeInt(u16, out[n..][0..2], CLUSTER_ON_OFF, .little);
        out[n + 2] = 1;
        out[n + 3] = @intFromBool(on);
        n += 4;
    }
    if (values.level) |level| {
        std.mem.writeInt(u16, out[n..][0..2], CLUSTER_LEVEL_CONTROL, .little);
        out[n + 2] = 1;
        out[n + 3] = level;
        n += 4;
    }
    return out[0..n];
}

/// Store, Recall or View Scene: a group and a scene, nothing else. Recall's
/// optional transition time is left out, so the scene's own is used.
pub fn buildSceneRef(zcl_seq: u8, command_id: u8, group_id: u16, scene_id: u8, out: *[6]u8) []const u8 {
    out[0] = 0x01;
    out[1] = zcl_seq;
    out[2] = command_id;
    std.mem.writeInt(u16, out[3..5], group_id, .little);
    out[5] = scene_id;
    return out[0..6];
}

pub const SceneStatus = struct { status: u8, group_id: u16, scene_id: u8 };

/// The start every Scenes response shares: status, group, scene.
pub fn parseSceneStatus(payload: []const u8) ?SceneStatus {
    if (payload.len < 4) return null;
    return .{ .status = payload[0], .group_id = std.mem.readInt(u16, payload[1..3], .little), .scene_id = payload[3] };
}

pub const ViewedScene = struct { status: SceneStatus, transition_s: u16 = 0, values: SceneValues = .{} };

/// View Scene Response (3.7.2.5.2). The extension sets of clusters other than
/// On/Off and Level are skipped by their length, as is a value past the first.
pub fn parseViewSceneResponse(payload: []const u8) ?ViewedScene {
    const status = parseSceneStatus(payload) orelse return null;
    var out: ViewedScene = .{ .status = status };
    if (status.status != STATUS_SUCCESS) return out;
    if (payload.len < 7) return null;
    out.transition_s = std.mem.readInt(u16, payload[4..6], .little);
    var i: usize = 7 + @as(usize, payload[6]); // past the name
    if (i > payload.len) return null;
    while (i + 3 <= payload.len) {
        const cluster = std.mem.readInt(u16, payload[i..][0..2], .little);
        const len = payload[i + 2];
        const start = i + 3;
        if (start + len > payload.len) return null;
        if (len >= 1) {
            if (cluster == CLUSTER_ON_OFF) out.values.on = payload[start] != 0;
            if (cluster == CLUSTER_LEVEL_CONTROL) out.values.level = payload[start];
        }
        i = start + len;
    }
    return out;
}

pub const CLUSTER_OTA: u16 = 0x0019;
pub const OTA_CMD_QUERY_NEXT_IMAGE: u8 = 0x01;
pub const OTA_CMD_QUERY_NEXT_IMAGE_RESPONSE: u8 = 0x02;
pub const OTA_STATUS_NO_IMAGE_AVAILABLE: u8 = 0x98;

/// Builds an OTA QueryNextImageResponse saying we have no image (status
/// NO_IMAGE_AVAILABLE) — the polite way to make a device stop polling our
/// (nonexistent) OTA server every few seconds. Server→client,
/// cluster-specific, disable default response; echoes the request's ZCL
/// sequence. A NO_IMAGE status carries only the status byte (a SUCCESS
/// response would append image metadata).
pub fn buildQueryNextImageNoImage(zcl_seq: u8, out: *[4]u8) []const u8 {
    out[0] = 0x19; // cluster-specific | server→client | disable default response
    out[1] = zcl_seq;
    out[2] = OTA_CMD_QUERY_NEXT_IMAGE_RESPONSE;
    out[3] = OTA_STATUS_NO_IMAGE_AVAILABLE;
    return out[0..4];
}

/// IAS Zone Status Change Notification payload (cmd 0x00): zoneStatus
/// (u16 LE bitmap) + extendedStatus(1, reserved) + zoneId(1) + delay
/// (u16 LE, quarter-seconds — only meaningful for some device profiles).
/// zoneStatus bit meanings are common across the IAS Zone spec regardless
/// of sensor type: bit0 Alarm1 (the sensor's primary trigger — water
/// detected / motion / contact open, depending on zone type), bit1 Alarm2
/// (secondary trigger, rare), bit2 Tamper, bit3 Battery (low battery),
/// bit4 Supervision reports, bit5 Restore reports, bit6 Trouble, bit7 AC
/// mains fault.
pub const IasZoneStatus = struct {
    zone_status: u16,
    zone_id: u8,

    pub fn alarm1(self: *const IasZoneStatus) bool {
        return self.zone_status & 0x0001 != 0;
    }
    pub fn alarm2(self: *const IasZoneStatus) bool {
        return self.zone_status & 0x0002 != 0;
    }
    pub fn tamper(self: *const IasZoneStatus) bool {
        return self.zone_status & 0x0004 != 0;
    }
    pub fn batteryLow(self: *const IasZoneStatus) bool {
        return self.zone_status & 0x0008 != 0;
    }
};

pub fn parseIasZoneStatusChange(payload: []const u8) ?IasZoneStatus {
    if (payload.len < 6) return null;
    return .{
        .zone_status = @as(u16, payload[0]) | (@as(u16, payload[1]) << 8),
        .zone_id = payload[3],
    };
}

pub const DefaultResponse = struct {
    zcl_seq: u8,
    command_id: u8, // the command being responded to
    status: u8, // 0x00 = SUCCESS
};

/// Returns the parsed Default Response if `payload` is one (global-command
/// frame carrying command id 0x0B), else null.
pub fn parseDefaultResponse(payload: []const u8) ?DefaultResponse {
    if (payload.len < 5) return null;
    if (payload[0] & 0x03 != 0x00) return null; // frame type must be "global command"
    if (payload[2] != CMD_DEFAULT_RESPONSE) return null;
    return .{ .zcl_seq = payload[1], .command_id = payload[3], .status = payload[4] };
}

/// A decoded incoming ZCL frame header. `payload` references the input
/// buffer (no copy) — same lifetime rules as the IncomingMessage it came
/// from.
pub const Frame = struct {
    frame_control: u8,
    manufacturer_code: ?u16,
    zcl_seq: u8,
    command_id: u8,
    payload: []const u8,

    pub fn isClusterSpecific(self: *const Frame) bool {
        return self.frame_control & 0x03 == 0x01;
    }

    pub fn isGlobal(self: *const Frame) bool {
        return self.frame_control & 0x03 == 0x00;
    }
};

/// Splits any incoming ZCL frame into header + payload. Frame control bit
/// 0x04 = manufacturer-specific: a 2-byte manufacturer code is inserted
/// between the frame control and the sequence number.
pub fn parseFrame(data: []const u8) !Frame {
    if (data.len < 3) return error.FrameTooShort;
    const fc = data[0];
    var idx: usize = 1;
    var manuf: ?u16 = null;
    if (fc & 0x04 != 0) {
        if (data.len < 5) return error.FrameTooShort;
        manuf = @as(u16, data[1]) | (@as(u16, data[2]) << 8);
        idx = 3;
    }
    return .{
        .frame_control = fc,
        .manufacturer_code = manuf,
        .zcl_seq = data[idx],
        .command_id = data[idx + 1],
        .payload = data[idx + 2 ..],
    };
}

/// Wire size of a ZCL data type's value, or null for types we don't
/// decode (arrays, structs, long strings). Strings (0x41/0x42) are
/// variable — handled separately by the report iterator.
pub fn dataTypeSize(data_type: u8) ?usize {
    return switch (data_type) {
        0x08...0x0F => data_type - 0x07, // dataN
        0x10 => 1, // bool
        0x18...0x1F => data_type - 0x17, // bitmapN
        0x20...0x27 => data_type - 0x1F, // uintN
        0x28...0x2F => data_type - 0x27, // intN
        0x30 => 1, // enum8
        0x31 => 2, // enum16
        0x38 => 2, // float16
        0x39 => 4, // float32
        0x3A => 8, // float64
        0xE0, 0xE1, 0xE2 => 4, // time of day / date / UTC time
        else => null,
    };
}

fn isSignedType(data_type: u8) bool {
    return data_type >= 0x28 and data_type <= 0x2F;
}

/// One attribute record from a Report Attributes command.
pub const AttributeRecord = struct {
    attr_id: u16,
    data_type: u8,
    raw: []const u8, // value bytes, LE

    /// Value as a sign-extended integer for all fixed-size numeric-ish
    /// types (uint/int/bool/bitmap/enum/data), null for strings/floats.
    pub fn intValue(self: *const AttributeRecord) ?i64 {
        if (self.raw.len == 0 or self.raw.len > 8) return null;
        if (self.data_type >= 0x38 and self.data_type <= 0x3A) return null; // floats
        var v: u64 = 0;
        for (self.raw, 0..) |b, i| v |= @as(u64, b) << @intCast(8 * i);
        if (isSignedType(self.data_type) and self.raw.len < 8) {
            const sign_bit = @as(u64, 1) << @intCast(8 * self.raw.len - 1);
            if (v & sign_bit != 0) v |= ~(sign_bit * 2 - 1); // sign-extend
        }
        return @bitCast(v);
    }
};

/// A ZCL character string's text: the value without its length prefix. Null for
/// anything else, or the "invalid" length 0xFF (ZCL 2.6.2).
pub fn charString(rec: *const AttributeRecord) ?[]const u8 {
    if (rec.data_type != 0x42 or rec.raw.len == 0 or rec.raw[0] == 0xFF) return null;
    return rec.raw[1..];
}

/// Iterates the attribute records of a Report Attributes (0x0A) payload:
/// repeated attr_id(u16 LE) + data_type(1) + value. Stops (returns null)
/// at the end of data or on a type it can't size.
/// Read Attributes (global command 0x00) for a single attribute.
///
/// Why hub needs it: some devices never volunteer state.
/// `bulb2` — an older Hue bulb — answers Configure Reporting with
/// `UNSUP_GENERAL_COMMAND`, so it can be commanded all day and will never say
/// what it is. Asking is the only way to know, and this is the ask.
pub fn buildReadAttributes(zcl_seq: u8, attr_id: u16, out: *[5]u8) []const u8 {
    out[0] = 0x00; // global command, client→server
    out[1] = zcl_seq;
    out[2] = CMD_READ_ATTRIBUTES;
    out[3] = @truncate(attr_id & 0xFF);
    out[4] = @truncate(attr_id >> 8);
    return out[0..5];
}

/// Builds a global **Write Attributes** (0x02) frame writing the CIE
/// address: attribute `IAS_CIE_Address` (0x0010), type IEEE (0xF0), value =
/// the coordinator's EUI64 (IAS enrollment). `eui` is wire order
/// (little-endian), exactly as `Ezsp.getEui64` returns it and as this
/// attribute wants it, so it's copied straight through. Header (3) + attr id
/// (2) + type (1) + value (8) = 14 bytes.
pub fn buildWriteIasCieAddress(zcl_seq: u8, eui: [8]u8, out: *[14]u8) []const u8 {
    out[0] = 0x00; // global command, client→server
    out[1] = zcl_seq;
    out[2] = CMD_WRITE_ATTRIBUTES;
    out[3] = @truncate(ATTR_IAS_CIE_ADDRESS & 0xFF);
    out[4] = @truncate(ATTR_IAS_CIE_ADDRESS >> 8);
    out[5] = TYPE_IEEE_ADDRESS;
    @memcpy(out[6..14], &eui);
    return out[0..14];
}

/// Builds a cluster-specific **Zone Enroll Response** (IAS command 0x00,
/// client→server): `enrollResponseCode` (0x00 = Success) + `zoneId`. Same
/// frame control (0x01: cluster-specific, client→server, default response
/// enabled) as every other command we send — the sensor may Default-Response
/// it, which we harmlessly log.
pub fn buildZoneEnrollResponse(zcl_seq: u8, response_code: u8, zone_id: u8, out: *[5]u8) []const u8 {
    out[0] = 0x01; // cluster-specific, client→server, default response enabled
    out[1] = zcl_seq;
    out[2] = IAS_CMD_ZONE_ENROLL_RESPONSE;
    out[3] = response_code;
    out[4] = zone_id;
    return out[0..5];
}

/// The `ZoneType`/`ManufacturerCode` a device sends in a Zone Enroll
/// Request — decoded only for logging (the enrollment itself doesn't depend
/// on the values). ZoneType hints at the physical kind (0x000D motion,
/// 0x0015 contact, 0x002A leak, 0x0028 fire…) but hub reacts to the alarm
/// bit generically, so this is informational.
pub const ZoneEnrollRequest = struct { zone_type: u16, manufacturer_code: u16 };
pub fn parseZoneEnrollRequest(payload: []const u8) ?ZoneEnrollRequest {
    if (payload.len < 4) return null;
    return .{
        .zone_type = @as(u16, payload[0]) | (@as(u16, payload[1]) << 8),
        .manufacturer_code = @as(u16, payload[2]) | (@as(u16, payload[3]) << 8),
    };
}

/// Iterates a **Read Attributes Response** payload (global command 0x01).
///
/// Deliberately separate from `AttributeReports`, which iterates a *Report
/// Attributes* payload: the two look almost identical but differ by one byte
/// per record — a response carries a per-attribute `status`, and on failure
/// the type/value are **absent entirely**. Decoding one with the other's
/// parser silently misreads every field after the first.
pub const ReadAttributeResponses = struct {
    data: []const u8,
    idx: usize = 0,

    pub fn next(self: *ReadAttributeResponses) ?AttributeRecord {
        if (self.idx + 3 > self.data.len) return null;
        const attr_id = @as(u16, self.data[self.idx]) | (@as(u16, self.data[self.idx + 1]) << 8);
        const status = self.data[self.idx + 2];
        self.idx += 3;
        // Unsupported/unreadable attribute: the record ends at the status,
        // with no type and no value. Skip it; a later record may be fine.
        if (status != 0x00) return self.next();

        if (self.idx >= self.data.len) return null;
        const data_type = self.data[self.idx];
        self.idx += 1;

        var size: usize = undefined;
        if (data_type == 0x41 or data_type == 0x42) { // octet/char string: 1-byte length prefix
            if (self.idx >= self.data.len) return null;
            size = @as(usize, self.data[self.idx]) + 1;
        } else {
            size = dataTypeSize(data_type) orelse return null;
        }
        if (self.idx + size > self.data.len) return null;
        const raw = self.data[self.idx .. self.idx + size];
        self.idx += size;
        return .{ .attr_id = attr_id, .data_type = data_type, .raw = raw };
    }
};

pub const AttributeReports = struct {
    data: []const u8,
    idx: usize = 0,

    pub fn next(self: *AttributeReports) ?AttributeRecord {
        if (self.idx + 3 > self.data.len) return null;
        const attr_id = @as(u16, self.data[self.idx]) | (@as(u16, self.data[self.idx + 1]) << 8);
        const data_type = self.data[self.idx + 2];
        self.idx += 3;

        var size: usize = undefined;
        if (data_type == 0x41 or data_type == 0x42) { // octet/char string: 1-byte length prefix
            if (self.idx >= self.data.len) return null;
            size = @as(usize, self.data[self.idx]) + 1;
        } else {
            size = dataTypeSize(data_type) orelse return null;
        }
        if (self.idx + size > self.data.len) return null;
        const raw = self.data[self.idx .. self.idx + size];
        self.idx += size;
        return .{ .attr_id = attr_id, .data_type = data_type, .raw = raw };
    }
};

/// Analog data types carry a "reportable change" field in reporting
/// configurations; discrete types (bool/bitmap/enum/data) omit it, per the
/// ZCL spec's analog/discrete split.
pub fn isAnalogType(data_type: u8) bool {
    return (data_type >= 0x20 and data_type <= 0x2F) // uintN/intN
    or (data_type >= 0x38 and data_type <= 0x3A) // floats
    or (data_type >= 0xE0 and data_type <= 0xE2); // time types
}

/// One attribute's reporting configuration for buildConfigureReporting.
pub const ReportingConfig = struct {
    attr_id: u16,
    data_type: u8,
    min_interval_s: u16, // don't report more often than this
    max_interval_s: u16, // report at least this often (heartbeat)
    /// Minimum change that triggers a report. Only encoded for analog
    /// types (truncated to the type's wire size); ignored for discrete.
    reportable_change: u32 = 0,
};

/// Builds a Configure Reporting command (global 0x06) with one record:
/// direction(0x00 = "you report to me") + attr(u16 LE) + type(1) +
/// min(u16 LE) + max(u16 LE) [+ reportable change, analog only]. The
/// device answers with Configure Reporting Response (0x07). Verified
/// against zigpy's foundation.AttributeReportingConfig.
pub fn buildConfigureReporting(zcl_seq: u8, cfg: ReportingConfig, out: *[16]u8) []const u8 {
    out[0] = 0x00; // global command, client→server
    out[1] = zcl_seq;
    out[2] = CMD_CONFIGURE_REPORTING;
    out[3] = 0x00; // direction: device sends reports
    out[4] = @truncate(cfg.attr_id & 0xFF);
    out[5] = @truncate(cfg.attr_id >> 8);
    out[6] = cfg.data_type;
    out[7] = @truncate(cfg.min_interval_s & 0xFF);
    out[8] = @truncate(cfg.min_interval_s >> 8);
    out[9] = @truncate(cfg.max_interval_s & 0xFF);
    out[10] = @truncate(cfg.max_interval_s >> 8);
    var n: usize = 11;
    if (isAnalogType(cfg.data_type)) {
        const size = dataTypeSize(cfg.data_type) orelse 0;
        for (0..size) |i| {
            // types wider than u32 (uint40+): high bytes zero-pad
            out[n] = if (i < 4) @truncate(cfg.reportable_change >> @intCast(8 * i)) else 0;
            n += 1;
        }
    }
    return out[0..n];
}

/// First status byte of a Configure Reporting Response (0x07): a lone
/// 0x00 means every record was accepted; otherwise per-record
/// status+direction+attr entries follow (we only send one record, so the
/// first status is the verdict either way).
pub fn parseConfigureReportingRsp(payload: []const u8) ?u8 {
    if (payload.len < 1) return null;
    return payload[0];
}

/// Philips Hue notification (cluster 0xFC00, manufacturer-specific command
/// 0x00) — carries BOTH button presses and Tap-dial rotations. Layout per
/// zigbee-herdsman-converters' `manuSpecificPhilips` hueNotification:
/// button(u8) + unknown1(u24) + type(u8) + unknown2(u8) + time(u8) +
/// unknown3(u8). `button` 1-4 = physical buttons; **`button` 20 (0x14) =
/// dial rotation**, where `unknown3` gives direction and `time` gives
/// magnitude (the dial reuses the same notification, which is why an
/// earlier version misprinted rotations as "button 20").
pub const HueNotification = struct {
    button: u8, // 1-4 buttons; 20 = dial rotation
    event_type: u8, // buttons: 0=press 1=hold 2=short-release 3=long-release
    time: u8, // buttons: eighths-of-a-second held; dial: rotation magnitude
    direction_raw: u8, // dial only (unknown3): <127 = right/clockwise, else left

    pub const DIAL_BUTTON: u8 = 20;

    pub fn isDial(self: *const HueNotification) bool {
        return self.button == DIAL_BUTTON;
    }

    pub fn typeName(self: *const HueNotification) []const u8 {
        return switch (self.event_type) {
            0 => "press",
            1 => "hold",
            2 => "short-release",
            3 => "long-release",
            else => "?",
        };
    }

    /// Dial rotation direction (button 20 only), per herdsman: unknown3
    /// below 127 is a right/clockwise turn, otherwise left.
    pub fn dialDirection(self: *const HueNotification) []const u8 {
        return if (self.direction_raw < 127) "right" else "left";
    }

    /// Dial rotation speed bucket (button 20 only), per herdsman: the
    /// `time` field, folded around 256 for left turns, classifies the turn
    /// as a single detent step vs a slow/fast continuous spin.
    pub fn dialSpeed(self: *const HueNotification) []const u8 {
        const adjusted: u16 = if (self.direction_raw < 127) self.time else 256 - @as(u16, self.time);
        return if (adjusted <= 25) "step" else if (adjusted <= 75) "slow" else "fast";
    }
};

pub fn parseHueNotification(payload: []const u8) ?HueNotification {
    if (payload.len < 8) return null;
    return .{ .button = payload[0], .event_type = payload[4], .time = payload[6], .direction_raw = payload[7] };
}

test "buildClusterCommand produces the 3-byte On/Off toggle frame" {
    var buf: [3]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x42, 0x02 }, buildClusterCommand(0x42, ONOFF_CMD_TOGGLE, &buf));
}

test "buildIdentify carries IdentifyTime little-endian" {
    var buf: [5]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x07, 0x00, 0x2C, 0x01 }, buildIdentify(0x07, 300, &buf));
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x08, 0x00, 0x00, 0x00 }, buildIdentify(0x08, 0, &buf));
}

test "buildLevelStep encodes step-with-onoff up and down" {
    var buf: [7]u8 = undefined;
    // up, step 25, transition 3 (0.3s)
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x42, 0x06, 0x00, 0x19, 0x03, 0x00 }, buildLevelStep(0x42, true, 25, 3, &buf));
    // down, step 40, transition 300 (30s → 0x012C)
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x43, 0x06, 0x01, 0x28, 0x2C, 0x01 }, buildLevelStep(0x43, false, 40, 300, &buf));
}

test "buildLevelMove / Stop encode the hold-to-ramp primitives" {
    var mbuf: [5]u8 = undefined;
    // move up, rate 50
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x42, 0x05, 0x00, 0x32 }, buildLevelMove(0x42, true, 50, &mbuf));
    // move down, rate 50
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x43, 0x05, 0x01, 0x32 }, buildLevelMove(0x43, false, 50, &mbuf));
    // Stop = a payload-less cluster command with id 0x07
    var sbuf: [3]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x44, 0x07 }, buildClusterCommand(0x44, LEVEL_CMD_STOP_WITH_ONOFF, &sbuf));
}

test "buildQueryNextImageNoImage encodes an OTA no-image response" {
    var buf: [4]u8 = undefined;
    // server→client cluster-specific, disable default response; cmd 0x02, status 0x98
    try std.testing.expectEqualSlices(u8, &.{ 0x19, 0x55, 0x02, 0x98 }, buildQueryNextImageNoImage(0x55, &buf));
}

test "buildAddGroup encodes group id LE with an empty group name" {
    var buf: [6]u8 = undefined;
    const frame = buildAddGroup(0x12, 0x0007, &buf);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x12, 0x00, 0x07, 0x00, 0x00 }, frame);
}

test "parseAddGroupResponse decodes status + group id" {
    const payload = [_]u8{ 0x00, 0x07, 0x00 }; // status=SUCCESS, group_id=0x0007
    const rsp = parseAddGroupResponse(&payload).?;
    try std.testing.expectEqual(@as(u8, 0x00), rsp.status);
    try std.testing.expectEqual(@as(u16, 0x0007), rsp.group_id);
    try std.testing.expectEqual(@as(?AddGroupResponse, null), parseAddGroupResponse(payload[0..1]));
}

test "parseIasZoneStatusChange decodes alarm/tamper/battery bits" {
    // zoneStatus 0x0009 (alarm1 | battery low), extendedStatus 0, zoneId 1, delay 0
    const wet = [_]u8{ 0x09, 0x00, 0x00, 0x01, 0x00, 0x00 };
    const s = parseIasZoneStatusChange(&wet).?;
    try std.testing.expect(s.alarm1());
    try std.testing.expect(!s.alarm2());
    try std.testing.expect(!s.tamper());
    try std.testing.expect(s.batteryLow());
    try std.testing.expectEqual(@as(u8, 1), s.zone_id);

    // cleared: zoneStatus 0x0000
    const dry = [_]u8{ 0x00, 0x00, 0x00, 0x01, 0x00, 0x00 };
    try std.testing.expect(!parseIasZoneStatusChange(&dry).?.alarm1());

    try std.testing.expectEqual(@as(?IasZoneStatus, null), parseIasZoneStatusChange(&.{ 1, 2, 3 }));
}

test "IAS enrollment: CIE-address write + enroll response byte layouts" {
    const eui = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };
    var wbuf: [14]u8 = undefined;
    const w = buildWriteIasCieAddress(0x30, eui, &wbuf);
    // global Write Attributes, seq, cmd 0x02, attr 0x0010 LE, type 0xF0, then
    // the EUI copied straight through (wire order, as getEui64 returns it).
    try std.testing.expectEqualSlices(u8, &.{
        // zig fmt: off
        0x00, 0x30, CMD_WRITE_ATTRIBUTES, 0x10, 0x00, TYPE_IEEE_ADDRESS,
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
        // zig fmt: on
    }, w);

    var ebuf: [5]u8 = undefined;
    const e = buildZoneEnrollResponse(0x31, 0x00, 0x00, &ebuf);
    // cluster-specific client→server, seq, cmd 0x00, code SUCCESS, zoneId 0
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x31, IAS_CMD_ZONE_ENROLL_RESPONSE, 0x00, 0x00 }, e);
}

test "parseZoneEnrollRequest decodes zone type + manufacturer code, rejects short" {
    // ZoneType 0x000D (motion), ManufacturerCode 0x1234 — both LE
    const req = parseZoneEnrollRequest(&.{ 0x0D, 0x00, 0x34, 0x12 }).?;
    try std.testing.expectEqual(@as(u16, 0x000D), req.zone_type);
    try std.testing.expectEqual(@as(u16, 0x1234), req.manufacturer_code);
    try std.testing.expectEqual(@as(?ZoneEnrollRequest, null), parseZoneEnrollRequest(&.{ 0x0D, 0x00 }));
}

test "parseDefaultResponse recognizes a success response and rejects others" {
    // frame control 0x18 = global command, server→client, disable default response
    const ok = [_]u8{ 0x18, 0x42, 0x0B, 0x02, 0x00 };
    const rsp = parseDefaultResponse(&ok).?;
    try std.testing.expectEqual(@as(u8, 0x42), rsp.zcl_seq);
    try std.testing.expectEqual(@as(u8, 0x02), rsp.command_id);
    try std.testing.expectEqual(@as(u8, 0x00), rsp.status);

    // cluster-specific frame (e.g. an On command) is not a default response
    const cluster_cmd = [_]u8{ 0x01, 0x42, 0x01, 0x00, 0x00 };
    try std.testing.expectEqual(@as(?DefaultResponse, null), parseDefaultResponse(&cluster_cmd));

    // global command that isn't 0x0B
    const other_global = [_]u8{ 0x18, 0x42, 0x01, 0x02, 0x00 };
    try std.testing.expectEqual(@as(?DefaultResponse, null), parseDefaultResponse(&other_global));
}

test "parseFrame splits plain and manufacturer-specific headers" {
    // Plain global frame: report attributes
    const plain = [_]u8{ 0x18, 0x2A, 0x0A, 0x00, 0x00, 0x10, 0x01 };
    const f = try parseFrame(&plain);
    try std.testing.expect(f.isGlobal());
    try std.testing.expectEqual(@as(?u16, null), f.manufacturer_code);
    try std.testing.expectEqual(@as(u8, 0x2A), f.zcl_seq);
    try std.testing.expectEqual(CMD_REPORT_ATTRIBUTES, f.command_id);
    try std.testing.expectEqual(@as(usize, 4), f.payload.len);

    // Manufacturer-specific cluster command (Philips 0x100B)
    const manuf = [_]u8{ 0x1D, 0x0B, 0x10, 0x33, 0x00, 0x01, 0x00, 0x00, 0x30, 0x00, 0x02, 0x00, 0x00 };
    const mf = try parseFrame(&manuf);
    try std.testing.expect(mf.isClusterSpecific());
    try std.testing.expectEqual(@as(?u16, 0x100B), mf.manufacturer_code);
    try std.testing.expectEqual(@as(u8, 0x33), mf.zcl_seq);
    try std.testing.expectEqual(@as(u8, 0x00), mf.command_id);
    try std.testing.expectEqual(@as(usize, 8), mf.payload.len);
}

test "AttributeReports iterates occupancy and temperature style records" {
    // occupancy bitmap8 = 0x01, then int16 = 2153 (21.53°C), then a
    // negative int16 = -500 (-5.00°C)
    const payload = [_]u8{
        0x00, 0x00, 0x18, 0x01, // attr 0x0000 bitmap8 0x01
        0x00, 0x00, 0x29, 0x69, 0x08, // attr 0x0000 int16 2153
        0x01, 0x00, 0x29, 0x0C, 0xFE, // attr 0x0001 int16 -500
    };
    var it = AttributeReports{ .data = &payload };

    const a = it.next().?;
    try std.testing.expectEqual(@as(u16, 0x0000), a.attr_id);
    try std.testing.expectEqual(@as(u8, 0x18), a.data_type);
    try std.testing.expectEqual(@as(?i64, 1), a.intValue());

    const b = it.next().?;
    try std.testing.expectEqual(@as(?i64, 2153), b.intValue());

    const c = it.next().?;
    try std.testing.expectEqual(@as(u16, 0x0001), c.attr_id);
    try std.testing.expectEqual(@as(?i64, -500), c.intValue());

    try std.testing.expectEqual(@as(?AttributeRecord, null), it.next());
}

test "AttributeReports stops cleanly on unknown types and truncated data" {
    // 0x4C = struct — unsupported, iterator must return null, not misparse
    const unknown_type = [_]u8{ 0x00, 0x00, 0x4C, 0x01, 0x02 };
    var it = AttributeReports{ .data = &unknown_type };
    try std.testing.expectEqual(@as(?AttributeRecord, null), it.next());

    // record header claims uint16 but only 1 value byte present
    const truncated = [_]u8{ 0x00, 0x00, 0x21, 0x01 };
    var it2 = AttributeReports{ .data = &truncated };
    try std.testing.expectEqual(@as(?AttributeRecord, null), it2.next());
}

test "buildConfigureReporting encodes analog and discrete records" {
    var buf: [16]u8 = undefined;

    // int16 temperature: analog → 2-byte reportable change appended
    const analog = buildConfigureReporting(0x50, .{
        .attr_id = 0x0000,
        .data_type = 0x29,
        .min_interval_s = 30,
        .max_interval_s = 900,
        .reportable_change = 50,
    }, &buf);
    try std.testing.expectEqualSlices(u8, &.{
        0x00, 0x50, 0x06, // header
        0x00, // direction
        0x00, 0x00, // attr
        0x29, // int16
        0x1E, 0x00, // min 30
        0x84, 0x03, // max 900
        0x32, 0x00, // change 50
    }, analog);

    // bitmap8 occupancy: discrete → no reportable change field
    const discrete = buildConfigureReporting(0x51, .{
        .attr_id = 0x0000,
        .data_type = 0x18,
        .min_interval_s = 0,
        .max_interval_s = 3600,
    }, &buf);
    try std.testing.expectEqual(@as(usize, 11), discrete.len);
    try std.testing.expectEqual(@as(u8, 0x18), discrete[6]);
}

test "parseConfigureReportingRsp returns the first status byte" {
    try std.testing.expectEqual(@as(?u8, 0x00), parseConfigureReportingRsp(&.{0x00}));
    try std.testing.expectEqual(@as(?u8, 0x8C), parseConfigureReportingRsp(&.{ 0x8C, 0x00, 0x00, 0x00 }));
    try std.testing.expectEqual(@as(?u8, null), parseConfigureReportingRsp(&.{}));
}

test "parseOffWithEffect / parseOnWithTimedOff decode payloads" {
    const owe = parseOffWithEffect(&.{ 0x00, 0x01 }).?;
    try std.testing.expectEqual(@as(u8, 0x00), owe.effect_id);
    try std.testing.expectEqual(@as(u8, 0x01), owe.effect_variant);
    try std.testing.expectEqual(@as(?OffWithEffect, null), parseOffWithEffect(&.{0x00}));

    const owto = parseOnWithTimedOff(&.{ 0x01, 0x2C, 0x01, 0x00, 0x00 }).?;
    try std.testing.expectEqual(@as(u8, 0x01), owto.control);
    try std.testing.expectEqual(@as(u16, 300), owto.on_time_tenths); // 30s
    try std.testing.expectEqual(@as(u16, 0), owto.off_wait_tenths);
    try std.testing.expectEqual(@as(?OnWithTimedOff, null), parseOnWithTimedOff(&.{ 1, 2, 3 }));
}

test "parseHueNotification decodes a button press" {
    // button 2, type 1 (hold), time 8 (1s), unknown3 0
    const payload = [_]u8{ 0x02, 0x00, 0x00, 0x00, 0x01, 0x00, 0x08, 0x00 };
    const ev = parseHueNotification(&payload).?;
    try std.testing.expectEqual(@as(u8, 2), ev.button);
    try std.testing.expect(!ev.isDial());
    try std.testing.expectEqual(@as(u8, 8), ev.time);
    try std.testing.expectEqualStrings("hold", ev.typeName());

    try std.testing.expectEqual(@as(?HueNotification, null), parseHueNotification(&.{ 1, 2, 3 }));
}

test "parseHueNotification decodes a dial rotation (button 20)" {
    // button 20 = dial; time 60, unknown3 0x0A (<127 => right), speed slow
    const right = [_]u8{ 0x14, 0x00, 0x30, 0x00, 0x00, 0x00, 0x3C, 0x0A };
    const r = parseHueNotification(&right).?;
    try std.testing.expect(r.isDial());
    try std.testing.expectEqualStrings("right", r.dialDirection());
    try std.testing.expectEqualStrings("slow", r.dialSpeed()); // 60 in (25,75]

    // unknown3 0xF0 (>=127 => left); time 250 => adjusted 256-250=6 => step
    const left = [_]u8{ 0x14, 0x00, 0x30, 0x00, 0x00, 0x00, 0xFA, 0xF0 };
    const l = parseHueNotification(&left).?;
    try std.testing.expectEqualStrings("left", l.dialDirection());
    try std.testing.expectEqualStrings("step", l.dialSpeed());
}

test "buildReadAttributes: a global Read Attributes frame for one attribute" {
    var buf: [5]u8 = undefined;
    const frame = buildReadAttributes(0x42, 0x0000, &buf);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x42, CMD_READ_ATTRIBUTES, 0x00, 0x00 }, frame);
    // It must parse back as a GLOBAL command — a cluster-specific frame with
    // command 0x00 is "Off" on the On/Off cluster, which would be a very
    // exciting way to poll a light's state.
    const parsed = try parseFrame(frame);
    try std.testing.expect(parsed.isGlobal());
    try std.testing.expectEqual(@as(u8, 0x42), parsed.zcl_seq);
    try std.testing.expectEqual(CMD_READ_ATTRIBUTES, parsed.command_id);
}

test "ReadAttributeResponses: the status byte is what makes this NOT a report payload" {
    // OnOff=true, as a bulb answers a poll: attr 0x0000, status SUCCESS,
    // type Boolean (0x10), value 1.
    var it = ReadAttributeResponses{ .data = &.{ 0x00, 0x00, 0x00, 0x10, 0x01 } };
    const rec = it.next().?;
    try std.testing.expectEqual(@as(u16, 0x0000), rec.attr_id);
    try std.testing.expectEqual(@as(u8, 0x10), rec.data_type);
    try std.testing.expectEqual(@as(i64, 1), rec.intValue().?);
    try std.testing.expectEqual(@as(?AttributeRecord, null), it.next());

    // A failed record ends at the status — no type, no value. Decoding it as
    // a report would treat 0x86 as a data type and read garbage onwards.
    var unsup = ReadAttributeResponses{ .data = &.{ 0x00, 0x00, 0x86 } };
    try std.testing.expectEqual(@as(?AttributeRecord, null), unsup.next());

    // A failure followed by a success: the good one still comes through.
    var mixed = ReadAttributeResponses{ .data = &.{ 0x01, 0x00, 0x86, 0x00, 0x00, 0x00, 0x10, 0x00 } };
    const good = mixed.next().?;
    try std.testing.expectEqual(@as(u16, 0x0000), good.attr_id);
    try std.testing.expectEqual(@as(i64, 0), good.intValue().?);
}

test "buildMoveToLevel: absolute brightness, with On/Off, LE transition" {
    var buf: [6]u8 = undefined;
    const frame = buildMoveToLevel(0x11, 254, 4, &buf);
    // frame control, seq, command, level, transition LE
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x11, LEVEL_CMD_MOVE_TO_LEVEL_WITH_ONOFF, 254, 0x04, 0x00 }, frame);
    const parsed = try parseFrame(frame);
    try std.testing.expect(parsed.isClusterSpecific());
}

test "buildMoveToColor: x/y/transition all little-endian u16" {
    var buf: [9]u8 = undefined;
    const frame = buildMoveToColor(0x22, 0x1234, 0xABCD, 4, &buf);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x22, COLOR_CMD_MOVE_TO_COLOR, 0x34, 0x12, 0xCD, 0xAB, 0x04, 0x00 }, frame);
}

test "charString takes the text out of a ZCL string, and nothing else" {
    const s: AttributeRecord = .{ .attr_id = 5, .data_type = 0x42, .raw = "\x06RWL022" };
    try std.testing.expectEqualStrings("RWL022", charString(&s).?);
    const empty: AttributeRecord = .{ .attr_id = 5, .data_type = 0x42, .raw = "\x00" };
    try std.testing.expectEqualStrings("", charString(&empty).?);
    const invalid: AttributeRecord = .{ .attr_id = 5, .data_type = 0x42, .raw = "\xFF" };
    try std.testing.expect(charString(&invalid) == null);
    const number: AttributeRecord = .{ .attr_id = 5, .data_type = 0x20, .raw = "\x06" };
    try std.testing.expect(charString(&number) == null);
}

test "buildAddScene: group, scene, transition, empty name, then each value's set" {
    var buf: [17]u8 = undefined;
    const frame = buildAddScene(7, 0x0000, 3, 1, .{ .on = true, .level = 64 }, &buf);
    try std.testing.expectEqualSlices(u8, &.{
        0x01, 7, 0x00, // header: Add Scene
        0x00, 0x00, 3, 0x01, 0x00, 0, // group 0, scene 3, 1 s, no name
        0x06, 0x00, 1, 1, // On/Off: on
        0x08, 0x00, 1, 64, // Level: 64
    }, frame);
    try std.testing.expectEqual(@as(usize, 13), buildAddScene(7, 0, 3, 0, .{ .on = false }, &buf).len);
}

test "buildSceneRef: the command, then group and scene, little-endian" {
    var buf: [6]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 9, 0x05, 0x34, 0x12, 2 }, buildSceneRef(9, SCENES_CMD_RECALL, 0x1234, 2, &buf));
}

test "parseViewSceneResponse finds On/Off and Level, past a name and an unknown set" {
    const payload = [_]u8{
        0x00, 0x00, 0x00, 3, // success, group 0, scene 3
        0x05, 0x00, // 5 s
        2, 'h', 'i', // name
        0x00, 0x03, 2, 0xAA, 0xBB, // colour control, skipped
        0x06, 0x00, 1, 1, // on
        0x08, 0x00, 1, 200, // level 200
    };
    const v = parseViewSceneResponse(&payload).?;
    try std.testing.expectEqual(@as(u8, 3), v.status.scene_id);
    try std.testing.expectEqual(@as(u16, 5), v.transition_s);
    try std.testing.expectEqual(@as(?bool, true), v.values.on);
    try std.testing.expectEqual(@as(?u8, 200), v.values.level);
}

test "parseViewSceneResponse: a scene that isn't there is just a status" {
    const v = parseViewSceneResponse(&.{ 0x8B, 0x00, 0x00, 4 }).?;
    try std.testing.expectEqual(@as(u8, 0x8B), v.status.status);
    try std.testing.expect(v.values.on == null);
    try std.testing.expect(parseViewSceneResponse(&.{ 0x00, 0, 0, 4, 0, 0, 9 }) == null); // name runs off the end
}
