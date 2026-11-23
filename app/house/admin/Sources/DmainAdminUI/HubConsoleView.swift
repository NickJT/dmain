import DmainAdminCore
import SwiftUI

/// hub's console: its lines, which carry every command's reply, and a line to
/// send. A line goes as typed; hub's own refusals and `confirm` words decide what runs.
struct HubConsoleView: View {
    let house: House
    @State private var typed = ""
    @State private var sending: Request?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if house.isStale { StaleBanner(house: house) }
            LinesBox(lines: house.console?.lines ?? []).opacity(house.isStale ? 0.45 : 1)
            HStack {
                TextField("A hub command, such as list", text: $typed)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(send)
                if sending?.isRunning == true { ProgressView().controlSize(.small) }
                Button("Send", action: send).disabled(!canSend).keyboardShortcut(.defaultAction)
            }
            if let o = sending?.outcome, !o.ok {
                Text(o.why ?? "It wasn't sent").foregroundStyle(.red)
            } else {
                Text("Sent as typed. hub's own refusals and `confirm` words decide what runs.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .navigationSubtitle(house.console?.state.text ?? "")
        .onAppear { focused = true }
    }

    private var canSend: Bool {
        !typed.trimmingCharacters(in: .whitespaces).isEmpty && sending?.isRunning != true && !house.isStale
    }

    private func send() {
        guard canSend else { return }
        let words = typed.split(separator: " ").map(String.init)
        sending = house.request(["hub"] + words)
        typed = ""
    }
}
