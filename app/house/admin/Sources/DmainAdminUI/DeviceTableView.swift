import DmainAdminCore
import SwiftUI

/// A row with its place in dmain's order, which is the order shown until a
/// column is clicked.
struct IndexedRow: Identifiable {
    let id: Int
    let row: Row
}

/// Sorts by one column's text, numbers by value, so "5%" comes before "11%".
/// Ages ("3 h ago") don't sort by time this way; dmain's own order does that.
struct CellComparator: SortComparator, Hashable {
    let index: Int
    var order: SortOrder = .forward

    func compare(_ a: IndexedRow, _ b: IndexedRow) -> ComparisonResult {
        let x = index < a.row.cells.count ? a.row.cells[index] : ""
        let y = index < b.row.cells.count ? b.row.cells[index] : ""
        let r = x.localizedStandardCompare(y)
        guard order == .reverse else { return r }
        switch r {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}

/// One class across every device, marked rows first, with the device inspector.
struct DeviceTableView: View {
    let house: House
    let screen: Screen
    @State private var differingOnly = false
    @State private var search = ""
    @State private var sortOrder: [CellComparator] = []
    @State private var selection: IndexedRow.ID?
    @State private var showInspector = true

    var body: some View {
        Group {
            if let t = house.tables[screen.rawValue] {
                VStack(alignment: .leading, spacing: 0) {
                    if house.isStale { StaleBanner(house: house).padding(10) }
                    table(t).opacity(house.isStale ? 0.45 : 1)
                }
                .navigationSubtitle(t.summary)
                .help(t.summary)
            } else {
                ProgressView("Waiting for the house").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .searchable(text: $search, placement: .toolbar)
        .toolbar {
            // Schedules are listed, not compared, and aren't devices.
            if screen != .schedules {
                ToolbarItem {
                    Picker("Show", selection: $differingOnly) {
                        Text("All").tag(false)
                        Text("Differing").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                ToolbarItem {
                    Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                }
            }
        }
        .inspector(isPresented: inspectorShown) {
            DeviceInspector(house: house, dev: selectedDev).inspectorColumnWidth(min: 220, ideal: 260)
        }
    }

    /// Schedules aren't devices, so they have nothing to inspect.
    private var inspectorShown: Binding<Bool> {
        Binding(get: { showInspector && screen != .schedules }, set: { showInspector = $0 })
    }

    private var selectedDev: String? {
        guard let id = selection, let t = house.tables[screen.rawValue], id < t.rows.count else { return nil }
        return t.rows[id].dev
    }

    private func rows(_ t: DmainAdminCore.Section) -> [IndexedRow] {
        var rows = t.rows.enumerated().map { IndexedRow(id: $0.offset, row: $0.element) }
        if differingOnly { rows = rows.filter { $0.row.mark != .none } }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { rows = rows.filter { $0.row.cells.contains { $0.localizedCaseInsensitiveContains(q) } } }
        if !sortOrder.isEmpty { rows.sort(using: sortOrder) }
        return rows
    }

    private func table(_ t: DmainAdminCore.Section) -> some View {
        Table(rows(t), selection: $selection, sortOrder: $sortOrder) {
            TableColumnForEach(Array(t.columns.indices), id: \.self) { i in
                TableColumn(t.columns[i], sortUsing: CellComparator(index: i)) { (r: IndexedRow) in
                    let text = i < r.row.cells.count ? r.row.cells[i] : ""
                    Text(text)
                        .foregroundStyle(i == 0 && r.row.mark != .none ? r.row.mark.colour : .primary)
                        .fontWeight(i == 0 && r.row.mark != .none ? .semibold : .regular)
                }
            }
        }
    }
}

/// One device across every class, and its last few events.
struct DeviceInspector: View {
    let house: House
    let dev: String?

    var body: some View {
        if let dev, !house.device(dev).isEmpty {
            ScrollView { DeviceDetail(house: house, dev: dev) }
        } else {
            ContentUnavailableView("No device chosen", systemImage: "cursorarrow.click", description: Text("Choose a row to see that device on every screen."))
        }
    }
}

struct DeviceDetail: View {
    let house: House
    let dev: String

    var body: some View {
        let found = house.device(dev)
        VStack(alignment: .leading, spacing: 4) {
            Text(found.first?.1.cells.first ?? dev).font(.headline)
            Text(dev).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            ForEach(found, id: \.0.screen) { section, row in
                // A mark belongs to the row, not to one value, so it colours the heading.
                Text(section.label.uppercased()).font(.caption).fontWeight(.semibold)
                    .foregroundStyle(row.mark == .none ? .secondary : row.mark.colour).padding(.top, 10)
                ForEach(Array(section.columns.indices.dropFirst()), id: \.self) { i in
                    HStack(alignment: .firstTextBaseline) {
                        Text(section.columns[i]).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(i < row.cells.count ? row.cells[i] : "").multilineTextAlignment(.trailing)
                    }
                }
            }
            let events = house.log.filter { $0.dev == dev }.prefix(6)
            Text("RECENT").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary).padding(.top, 10)
            if events.isEmpty {
                Text("Nothing in the recent log").foregroundStyle(.secondary)
            }
            ForEach(Array(events.enumerated()), id: \.offset) { _, e in
                Text("\(e.at)  \(e.text)").font(.system(.caption, design: .monospaced))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
