const std = @import("std");
const Ash = @import("ash");

// EZSP (EmberZNet Serial Protocol) application layer, riding on top of ASH
// DATA frames. Frame IDs, header layouts, and struct field orders verified
// against the bellows reference implementation
// (https://github.com/zigpy/bellows/tree/dev/bellows).

/// Matches ash.zig's own MAX_EZSP_PAYLOAD — the transport never accepts a
/// larger frame, so this is a tight, safe bound. Callback buffers must be
/// sized to this (not just big enough for the callbacks we decode): some
/// unsolicited frames we don't care about (e.g. messageSentHandler echoing
/// a full APS message during a real join) are still fully copied into the
/// buffer before we get to inspect/discard them.
const MAX_CALLBACK_PAYLOAD = 140;

pub const FRAME_VERSION: u16 = 0x00;
pub const FRAME_ADD_ENDPOINT: u16 = 0x02;
pub const FRAME_GET_CONFIGURATION_VALUE: u16 = 0x52;
pub const FRAME_SET_CONFIGURATION_VALUE: u16 = 0x53;
pub const FRAME_NETWORK_INIT: u16 = 0x17;
pub const FRAME_STACK_STATUS_HANDLER: u16 = 0x19;
pub const FRAME_FORM_NETWORK: u16 = 0x1E;
pub const FRAME_CHILD_JOIN_HANDLER: u16 = 0x23;
pub const FRAME_TRUST_CENTER_JOIN_HANDLER: u16 = 0x24;
pub const FRAME_GET_EUI64: u16 = 0x26;
pub const FRAME_GET_NODE_ID: u16 = 0x27;
pub const FRAME_GET_NETWORK_PARAMETERS: u16 = 0x28;
/// UG100: childCount, then the parent's EUI64 and node id, which a coordinator has none of.
pub const FRAME_GET_PARENT_CHILD_PARAMETERS: u16 = 0x29;
/// UG100: the number of active entries in the neighbor table.
pub const FRAME_NEIGHBOR_COUNT: u16 = 0x7A;
/// "A command which does nothing. The Host can use this to ... check the
/// status of the NCP" (UG100 p.2455). No parameters either way — the
/// cheapest possible "are you there?", and the reason hub can tell an idle
/// radio from a dead one. See `Client.nop`.
pub const FRAME_NOP: u16 = 0x05;
/// getValue/setValue (UG100 p.50, and the current API guide): read/write an
/// NCP value by id. Layouts confirmed against the doc, not guessed —
/// getValue params are `valueId`, responding `status, valueLength, value[]`;
/// setValue params are `valueId, valueLength, value[]`, responding `status`.
pub const FRAME_GET_VALUE: u16 = 0xAA;
pub const FRAME_SET_VALUE: u16 = 0xAB;
pub const FRAME_LEAVE_NETWORK: u16 = 0x20;
pub const FRAME_PERMIT_JOINING: u16 = 0x22;
pub const FRAME_SET_POLICY: u16 = 0x55;
pub const FRAME_GET_KEY: u16 = 0x6A;
pub const FRAME_SEND_UNICAST: u16 = 0x34;
pub const FRAME_SEND_BROADCAST: u16 = 0x36;
/// sendMulticast (EZSP 0x38, confirmed against the EZSP host serial
/// protocol reference read 2026-07): sends one frame that reaches every
/// device bound into the APS frame's `group_id` (via ZCL Groups cluster
/// Add Group) within `hops`. **Byte layout below is NOT independently
/// hardware-verified** — see `sendMulticast`'s doc comment for why and
/// what to check first if group sends misbehave.
pub const FRAME_SEND_MULTICAST: u16 = 0x38;
pub const FRAME_INCOMING_MESSAGE_HANDLER: u16 = 0x45;
/// messageSentHandler (0x3F) — the NCP reporting the outcome of a frame WE
/// sent (delivered / APS-acked / failed). One arrives after each
/// unicast/multicast. incomingRouteRecordHandler (0x59) — a router in the
/// mesh recording its path back to the coordinator (routing upkeep). Both
/// are frequent, benign callbacks; named so the interleaved-callback log
/// line reads as routine, not alarming (see `callbackDesc`).
pub const FRAME_MESSAGE_SENT_HANDLER: u16 = 0x3F;
pub const FRAME_INCOMING_ROUTE_RECORD_HANDLER: u16 = 0x59;
pub const FRAME_IMPORT_TRANSIENT_KEY: u16 = 0x0111;
pub const FRAME_ZIGBEE_KEY_ESTABLISHMENT_HANDLER: u16 = 0x9B;

/// EmberOutgoingMessageType.DIRECT — send straight to a node ID.
pub const OUTGOING_DIRECT: u8 = 0x00;

/// Broadcast destination reaching every rx-on-when-idle node (routers +
/// mains devices) — zigpy's default for ZDO broadcasts like NWK_addr_req.
/// Sleepy end devices don't hear it, but their PARENT answers address
/// requests on their behalf, so that's still sufficient for lookups.
pub const BROADCAST_RX_ON_WHEN_IDLE: u16 = 0xFFFD;
/// EmberApsOption: retry delivery + discover routes as needed — bellows'
/// baseline options for ordinary unicasts (0x0140 combined).
pub const APS_OPTION_RETRY: u16 = 0x0040;
pub const APS_OPTION_ENABLE_ROUTE_DISCOVERY: u16 = 0x0100;

/// EmberApsFrame — 11 bytes on the wire, field-by-field LE. Same layout in
/// sendUnicast requests and incomingMessageHandler callbacks.
pub const ApsFrame = struct {
    profile_id: u16,
    cluster_id: u16,
    source_endpoint: u8,
    destination_endpoint: u8,
    options: u16 = APS_OPTION_RETRY | APS_OPTION_ENABLE_ROUTE_DISCOVERY,
    group_id: u16 = 0,
    sequence: u8 = 0, // stack assigns the real APS sequence on send

    pub const WIRE_LEN = 11;

    fn serialize(self: *const ApsFrame, out: *[WIRE_LEN]u8) void {
        out[0] = @truncate(self.profile_id & 0xFF);
        out[1] = @truncate(self.profile_id >> 8);
        out[2] = @truncate(self.cluster_id & 0xFF);
        out[3] = @truncate(self.cluster_id >> 8);
        out[4] = self.source_endpoint;
        out[5] = self.destination_endpoint;
        out[6] = @truncate(self.options & 0xFF);
        out[7] = @truncate(self.options >> 8);
        out[8] = @truncate(self.group_id & 0xFF);
        out[9] = @truncate(self.group_id >> 8);
        out[10] = self.sequence;
    }

    fn parse(bytes: []const u8) !ApsFrame {
        if (bytes.len < WIRE_LEN) return error.FrameTooShort;
        return .{
            .profile_id = @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8),
            .cluster_id = @as(u16, bytes[2]) | (@as(u16, bytes[3]) << 8),
            .source_endpoint = bytes[4],
            .destination_endpoint = bytes[5],
            .options = @as(u16, bytes[6]) | (@as(u16, bytes[7]) << 8),
            .group_id = @as(u16, bytes[8]) | (@as(u16, bytes[9]) << 8),
            .sequence = bytes[10],
        };
    }
};
pub const FRAME_SET_INITIAL_SECURITY_STATE: u16 = 0x68;
/// Modern Zigbee Security Manager commands (EZSP v10+-ish) — some current
/// NCP firmware doesn't ship the legacy security library backing `getKey`
/// at all (see STATUS_LIBRARY_NOT_PRESENT) and requires these instead.
pub const FRAME_EXPORT_KEY: u16 = 0x0114;
pub const FRAME_GET_NETWORK_KEY_INFO: u16 = 0x0116;

/// Plain-language label for a callback frame id, used in the
/// interleaved-callback log line so the routine background chatter of a
/// live mesh (device reports, send confirmations, mesh route records)
/// reads as the ordinary events they are rather than looking like errors.
/// Unnamed frames fall back to "callback" and are shown with their id.
fn callbackDesc(frame_id: u16) []const u8 {
    return switch (frame_id) {
        FRAME_INCOMING_MESSAGE_HANDLER => "incoming msg received",
        FRAME_MESSAGE_SENT_HANDLER => "msg ack received",
        FRAME_INCOMING_ROUTE_RECORD_HANDLER => "route record received",
        FRAME_STACK_STATUS_HANDLER => "stack status update",
        FRAME_CHILD_JOIN_HANDLER => "child join",
        FRAME_TRUST_CENTER_JOIN_HANDLER => "trust-center join",
        FRAME_ZIGBEE_KEY_ESTABLISHMENT_HANDLER => "key establishment",
        else => "callback",
    };
}

/// SecurityManagerKeyType.NETWORK / legacy EMBER_CURRENT_NETWORK_KEY.
pub const KEY_TYPE_CURRENT_NETWORK_KEY: u8 = 0x01;

pub const STATUS_SUCCESS: u8 = 0x00;
/// The NCP has no network stored in NVM to resume (e.g. never joined, or
/// factory reset) — a real, expected outcome, not a protocol error.
pub const STATUS_NOT_JOINED: u8 = 0x93;
/// stackStatusHandler payload value meaning the stack finished (re)joining
/// or forming and is ready to send/receive.
pub const STATUS_NETWORK_UP: u8 = 0x90;
/// Legacy getKey's failure mode on NCPs that don't ship the classic
/// security-manager library — the modern Security Manager API is required.
pub const STATUS_LIBRARY_NOT_PRESENT: u8 = 0xB5;

/// EmberDeviceUpdate values carried in trustCenterJoinHandler.status — NOT
/// all "join" values; DEVICE_LEFT in particular means the opposite (the
/// device left the network), so callers must check this rather than
/// treating every trustCenterJoinHandler as a successful join.
pub const DEVICE_UPDATE_STANDARD_SECURITY_SECURED_REJOIN: u8 = 0x00;
pub const DEVICE_UPDATE_STANDARD_SECURITY_UNSECURED_JOIN: u8 = 0x01;
pub const DEVICE_UPDATE_DEVICE_LEFT: u8 = 0x02;
pub const DEVICE_UPDATE_STANDARD_SECURITY_UNSECURED_REJOIN: u8 = 0x03;
pub const DEVICE_UPDATE_HIGH_SECURITY_SECURED_REJOIN: u8 = 0x04;
pub const DEVICE_UPDATE_HIGH_SECURITY_UNSECURED_JOIN: u8 = 0x05;
pub const DEVICE_UPDATE_HIGH_SECURITY_UNSECURED_REJOIN: u8 = 0x07;

/// EzspPolicyId.TRUST_CENTER_POLICY — governs whether the NCP authorizes
/// devices to join.
pub const POLICY_TRUST_CENTER: u8 = 0x00;
/// EzspDecisionId.ALLOW_JOINS — authorize any joining device unconditionally,
/// sending the network key in the clear (no preconfigured-key requirement).
pub const DECISION_ALLOW_JOINS: u8 = 0x00;
/// EzspDecisionId.ALLOW_PRECONFIGURED_KEY_JOINS — bellows' actual default:
/// authorize joins that authenticate with the well-known TC link key
/// ("ZigBeeAlliance09", see DEFAULT_TC_LINK_KEY), matching how Zigbee 3.0
/// devices normally join. Use this rather than DECISION_ALLOW_JOINS.
pub const DECISION_ALLOW_PRECONFIGURED_KEY_JOINS: u8 = 0x01;

/// EZSP v8+ reinterprets the TRUST_CENTER policy value as an
/// EzspDecisionBitmask rather than the legacy decision enum. bellows'
/// `pre_permit` (v8+) sets ALLOW_JOINS | ALLOW_UNSECURED_REJOINS before
/// opening the network. The legacy enum value 0x01 happens to read as
/// bare ALLOW_JOINS under bitmask semantics — joins work, but devices
/// whose commissioning dance includes a trust-center (unsecured) rejoin
/// get denied at that step and leave: observed on real hardware as an
/// endless join/leave flap (Hue smart socket + a second bulb) while
/// secured-rejoin devices (the first bulb) settled fine.
pub const DECISION_BITMASK_ALLOW_JOINS: u8 = 0x01;
pub const DECISION_BITMASK_ALLOW_UNSECURED_REJOINS: u8 = 0x02;

/// EzspPolicyId.TC_KEY_REQUEST_POLICY — governs whether the NCP answers a
/// joined device's request for the current network key. Left at whatever
/// the firmware defaults to (unlike TRUST_CENTER_POLICY, we never set this)
/// this can silently sabotage joins: a device that joins fine at the MAC/NWK
/// layer but then gets denied when it requests the network key will leave
/// and retry — a join/leave flap that looks like instability but is really
/// a missing policy. Real-world symptom we hit: a device joined, generated
/// an `incomingMessageHandler` (0x45) shortly after, then immediately left
/// and rejoined, repeatedly.
pub const POLICY_TC_KEY_REQUEST: u8 = 0x05;
/// EzspDecisionId.ALLOW_TC_KEY_REQUESTS — bellows' actual default for
/// POLICY_TC_KEY_REQUEST.
pub const DECISION_ALLOW_TC_KEY_REQUESTS: u8 = 0x51;

/// EzspPolicyId.APP_KEY_REQUEST_POLICY — governs application (non-TC) link
/// key requests between devices. Not needed for basic join/control, but
/// set alongside TC_KEY_REQUEST_POLICY to match bellows' baseline exactly.
pub const POLICY_APP_KEY_REQUEST: u8 = 0x06;
/// EzspDecisionId.DENY_APP_KEY_REQUESTS — bellows' actual default for
/// POLICY_APP_KEY_REQUEST.
pub const DECISION_DENY_APP_KEY_REQUESTS: u8 = 0x60;

// EzspConfigId values that matter before networkInit/formNetwork — these
// size fixed internal NCP tables and can't be changed once the stack is
// running. bellows always applies these (as minimums for most) before
// touching the network; we never had, which plausibly explains a NCP that
// reports success on every join-related call yet never actually completes
// one (e.g. if its firmware default child-table size is too small).
pub const CONFIG_PACKET_BUFFER_COUNT: u16 = 0x01;
/// UG100: the most router neighbours the stack can keep track of.
pub const CONFIG_NEIGHBOR_TABLE_SIZE: u16 = 0x02;
pub const CONFIG_ADDRESS_TABLE_SIZE: u16 = 0x05;
pub const CONFIG_MULTICAST_TABLE_SIZE: u16 = 0x06;
pub const CONFIG_STACK_PROFILE: u16 = 0x0C;
pub const CONFIG_SECURITY_LEVEL: u16 = 0x0D;
pub const CONFIG_MAX_END_DEVICE_CHILDREN: u16 = 0x11;
pub const CONFIG_INDIRECT_TRANSMISSION_TIMEOUT: u16 = 0x12;
pub const CONFIG_TRUST_CENTER_ADDRESS_CACHE_SIZE: u16 = 0x19;
pub const CONFIG_SOURCE_ROUTE_TABLE_SIZE: u16 = 0x1A;
pub const CONFIG_KEY_TABLE_SIZE: u16 = 0x1E;
pub const CONFIG_SUPPORTED_NETWORKS: u16 = 0x2D;

/// Config values bellows sets before networkInit/formNetwork (its
/// DEFAULT_CONFIG for EZSP v7+, which covers our v13 device).
/// PACKET_BUFFER_COUNT is applied last on purpose (bellows does the same —
/// it's a "use whatever's left" value best set after the other tables are sized).
const DefaultConfigEntry = struct { config_id: u16, value: u16 };
const DEFAULT_CONFIG = [_]DefaultConfigEntry{
    .{ .config_id = CONFIG_STACK_PROFILE, .value = 2 },
    .{ .config_id = CONFIG_SECURITY_LEVEL, .value = 5 },
    .{ .config_id = CONFIG_SUPPORTED_NETWORKS, .value = 1 },
    .{ .config_id = CONFIG_MULTICAST_TABLE_SIZE, .value = 16 },
    .{ .config_id = CONFIG_TRUST_CENTER_ADDRESS_CACHE_SIZE, .value = 2 },
    .{ .config_id = CONFIG_ADDRESS_TABLE_SIZE, .value = 16 },
    .{ .config_id = CONFIG_KEY_TABLE_SIZE, .value = 4 },
    .{ .config_id = CONFIG_MAX_END_DEVICE_CHILDREN, .value = 32 },
    .{ .config_id = CONFIG_INDIRECT_TRANSMISSION_TIMEOUT, .value = 7680 },
    .{ .config_id = CONFIG_SOURCE_ROUTE_TABLE_SIZE, .value = 200 },
    .{ .config_id = CONFIG_PACKET_BUFFER_COUNT, .value = 0xFF },
};

const EXTENDED_FRAME_MIN_VERSION: u8 = 8;

// EmberInitialSecurityBitmask flags used when forming (mirrors bellows'
// zha_security(), non-hashed-TC-link-key path).
const SECURITY_BITMASK_HAVE_PRECONFIGURED_KEY: u16 = 0x0100;
const SECURITY_BITMASK_REQUIRE_ENCRYPTED_KEY: u16 = 0x0800;
const SECURITY_BITMASK_TRUST_CENTER_GLOBAL_LINK_KEY: u16 = 0x0004;
const SECURITY_BITMASK_HAVE_NETWORK_KEY: u16 = 0x0200;
const SECURITY_BITMASK_NO_FRAME_COUNTER_RESET: u16 = 0x1000;
/// EMBER_TRUST_CENTER_USES_HASHED_LINK_KEY (0x0084 — a multi-bit value in
/// Ember's headers, not a single flag). With this set, the NCP derives a
/// UNIQUE per-device TC link key by hashing the `preconfiguredKey` (used as
/// a hash seed, NOT handed to devices) with each device's EUI64. Devices
/// still JOIN with the well-known "ZigBeeAlliance09" key — the stack
/// special-cases that — but when a Zigbee 3.0 device requests its mandatory
/// post-join TC link key update, it receives its unique hashed key instead
/// of the well-known one. THIS IS REQUIRED for modern Hue firmware: without
/// it the update response contains the same well-known key, which strict
/// devices treat as a failed update and LEAVE (observed live as endless
/// join→announce→keyEstablishment(0x06 TC_RESPONDED_TO_KEY_REQUEST)→leave
/// loops). bellows forms with use_hashed_tclk=True by default — this is why
/// the same devices stayed joined under ZHA/zigpy.
const SECURITY_BITMASK_TC_USES_HASHED_LINK_KEY: u16 = 0x0084;

/// The well-known default Zigbee HA/ZLL trust center link key, ASCII
/// "ZigBeeAlliance09" — used as the (unhashed) preconfigured TC link key.
pub const DEFAULT_TC_LINK_KEY: [16]u8 = "ZigBeeAlliance09".*;

pub const VersionInfo = struct {
    protocol_version: u8,
    stack_type: u8,
    stack_version: u16,
};

/// `EzspValueId`. **0x23 independently confirmed in two Silicon Labs docs**
/// (the current API guide's `SL_ZIGBEE_EZSP_VALUE_NWK_FRAME_COUNTER`, and
/// UG100's `EZSP_VALUE_NWK_FRAME_COUNTER`) — worth the check, since a wrong
/// id here writes some *other* NCP value.
///
/// The stack call behind it, `sl_zigbee_set_outgoing_nwk_frame_counter`, is
/// documented as "intended for device restoration purposes" and carries
/// three constraints that shape `Coordinator.restoreNetwork`:
///   - callable **only with no network** (before networkInit/form/join);
///   - **before** `setInitialSecurityState`;
///   - `NO_FRAME_COUNTER_RESET` must be in the security bitmask, or the
///     counter is reset right back (hub's bitmask already carries it —
///     `buildSecurityStateParams`).
pub const VALUE_NWK_FRAME_COUNTER: u8 = 0x23;
/// The APS counterpart. Deliberately unused: the doc says the stack manages
/// it and "users should not set these unless doing backup and restore" —
/// which is us, but hub's backup doesn't capture it (`getCurrentNetworkKey`
/// reports the NWK counter only). A known gap, not a silent one.
pub const VALUE_APS_FRAME_COUNTER: u8 = 0x24;

/// `EzspStatus` (UG100 p.1322+) — the status byte getValue/setValue answer
/// with. Distinct from `EmberStatus`, which most other commands return.
pub const EZSP_STATUS_SUCCESS: u8 = 0x00;
pub const EZSP_ERROR_INVALID_VALUE: u8 = 0x36;
pub const EZSP_ERROR_INVALID_ID: u8 = 0x37;
pub const EZSP_ERROR_INVALID_CALL: u8 = 0x38;

pub const NetworkParameters = struct {
    extended_pan_id: [8]u8, // wire order; caller reverses to display MSB-first
    pan_id: u16,
    radio_channel: u8,
    nwk_update_id: u8,
    channel_mask: u32, // bit N set => channel N present (N in 11..26)
};

pub const KeyInfo = struct {
    key: [16]u8, // wire order, displayed as-is (unlike EUI64-family types)
    sequence_number: u8,
    outgoing_frame_counter: u32,
};

/// Parameters for forming a brand-new network. Callers (not this module)
/// are responsible for randomizing pan_id/extended_pan_id/network_key —
/// mirrors zigpy's own `form_network`, which generates these host-side and
/// passes explicit values down to the radio library.
pub const FormNetworkParams = struct {
    extended_pan_id: [8]u8,
    pan_id: u16,
    radio_channel: u8,
    network_key: [16]u8,
    network_key_sequence: u8 = 0,
    tx_power: i8 = 8,
};

pub const TrustCenterJoinEvent = struct {
    new_node_id: u16,
    new_node_eui64: [8]u8, // wire order; reverse to display MSB-first
    status: u8, // EmberDeviceUpdate
    policy_decision: u8, // EmberJoinDecision
    parent_of_new_node_id: u16,
};

pub const ChildJoinEvent = struct {
    joining: bool,
    child_id: u16,
    child_eui64: [8]u8, // wire order; reverse to display MSB-first
    child_type: u8, // EmberNodeType
};

/// An incoming APS message delivered via incomingMessageHandler (0x45) —
/// the receive half of all ZDO/ZCL traffic. `contents` is copied out of the
/// callback frame (fixed buffer, no allocation); `contents_len` bounds it.
pub const IncomingMessage = struct {
    message_type: u8, // EmberIncomingMessageType (unicast=0x00, broadcast=0x04, ...)
    aps: ApsFrame,
    last_hop_lqi: u8,
    last_hop_rssi: i8,
    sender: u16,
    contents_len: usize,
    contents: [MAX_CALLBACK_PAYLOAD]u8,

    pub fn payload(self: *const IncomingMessage) []const u8 {
        return self.contents[0..self.contents_len];
    }
};

/// zigbeeKeyEstablishmentHandler (0x9B): the NCP's report of how a
/// post-join key exchange ended for a partner device — the decisive
/// diagnostic for devices that join at the MAC/NWK layer and then leave.
/// `status` is an EmberKeyStatus code.
pub const KeyEstablishmentEvent = struct {
    partner: [8]u8, // wire order
    status: u8,
};

/// A decoded unsolicited NCP callback frame. `unknown` covers every EZSP
/// callback we don't have a typed decoder for yet — callers can still see
/// its frame ID for logging/diagnostics.
pub const Callback = union(enum) {
    stack_status: u8, // raw EmberStatus
    trust_center_join: TrustCenterJoinEvent,
    child_join: ChildJoinEvent,
    incoming_message: IncomingMessage,
    key_establishment: KeyEstablishmentEvent,
    unknown: struct { frame_id: u16, payload_len: usize },
};

fn parseKeyEstablishment(payload: []const u8) !KeyEstablishmentEvent {
    if (payload.len < 9) return error.FrameTooShort;
    var ev: KeyEstablishmentEvent = undefined;
    std.mem.copyForwards(u8, &ev.partner, payload[0..8]);
    ev.status = payload[8];
    return ev;
}

/// incomingMessageHandler payload: type(1) + ApsFrame(11) + lastHopLqi(1) +
/// lastHopRssi(1) + sender(u16 LE) + bindingIndex(1) + addressIndex(1) +
/// messageContents(LVBytes: 1-byte length + bytes) = 19 bytes + contents.
fn parseIncomingMessage(payload: []const u8) !IncomingMessage {
    if (payload.len < 19) return error.FrameTooShort;
    var msg: IncomingMessage = undefined;
    msg.message_type = payload[0];
    msg.aps = try ApsFrame.parse(payload[1..12]);
    msg.last_hop_lqi = payload[12];
    msg.last_hop_rssi = @bitCast(payload[13]);
    msg.sender = @as(u16, payload[14]) | (@as(u16, payload[15]) << 8);
    // payload[16] bindingIndex, payload[17] addressIndex — unused
    const contents_len: usize = payload[18];
    if (payload.len < 19 + contents_len) return error.FrameTooShort;
    if (contents_len > msg.contents.len) {
        std.log.warn("BufferTooSmall@ezsp.parseIncomingMessage: contents_len={d} cap={d}", .{ contents_len, msg.contents.len });
        return error.BufferTooSmall;
    }
    std.mem.copyForwards(u8, msg.contents[0..contents_len], payload[19 .. 19 + contents_len]);
    msg.contents_len = contents_len;
    return msg;
}

fn buildHeader(seq: u8, frame_id: u16, extended: bool, out: []u8) usize {
    if (extended) {
        out[0] = seq;
        out[1] = 0x00;
        out[2] = 0x01;
        out[3] = @truncate(frame_id & 0xFF);
        out[4] = @truncate(frame_id >> 8);
        return 5;
    } else {
        out[0] = seq;
        out[1] = 0x00;
        out[2] = @truncate(frame_id & 0xFF);
        return 3;
    }
}

const ParsedHeader = struct {
    frame_id: u16,
    payload_offset: usize,
    /// Direction: true = NCP→host (a command response or a callback),
    /// false = host→NCP (a command — i.e. one of OURS, which must never be
    /// mistaken for a reply; see `FRAME_CONTROL_RESPONSE`).
    is_response: bool,
};

/// Bit 7 of the frame-control byte (the LOW byte of the two-byte control in
/// extended framing): set on everything the NCP sends, clear on everything
/// the host sends. **Hardware-confirmed on the ZBT-2 (2026-07-16), both
/// framings**: every genuine response observed across a full bootstrap
/// carried `fc_low = 0x80` (one `0x84`), and the legacy v4 version probe's
/// response carried `fc = 0x80` — while an echoed frame carrying our own
/// command bytes carried `0x00`. That echo is why this bit is checked at
/// all: see `call`.
const FRAME_CONTROL_RESPONSE: u8 = 0x80;

fn parseHeader(data: []const u8, extended: bool) !ParsedHeader {
    if (extended) {
        if (data.len < 5) return error.FrameTooShort;
        return .{
            .frame_id = @as(u16, data[3]) | (@as(u16, data[4]) << 8),
            .payload_offset = 5,
            .is_response = data[1] & FRAME_CONTROL_RESPONSE != 0,
        };
    } else {
        if (data.len < 3) return error.FrameTooShort;
        return .{
            .frame_id = data[2],
            .payload_offset = 3,
            .is_response = data[1] & FRAME_CONTROL_RESPONSE != 0,
        };
    }
}

fn buildSecurityStateParams(network_key: [16]u8, network_key_sequence: u8, tclk_hash_seed: [16]u8) [43]u8 {
    const bitmask: u16 = SECURITY_BITMASK_HAVE_PRECONFIGURED_KEY |
        SECURITY_BITMASK_REQUIRE_ENCRYPTED_KEY |
        SECURITY_BITMASK_TRUST_CENTER_GLOBAL_LINK_KEY |
        SECURITY_BITMASK_HAVE_NETWORK_KEY |
        SECURITY_BITMASK_NO_FRAME_COUNTER_RESET |
        SECURITY_BITMASK_TC_USES_HASHED_LINK_KEY;

    var params: [43]u8 = undefined;
    params[0] = @truncate(bitmask & 0xFF);
    params[1] = @truncate(bitmask >> 8);
    // In hashed-TCLK mode the preconfiguredKey field carries the RANDOM
    // hash seed (bellows: os.urandom(16)); the well-known join key is
    // implied by the mode, not written here.
    std.mem.copyForwards(u8, params[2..18], &tclk_hash_seed);
    std.mem.copyForwards(u8, params[18..34], &network_key);
    params[34] = network_key_sequence;
    @memset(params[35..43], 0); // preconfiguredTrustCenterEui64: unknown
    return params;
}

fn buildFormNetworkParams(params: FormNetworkParams) [20]u8 {
    var req: [20]u8 = undefined;
    std.mem.copyForwards(u8, req[0..8], &params.extended_pan_id);
    req[8] = @truncate(params.pan_id & 0xFF);
    req[9] = @truncate(params.pan_id >> 8);
    req[10] = @bitCast(params.tx_power);
    req[11] = params.radio_channel;
    req[12] = 0; // joinMethod: USE_MAC_ASSOCIATION
    req[13] = 0; // nwkManagerId lo: coordinator manages itself
    req[14] = 0; // nwkManagerId hi
    req[15] = 0; // nwkUpdateId
    const channel_mask: u32 = @as(u32, 1) << @intCast(params.radio_channel);
    req[16] = @truncate(channel_mask & 0xFF);
    req[17] = @truncate((channel_mask >> 8) & 0xFF);
    req[18] = @truncate((channel_mask >> 16) & 0xFF);
    req[19] = @truncate((channel_mask >> 24) & 0xFF);
    return req;
}

/// A response whose first parameter is the one wanted.
fn firstByte(resp: []const u8) !u8 {
    if (resp.len < 1) return error.FrameTooShort;
    return resp[0];
}

test "a count is a response's first byte, and an empty one is refused" {
    try std.testing.expectEqual(@as(u8, 3), try firstByte(&.{ 3, 0xff, 0xff }));
    try std.testing.expectError(error.FrameTooShort, firstByte(&.{}));
}

fn parseNetworkParameters(resp: []const u8) !NetworkParameters {
    if (resp.len < 22) return error.FrameTooShort;
    if (resp[0] != 0) {
        std.log.err("getNetworkParameters: NCP status=0x{x:0>2} nodeType=0x{x:0>2}", .{ resp[0], resp[1] });
        return error.NcpStatusError;
    }

    var params: NetworkParameters = undefined;
    std.mem.copyForwards(u8, &params.extended_pan_id, resp[2..10]);
    params.pan_id = @as(u16, resp[10]) | (@as(u16, resp[11]) << 8);
    params.radio_channel = resp[13];
    params.nwk_update_id = resp[17];
    params.channel_mask = @as(u32, resp[18]) | (@as(u32, resp[19]) << 8) | (@as(u32, resp[20]) << 16) | (@as(u32, resp[21]) << 24);
    return params;
}

fn parseKeyInfo(resp: []const u8) !KeyInfo {
    if (resp.len < 37) return error.FrameTooShort;
    if (resp[0] != 0) return error.NcpStatusError;

    var info: KeyInfo = undefined;
    std.mem.copyForwards(u8, &info.key, resp[4..20]);
    info.outgoing_frame_counter = @as(u32, resp[20]) | (@as(u32, resp[21]) << 8) | (@as(u32, resp[22]) << 16) | (@as(u32, resp[23]) << 24);
    info.sequence_number = resp[28];
    return info;
}

/// SecurityManagerContextV13 struct: core_key_type(1) + key_index(1) +
/// derived_type(1) + eui64(8) + multi_network_index(1) + flags(1) +
/// psa_key_alg_permission(4) = 17 bytes. Requests the plain (non-derived)
/// current network key, no multi-network/PSA-algorithm restrictions.
fn buildExportKeyContext() [17]u8 {
    var ctx: [17]u8 = undefined;
    ctx[0] = KEY_TYPE_CURRENT_NETWORK_KEY; // core_key_type = NETWORK
    ctx[1] = 0; // key_index
    ctx[2] = 0; // derived_type = NONE
    @memset(ctx[3..11], 0); // eui64: unused for the network key
    ctx[11] = 0; // multi_network_index
    ctx[12] = 0; // flags
    @memset(ctx[13..17], 0); // psa_key_alg_permission
    return ctx;
}

fn parseExportKeyResponse(resp: []const u8) ![16]u8 {
    if (resp.len < 20) return error.FrameTooShort;
    const status = @as(u32, resp[16]) | (@as(u32, resp[17]) << 8) | (@as(u32, resp[18]) << 16) | (@as(u32, resp[19]) << 24);
    if (status != 0) return error.NcpStatusError;
    var key: [16]u8 = undefined;
    std.mem.copyForwards(u8, &key, resp[0..16]);
    return key;
}

const NetworkKeyMeta = struct {
    sequence_number: u8,
    frame_counter: u32,
};

fn parseNetworkKeyInfoResponse(resp: []const u8) !NetworkKeyMeta {
    if (resp.len < 12) return error.FrameTooShort;
    const status = @as(u32, resp[0]) | (@as(u32, resp[1]) << 8) | (@as(u32, resp[2]) << 16) | (@as(u32, resp[3]) << 24);
    if (status != 0) return error.NcpStatusError;
    return .{
        .sequence_number = resp[6],
        .frame_counter = @as(u32, resp[8]) | (@as(u32, resp[9]) << 8) | (@as(u32, resp[10]) << 16) | (@as(u32, resp[11]) << 24),
    };
}

/// Serializes an EZSP addEndpoint request body. Cluster lists are bare
/// back-to-back u16 LE values — NOT length-prefixed; the explicit count
/// fields are the lengths (bellows encodes `t.List[t.uint16_t]` unprefixed
/// here, unlike `LVBytes`).
fn buildAddEndpointParams(
    endpoint: u8,
    profile_id: u16,
    device_id: u16,
    device_version: u8,
    input_clusters: []const u16,
    output_clusters: []const u16,
    out: []u8,
) ![]const u8 {
    const needed = 8 + 2 * (input_clusters.len + output_clusters.len);
    if (needed > out.len) {
        std.log.warn("BufferTooSmall@ezsp.registerEndpoint/params: needed={d} out={d}", .{ needed, out.len });
        return error.BufferTooSmall;
    }

    var n: usize = 0;
    out[n] = endpoint;
    n += 1;
    out[n] = @truncate(profile_id & 0xFF);
    out[n + 1] = @truncate(profile_id >> 8);
    n += 2;
    out[n] = @truncate(device_id & 0xFF);
    out[n + 1] = @truncate(device_id >> 8);
    n += 2;
    out[n] = device_version;
    n += 1;
    out[n] = @intCast(input_clusters.len);
    n += 1;
    out[n] = @intCast(output_clusters.len);
    n += 1;
    for (input_clusters) |c| {
        out[n] = @truncate(c & 0xFF);
        out[n + 1] = @truncate(c >> 8);
        n += 2;
    }
    for (output_clusters) |c| {
        out[n] = @truncate(c & 0xFF);
        out[n + 1] = @truncate(c >> 8);
        n += 2;
    }
    return out[0..n];
}

fn parseTrustCenterJoinEvent(payload: []const u8) !TrustCenterJoinEvent {
    if (payload.len < 14) return error.FrameTooShort;
    var event: TrustCenterJoinEvent = undefined;
    event.new_node_id = @as(u16, payload[0]) | (@as(u16, payload[1]) << 8);
    std.mem.copyForwards(u8, &event.new_node_eui64, payload[2..10]);
    event.status = payload[10];
    event.policy_decision = payload[11];
    event.parent_of_new_node_id = @as(u16, payload[12]) | (@as(u16, payload[13]) << 8);
    return event;
}

fn parseChildJoinEvent(payload: []const u8) !ChildJoinEvent {
    if (payload.len < 13) return error.FrameTooShort;
    var event: ChildJoinEvent = undefined;
    event.joining = payload[1] != 0;
    event.child_id = @as(u16, payload[2]) | (@as(u16, payload[3]) << 8);
    std.mem.copyForwards(u8, &event.child_eui64, payload[4..12]);
    event.child_type = payload[12];
    return event;
}

/// EZSP client over an ASH transport. Handles version negotiation (which
/// determines legacy vs extended frame headers) and the specific commands
/// needed to assemble `radio info`-style output.
pub const Client = struct {
    transport: *Ash.Transport,
    seq: u8 = 0,
    extended: bool = false,
    // Callback frames that arrive interleaved while `call` is waiting for a
    // command response are QUEUED here for `pollCallback` to drain, not
    // dropped — dropping them lost real data (a ZDO Active_EP_rsp arriving
    // during the next request's `call` window vanished, timing out
    // discovery). Small ring buffer; oldest is discarded (with a warning)
    // on overflow.
    queued: [CALLBACK_QUEUE_CAP][MAX_CALLBACK_PAYLOAD]u8 = undefined,
    queued_lens: [CALLBACK_QUEUE_CAP]usize = undefined,
    queue_head: usize = 0,
    queue_count: usize = 0,

    // Sized to hold a full skip-burst (see `call`'s bound) so a dial-spin
    // flood doesn't force us to drop queued callbacks mid-skip.
    const CALLBACK_QUEUE_CAP = 32;

    /// Clears every scrap of pre-reset protocol state, for reuse across an
    /// NCP reset. The `*Transport` is NOT
    /// touched — `Link.rehandshake` rebuilds that value in place, through
    /// the same address, so this client's pointer stays valid.
    ///
    /// What has to go, and why:
    ///   - `seq`: the NCP restarts its own sequence numbering after a reset,
    ///     so ours must too or every response looks out of order;
    ///   - `extended`: re-derived by the next `negotiateVersion`. Starting
    ///     from `false` is not a guess — it's the same legacy-first probe
    ///     bootstrap does, and the NCP speaks v4 framing until told
    ///     otherwise;
    ///   - the queued-callback ring: those frames were decoded from the
    ///     network we just lost. Replaying them post-reset would inject
    ///     stale events (a device announce from a dead session, a ZDO reply
    ///     nobody is waiting for any more) into a fresh stack.
    pub fn reset(self: *Client) void {
        self.seq = 0;
        self.extended = false;
        self.queue_head = 0;
        self.queue_count = 0;
    }

    pub fn init(transport: *Ash.Transport) Client {
        return .{ .transport = transport };
    }

    fn enqueueCallbackFrame(self: *Client, frame: []const u8) void {
        if (frame.len > MAX_CALLBACK_PAYLOAD) {
            std.log.warn("enqueueCallbackFrame: dropping oversized frame ({d} bytes)", .{frame.len});
            return;
        }
        if (self.queue_count == CALLBACK_QUEUE_CAP) {
            std.log.warn("enqueueCallbackFrame: queue full — dropping oldest queued callback", .{});
            self.queue_head = (self.queue_head + 1) % CALLBACK_QUEUE_CAP;
            self.queue_count -= 1;
        }
        const slot = (self.queue_head + self.queue_count) % CALLBACK_QUEUE_CAP;
        std.mem.copyForwards(u8, self.queued[slot][0..frame.len], frame);
        self.queued_lens[slot] = frame.len;
        self.queue_count += 1;
    }

    /// Pops the oldest queued callback frame into `out`, or returns null.
    fn dequeueCallbackFrame(self: *Client, out: []u8) ?[]const u8 {
        if (self.queue_count == 0) return null;
        const len = self.queued_lens[self.queue_head];
        std.mem.copyForwards(u8, out[0..len], self.queued[self.queue_head][0..len]);
        self.queue_head = (self.queue_head + 1) % CALLBACK_QUEUE_CAP;
        self.queue_count -= 1;
        return out[0..len];
    }

    fn call(self: *Client, frame_id: u16, params: []const u8, out: []u8) ![]const u8 {
        var header: [5]u8 = undefined;
        const hlen = buildHeader(self.seq, frame_id, self.extended, &header);
        self.seq +%= 1;

        var request: [144]u8 = undefined; // ASH transport caps EZSP frames at 140 (MAX_EZSP_PAYLOAD); header + params must fit
        if (hlen + params.len > request.len) {
            std.log.warn("BufferTooSmall@ezsp.call/request: hlen={d} params={d} request={d} frame_id=0x{x:0>4}", .{ hlen, params.len, request.len, frame_id });
            return error.BufferTooSmall;
        }
        std.mem.copyForwards(u8, request[0..hlen], header[0..hlen]);
        std.mem.copyForwards(u8, request[hlen .. hlen + params.len], params);

        var response_buf: [160]u8 = undefined;
        var response = try self.transport.exchange(request[0 .. hlen + params.len], &response_buf);
        var parsed = try parseHeader(response, self.extended);

        // Under real traffic (devices joining, inter-PAN scan responses
        // arriving), unsolicited callback frames can interleave between our
        // request and its response — the next DATA frame is NOT guaranteed
        // to be the reply. Skip past a bounded number of them rather than
        // misparsing a callback as the response (this bit us for real:
        // touchlink-reset crashed with UnexpectedResponse mid-channel-cycle
        // the moment the target started answering our scans).
        //
        // The match requires the frame to be a RESPONSE as well as to carry
        // our frame id. Matching on the id alone is not enough, and this is
        // hardware-proven, not theoretical: under a dimmer-mash callback
        // flood this NCP emits a frame carrying OUR OWN command bytes back
        // — same seq, same frame id, our parameters, arriving as a clean
        // in-sequence ASH DATA frame (no CRC/out-of-sequence warnings). Its
        // only distinguishing mark is the direction bit
        // (`FRAME_CONTROL_RESPONSE`). Without this check the echo satisfied
        // `parsed.frame_id == frame_id` and was returned as the reply: for
        // sendUnicast its 19-byte payload overflowed the 2-byte reply
        // buffer and surfaced as `error.BufferTooSmall` — the LUCKY case.
        // Had the echoed payload been small enough to fit, our own request
        // bytes would have been handed back as the NCP's status/sequence:
        // a silently wrong answer. Why the NCP echoes at all is unexplained
        // (NCP-side, not visible from here); that it must never be taken
        // for a response is not in doubt.
        var skips: u16 = 0;
        while (!parsed.is_response or parsed.frame_id != frame_id) : (skips += 1) {
            // Generous bound: a real device join bursts a dozen-plus
            // callbacks (route records, join events) between our request
            // and its response — 8 proved too small, then 32 was tripped by
            // a fast Hue-dial spin (each detent = a genLevelCtrl step + a
            // rotation notification + route records, all inbound at once).
            // 64 clears that; the flood is finite (a human spinning a dial).
            if (skips >= 64) return error.UnexpectedResponse;
            if (parsed.is_response) {
                // A real NCP-originated frame, just not the one we're
                // waiting for. Queue it for pollCallback rather than
                // dropping it — it may be exactly the ZDO/ZCL response some
                // caller is polling for.
                std.log.debug("ncp: {s} (0x{x:0>4}) while a command was in flight", .{ callbackDesc(parsed.frame_id), parsed.frame_id });
                self.enqueueCallbackFrame(response);
            } else {
                // The echo described above. Not a callback — it's our own
                // command coming back — so it must NOT go into the callback
                // queue for pollCallback to try to decode. Drop it, and say
                // so: this is rare and worth seeing in the log if it ever
                // becomes frequent.
                std.log.warn("call: dropped echoed command-direction frame_id=0x{x:0>4} (len={d}) while waiting for 0x{x:0>4}", .{ parsed.frame_id, response.len, frame_id });
            }
            response = self.transport.receiveCallback(&response_buf, 3) catch |err| switch (err) {
                error.CallbackTimeout => return error.UnexpectedResponse,
                else => return err,
            };
            parsed = try parseHeader(response, self.extended);
        }

        const payload = response[parsed.payload_offset..];
        if (payload.len > out.len) {
            // Head bytes copied out one scalar at a time: `{x:0>2}` on a
            // SLICE is a runtime panic in this Zig (Writer's
            // optionsForbidden asserts width == null for that value type),
            // and a bad format string in a rarely-hit error path only
            // detonates once that path fires — which is exactly what
            // happened the first time this line ran on real hardware.
            var head: [8]u8 = @splat(0);
            const hn = @min(response.len, head.len);
            @memcpy(head[0..hn], response[0..hn]);
            std.log.warn("BufferTooSmall@ezsp.call/response: payload={d} out={d} frame_id=0x{x:0>4} skips={d} response_len={d} extended={} head={x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2}", .{ payload.len, out.len, frame_id, skips, response.len, self.extended, head[0], head[1], head[2], head[3], head[4], head[5], head[6], head[7] });
            return error.BufferTooSmall;
        }
        std.mem.copyForwards(u8, out[0..payload.len], payload);
        return out[0..payload.len];
    }

    /// Negotiates the EZSP protocol version: probes with the legacy baseline
    /// (v4), then if the NCP reports something higher, switches header
    /// format (extended framing kicks in at v8+) and re-sends `version` in
    /// the new format, as EZSP requires.
    pub fn negotiateVersion(self: *Client) !VersionInfo {
        var out: [8]u8 = undefined;
        var resp = try self.call(FRAME_VERSION, &.{4}, &out);
        if (resp.len < 4) return error.FrameTooShort;
        const reported = resp[0];

        if (reported != 4) {
            self.extended = reported >= EXTENDED_FRAME_MIN_VERSION;
            resp = try self.call(FRAME_VERSION, &.{reported}, &out);
            if (resp.len < 4) return error.FrameTooShort;
        }

        return .{
            .protocol_version = resp[0],
            .stack_type = resp[1],
            .stack_version = @as(u16, resp[2]) | (@as(u16, resp[3]) << 8),
        };
    }

    /// Sets a single EZSP config value. Returns the raw NCP status rather
    /// than erroring, since some values are only writable as a "raise the
    /// minimum" (real firmware may reject a redundant write) — callers
    /// applying a batch of these should treat non-success as advisory, not
    /// fatal. Must be called before `networkInit`/`formNetwork`: these size
    /// fixed internal tables and can't change once the stack is running.
    pub fn setConfigurationValue(self: *Client, config_id: u16, value: u16) !u8 {
        const params = [_]u8{ @truncate(config_id & 0xFF), @truncate(value & 0xFF), @truncate(value >> 8) };
        var out: [4]u8 = undefined;
        const resp = try self.call(FRAME_SET_CONFIGURATION_VALUE, &params, &out);
        if (resp.len < 1) return error.FrameTooShort;
        return resp[0];
    }

    /// Reads back a single EZSP config value's value actually in effect on
    /// the NCP — distinct from what we last tried to set via
    /// `setConfigurationValue`, since some values silently fail to apply on
    /// this firmware (status 0x35/0x37) and fall back to whatever the
    /// firmware default is.
    pub fn getConfigurationValue(self: *Client, config_id: u16) !struct { status: u8, value: u16 } {
        const params = [_]u8{@truncate(config_id & 0xFF)};
        var out: [4]u8 = undefined;
        const resp = try self.call(FRAME_GET_CONFIGURATION_VALUE, &params, &out);
        if (resp.len < 3) return error.FrameTooShort;
        return .{ .status = resp[0], .value = @as(u16, resp[1]) | (@as(u16, resp[2]) << 8) };
    }

    /// Applies bellows' DEFAULT_CONFIG (table sizes etc. that matter for
    /// actually being able to accept a joining device — see DEFAULT_CONFIG's
    /// doc comment). Must run before `networkInit`/`formNetwork`. Logs but
    /// doesn't fail on individual non-success statuses, matching bellows'
    /// own "best effort" treatment of these.
    pub fn applyDefaultConfig(self: *Client) !void {
        for (DEFAULT_CONFIG) |entry| {
            const status = try self.setConfigurationValue(entry.config_id, entry.value);
            if (status != STATUS_SUCCESS) {
                std.log.warn("setConfigurationValue(0x{x:0>2}, {d}): NCP status=0x{x:0>2}", .{ entry.config_id, entry.value, status });
            }
        }
    }

    /// Registers an application endpoint on the NCP (EZSP addEndpoint).
    /// Like the config values, endpoints are RAM-only: they're forgotten on
    /// every NCP reset and can only be added *before* the network comes up
    /// (after NETWORK_UP the NCP rejects this with an invalid-call status),
    /// so this must run between `negotiateVersion` and
    /// `networkInit`/`formNetwork`, every session. Response is a 1-byte
    /// EzspStatus (0x00 = success), returned raw.
    pub fn addEndpoint(
        self: *Client,
        endpoint: u8,
        profile_id: u16,
        device_id: u16,
        device_version: u8,
        input_clusters: []const u16,
        output_clusters: []const u16,
    ) !u8 {
        var params: [56]u8 = undefined;
        const req = try buildAddEndpointParams(endpoint, profile_id, device_id, device_version, input_clusters, output_clusters, &params);
        var out: [4]u8 = undefined;
        const resp = try self.call(FRAME_ADD_ENDPOINT, req, &out);
        if (resp.len < 1) return error.FrameTooShort;
        return resp[0];
    }

    /// Registers the same default coordinator endpoints zigpy's
    /// `register_endpoints` does (and ZHA therefore always runs with):
    /// endpoint 1 on the ZHA profile with a standard cluster set, and
    /// endpoint 2 on the ZLL profile. Without any registered endpoint the
    /// coordinator is mute at the application layer — devices that join and
    /// then query it (ZDO/match-descriptor traffic immediately after
    /// association) get no answer, which is suspected (not yet proven) to
    /// make them give up and re-associate from scratch repeatedly (the
    /// "join storm"). Statuses are logged but not fatal, matching our
    /// best-effort treatment of the config bootstrap.
    pub fn registerEndpoints(self: *Client) !void {
        // Endpoint 1: ZHA profile 0x0104, device type 0x0400 (IAS Control),
        // clusters Basic/OnOff/Time/OTA/IasAce in, PowerConfig/PollControl/
        // IasZone/IasWd out — verbatim from zigpy application.py.
        const s1 = try self.addEndpoint(1, 0x0104, 0x0400, 0, &.{ 0x0000, 0x0006, 0x000A, 0x0019, 0x0501 }, &.{ 0x0001, 0x0020, 0x0500, 0x0502 });
        if (s1 != STATUS_SUCCESS) {
            std.log.warn("addEndpoint(1): NCP status=0x{x:0>2}", .{s1});
        }
        // Endpoint 2: ZLL profile 0xC05E, device type 0x0820 (controller).
        const s2 = try self.addEndpoint(2, 0xC05E, 0x0820, 0, &.{0x0000}, &.{});
        if (s2 != STATUS_SUCCESS) {
            std.log.warn("addEndpoint(2): NCP status=0x{x:0>2}", .{s2});
        }
    }

    /// Tells the NCP to resume the network it has stored in NVM. Required
    /// after a reset — getNetworkParameters/getKey report STATUS_NOT_JOINED
    /// until this is called, even on a device with an established network,
    /// since a reset doesn't auto-rejoin. Returns the raw NCP status byte
    /// rather than erroring on non-success, since STATUS_NOT_JOINED is a
    /// legitimate outcome (no network stored) that callers may want to
    /// handle gracefully rather than treat as fatal.
    pub fn networkInit(self: *Client) !u8 {
        var out: [4]u8 = undefined;
        const resp = try self.call(FRAME_NETWORK_INIT, &.{}, &out);
        if (resp.len < 1) return error.FrameTooShort;
        return resp[0];
    }

    pub fn getEui64(self: *Client) ![8]u8 {
        var out: [8]u8 = undefined;
        const resp = try self.call(FRAME_GET_EUI64, &.{}, &out);
        if (resp.len < 8) return error.FrameTooShort;
        var eui: [8]u8 = undefined;
        std.mem.copyForwards(u8, &eui, resp[0..8]);
        return eui;
    }

    pub fn getNodeId(self: *Client) !u16 {
        var out: [4]u8 = undefined;
        const resp = try self.call(FRAME_GET_NODE_ID, &.{}, &out);
        if (resp.len < 2) return error.FrameTooShort;
        return @as(u16, resp[0]) | (@as(u16, resp[1]) << 8);
    }

    /// Reads an NCP value by id into `out`. Read-only and harmless for an
    /// unknown id (the NCP answers `EZSP_ERROR_INVALID_ID` rather than
    /// doing anything), which makes it the safe way to confirm a value id
    /// means what a doc claims before writing to it.
    pub fn getValue(self: *Client, value_id: u8, out: []u8) ![]const u8 {
        var resp_buf: [80]u8 = undefined;
        const resp = try self.call(FRAME_GET_VALUE, &.{value_id}, &resp_buf);
        if (resp.len < 2) return error.FrameTooShort;
        if (resp[0] != EZSP_STATUS_SUCCESS) {
            std.log.warn("getValue(0x{x:0>2}): EzspStatus=0x{x:0>2}", .{ value_id, resp[0] });
            return error.NcpStatusError;
        }
        const len: usize = resp[1];
        if (resp.len < 2 + len) return error.FrameTooShort;
        if (len > out.len) return error.BufferTooSmall;
        std.mem.copyForwards(u8, out[0..len], resp[2 .. 2 + len]);
        return out[0..len];
    }

    /// Writes an NCP value by id. Every caller should know exactly why —
    /// see `VALUE_NWK_FRAME_COUNTER`'s constraints for the one hub uses.
    pub fn setValue(self: *Client, value_id: u8, value: []const u8) !void {
        var params: [72]u8 = undefined;
        if (value.len + 2 > params.len) return error.BufferTooSmall;
        params[0] = value_id;
        params[1] = @intCast(value.len);
        std.mem.copyForwards(u8, params[2 .. 2 + value.len], value);
        var out: [4]u8 = undefined;
        const resp = try self.call(FRAME_SET_VALUE, params[0 .. 2 + value.len], &out);
        if (resp.len < 1) return error.FrameTooShort;
        if (resp[0] != EZSP_STATUS_SUCCESS) {
            std.log.err("setValue(0x{x:0>2}): EzspStatus=0x{x:0>2}{s}", .{ value_id, resp[0], switch (resp[0]) {
                EZSP_ERROR_INVALID_CALL => " (INVALID_CALL — wrong stack state? the frame counter can only be set with NO network)",
                EZSP_ERROR_INVALID_ID => " (INVALID_ID — the NCP doesn't know this value id)",
                EZSP_ERROR_INVALID_VALUE => " (INVALID_VALUE — out of bounds)",
                else => "",
            } });
            return error.NcpStatusError;
        }
    }

    /// The live NWK outgoing frame counter, read back from the NCP.
    pub fn getNwkFrameCounter(self: *Client) !u32 {
        var buf: [8]u8 = undefined;
        const v = try self.getValue(VALUE_NWK_FRAME_COUNTER, &buf);
        if (v.len != 4) return error.UnexpectedResponse;
        return std.mem.readInt(u32, v[0..4], .little);
    }

    /// Restores the NWK outgoing frame counter. See
    /// `VALUE_NWK_FRAME_COUNTER` for the three constraints; violating the
    /// no-network one surfaces as `EZSP_ERROR_INVALID_CALL`.
    pub fn setNwkFrameCounter(self: *Client, counter: u32) !void {
        var v: [4]u8 = undefined;
        std.mem.writeInt(u32, &v, counter, .little);
        try self.setValue(VALUE_NWK_FRAME_COUNTER, &v);
    }

    /// Asks the NCP to prove it's alive, and nothing else.
    ///
    /// **Why hub needs this**: the poll loop only ever *reads* when the
    /// house is quiet, and a read from a vanished USB radio returns no bytes
    /// — which is exactly what an idle radio returns. So an unplug at 3am
    /// was invisible: `pollOnce` kept returning null and recovery never
    /// fired (observed for real, 2026-07-17: the cable was out for a minute
    /// and hub logged nothing at all). A write is what fails loudly, so
    /// after a stretch of silence the loop sends this and finds out.
    pub fn nop(self: *Client) !void {
        var out: [4]u8 = undefined;
        _ = try self.call(FRAME_NOP, &.{}, &out); // no response parameters
    }

    /// How many end-device children the node has now.
    pub fn childCount(self: *Client) !u8 {
        var out: [16]u8 = undefined;
        return firstByte(try self.call(FRAME_GET_PARENT_CHILD_PARAMETERS, &.{}, &out));
    }

    /// How many entries of the neighbour table are in use.
    pub fn neighborCount(self: *Client) !u8 {
        var out: [4]u8 = undefined;
        return firstByte(try self.call(FRAME_NEIGHBOR_COUNT, &.{}, &out));
    }

    pub fn getNetworkParameters(self: *Client) !NetworkParameters {
        var out: [32]u8 = undefined;
        const resp = try self.call(FRAME_GET_NETWORK_PARAMETERS, &.{}, &out);
        return parseNetworkParameters(resp);
    }

    /// Tries the legacy getKey command first; if the NCP reports
    /// STATUS_LIBRARY_NOT_PRESENT (common on current firmware that ships
    /// only the modern Security Manager library), falls back to
    /// exportKey + getNetworkKeyInfo.
    pub fn getCurrentNetworkKey(self: *Client) !KeyInfo {
        var out: [40]u8 = undefined;
        const resp = self.call(FRAME_GET_KEY, &.{KEY_TYPE_CURRENT_NETWORK_KEY}, &out) catch |err| return err;
        if (resp.len >= 1 and resp[0] == STATUS_LIBRARY_NOT_PRESENT) {
            return self.getCurrentNetworkKeyModern();
        }
        return parseKeyInfo(resp);
    }

    fn getCurrentNetworkKeyModern(self: *Client) !KeyInfo {
        const context = buildExportKeyContext();
        var key_out: [24]u8 = undefined;
        const key_resp = try self.call(FRAME_EXPORT_KEY, &context, &key_out);
        const key = try parseExportKeyResponse(key_resp);

        var info_out: [16]u8 = undefined;
        const info_resp = try self.call(FRAME_GET_NETWORK_KEY_INFO, &.{}, &info_out);
        const meta = try parseNetworkKeyInfoResponse(info_resp);

        return .{ .key = key, .sequence_number = meta.sequence_number, .outgoing_frame_counter = meta.frame_counter };
    }

    /// Configures the network key and hashed-TCLK security state the NCP
    /// will use (`tclk_hash_seed` = 16 random bytes, the per-device link-key
    /// derivation seed). Must precede `formNetwork`. Mirrors bellows'
    /// `zha_security()` with `use_hashed_tclk=True` (its default) and no
    /// known TC EUI64.
    pub fn setInitialSecurityState(self: *Client, network_key: [16]u8, network_key_sequence: u8, tclk_hash_seed: [16]u8) !void {
        const params = buildSecurityStateParams(network_key, network_key_sequence, tclk_hash_seed);
        var out: [4]u8 = undefined;
        const resp = try self.call(FRAME_SET_INITIAL_SECURITY_STATE, &params, &out);
        if (resp.len < 1) return error.FrameTooShort;
        if (resp[0] != STATUS_SUCCESS) {
            std.log.err("setInitialSecurityState: NCP status=0x{x:0>2}", .{resp[0]});
            return error.NcpStatusError;
        }
    }

    /// Requests network formation with the given parameters. A SUCCESS
    /// response here only means the request was accepted — actual
    /// completion is reported asynchronously; call `waitForNetworkUp`
    /// afterward.
    pub fn formNetwork(self: *Client, params: FormNetworkParams) !void {
        const req = buildFormNetworkParams(params);
        var out: [4]u8 = undefined;
        const resp = try self.call(FRAME_FORM_NETWORK, &req, &out);
        if (resp.len < 1) return error.FrameTooShort;
        if (resp[0] != STATUS_SUCCESS) {
            std.log.err("formNetwork: NCP status=0x{x:0>2}", .{resp[0]});
            return error.NcpStatusError;
        }
    }

    /// Waits for the asynchronous stackStatusHandler callback confirming
    /// the network formed by `formNetwork` came up. Ignores unrelated
    /// callback frames that might interleave, retrying up to `max_rounds`.
    pub fn waitForNetworkUp(self: *Client, max_rounds: u8) !void {
        var round: u8 = 0;
        while (round < max_rounds) : (round += 1) {
            var raw: [MAX_CALLBACK_PAYLOAD]u8 = undefined;
            const frame = self.transport.receiveCallback(&raw, 1) catch |err| switch (err) {
                error.CallbackTimeout => continue,
                else => return err,
            };
            const parsed = try parseHeader(frame, self.extended);
            if (parsed.frame_id != FRAME_STACK_STATUS_HANDLER) continue;

            const payload = frame[parsed.payload_offset..];
            if (payload.len < 1) return error.FrameTooShort;
            if (payload[0] == STATUS_NETWORK_UP) return;
            // Some other transient status (e.g. NETWORK_DOWN mid-join) — keep waiting.
        }
        return error.NetworkUpTimeout;
    }

    /// Sets the trust center join policy to unconditionally authorize
    /// joining devices. Without this the NCP's default policy may reject
    /// join attempts before `trustCenterJoinHandler` is even worth watching.
    fn setPolicy(self: *Client, policy_id: u8, decision: u8) !void {
        var out: [4]u8 = undefined;
        const resp = try self.call(FRAME_SET_POLICY, &.{ policy_id, decision }, &out);
        if (resp.len < 1) return error.FrameTooShort;
        if (resp[0] != STATUS_SUCCESS) {
            std.log.err("setPolicy(0x{x:0>2}, 0x{x:0>2}): NCP status=0x{x:0>2}", .{ policy_id, decision, resp[0] });
            return error.NcpStatusError;
        }
    }

    /// Sets the trust-center join policy plus the two policies that govern
    /// what happens *after* a device joins at the MAC/NWK layer
    /// (TC_KEY_REQUEST_POLICY, APP_KEY_REQUEST_POLICY). All three matter:
    /// leaving TC_KEY_REQUEST_POLICY at the firmware default can cause a
    /// device to join, get denied when it requests the network key, and
    /// leave+retry — a join/leave flap that looks like flakiness but is
    /// really a missing policy. Matches bellows' baseline policy bundle.
    pub fn setJoinPolicy(self: *Client, decision: u8) !void {
        // v8+ NCPs read the trust-center policy as a bitmask (see the
        // DECISION_BITMASK_* doc comment) — unsecured rejoins must be
        // explicitly allowed or rejoin-flavored commissioning flaps forever.
        const tc_value: u8 = if (self.extended)
            DECISION_BITMASK_ALLOW_JOINS | DECISION_BITMASK_ALLOW_UNSECURED_REJOINS
        else
            decision;
        try self.setPolicy(POLICY_TRUST_CENTER, tc_value);
        try self.setPolicy(POLICY_TC_KEY_REQUEST, DECISION_ALLOW_TC_KEY_REQUESTS);
        try self.setPolicy(POLICY_APP_KEY_REQUEST, DECISION_DENY_APP_KEY_REQUESTS);
    }

    /// Tells the NCP to leave its current network (EmberStatus response;
    /// 0x93 NOT_JOINED if there was nothing to leave). The stack confirms
    /// asynchronously via a NETWORK_DOWN (0x91) stackStatusHandler.
    pub fn leaveNetwork(self: *Client) !u8 {
        var out: [4]u8 = undefined;
        const resp = try self.call(FRAME_LEAVE_NETWORK, &.{}, &out);
        if (resp.len < 1) return error.FrameTooShort;
        return resp[0];
    }

    /// Registers the well-known "ZigBeeAlliance09" key as a TRANSIENT link
    /// key for any joiner (wildcard EUI FF:...:FF) — bellows' `pre_permit`
    /// does exactly this before every permit. REQUIRED on hashed-TCLK
    /// networks: without it the stack wraps the join-time network-key
    /// transport with the joiner's DERIVED per-device key, which a
    /// factory-new device doesn't know — observed live as every device
    /// associating then silently retrying forever (fresh nwk each attempt,
    /// no Device Announce, no key establishment, not even a leave).
    /// Transient keys expire on their own (minutes), so this is re-imported
    /// before each permitJoining. importTransientKey is the v13+ command
    /// (0x0111, Security Manager; 4-byte sl_Status response) — the legacy
    /// addTransientLinkKey (0xAF) was removed in v13.
    fn importWellKnownTransientKey(self: *Client) !void {
        var params: [25]u8 = undefined;
        @memset(params[0..8], 0xFF); // wildcard EUI64: any joiner
        std.mem.copyForwards(u8, params[8..24], &DEFAULT_TC_LINK_KEY);
        params[24] = 0; // SecurityManagerContextFlags: none
        var out: [8]u8 = undefined;
        const resp = try self.call(FRAME_IMPORT_TRANSIENT_KEY, params[0..25], &out);
        if (resp.len < 4) return error.FrameTooShort;
        const status = @as(u32, resp[0]) | (@as(u32, resp[1]) << 8) | (@as(u32, resp[2]) << 16) | (@as(u32, resp[3]) << 24);
        if (status != 0) {
            std.log.warn("importTransientKey: sl_Status=0x{x:0>8} — joins may fail on hashed-TCLK networks", .{status});
        }
    }

    /// Opens the network for joining for `duration_seconds` (0 closes it
    /// immediately; the NCP auto-closes after the duration elapses). NOTE
    /// per the EZSP serial protocol doc: `0xFF` is NOT "255 seconds" — it
    /// means "enable joining indefinitely" (no auto-close). A caller
    /// passing 255 intending a long-but-bounded window would get an
    /// unbounded one instead. `zd`'s `permit` console command and CLI
    /// subcommands never pass 255 today, so this hasn't bitten us, but
    /// worth knowing before adding a "permit for a long time" shortcut.
    pub fn permitJoining(self: *Client, duration_seconds: u8) !void {
        if (duration_seconds > 0) try self.importWellKnownTransientKey();
        var out: [4]u8 = undefined;
        const resp = try self.call(FRAME_PERMIT_JOINING, &.{duration_seconds}, &out);
        if (resp.len < 1) return error.FrameTooShort;
        if (resp[0] != STATUS_SUCCESS) {
            std.log.err("permitJoining: NCP status=0x{x:0>2}", .{resp[0]});
            return error.NcpStatusError;
        }
    }

    /// Sends an APS unicast (EZSP sendUnicast, 0x34) — the transmit half of
    /// all ZDO/ZCL traffic. A SUCCESS status only means the NCP accepted
    /// the message for delivery; end-to-end confirmation arrives later via
    /// messageSentHandler (matched by `tag`), and any reply via
    /// incomingMessageHandler. Returns the raw EmberStatus + the APS
    /// sequence number the stack assigned.
    pub fn sendUnicast(self: *Client, destination: u16, aps: ApsFrame, tag: u8, message: []const u8) !struct { status: u8, sequence: u8 } {
        if (message.len > 100) {
            std.log.warn("BufferTooSmall@ezsp.sendUnicast/message: len={d}", .{message.len});
            return error.BufferTooSmall; // stays inside call()'s request buffer
        }
        var params: [128]u8 = undefined;
        params[0] = OUTGOING_DIRECT;
        params[1] = @truncate(destination & 0xFF);
        params[2] = @truncate(destination >> 8);
        aps.serialize(params[3..14]);
        params[14] = tag;
        params[15] = @intCast(message.len);
        std.mem.copyForwards(u8, params[16 .. 16 + message.len], message);

        var out: [4]u8 = undefined;
        const resp = try self.call(FRAME_SEND_UNICAST, params[0 .. 16 + message.len], &out);
        if (resp.len < 2) return error.FrameTooShort;
        return .{ .status = resp[0], .sequence = resp[1] };
    }

    /// Sends an APS broadcast (EZSP sendBroadcast, 0x36) — needed for ZDO
    /// requests whose whole point is that we don't know the destination
    /// (NWK_addr_req). Same wire layout as sendUnicast minus the message
    /// type, plus a radius byte (0 = maximum hops). Layout confirmed
    /// unchanged v4→v13 in bellows, same as sendUnicast.
    pub fn sendBroadcast(self: *Client, destination: u16, aps: ApsFrame, radius: u8, tag: u8, message: []const u8) !struct { status: u8, sequence: u8 } {
        if (message.len > 100) {
            std.log.warn("BufferTooSmall@ezsp.sendBroadcast/message: len={d}", .{message.len});
            return error.BufferTooSmall; // stays inside call()'s request buffer
        }
        var params: [128]u8 = undefined;
        params[0] = @truncate(destination & 0xFF);
        params[1] = @truncate(destination >> 8);
        aps.serialize(params[2..13]);
        params[13] = radius;
        params[14] = tag;
        params[15] = @intCast(message.len);
        std.mem.copyForwards(u8, params[16 .. 16 + message.len], message);

        var out: [4]u8 = undefined;
        const resp = try self.call(FRAME_SEND_BROADCAST, params[0 .. 16 + message.len], &out);
        if (resp.len < 2) return error.FrameTooShort;
        return .{ .status = resp[0], .sequence = resp[1] };
    }

    /// Sends an APS multicast (EZSP sendMulticast, 0x38) — the group-send
    /// primitive: one frame reaches every device that has been made a
    /// member of `aps.group_id` (via `Zcl.buildAddGroup`, sent to each
    /// member individually first), all switching together instead of the
    /// visible stagger a coordinator-side unicast fan-out would show.
    ///
    /// **Layout confidence note**: the current EZSP host serial protocol
    /// reference (read 2026-07) documents `sendMulticast`'s parameters as
    /// `apsFrame, hops(u8), broadcastAddr(u16), alias(u16),
    /// nwkSequence(u8), messageTag(u16), messageLength(u8),
    /// messageContents` — but that same reference documents
    /// `sendUnicast`'s tag as `uint16_t` and `sendBroadcast` with a
    /// leading `alias`+`destination`+`nwkSequence` prefix, NEITHER of
    /// which matches this codebase's `sendUnicast`/`sendBroadcast` above
    /// (1-byte tag, no alias/nwkSequence prefix) — and those two are
    /// extensively hardware-verified against our actual negotiated EZSP
    /// v13 NCP. The likely explanation: that reference describes a newer
    /// SDK's expanded command surface (probably added for a broadcast-
    /// alias feature we don't use), while our NCP still speaks the
    /// older, simpler layout bellows' v4 command table targets — the
    /// same one `sendUnicast`/`sendBroadcast` already prove works here.
    /// This function follows that same simpler convention (no alias/
    /// nwkSequence, one-byte tag, one-byte non-member radius in place of
    /// the doc's `u16 broadcastAddr`) for consistency with what's
    /// already proven, but **this specific frame has not itself been
    /// hardware-verified** — if group sends fail or the NCP returns a
    /// non-success status, this byte layout (particularly whether
    /// `nonmember_radius` is really one byte, and whether an alias
    /// prefix is genuinely absent on real v13 firmware) is the first
    /// thing to re-check, ideally by capturing a known-good multicast
    /// send from `zigbee-herdsman` or bellows against the same NCP.
    ///
    /// `nonmember_radius`: hop limit for relaying by devices that are
    /// NOT members of the group (0 = converted to max hops by the stack;
    /// per the reference doc, 7+ is treated as infinite — an unusually
    /// specific detail that's likely accurate regardless of the
    /// surrounding layout uncertainty, since it describes stack
    /// *behavior*, not wire *layout*).
    pub fn sendMulticast(self: *Client, aps: ApsFrame, hops: u8, nonmember_radius: u8, tag: u8, message: []const u8) !struct { status: u8, sequence: u8 } {
        if (message.len > 100) {
            std.log.warn("BufferTooSmall@ezsp.sendMulticast/message: len={d}", .{message.len});
            return error.BufferTooSmall; // stays inside call()'s request buffer
        }
        var params: [128]u8 = undefined;
        aps.serialize(params[0..11]);
        params[11] = hops;
        params[12] = nonmember_radius;
        params[13] = tag;
        params[14] = @intCast(message.len);
        std.mem.copyForwards(u8, params[15 .. 15 + message.len], message);

        var out: [4]u8 = undefined;
        const resp = try self.call(FRAME_SEND_MULTICAST, params[0 .. 15 + message.len], &out);
        if (resp.len < 2) return error.FrameTooShort;
        return .{ .status = resp[0], .sequence = resp[1] };
    }

    /// Waits for and decodes the next unsolicited NCP callback frame,
    /// regardless of which one it is — general-purpose counterpart to the
    /// single-minded `waitForNetworkUp`. Returns null on timeout rather
    /// than erroring, since "nothing happened yet" is a normal outcome
    /// while polling for join events.
    pub fn pollCallback(self: *Client, max_rounds: u8) !?Callback {
        var round: u8 = 0;
        while (round < max_rounds) : (round += 1) {
            var raw: [MAX_CALLBACK_PAYLOAD]u8 = undefined;
            // Serve callbacks that `call` queued (frames that arrived
            // interleaved with a command response) before reading fresh
            // ones off the transport.
            const frame = self.dequeueCallbackFrame(&raw) orelse
                self.transport.receiveCallback(&raw, 1) catch |err| switch (err) {
                error.CallbackTimeout => continue,
                else => return err,
            };
            const parsed = try parseHeader(frame, self.extended);
            const payload = frame[parsed.payload_offset..];

            return switch (parsed.frame_id) {
                FRAME_STACK_STATUS_HANDLER => blk: {
                    if (payload.len < 1) return error.FrameTooShort;
                    break :blk .{ .stack_status = payload[0] };
                },
                FRAME_TRUST_CENTER_JOIN_HANDLER => .{ .trust_center_join = try parseTrustCenterJoinEvent(payload) },
                FRAME_CHILD_JOIN_HANDLER => .{ .child_join = try parseChildJoinEvent(payload) },
                FRAME_INCOMING_MESSAGE_HANDLER => .{ .incoming_message = try parseIncomingMessage(payload) },
                FRAME_ZIGBEE_KEY_ESTABLISHMENT_HANDLER => .{ .key_establishment = try parseKeyEstablishment(payload) },
                else => .{ .unknown = .{ .frame_id = parsed.frame_id, .payload_len = payload.len } },
            };
        }
        return null;
    }
};

test "parseTrustCenterJoinEvent decodes field layout" {
    const payload = [_]u8{
        0x34, 0x12, // newNodeId = 0x1234
        1, 2, 3, 4, 5, 6, 7, 8, // newNodeEui64
        0x01, // status = STANDARD_SECURITY_UNSECURED_JOIN
        0x03, // policyDecision = NO_ACTION
        0x00, 0x00, // parentOfNewNodeId = 0x0000 (coordinator)
    };
    const event = try parseTrustCenterJoinEvent(&payload);
    try std.testing.expectEqual(@as(u16, 0x1234), event.new_node_id);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, &event.new_node_eui64);
    try std.testing.expectEqual(@as(u8, 0x01), event.status);
    try std.testing.expectEqual(@as(u8, 0x03), event.policy_decision);
    try std.testing.expectEqual(@as(u16, 0x0000), event.parent_of_new_node_id);
}

test "parseChildJoinEvent decodes field layout" {
    const payload = [_]u8{
        0, // index
        1, // joining = true
        0x34, 0x12, // childId = 0x1234
        1, 2, 3, 4, 5, 6, 7, 8, // childEui64
        0x01, // childType
    };
    const event = try parseChildJoinEvent(&payload);
    try std.testing.expect(event.joining);
    try std.testing.expectEqual(@as(u16, 0x1234), event.child_id);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, &event.child_eui64);
    try std.testing.expectEqual(@as(u8, 0x01), event.child_type);
}

test "parseExportKeyResponse decodes key and rejects non-zero sl_Status" {
    var resp: [20]u8 = undefined;
    const key = @as([16]u8, @splat(9));
    std.mem.copyForwards(u8, resp[0..16], &key);
    @memset(resp[16..20], 0); // sl_Status.OK

    const parsed = try parseExportKeyResponse(&resp);
    try std.testing.expectEqualSlices(u8, &key, &parsed);

    resp[16] = 0x01; // any non-zero sl_Status
    try std.testing.expectError(error.NcpStatusError, parseExportKeyResponse(&resp));
}

test "parseNetworkKeyInfoResponse decodes sequence number and frame counter" {
    var resp: [12]u8 = undefined;
    @memset(resp[0..4], 0); // sl_Status.OK
    resp[4] = 1; // network_key_set
    resp[5] = 0; // alternate_network_key_set
    resp[6] = 3; // network_key_sequence_number
    resp[7] = 0; // alt_network_key_sequence_number
    resp[8] = 0x01;
    resp[9] = 0x60;
    resp[10] = 0x00;
    resp[11] = 0x00; // frame_counter = 24577, LE

    const meta = try parseNetworkKeyInfoResponse(&resp);
    try std.testing.expectEqual(@as(u8, 3), meta.sequence_number);
    try std.testing.expectEqual(@as(u32, 24577), meta.frame_counter);
}

test "buildSecurityStateParams matches the exact EmberInitialSecurityState field layout" {
    const key = @as([16]u8, @splat(1));
    const seed = @as([16]u8, @splat(2));
    const params = buildSecurityStateParams(key, 7, seed);

    try std.testing.expectEqual(@as(u16, 0x1B84), @as(u16, params[0]) | (@as(u16, params[1]) << 8)); // 0x1B04 | hashed-TCLK 0x0084
    try std.testing.expectEqualSlices(u8, &seed, params[2..18]);
    try std.testing.expectEqualSlices(u8, &key, params[18..34]);
    try std.testing.expectEqual(@as(u8, 7), params[34]);
    try std.testing.expectEqualSlices(u8, &@as([8]u8, @splat(0)), params[35..43]);
}

test "buildFormNetworkParams round-trips through parseNetworkParameters" {
    const params = FormNetworkParams{
        .extended_pan_id = .{ 1, 2, 3, 4, 5, 6, 7, 8 },
        .pan_id = 0xBBC6,
        .radio_channel = 20,
        .network_key = undefined,
        .tx_power = 8,
    };
    const req = buildFormNetworkParams(params);

    // formNetwork's request uses the same EmberNetworkParameters layout as
    // getNetworkParameters' response, just without the leading status/nodeType.
    var synthetic_resp: [22]u8 = undefined;
    synthetic_resp[0] = 0x00;
    synthetic_resp[1] = 0x00;
    std.mem.copyForwards(u8, synthetic_resp[2..22], &req);

    const parsed = try parseNetworkParameters(&synthetic_resp);
    try std.testing.expectEqualSlices(u8, &params.extended_pan_id, &parsed.extended_pan_id);
    try std.testing.expectEqual(params.pan_id, parsed.pan_id);
    try std.testing.expectEqual(params.radio_channel, parsed.radio_channel);
    try std.testing.expectEqual(@as(u32, 1) << 20, parsed.channel_mask);
}

test "Client.reset clears pre-reset protocol state: seq, framing, and the callback ring" {
    var transport: Ash.Transport = undefined; // never touched by reset()
    var client = Client.init(&transport);
    client.seq = 42;
    client.extended = true;
    // Two callbacks decoded from the network we are about to lose.
    client.enqueueCallbackFrame(&.{ 0x01, 0x80, 0x01, 0x45, 0x00 });
    client.enqueueCallbackFrame(&.{ 0x02, 0x80, 0x01, 0x45, 0x00 });
    try std.testing.expectEqual(@as(usize, 2), client.queue_count);

    client.reset();

    try std.testing.expectEqual(@as(u8, 0), client.seq);
    try std.testing.expect(!client.extended); // re-derived by the next negotiateVersion
    try std.testing.expectEqual(@as(usize, 0), client.queue_count);
    // The ring must be genuinely empty, not merely counted as such: stale
    // frames from a dead session must never surface post-reset.
    var buf: [MAX_CALLBACK_PAYLOAD]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), client.dequeueCallbackFrame(&buf));
    // And the transport pointer is untouched — Link rebuilds that value in
    // place, so this client stays usable across the reset.
    try std.testing.expectEqual(&transport, client.transport);
}

test "buildHeader/parseHeader round-trip in legacy mode" {
    var buf: [8]u8 = undefined;
    const n = buildHeader(0x05, FRAME_GET_EUI64, false, &buf);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualSlices(u8, &.{ 0x05, 0x00, 0x26 }, buf[0..n]);

    const parsed = try parseHeader(buf[0..n], false);
    try std.testing.expectEqual(FRAME_GET_EUI64, parsed.frame_id);
    try std.testing.expectEqual(@as(usize, 3), parsed.payload_offset);
    // What we build is a COMMAND: nothing we send may ever satisfy call()'s
    // response match.
    try std.testing.expect(!parsed.is_response);
}

test "parseHeader reads the direction bit — a real NCP response vs. our own echoed command" {
    // Both frames captured from the ZBT-2 (2026-07-16). The echo is the one
    // that broke `call()`: identical frame id to the reply we were waiting
    // for, distinguishable ONLY by the direction bit.
    const echoed_command = [_]u8{ 0x1e, 0x00, 0x01, 0x34, 0x00, 0x00, 0x14, 0xd7 }; // our own sendUnicast, echoed back
    const echo = try parseHeader(&echoed_command, true);
    try std.testing.expectEqual(FRAME_SEND_UNICAST, echo.frame_id); // matches by id...
    try std.testing.expect(!echo.is_response); // ...but is not a response

    const real_response = [_]u8{ 0x1e, 0x80, 0x01, 0x34, 0x00, 0x00, 0x42 }; // fc_low=0x80: what every genuine reply carries
    const rsp = try parseHeader(&real_response, true);
    try std.testing.expectEqual(FRAME_SEND_UNICAST, rsp.frame_id);
    try std.testing.expect(rsp.is_response);

    // Legacy framing (the v4 version probe at startup) uses the same bit —
    // confirmed against the real NCP's own probe response, which carried
    // fc=0x80.
    const legacy_response = [_]u8{ 0x00, 0x80, 0x00, 0x0d };
    const legacy = try parseHeader(&legacy_response, false);
    try std.testing.expect(legacy.is_response);
    const legacy_command = [_]u8{ 0x00, 0x00, 0x00 };
    try std.testing.expect(!(try parseHeader(&legacy_command, false)).is_response);
}

test "buildHeader/parseHeader round-trip in extended mode" {
    var buf: [8]u8 = undefined;
    const n = buildHeader(0x05, FRAME_GET_KEY, true, &buf);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualSlices(u8, &.{ 0x05, 0x00, 0x01, 0x6A, 0x00 }, buf[0..n]);

    const parsed = try parseHeader(buf[0..n], true);
    try std.testing.expectEqual(FRAME_GET_KEY, parsed.frame_id);
    try std.testing.expectEqual(@as(usize, 5), parsed.payload_offset);
    try std.testing.expect(!parsed.is_response); // ours = a command
}

test "parseNetworkParameters decodes a synthetic response matching mbt2.txt's values" {
    // status=SUCCESS, nodeType=0 (unused), extendedPanId, panId=0xBBC6,
    // radioTxPower=0(unused), radioChannel=20, joinMethod=0(unused),
    // nwkManagerId=0(unused), nwkUpdateId=0, channels=0x07FFF800 (11..26).
    const resp = [_]u8{
        0x00, 0x00,
        0x6f, 0x06, 0xeb, 0x48, 0xcb, 0x13, 0xdb, 0xac, // extendedPanId (wire order)
        0xC6, 0xBB, // panId LE
        0x00, // radioTxPower
        20, // radioChannel
        0x00, // joinMethod
        0x00, 0x00, // nwkManagerId
        0x00, // nwkUpdateId
        0x00, 0xF8, 0xFF, 0x07, // channels LE (0x07FFF800)
    };
    const params = try parseNetworkParameters(&resp);
    try std.testing.expectEqualSlices(u8, &.{ 0x6f, 0x06, 0xeb, 0x48, 0xcb, 0x13, 0xdb, 0xac }, &params.extended_pan_id);
    try std.testing.expectEqual(@as(u16, 0xBBC6), params.pan_id);
    try std.testing.expectEqual(@as(u8, 20), params.radio_channel);
    try std.testing.expectEqual(@as(u8, 0), params.nwk_update_id);
    try std.testing.expectEqual(@as(u32, 0x07FFF800), params.channel_mask);

    var channel: u5 = 11;
    while (channel <= 26) : (channel += 1) {
        try std.testing.expect(params.channel_mask & (@as(u32, 1) << channel) != 0);
    }
}

test "parseKeyInfo decodes a synthetic response matching mbt2.txt's values" {
    var resp: [37]u8 = undefined;
    resp[0] = 0x00; // status
    resp[1] = 0x00;
    resp[2] = 0x00; // bitmask
    resp[3] = 0x01; // type
    const key = [_]u8{ 0x42, 0x02, 0xd7, 0xa1, 0x17, 0x0e, 0x6b, 0x7b, 0x20, 0x2d, 0x10, 0x4e, 0x62, 0x24, 0xa3, 0x9c };
    std.mem.copyForwards(u8, resp[4..20], &key);
    // outgoingFrameCounter = 24577 = 0x00006001, LE
    resp[20] = 0x01;
    resp[21] = 0x60;
    resp[22] = 0x00;
    resp[23] = 0x00;
    @memset(resp[24..28], 0); // incomingFrameCounter, unused
    resp[28] = 0x00; // sequenceNumber
    @memset(resp[29..37], 0); // partnerEUI64, unused

    const info = try parseKeyInfo(&resp);
    try std.testing.expectEqualSlices(u8, &key, &info.key);
    try std.testing.expectEqual(@as(u8, 0), info.sequence_number);
    try std.testing.expectEqual(@as(u32, 24577), info.outgoing_frame_counter);
}

test "buildAddEndpointParams matches the EZSP addEndpoint wire layout" {
    var buf: [56]u8 = undefined;
    // zigpy's default endpoint 1 registration.
    const req = try buildAddEndpointParams(1, 0x0104, 0x0400, 0, &.{ 0x0000, 0x0006, 0x000A, 0x0019, 0x0501 }, &.{ 0x0001, 0x0020, 0x0500, 0x0502 }, &buf);
    try std.testing.expectEqualSlices(u8, &.{
        0x01, // endpoint
        0x04, 0x01, // profile 0x0104 LE
        0x00, 0x04, // device 0x0400 LE
        0x00, // device version
        0x05, // input cluster count
        0x04, // output cluster count
        0x00, 0x00, 0x06, 0x00, 0x0A, 0x00, 0x19, 0x00, 0x01, 0x05, // inputs LE
        0x01, 0x00, 0x20, 0x00, 0x00, 0x05, 0x02, 0x05, // outputs LE
    }, req);
}

test "ApsFrame serialize/parse round-trip and wire layout" {
    const aps = ApsFrame{
        .profile_id = 0x0000,
        .cluster_id = 0x0005,
        .source_endpoint = 0,
        .destination_endpoint = 0,
    };
    var wire: [ApsFrame.WIRE_LEN]u8 = undefined;
    aps.serialize(&wire);
    try std.testing.expectEqualSlices(u8, &.{
        0x00, 0x00, // profile
        0x05, 0x00, // cluster
        0x00, 0x00, // endpoints
        0x40, 0x01, // options: RETRY | ENABLE_ROUTE_DISCOVERY
        0x00, 0x00, // group
        0x00, // sequence
    }, &wire);

    const back = try ApsFrame.parse(&wire);
    try std.testing.expectEqual(aps.cluster_id, back.cluster_id);
    try std.testing.expectEqual(aps.options, back.options);
}

test "parseIncomingMessage decodes a synthetic ZDO Active_EP_rsp callback" {
    var payload: [26]u8 = undefined;
    payload[0] = 0x00; // EmberIncomingMessageType.UNICAST
    const aps = ApsFrame{
        .profile_id = 0x0000,
        .cluster_id = 0x8005,
        .source_endpoint = 0,
        .destination_endpoint = 0,
        .options = 0x0140,
        .sequence = 0x77,
    };
    aps.serialize(payload[1..12]);
    payload[12] = 200; // lqi
    payload[13] = @bitCast(@as(i8, -55)); // rssi
    payload[14] = 0x4E;
    payload[15] = 0x65; // sender 0x654E
    payload[16] = 0xFF; // bindingIndex
    payload[17] = 0xFF; // addressIndex
    payload[18] = 7; // contents length
    const zdo_rsp = [_]u8{ 0x2A, 0x00, 0x4E, 0x65, 0x02, 0x0B, 0xF2 };
    std.mem.copyForwards(u8, payload[19..26], &zdo_rsp);

    const msg = try parseIncomingMessage(&payload);
    try std.testing.expectEqual(@as(u16, 0x8005), msg.aps.cluster_id);
    try std.testing.expectEqual(@as(u16, 0x654E), msg.sender);
    try std.testing.expectEqual(@as(i8, -55), msg.last_hop_rssi);
    try std.testing.expectEqualSlices(u8, &zdo_rsp, msg.payload());
}

test "Semantic Check" {
    std.testing.refAllDecls(@This());
}
