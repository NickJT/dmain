import DmainAdminCore
import SwiftUI

/// The rooms, as each network's inventory names them, and the chosen one's page.
/// Until `rooms.json` exists the two networks can spell a room differently, and
/// then it shows twice: which is what that file is for.
struct RoomsView: View {
    let house: House
    @AppStorage("room") private var chosen = ""

    var body: some View {
        Group {
            if house.devices.isEmpty {
                ProgressView("Waiting for the house").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(selection: Binding(get: { chosen.isEmpty ? nil : chosen }, set: { chosen = $0 ?? "" })) {
                        ForEach(rooms, id: \.self) { room in
                            HStack {
                                Text(room)
                                Spacer()
                                Text("\(devices(in: room).count)").foregroundStyle(.secondary).monospacedDigit()
                            }
                            .tag(room)
                        }
                    }
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 300, maxHeight: .infinity)
                    Group {
                        if rooms.contains(chosen) {
                            RoomPage(house: house, room: chosen, devices: devices(in: chosen)).id(chosen)
                        } else {
                            ContentUnavailableView("No room chosen", systemImage: "door.left.hand.closed", description: Text("Choose a room to see what's in it."))
                        }
                    }
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
                .opacity(house.isStale ? 0.45 : 1)
            }
        }
        .navigationSubtitle("\(rooms.count) rooms, as the Bridge and hub name them")
    }

    static let noRoom = "No room"

    private var rooms: [String] {
        Set(house.devices.map { $0.room ?? Self.noRoom }).sorted { a, b in
            // The devices with no room last, where they read as a to-do.
            if (a == Self.noRoom) != (b == Self.noRoom) { return b == Self.noRoom }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    private func devices(in room: String) -> [DeviceInfo] {
        house.devices.filter { ($0.room ?? Self.noRoom) == room }
    }
}

/// What a device is, for grouping a room: from what it offers.
enum DeviceKind: String, CaseIterable {
    case lights = "Lights", switches = "Switches", sensors = "Sensors", other = "Other"

    var one: String {
        switch self {
        case .lights: "light"
        case .switches: "switch"
        case .sensors: "sensor"
        case .other: "other"
        }
    }

    init(_ d: DeviceInfo) {
        if d.has.contains("light") { self = .lights }
        else if d.has.contains("button") || d.has.contains("rotary") { self = .switches }
        else if !Set(d.has).isDisjoint(with: ["motion", "temperature", "humidity", "light_level", "alarm"]) { self = .sensors }
        else { self = .other }
    }
}

/// One room: its devices on both networks, how each is doing, and Identify.
struct RoomPage: View {
    let house: House
    let room: String
    let devices: [DeviceInfo]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(room).font(.title2).fontWeight(.semibold)
                    Text(summary).foregroundStyle(.secondary)
                }
                RoomDefault(house: house, room: room)
                if let err = house.rooms?.err { Text(err).foregroundStyle(.red) }
                // One grid for every kind, so the columns line up down the page.
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                    ForEach(DeviceKind.allCases, id: \.self) { kind in
                        let list = devices.filter { DeviceKind($0) == kind }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                        if !list.isEmpty {
                            GridRow {
                                Text(kind.rawValue.uppercased()).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                                    .padding(.top, 10).gridCellColumns(3)
                            }
                            ForEach(list) { d in
                                GridRow {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(d.name).foregroundStyle(d.parked != nil ? Color.secondary : mark(d) == .none ? Color.primary : mark(d).colour)
                                        Text([d.product, d.networkName].compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(state(d)).foregroundStyle(.secondary)
                                    IdentifyButton(house: house, device: d, compact: true)
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var summary: String {
        let counts = DeviceKind.allCases.compactMap { k -> String? in
            let n = devices.filter { DeviceKind($0) == k }.count
            return n == 0 ? nil : "\(n) \(n == 1 ? k.one : k.rawValue.lowercased())"
        }
        return counts.joined(separator: ", ")
    }

    /// The worst mark on any of the device's rows.
    private func mark(_ d: DeviceInfo) -> Mark {
        let marks = house.device(d.dev).map(\.1.mark)
        return marks.contains(.broken) ? .broken : marks.contains(.differs) ? .differs : .none
    }

    /// Its link and when last heard, and its battery when it has one.
    private func state(_ d: DeviceInfo) -> String {
        if let why = d.parked { return "parked: \(why)" }
        let rows = house.device(d.dev)
        var parts: [String] = []
        if let heard = rows.first(where: { $0.0.screen == "heard" })?.1.cells, heard.count > 2 {
            parts.append(heard[1] == "connected" ? heard[2] : "\(heard[1]), \(heard[2])")
        }
        if let battery = rows.first(where: { $0.0.screen == "battery" })?.1.cells, battery.count > 1 {
            parts.append("battery \(battery[1])")
        }
        return parts.joined(separator: " · ")
    }
}

/// A room's default scene from `rooms.json`, and Choose…, which picks it from the
/// scenes the Bridge has for the room now. Choosing edits `rooms.json` in the
/// checkout and nothing more: the house changes when Config's rows are applied.
struct RoomDefault: View {
    let house: House
    let room: String
    @State private var choosing = false
    @State private var request: Request?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                LabeledContent("Default scene") { current }.fixedSize()
                Button("Choose…") { choosing = true }
                    .disabled(refusal != nil || request?.isRunning == true)
                    .help(refusal ?? "Pick from the room's scenes on the Bridge; this changes rooms.json only")
            }
            if let request { RequestOutput(request: request) }
        }
        .sheet(isPresented: $choosing) {
            ChooseDefault(house: house, room: room, current: house.rooms?.room(room)?.default) { scene in
                choosing = false
                request = house.request(["default", room, scene])
            } cancel: {
                choosing = false
            }
        }
    }

    @ViewBuilder private var current: some View {
        if house.rooms?.list.isEmpty ?? true {
            Text("no rooms.json").foregroundStyle(.tertiary)
        } else if let name = house.rooms?.room(room)?.default {
            Text(name)
        } else {
            Text("none").foregroundStyle(.tertiary)
        }
    }

    private var refusal: String? {
        if house.command == nil { return "Not connected to a house" }
        if let err = house.rooms?.err { return err }
        if house.rooms?.room(room) == nil { return "rooms.json has no room called \(room)" }
        return nil
    }
}

/// The sheet: reads the room's scenes from the Bridge as it opens, since the Hue
/// app may have changed them, and offers them.
struct ChooseDefault: View {
    let house: House
    let room: String
    let current: String?
    let choose: (String) -> Void
    let cancel: () -> Void
    @State private var reading: Request?
    @State private var picked: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Default scene for \(room)").font(.headline)
            content.frame(minWidth: 320, minHeight: 120, alignment: .topLeading)
            Text("The default is what the room's dimmers, its sensors and the Dial recall. This changes rooms.json only; Config's rooms, switches, sensors and actions rows then show what it would change.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Make default") { if let picked { choose(picked) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked == nil || picked == current)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            picked = current
            reading = house.request(["scenes"])
        }
    }

    @ViewBuilder private var content: some View {
        if let reading {
            if reading.isRunning {
                ProgressView("Reading the Bridge's scenes")
            } else if let why = reading.outcome?.why, reading.outcome?.ok == false {
                Text("Couldn't read the scenes: \(why)").foregroundStyle(.red)
            } else if let scenes = reading.scenes?.first(where: { $0.room == room })?.scenes {
                if scenes.isEmpty {
                    Text("The Bridge has no scenes for \(room). Make one in the Hue app.").foregroundStyle(.secondary)
                } else {
                    Picker("Scene", selection: $picked) {
                        ForEach(scenes, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    if let current, !scenes.contains(current) {
                        Text("\(current), the default now, isn't on the Bridge.").foregroundStyle(.orange)
                    }
                }
            } else {
                Text("The Bridge has no room called \(room), so it has no scenes.").foregroundStyle(.secondary)
            }
        } else {
            Text("Not connected to a house").foregroundStyle(.secondary)
        }
    }
}
