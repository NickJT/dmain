import DmainAdminCore
import SwiftUI

/// What every other screen marks, a card each, then the latest events. Every
/// sentence is dmain's; this only lays them out.
struct AttentionView: View {
    let house: House
    let open: (Screen) -> Void

    private static let shownRows = 5
    private static let shownEvents = 6

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if house.isStale { StaleBanner(house: house) }
                if let a = house.attention {
                    Text(a.count == 0 ? "Nothing differs from what it should be" : "\(a.count) \(a.count == 1 ? "thing differs" : "things differ") from what \(a.count == 1 ? "it" : "they") should be")
                        .font(.title3).foregroundStyle(.secondary)
                    content(a).opacity(house.isStale ? 0.45 : 1)
                } else {
                    ProgressView("Waiting for the house").frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func content(_ a: Attention) -> some View {
        ForEach(Array((a.services ?? []).enumerated()), id: \.offset) { _, item in
            Card(label: "Services", screen: .services, open: open) { ItemText(item: item) }
        }
        ForEach(Array((a.config ?? []).enumerated()), id: \.offset) { _, item in
            Card(label: "Config", screen: .config, open: open) { ItemText(item: item) }
        }
        ForEach(a.sections.filter { $0.count > 0 }, id: \.screen) { section in
            Card(label: section.label, screen: Screen(rawValue: section.screen) ?? .attention, open: open) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.summary)
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
                        ForEach(Array(section.rows.prefix(Self.shownRows).enumerated()), id: \.offset) { _, row in
                            GridRow {
                                ForEach(Array(row.cells.enumerated()), id: \.offset) { i, cell in
                                    Text(cell).foregroundStyle(i == 0 ? row.mark.colour : .primary)
                                        .fontWeight(i == 0 ? .semibold : .regular)
                                }
                            }
                        }
                    }
                    if section.count > Self.shownRows {
                        Text("and \(section.count - Self.shownRows) more").foregroundStyle(.secondary)
                    }
                }
            }
        }
        Text(quiet(a)).foregroundStyle(.secondary).padding(.horizontal, 2)
        Text("Latest events").font(.headline).foregroundStyle(.secondary).padding(.top, 6)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(house.log.prefix(Self.shownEvents).enumerated()), id: \.offset) { _, e in
                Text("\(e.at)  \(e.text)").foregroundStyle(e.mark == .none ? .primary : e.mark.colour)
            }
        }
        .font(.system(.body, design: .monospaced))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    /// The screens with nothing marked, and hub's console, in a line.
    private func quiet(_ a: Attention) -> String {
        var clear = a.sections.filter { $0.count == 0 }.map(\.label)
        if a.services?.isEmpty == true { clear.append("Services") }
        if a.config?.isEmpty == true { clear.append("Config") }
        let start = clear.isEmpty ? "" : "Nothing differs: \(clear.joined(separator: ", ")). "
        return start + a.console.text + "."
    }
}

private struct Card<Content: View>: View {
    let label: String
    let screen: Screen
    let open: (Screen) -> Void
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label).fontWeight(.semibold).frame(width: 90, alignment: .leading)
            content
            Spacer(minLength: 8)
            Button("\(screen.title) ›") { open(screen) }.buttonStyle(.link)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }
}

private struct ItemText: View {
    let item: Item
    var body: some View {
        (Text(item.name).foregroundStyle(item.mark.colour).fontWeight(.semibold) + Text(": \(item.text)"))
    }
}

/// Stale must look stale: what's below is as it was, and since when.
struct StaleBanner: View {
    let house: House
    var body: some View {
        let since = house.since.map { " since \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
        let what = house.ended != nil ? "dmain has stopped" : house.link?.state == .connecting ? "Connecting" : "The link is quiet"
        let why = house.ended ?? house.link?.why
        Label("\(what)\(since)\(why.map { ": \($0)" } ?? ""). What's shown is as it was.", systemImage: "clock.badge.exclamationmark")
            .foregroundStyle(house.ended != nil ? .red : .orange)
    }
}

extension Mark {
    var colour: Color {
        switch self {
        case .none: .primary
        case .differs: .orange
        case .broken: .red
        }
    }
}
