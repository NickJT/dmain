import AppKit
import DmainAdminCore
import SwiftUI

/// The one window: sidebar, then the chosen screen.
public struct ContentView: View {
    let house: House
    let host: String
    let reconnect: () -> Void
    /// Remembered on this Mac. `open … --args -screen battery` chooses one at launch.
    @AppStorage("screen") private var screen: Screen = .attention

    public init(house: House, host: String, reconnect: @escaping () -> Void) {
        self.house = house
        self.host = host
        self.reconnect = reconnect
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $screen) {
                ForEach(Screen.groups, id: \.0) { group, screens in
                    Section(group) {
                        ForEach(screens, id: \.self) { s in
                            SidebarRow(screen: s, count: s == .add ? house.rooms?.unlisted(house.devices).count ?? 0 : s.count(in: house.attention)).tag(s)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                LinkFoot(house: house, host: host, reconnect: reconnect)
            }
            .navigationSplitViewColumnWidth(200)
        } detail: {
            Group {
                switch screen {
                case .attention: AttentionView(house: house) { screen = $0 }
                case .powerOn, .firmware, .battery, .heard, .schedules:
                    DeviceTableView(house: house, screen: screen).id(screen)
                case .devices: DevicesView(house: house)
                case .rooms: RoomsView(house: house)
                case .add: AddDeviceView(house: house)
                case .zigbee: ZigbeeView(house: house)
                case .bridge: BridgeView(house: house)
                case .log: LogView(house: house)
                case .services: ServicesView(house: house)
                case .config: ConfigView(house: house)
                case .hub: HubConsoleView(house: house)
                case .charts: ChartsView(house: house)
                default: NotYetView(screen: screen, host: host)
                }
            }
            .navigationTitle(screen.title)
        }
        .background { ScreenKeys(screen: $screen) }
        .onChange(of: house.attention?.count, initial: true) { _, n in
            // The only way Attention reaches outside the window.
            NSApp?.dockTile.badgeLabel = (n ?? 0) > 0 ? "\(n!)" : nil
        }
    }
}

private struct SidebarRow: View {
    let screen: Screen
    let count: Int

    var body: some View {
        HStack {
            Text(screen.title)
            Spacer()
            if count > 0 {
                Text("\(count)").foregroundStyle(.orange).fontWeight(.semibold).monospacedDigit()
            }
            if let d = screen.digit {
                Text("⌘" + String(d)).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

/// ⌘0 to ⌘9 choose a screen, as the digits do in `dmain admin`.
private struct ScreenKeys: View {
    @Binding var screen: Screen

    var body: some View {
        ForEach(Screen.allCases.filter { $0.digit != nil }, id: \.self) { s in
            Button("") { screen = s }
                .keyboardShortcut(KeyEquivalent(s.digit!), modifiers: .command)
                .hidden()
        }
    }
}

/// The sidebar's foot: the link, and the newest record's time rather than a ping.
struct LinkFoot: View {
    let house: House
    let host: String
    let reconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(colour).frame(width: 8, height: 8)
                Text(host)
                Spacer()
                if house.ended != nil {
                    Button("Reconnect", action: reconnect).controlSize(.small).keyboardShortcut("r")
                }
            }
            if let newest = house.link?.newest {
                Text("newest record \(newest.formatted(date: .omitted, time: .standard))")
            }
            if let why = house.ended ?? house.link?.why {
                Text(why).foregroundStyle(house.ended != nil ? .red : .secondary).lineLimit(3)
            }
            if let at = house.reconnectAt {
                Text("trying again at \(at.formatted(date: .omitted, time: .standard))")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(10)
    }

    private var colour: Color {
        if house.ended != nil { return .red }
        switch house.link?.state {
        case .up: return .green
        case .closed: return .red
        case .connecting, .quiet, nil: return .orange
        }
    }
}

struct NotYetView: View {
    let screen: Screen
    let host: String

    var body: some View {
        ContentUnavailableView {
            Label(screen.title, systemImage: "hammer")
        } description: {
            if let d = screen.digit {
                Text("Not drawn here yet. It's screen \(String(d)) of `dmain admin \(host)`.")
            } else {
                Text("Not built yet: it waits for the log mirror.")
            }
        }
    }
}
