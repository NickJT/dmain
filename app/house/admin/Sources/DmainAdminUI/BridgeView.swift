import DmainAdminCore
import SwiftUI

/// What the Bridge is and holds, read from it when the page opens and on Refresh,
/// and Search, which starts its own device search. A device it finds reaches the
/// inventory as an add, and shows on Add a device.
struct BridgeView: View {
    let house: House
    @State private var reading: Request?
    @State private var info: BridgeInfo?
    @State private var searchRequest: Request?
    /// While the Bridge searches, it's read again every few seconds to see it finish.
    @State private var watching: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Button("Refresh", action: read).disabled(house.command == nil || reading?.isRunning == true)
                    if reading?.isRunning == true { ProgressView().controlSize(.small) }
                    if let r = reading, r.outcome?.ok == false, let why = r.outcome?.why {
                        Text(why).foregroundStyle(.red)
                    }
                }
                if let info {
                    facts(info)
                    holds(info.counts)
                    search(info)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // At launch the page can show before the house is connected.
        .onChange(of: house.command == nil, initial: true) { _, none in
            if !none && info == nil && reading?.isRunning != true { read() }
        }
        .onDisappear { watching?.cancel() }
    }

    private func facts(_ b: BridgeInfo) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
            row("Name", b.name)
            row("Model", [b.product, b.model].compactMap { $0 }.joined(separator: " · "))
            row("Software", b.software)
            row("Update", b.update.map(Self.words) ?? "not reported by the Bridge for itself")
            row("Zigbee channel", b.channel.map { $0.replacingOccurrences(of: "channel_", with: "") + (b.channel_status == "changing" ? ", changing" : "") })
            row("Bridge id", b.bridge_id)
            row("Time zone", b.time_zone)
        }
    }

    private func holds(_ c: BridgeInfo.Counts) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("HOLDS").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                count("Devices", c.devices)
                count("Lights", c.lights)
                count("Rooms", c.rooms)
                count("Zones", c.zones)
                count("Scenes", c.scenes)
                count("Automations", c.automations)
            }
        }
    }

    private func search(_ b: BridgeInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DEVICE SEARCH").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Search", action: startSearch)
                    .disabled(house.command == nil || b.searching || searchRequest?.isRunning == true)
                Text(b.searching ? "Searching…" : "Ready").foregroundStyle(b.searching ? .orange : .secondary)
            }
            Text("Reset the device first. A plain search only: a serial number or install code still goes through the Hue app. What it finds shows on Add a device.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let searchRequest { RequestOutput(request: searchRequest) }
        }
    }

    private func row(_ label: String, _ value: String?) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value ?? "not reported").foregroundStyle(value == nil ? .tertiary : .primary).textSelection(.enabled)
        }
    }

    private func count(_ label: String, _ n: Int) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text("\(n)").monospacedDigit().gridColumnAlignment(.trailing)
        }
    }

    static func words(_ state: String) -> String {
        state.replacingOccurrences(of: "_", with: " ")
    }

    private func read() {
        reading = house.request(["bridge"]) { r in
            if let b = r.bridge { info = b }
        }
    }

    private func startSearch() {
        searchRequest = house.request(["search"]) { r in
            guard r.outcome?.ok == true else { return }
            watch()
        }
    }

    /// Reads again every 5 s until the search has finished, for at most 5 minutes.
    private func watch() {
        watching?.cancel()
        watching = Task {
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
                read()
                try? await Task.sleep(for: .seconds(3))
                if info?.searching == false { return }
            }
        }
    }
}
