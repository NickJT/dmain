import DmainAdminCore
import SwiftUI

/// The house services as systemd has them, the chosen one's journal, and a
/// restart behind a sheet that says what it stops.
struct ServicesView: View {
    let house: House
    @State private var chosen: String? = "hub"
    @State private var journal: Request?
    @State private var restart: ServiceRow?
    @State private var restarting: Request?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if house.isStale { StaleBanner(house: house) }
            if let list = house.services {
                Table(list, selection: $chosen) {
                    TableColumn("Service") { s in Text(s.unit).fontWeight(.semibold).foregroundStyle(s.mark.colour) }
                    TableColumn("State") { s in Text(s.state).foregroundStyle(s.mark == .broken ? .red : .primary) }
                    TableColumn("Enabled", value: \.enabled)
                    TableColumn("Since") { s in Text(s.since ?? "") }
                    TableColumn("Restarts") { s in Text("\(s.restarts)") }
                    TableColumn("Binary") { s in
                        Text(s.newerBinary ? "newer than its start: restart to run it" : "as started")
                            .foregroundStyle(s.newerBinary ? Mark.differs.colour : .primary)
                    }
                }
                .frame(height: 130)
                HStack {
                    Text(chosen.map { "\($0): journal, following" } ?? "Choose a service").font(.headline).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart \(chosen ?? "")…") { restart = list.first { $0.unit == chosen } }
                        .disabled(chosen == nil || house.isStale)
                }
                LinesBox(lines: journal?.lines ?? [])
            } else {
                ProgressView("Waiting for the services").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .opacity(house.isStale ? 0.6 : 1)
        .onChange(of: chosen, initial: true) { _, unit in follow(unit) }
        // The screen can open before the app has connected, or reconnect under it.
        .onChange(of: house.command) { follow(chosen) }
        .onDisappear { journal?.stop() }
        .sheet(item: $restart) { s in
            RestartSheet(service: s, house: house, request: $restarting) { restart = nil; restarting = nil }
        }
    }

    private func follow(_ unit: String?) {
        journal?.stop()
        journal = unit.flatMap { house.request(["journal", $0]) }
    }
}

extension ServiceRow: Identifiable {
    public var id: String { unit }
}

private struct RestartSheet: View {
    let service: ServiceRow
    let house: House
    @Binding var request: Request?
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Restart \(service.unit) on the house server?").font(.headline)
            Text("While it starts, \(service.cost).").foregroundStyle(.secondary)
            if let request { RequestOutput(request: request) }
            HStack {
                Spacer()
                if let request, !request.isRunning {
                    Button("Close", action: close).keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", action: close).keyboardShortcut(.cancelAction).disabled(request != nil)
                    Button("Restart \(service.unit)") { request = house.request(["restart", service.unit]) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(request != nil)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
