import DmainAdminCore
import SwiftUI

/// hub's Zigbee network as its radio sees it: channel, PAN, how full its tables
/// are, Permit with a countdown, and each device's short address and last-hop link,
/// worst first. hub rewrites the file once a minute and at once on a Permit.
struct ZigbeeView: View {
    let house: House
    @State private var permitRequest: Request?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let n = house.zigbee?.network {
                    facts(n)
                    permit(n)
                    devices(n)
                } else if let why = house.zigbee?.err {
                    Text(why).foregroundStyle(.red)
                    Text("hub writes network.json once a minute; an older hub writes none.").foregroundStyle(.secondary)
                } else {
                    ProgressView("Waiting for the house")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(house.isStale ? 0.45 : 1)
    }

    private func facts(_ n: ZigbeeState.Network) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
            row("Network", n.up ? "up" : "down", bad: !n.up)
            row("Channel", n.channel.map(String.init))
            row("PAN id", n.pan)
            row("End-device children", use(n.children), bad: full(n.children))
            row("Router neighbours", use(n.neighbours), bad: full(n.neighbours))
            row("As of", Self.isoTime(n.t))
        }
    }

    private func permit(_ n: ZigbeeState.Network) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("JOINING").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let left = n.permitUntil.map { Int($0.timeIntervalSince(ctx.date).rounded(.up)) } ?? 0
                HStack(spacing: 12) {
                    Button("Permit for 60 s") { permitRequest = house.request(["hub", "permit", "60"]) }
                        .disabled(house.command == nil || left > 0 || permitRequest?.isRunning == true || !n.up)
                    Text(left > 0 ? "open, \(left) s left" : "closed")
                        .foregroundStyle(left > 0 ? Color.orange : Color.secondary).monospacedDigit()
                }
            }
            Text("Reset the device first. What joins shows on Add a device once hub lists it.")
                .font(.callout).foregroundStyle(.secondary)
            if let permitRequest { RequestOutput(request: permitRequest) }
        }
    }

    private func devices(_ n: ZigbeeState.Network) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DEVICES").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            Text("Link quality is the last hop's, from the latest frame since hub started: for a device routed through a router, it's that router's link.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    ForEach(["Name", "Address", "LQI", "RSSI", "Last heard"], id: \.self) {
                        Text($0).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(Self.worstFirst(n.devices), id: \.dev) { d in
                    GridRow {
                        Text(name(d.dev))
                        Text(d.nwk).font(.system(.body, design: .monospaced))
                        Text(d.lqi.map(String.init) ?? "–").monospacedDigit().gridColumnAlignment(.trailing)
                            .foregroundStyle((d.lqi ?? 255) < 100 ? Color.orange : Color.primary)
                        Text(d.rssi.map { "\($0) dBm" } ?? "–").monospacedDigit().gridColumnAlignment(.trailing)
                        Text(heard(d.dev)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Lowest link quality first; a device not heard since hub started, last.
    static func worstFirst(_ list: [ZigbeeState.Device]) -> [ZigbeeState.Device] {
        list.sorted { a, b in
            switch (a.lqi, b.lqi) {
            case let (x?, y?): x < y
            case (.some, nil): true
            default: false
            }
        }
    }

    private func name(_ dev: String) -> String {
        house.devices.first { $0.dev == dev }?.name ?? dev
    }

    /// From the house log, as Last heard shows it.
    private func heard(_ dev: String) -> String {
        guard let cells = house.device(dev).first(where: { $0.0.screen == "heard" })?.1.cells, cells.count > 2 else { return "" }
        return cells[2]
    }

    private func use(_ u: ZigbeeState.Use) -> String? {
        switch (u.used, u.size) {
        case let (used?, size?): "\(used) of \(size)"
        case let (used?, nil): "\(used)"
        case let (nil, size?): "? of \(size)"
        default: nil
        }
    }

    private func full(_ u: ZigbeeState.Use) -> Bool {
        guard let used = u.used, let size = u.size, size > 0 else { return false }
        return used * 10 >= size * 9
    }

    private func row(_ label: String, _ value: String?, bad: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value ?? "not reported").foregroundStyle(value == nil ? Color.secondary : bad ? Color.orange : Color.primary)
        }
    }

    static func isoTime(_ t: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: t) else { return t }
        return d.formatted(date: .omitted, time: .standard)
    }
}
