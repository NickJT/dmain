import DmainAdminCore
import SwiftUI

/// What a network holds that `rooms.json` doesn't list yet, each named and placed
/// here. Pairing itself happens elsewhere: the Hue app for the Bridge, `permit`
/// on hub's console. A device shows here once its network's inventory reports it.
/// Adding edits `rooms.json` in the checkout and nothing more; Config's rooms row
/// then names and places it on its network.
struct AddDeviceView: View {
    let house: House

    var body: some View {
        let new = house.rooms?.unlisted(house.devices) ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Pair a device in the Hue app, or with `permit` on hub's console. It shows here once its network reports it; name it and choose its room. That changes rooms.json only, and applying the rooms row on Config names and places it.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let why = refusal {
                    Text(why).foregroundStyle(.red)
                } else if new.isEmpty {
                    ContentUnavailableView("Every device is in rooms.json", systemImage: "checkmark.circle",
                                           description: Text("A newly paired device appears here."))
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(new) { d in
                        NewDeviceRow(house: house, device: d).id(d.dev)
                        Divider()
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(house.isStale ? 0.45 : 1)
    }

    private var refusal: String? {
        if house.command == nil { return "Not connected to a house" }
        if let err = house.rooms?.err { return err }
        if house.rooms?.list.isEmpty ?? true { return "There's no rooms.json in the checkout" }
        return nil
    }
}

/// One new device: what its network says it is, a name and a room, and Add.
struct NewDeviceRow: View {
    let house: House
    let device: DeviceInfo
    @State private var name = ""
    @State private var room: String?
    @State private var request: Request?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name).fontWeight(.semibold)
                    Text([device.product, device.networkName, device.dev].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                IdentifyButton(house: house, device: device, compact: true)
            }
            HStack(spacing: 12) {
                TextField("Name", text: $name).textFieldStyle(.roundedBorder).frame(minWidth: 220, maxWidth: 320)
                Picker("Room", selection: $room) {
                    Text("No room").tag(String?.none)
                    ForEach(rooms, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .fixedSize()
                Button("Add", action: add)
                    .disabled(trimmed.isEmpty || request?.isRunning == true)
                    .help("Lists it in rooms.json; apply the rooms row on Config to name and place it on \(device.networkName)")
            }
            if let request { RequestOutput(request: request) }
        }
        .onAppear {
            name = device.name
            // The network's room when the file has one of that name.
            room = device.room.flatMap { r in rooms.contains(r) ? r : nil }
        }
    }

    private var rooms: [String] { house.rooms?.list.map(\.name) ?? [] }
    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    private func add() {
        var words = ["add", device.dev, trimmed]
        if let room { words.append(room) }
        request = house.request(words)
    }
}
