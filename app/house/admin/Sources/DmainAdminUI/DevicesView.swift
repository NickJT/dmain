import DmainAdminCore
import SwiftUI

/// Every device on either network, and the chosen one's page.
struct DevicesView: View {
    let house: House
    @State private var search = ""
    @State private var selection: DeviceInfo.ID?
    @State private var sortOrder = [KeyPathComparator(\DeviceInfo.name)]

    var body: some View {
        Group {
            if house.devices.isEmpty {
                ProgressView("Waiting for the house").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    Table(rows, selection: $selection, sortOrder: $sortOrder) {
                        TableColumn("Name", value: \.name) { d in
                            Text(d.name).foregroundStyle(d.parked == nil ? .primary : .tertiary)
                        }
                        TableColumn("Room") { Text($0.room ?? "") }
                        TableColumn("Network", value: \.networkName)
                        TableColumn("Product") { Text($0.product ?? "") }
                    }
                    // Without the height, until a device is chosen the table sat at its
                    // natural height, a few rows, in the middle of the window.
                    .frame(minWidth: 380, maxHeight: .infinity)
                    Group {
                        if let d = house.devices.first(where: { $0.dev == selection }) {
                            DevicePage(house: house, device: d).id(d.dev)
                        } else {
                            ContentUnavailableView("No device chosen", systemImage: "cursorarrow.click", description: Text("Choose a device to see its page."))
                        }
                    }
                    .frame(minWidth: 300, idealWidth: 360, maxHeight: .infinity)
                }
                .opacity(house.isStale ? 0.45 : 1)
            }
        }
        .navigationSubtitle("\(house.devices.count) devices, \(house.devices.filter(\.onHub).count) on hub")
        .searchable(text: $search, placement: .toolbar)
    }

    private var rows: [DeviceInfo] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let found = q.isEmpty ? house.devices : house.devices.filter {
            [$0.name, $0.room ?? "", $0.product ?? "", $0.dev].contains { $0.localizedCaseInsensitiveContains(q) }
        }
        return found.sorted(using: sortOrder)
    }
}

/// One device: who it is, what can be done to it now, and how it's doing on every screen.
struct DevicePage: View {
    let house: House
    let device: DeviceInfo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.title2).fontWeight(.semibold)
                    Text([device.room ?? "No room", device.networkName, device.product].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                    Text(device.dev).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let why = device.parked {
                    Label("Parked: \(why)", systemImage: "moon.zzz").foregroundStyle(.secondary)
                        .help("Off on purpose, as rooms.json says, so nothing counts it as wrong")
                }
                IdentifyButton(house: house, device: device, compact: false)
                DeviceEdits(house: house, device: device)
                RemoveDevice(house: house, device: device)
                DeviceDetail(house: house, dev: device.dev).padding(-12)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Rename and Move to room: each an edit dmain makes to `rooms.json` in the
/// checkout, and nothing more. The house changes when Config's rooms row is applied.
struct DeviceEdits: View {
    let house: House
    let device: DeviceInfo
    @State private var renaming = false
    @State private var name = ""
    @State private var request: Request?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Rename…") {
                    name = device.name
                    renaming = true
                }
                Menu("Move to room") {
                    ForEach(rooms, id: \.self) { room in
                        Button(room) { edit(["room", device.dev, room]) }.disabled(room == device.room)
                    }
                    Divider()
                    Button("No room") { edit(["room", device.dev]) }.disabled(device.room == nil)
                }
                .fixedSize()
            }
            .disabled(refusal != nil || request?.isRunning == true)
            .help(refusal ?? "Changes rooms.json; apply the rooms row on Config to change the house")
            if let request { RequestOutput(request: request) }
        }
        .sheet(isPresented: $renaming) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Rename \(device.name)").font(.headline)
                TextField("Name", text: $name).textFieldStyle(.roundedBorder).frame(minWidth: 320)
                    .onSubmit(save)
                Text("This changes rooms.json only. Applying the rooms row on Config renames it on \(device.networkName).")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { renaming = false }.keyboardShortcut(.cancelAction)
                    Button("Rename", action: save).keyboardShortcut(.defaultAction).disabled(!nameIsNew)
                }
            }
            .padding(20)
        }
    }

    private var rooms: [String] { house.rooms?.list.map(\.name) ?? [] }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var nameIsNew: Bool { !trimmed.isEmpty && trimmed != device.name }

    private func save() {
        guard nameIsNew else { return }
        renaming = false
        edit(["rename", device.dev, trimmed])
    }

    private func edit(_ words: [String]) { request = house.request(words) }

    private var refusal: String? {
        if house.command == nil { return "Not connected to a house" }
        if let err = house.rooms?.err { return err }
        if rooms.isEmpty { return "There's no rooms.json in the checkout" }
        return nil
    }
}

/// Identify, behind a sheet saying what it does, and how it went: in full under
/// the buttons, or `compact` as an icon beside it, for a row.
struct IdentifyButton<Others: View>: View {
    let house: House
    let device: DeviceInfo
    let compact: Bool
    @ViewBuilder var others: Others
    @State private var confirming = false
    @State private var request: Request?

    init(house: House, device: DeviceInfo, compact: Bool, @ViewBuilder others: () -> Others = { EmptyView() }) {
        self.house = house
        self.device = device
        self.compact = compact
        self.others = others()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Identify") { confirming = true }
                    .disabled(refusal != nil || house.command == nil)
                    .help(refusal ?? "Have it show itself, to find it")
                    .controlSize(compact ? .small : .regular)
                if compact, let request { outcome(request) }
                others
            }
            if !compact, let request { RequestOutput(request: request) }
        }
        .confirmationDialog("Identify \(device.name)?", isPresented: $confirming) {
            Button("Identify") {
                request = house.request(device.onHub ? ["hub", "identify", device.dev] : ["identify", device.dev])
            }
        } message: {
            Text(device.onHub
                ? "hub asks it to show itself for 10 seconds: a light flashes, then goes back to how it was. Nothing is changed."
                : "The Bridge asks it to show itself: a light breathes once, a sensor flashes its light for 15 seconds. Nothing is changed.")
        }
    }

    @ViewBuilder private func outcome(_ r: Request) -> some View {
        if r.isRunning {
            ProgressView().controlSize(.mini)
        } else if let o = r.outcome {
            Image(systemName: o.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(o.ok ? .green : .red)
                .help(o.ok ? "Done" : (o.why ?? "It failed"))
        }
    }

    /// Why Identify can't be used on this device, or nil when it can.
    private var refusal: String? {
        if device.parked != nil { return "It's parked, so it wouldn't hear it" }
        if device.onHub && !device.has.contains("light") { return "Only a light can identify: a battery device sleeps and wouldn't hear it" }
        return nil
    }
}

/// Remove…: un-joins the device from its network, waits for it to leave the
/// inventory, then takes it out of `rooms.json` and hub's `devices.json` in the
/// checkout. Behind a sheet that takes its name typed, since only pairing again
/// undoes it.
struct RemoveDevice: View {
    let house: House
    let device: DeviceInfo
    @State private var asking = false
    @State private var typed = ""
    @State private var request: Request?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Remove…", role: .destructive) {
                typed = ""
                asking = true
            }
            .disabled(house.command == nil || request?.isRunning == true)
            if let request { RequestOutput(request: request) }
        }
        .sheet(isPresented: $asking) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Remove \(device.name)").font(.headline)
                Text(what).fixedSize(horizontal: false, vertical: true)
                Text("Type its name to confirm.").foregroundStyle(.secondary)
                TextField(device.name, text: $typed).textFieldStyle(.roundedBorder).frame(minWidth: 320)
                    .onSubmit(remove)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { asking = false }.keyboardShortcut(.cancelAction)
                    Button("Remove", role: .destructive, action: remove).disabled(typed != device.name)
                }
            }
            .padding(20)
            .frame(width: 440)
        }
    }

    private var what: String {
        let leave = device.onHub
            ? "hub asks it to leave the network. A sleepy device leaves when it next wakes; press a button on it to hurry it."
            : "the Bridge deletes it, which un-joins it."
        return "\(leave) Once it has gone from the inventory, rooms.json and hub's devices.json stop listing it, and any other file that still names it is listed for a hand edit. Only pairing it again brings it back. If rooms.json still uses it in an action, a schedule or as a fan, nothing is done."
    }

    private func remove() {
        guard typed == device.name else { return }
        asking = false
        request = house.request(["remove", device.dev])
    }
}
