import DmainAdminCore

/// The sidebar's entries: the terminal's ten screens in its order and with its
/// digits, plus Charts, which has none.
public enum Screen: String, CaseIterable, Hashable, Sendable {
    case attention, rooms, devices, powerOn = "power_on", firmware, battery, heard, schedules, add, zigbee, bridge, log, hub, config, services, charts

    var title: String {
        switch self {
        case .attention: "Attention"
        case .rooms: "Rooms"
        case .devices: "All devices"
        case .powerOn: "Power-on"
        case .firmware: "Firmware"
        case .battery: "Battery"
        case .heard: "Last heard"
        case .schedules: "Schedules"
        case .add: "Add a device"
        case .zigbee: "Zigbee"
        case .bridge: "Bridge"
        case .log: "Log"
        case .hub: "hub console"
        case .config: "Config"
        case .services: "Services"
        case .charts: "Charts"
        }
    }

    /// ⌘ and this digit, as `dmain admin` takes the digit alone.
    var digit: Character? {
        switch self {
        case .attention: "0"
        case .powerOn: "1"
        case .firmware: "2"
        case .battery: "3"
        case .heard: "4"
        case .schedules: "5"
        case .log: "6"
        case .hub: "7"
        case .config: "8"
        case .services: "9"
        case .charts, .devices, .rooms, .add, .zigbee, .bridge: nil
        }
    }

    static let groups: [(String, [Screen])] = [
        ("House", [.attention, .rooms]),
        ("Devices", [.devices, .powerOn, .firmware, .battery, .heard, .schedules]),
        ("Network", [.add, .zigbee, .bridge]),
        ("History", [.charts, .log]),
        ("System", [.hub, .config, .services]),
    ]

    /// How many rows differ on this screen, as far as Attention says.
    func count(in a: Attention?) -> Int {
        guard let a else { return 0 }
        switch self {
        case .attention: return a.count
        case .services: return a.services?.count ?? 0
        case .config: return a.config?.count ?? 0
        case .devices, .rooms, .add, .zigbee, .bridge: return 0
        default: return a.section(rawValue)?.count ?? 0
        }
    }
}
