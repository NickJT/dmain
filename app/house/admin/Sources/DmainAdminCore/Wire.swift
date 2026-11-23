import Foundation

/// How a row reads against what it should be. `differs` is drawn orange and
/// `broken` red; nothing else on screen is coloured.
public enum Mark: String, Decodable, Sendable {
    case none, differs, broken
}

/// The link to the house server, as `dmain` reports it.
public enum LinkState: String, Decodable, Sendable {
    case connecting, up, quiet, closed
}

public struct LinkStatus: Decodable, Equatable, Sendable {
    public var state: LinkState
    /// What's wrong with the link, or what it's waiting for.
    public var why: String?
    /// The newest house record from either log, which is how staleness is judged.
    public var newestMs: Int64?

    enum CodingKeys: String, CodingKey {
        case state, why
        case newestMs = "newest_ms"
    }

    public init(state: LinkState, why: String? = nil, newestMs: Int64? = nil) {
        self.state = state
        self.why = why
        self.newestMs = newestMs
    }

    public var newest: Date? { newestMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
}

/// One thing on another screen that isn't as it should be, said in a line.
public struct Item: Decodable, Equatable, Sendable {
    public var name: String
    public var text: String
    public var mark: Mark
}

public struct ConsoleState: Decodable, Equatable, Sendable {
    /// nil until hub's console has been tried.
    public var up: Bool?
    public var busy: Bool
    public var text: String
}

public struct Row: Decodable, Equatable, Sendable {
    public var cells: [String]
    public var mark: Mark
    /// The device's IEEE address; nil for a row that isn't a device, such as a schedule.
    public var dev: String?
}

/// A whole-class screen: its summary and rows. In Attention, only the marked
/// rows; on a `table` line, every row, in dmain's order (marked first).
public struct Section: Decodable, Equatable, Sendable {
    /// `power_on`, `firmware`, `battery`, `heard` or `schedules`.
    public var screen: String
    public var label: String
    public var summary: String
    public var columns: [String]
    public var count: Int
    public var rows: [Row]
}

public struct Event: Decodable, Equatable, Sendable {
    public var at: String
    /// `hue` or `hub`: which log it came from.
    public var src: String
    public var text: String
    public var mark: Mark
    public var dev: String?
}

/// What every other screen marks, gathered by `dmain`. The app only draws it.
public struct Attention: Decodable, Equatable, Sendable {
    /// Those needing a look; nil until the link has reported any.
    public var services: [Item]?
    public var console: ConsoleState
    /// Wanted files whose dry run would change something or failed; nil with no checkout.
    public var config: [Item]?
    public var sections: [Section]

    /// Everything marked, which is the sidebar's count and the Dock badge.
    public var count: Int {
        (services?.count ?? 0) + (config?.count ?? 0) + sections.reduce(0) { $0 + $1.count }
    }

    public func section(_ screen: String) -> Section? {
        sections.first { $0.screen == screen }
    }
}

/// A house service as the Services screen shows it.
public struct ServiceRow: Decodable, Equatable, Sendable {
    /// `huelog`, `hub` or `dmain`.
    public var unit: String
    public var state: String
    public var enabled: String
    public var since: String?
    public var restarts: Int
    public var newerBinary: Bool
    public var mark: Mark
    /// What a restart stops, said before it's confirmed.
    public var cost: String

    enum CodingKeys: String, CodingKey {
        case unit, state, enabled, since, restarts, mark, cost
        case newerBinary = "newer_binary"
    }
}

/// A wanted target: its last run, and whether it can be applied.
public struct ConfigTarget: Decodable, Equatable, Sendable {
    /// `power-on`, `switches` or `hub`: what `apply` is given.
    public var name: String
    /// "the Bridge" or "hub".
    public var to: String
    public var files: String
    public var paths: [String]
    public var status: String
    public var mark: Mark
    public var what: String
    /// What the last dry run checked; `apply` is given it back.
    public var hash: String?
    /// Why it can't be applied now; nil when it can.
    public var refusal: String?
    public var lines: [String]
}

public struct ConfigState: Decodable, Equatable, Sendable {
    /// The checkout whose files are applied; nil with none.
    public var checkout: String?
    public var targets: [ConfigTarget]?
}

public struct ConsoleFeed: Decodable, Equatable, Sendable {
    public var state: ConsoleState
    /// hub's newest console lines: its log, and the replies to any command.
    public var lines: [String]
}

/// A reading: `[t, v]` on the wire, Unix milliseconds and a value.
public struct HistoryPoint: Decodable, Equatable, Sendable {
    public var t: Int64
    public var v: Double

    public init(t: Int64, v: Double) {
        self.t = t
        self.v = v
    }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        t = try c.decode(Int64.self)
        v = try c.decode(Double.self)
    }

    public var date: Date { .fromMs(t) }
}

/// Where a line stops and why: `link_lost` or `silent`. `to` is nil while it lasts to the range's end.
public struct HistoryGap: Decodable, Equatable, Sendable {
    public var from: Int64
    public var to: Int64?
    public var why: String
}

/// One sensor's readings over a range, as segments never to be joined.
public struct HistorySeries: Decodable, Equatable, Sendable {
    public var dev: String
    public var label: String
    public var outside: Bool
    public var segments: [[HistoryPoint]]
    public var gaps: [HistoryGap]
}

public struct MotionSpan: Decodable, Equatable, Sendable {
    public var from: Int64
    public var to: Int64
}

public struct MotionSeries: Decodable, Equatable, Sendable {
    public var dev: String
    public var label: String
    public var outdoor: Bool
    public var spans: [MotionSpan]
}

/// A range of the house logs, folded by `dmain admin H history`.
public struct History: Decodable, Equatable, Sendable {
    public var from: Int64
    public var to: Int64
    /// The newest record read: where today's lines stop.
    public var newest: Int64?
    public var raw: Bool
    public var temperature: [HistorySeries]
    public var humidity: [HistorySeries]
    public var motion: [MotionSeries]
}

/// One device either network lists: who it is, which network acts on it, and what it offers.
public struct DeviceInfo: Decodable, Equatable, Sendable, Identifiable {
    /// The IEEE address.
    public var dev: String
    public var name: String
    public var room: String?
    /// `hue-bridge` or `hub`, as the house log names its sources.
    public var network: String
    public var product: String?
    /// What it offers: `light`, `button`, `motion`, `temperature`, `battery`…
    public var has: [String]
    /// Why it's off on purpose, from `rooms.json`: shown greyed, never as wrong.
    public var parked: String?

    public var id: String { dev }
    public var onHub: Bool { network == "hub" }
    public var networkName: String { onHub ? "hub" : "the Bridge" }
}

/// `rooms.json`'s rooms, as the checkout has it.
public struct RoomsState: Decodable, Equatable, Sendable {
    public struct Room: Decodable, Equatable, Sendable {
        public var name: String
        public var `default`: String?
    }
    /// Empty when there's no `rooms.json`.
    public var list: [Room]
    /// The addresses it lists.
    public var devices: [String]
    /// Why it wouldn't read, when it wouldn't.
    public var err: String?

    public init(list: [Room], devices: [String], err: String?) {
        self.list = list
        self.devices = devices
        self.err = err
    }

    public func room(_ name: String) -> Room? { list.first { $0.name == name } }

    /// What a network holds that the file doesn't list yet, newest name first in
    /// name order. None while the file is missing or won't read: everything would
    /// look new.
    public func unlisted(_ held: [DeviceInfo]) -> [DeviceInfo] {
        guard err == nil, !list.isEmpty else { return [] }
        let known = Set(devices)
        return held.filter { !known.contains($0.dev) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// hub's Zigbee network as its radio sees it, from hub's `network.json`, or why
/// there's none.
public struct ZigbeeState: Decodable, Equatable, Sendable {
    public struct Use: Decodable, Equatable, Sendable {
        public var used: Int?
        public var size: Int?
    }
    public struct Device: Decodable, Equatable, Sendable {
        public var dev: String
        public var nwk: String
        /// The last hop's, for its latest frame: a router's, for a routed device.
        public var lqi: Int?
        public var rssi: Int?
    }
    public struct Network: Decodable, Equatable, Sendable {
        /// When hub wrote it, ISO.
        public var t: String
        public var up: Bool
        public var channel: Int?
        public var pan: String?
        public var children: Use
        public var neighbours: Use
        public var permit_until_ms: Int64?
        public var devices: [Device]

        public var permitUntil: Date? { permit_until_ms.map(Date.fromMs) }
    }
    public var network: Network?
    public var err: String?
}

/// What the Bridge is and holds, as `dmain admin H bridge` read it. A field the
/// Bridge doesn't report is nil: its own software update, for one.
public struct BridgeInfo: Decodable, Equatable, Sendable {
    public struct Counts: Decodable, Equatable, Sendable {
        public var devices, lights, rooms, zones, scenes, automations: Int
    }
    public var name: String?
    public var bridge_id: String?
    public var time_zone: String?
    public var model: String?
    public var product: String?
    public var software: String?
    public var update: String?
    public var channel: String?
    public var channel_status: String?
    public var discovery: String?
    public var counts: Counts

    public var searching: Bool { discovery == "active" }
}

/// One Bridge room's scenes, which its default is chosen from, as `dmain admin H scenes` read them.
public struct RoomScenes: Decodable, Equatable, Sendable {
    public var room: String
    /// Sorted; never Max, which dmain makes for the dimmers.
    public var scenes: [String]
}

extension Date {
    public static func fromMs(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
    public var ms: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
}

/// One line of `dmain admin H --json`, or of a request such as `dmain admin H restart hub`.
public enum StreamLine: Equatable, Sendable {
    case link(LinkStatus)
    case attention(Attention)
    /// Every device, by name.
    case devices([DeviceInfo])
    case rooms(RoomsState)
    /// One whole-class screen, every row.
    case table(Section)
    /// The recent log, newest first, without temperature and light level.
    case log([Event])
    /// The services, or nil before the link has reported them.
    case services([ServiceRow]?)
    case config(ConfigState)
    case console(ConsoleFeed)
    /// A request's output.
    case output(String)
    /// A request has moved on: `check`, `apply`, `read back`.
    case phase(String)
    /// A request has finished, and why if it didn't do what it was asked.
    case done(ok: Bool, why: String?)
    /// What `history` folded.
    case history(History)
    /// What `scenes` read from the Bridge.
    case scenes([RoomScenes])
    /// What `bridge` read from the Bridge.
    case bridge(BridgeInfo)
    case zigbee(ZigbeeState)

    private struct Log: Decodable {
        var events: [Event]
    }

    private struct Done: Decodable {
        var ok: Bool
        var why: String?
    }

    private struct Envelope: Decodable {
        var link: LinkStatus?
        var attention: Attention?
        var devices: [DeviceInfo]?
        var rooms: RoomsState?
        var table: Section?
        var log: Log?
        var hasServices = false
        var services: [ServiceRow]?
        var config: ConfigState?
        var console: ConsoleFeed?
        var line: String?
        var phase: String?
        var done: Done?
        var history: History?
        var scenes: [RoomScenes]?
        var bridge: BridgeInfo?
        var zigbee: ZigbeeState?

        enum CodingKeys: String, CodingKey {
            case link, attention, devices, rooms, table, log, services, config, console, line, phase, done, history, scenes, bridge, zigbee
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            link = try c.decodeIfPresent(LinkStatus.self, forKey: .link)
            attention = try c.decodeIfPresent(Attention.self, forKey: .attention)
            devices = try c.decodeIfPresent([DeviceInfo].self, forKey: .devices)
            rooms = try c.decodeIfPresent(RoomsState.self, forKey: .rooms)
            table = try c.decodeIfPresent(Section.self, forKey: .table)
            log = try c.decodeIfPresent(Log.self, forKey: .log)
            // `"services":null` says they aren't known yet, which isn't the same as no such line.
            hasServices = c.contains(.services)
            services = try c.decodeIfPresent([ServiceRow].self, forKey: .services)
            config = try c.decodeIfPresent(ConfigState.self, forKey: .config)
            console = try c.decodeIfPresent(ConsoleFeed.self, forKey: .console)
            line = try c.decodeIfPresent(String.self, forKey: .line)
            phase = try c.decodeIfPresent(String.self, forKey: .phase)
            done = try c.decodeIfPresent(Done.self, forKey: .done)
            history = try c.decodeIfPresent(History.self, forKey: .history)
            scenes = try c.decodeIfPresent([RoomScenes].self, forKey: .scenes)
            bridge = try c.decodeIfPresent(BridgeInfo.self, forKey: .bridge)
            zigbee = try c.decodeIfPresent(ZigbeeState.self, forKey: .zigbee)
        }
    }

    /// nil for a kind of line this app doesn't know, which a newer `dmain` may send.
    public static func decode(_ line: Data) throws -> StreamLine? {
        let e = try JSONDecoder().decode(Envelope.self, from: line)
        if let link = e.link { return .link(link) }
        if let attention = e.attention { return .attention(attention) }
        if let devices = e.devices { return .devices(devices) }
        if let rooms = e.rooms { return .rooms(rooms) }
        if let table = e.table { return .table(table) }
        if let log = e.log { return .log(log.events) }
        if e.hasServices { return .services(e.services) }
        if let config = e.config { return .config(config) }
        if let console = e.console { return .console(console) }
        if let line = e.line { return .output(line) }
        if let phase = e.phase { return .phase(phase) }
        if let done = e.done { return .done(ok: done.ok, why: done.why) }
        if let history = e.history { return .history(history) }
        if let scenes = e.scenes { return .scenes(scenes) }
        if let bridge = e.bridge { return .bridge(bridge) }
        if let zigbee = e.zigbee { return .zigbee(zigbee) }
        return nil
    }
}
