import DmainAdminCore
import SwiftUI

/// Both house logs' recent lines, newest first, without temperature and light level.
struct LogView: View {
    let house: House
    @State private var source = "all"
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if house.isStale { StaleBanner(house: house).padding(10) }
            List(Array(shown.enumerated()), id: \.offset) { _, e in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(e.at).foregroundStyle(.secondary)
                    Text(e.text).foregroundStyle(e.mark == .none ? .primary : e.mark.colour)
                }
                .font(.system(.body, design: .monospaced))
            }
            .opacity(house.isStale ? 0.45 : 1)
        }
        .navigationSubtitle("\(shown.count) of \(house.log.count) lines")
        .searchable(text: $search, placement: .toolbar)
        .toolbar {
            ToolbarItem {
                Picker("Source", selection: $source) {
                    Text("All").tag("all")
                    Text("Hue").tag("hue")
                    Text("hub").tag("hub")
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var shown: [Event] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return house.log.filter { e in
            (source == "all" || e.src == source) && (q.isEmpty || e.text.localizedCaseInsensitiveContains(q))
        }
    }
}
