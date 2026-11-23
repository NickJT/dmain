import AppKit
import DmainAdminCore
import SwiftUI

/// The wanted files in the checkout, each one's last dry run, and Apply behind
/// a sheet that shows the changes again. No form edits a value: Zed does.
struct ConfigView: View {
    let house: House
    @State private var chosen: String? = "switches"
    @State private var applying: ConfigTarget?
    @State private var request: Request?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if house.isStale { StaleBanner(house: house) }
            if let targets = house.config?.targets {
                Table(targets, selection: $chosen) {
                    TableColumn("Wanted") { t in Text(t.name).fontWeight(.semibold).foregroundStyle(t.mark.colour) }
                    TableColumn("Files", value: \.files)
                    TableColumn("To", value: \.to)
                    TableColumn("Says") { t in Text(t.status).foregroundStyle(t.mark == .none ? .primary : t.mark.colour) }
                        .width(min: 260, ideal: 420)
                }
                .frame(height: 150)
                if let t = targets.first(where: { $0.name == chosen }) {
                    Text("\(t.name): \(t.what)").font(.headline).foregroundStyle(.secondary)
                    LinesBox(lines: t.lines)
                    HStack {
                        Button("Edit in Zed") { openInZed(t.paths) }
                        Spacer()
                        if let why = t.refusal { Text(why).foregroundStyle(.secondary) }
                        Button("Apply…") { applying = t }
                            .disabled(t.refusal != nil || t.hash == nil || house.isStale)
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else if house.config != nil {
                ContentUnavailableView("No checkout", systemImage: "folder.badge.questionmark",
                                       description: Text("dmain found no wanted files. Set the checkout to app/house/dmain in the git tree."))
            } else {
                ProgressView("Waiting for the house").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .opacity(house.isStale ? 0.6 : 1)
        .navigationSubtitle(house.config?.checkout.map { "The checkout at \($0) is what's applied" } ?? "")
        .sheet(item: $applying) { t in
            ApplySheet(target: t, house: house, request: $request) { applying = nil; request = nil }
        }
    }

    private func openInZed(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let ws = NSWorkspace.shared
        if let zed = ws.urlForApplication(withBundleIdentifier: "dev.zed.Zed") {
            ws.open(urls, withApplicationAt: zed, configuration: NSWorkspace.OpenConfiguration())
        } else {
            for u in urls { ws.open(u) }
        }
    }
}

extension ConfigTarget: Identifiable {
    public var id: String { name }
}

private struct ApplySheet: View {
    let target: ConfigTarget
    let house: House
    @Binding var request: Request?
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Write \(target.files) to \(target.to)?").font(.headline)
            if let request {
                RequestOutput(request: request)
                if !request.isRunning {
                    Text("The screens reconnect now, so what they show is checked again.").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text("It's checked again first, and written only if the files are still as this dry run saw them. Each change's old setup is kept in backups/ on the server.")
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(target.lines.joined(separator: "\n"))
                        .font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 220)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Spacer()
                if let request, !request.isRunning {
                    Button("Close", action: close).keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", action: close).keyboardShortcut(.cancelAction).disabled(request != nil)
                    Button("Apply") {
                        if let hash = target.hash { request = house.request(["apply", target.name, hash]) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(request != nil)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
