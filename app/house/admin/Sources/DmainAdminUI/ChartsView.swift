import Charts
import DmainAdminCore
import SwiftUI

/// How much one chart shows. The arrows step by the same amount.
enum ChartSpan: String, CaseIterable {
    case day = "Day", week = "Week", month = "Month"

    var days: Int {
        switch self {
        case .day: 1
        case .week: 7
        case .month: 30
        }
    }
}

/// Temperature per room against Outside, with motion on the same time axis.
/// Everything drawn comes from `dmain admin H history` over this Mac's mirror of
/// the house logs; the view only picks the range and what to show.
struct ChartsView: View {
    let house: House
    /// Remembered on this Mac; `--args -chartSpan Week` chooses one at launch.
    @AppStorage("chartSpan") private var span: ChartSpan = .day
    /// The last day shown.
    @State private var anchor = Calendar.current.startOfDay(for: Date())
    @State private var custom: ClosedRange<Date>?
    @State private var choosingRange = false
    @State private var mirroring: Request?
    @State private var folding: Request?
    @State private var shown: History?
    @AppStorage("chartRaw") private var raw = false
    /// Labels hidden from the chart, remembered on this Mac.
    @AppStorage("chartHidden") private var hiddenText = ""
    @AppStorage("chartMotion") private var drawMotion = true
    @AppStorage("chartHumidity") private var drawHumidity = false
    @AppStorage("chartOutdoorMotion") private var drawOutdoorMotion = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                status
                if let h = shown {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            TemperatureChart(history: h, hidden: hidden, range: range)
                                .frame(height: 360)
                            if drawHumidity, !visible(h.humidity).isEmpty {
                                Text("Humidity").font(.headline).foregroundStyle(.secondary)
                                LineChart(series: visible(h.humidity), unit: "%", range: range, newest: h.newest, colours: colours(h))
                                    .frame(height: 160)
                            }
                            if drawMotion {
                                MotionChart(rows: motionRows(h), range: range, colours: colours(h))
                            }
                            Text("A gap is a sensor whose link was lost, or which was silent for longer than display.json's stale_min, never a joined line.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.trailing, 8)
                    }
                    .opacity(isBusy ? 0.6 : 1)
                } else if let o = folding?.outcome, !o.ok {
                    ContentUnavailableView("No history", systemImage: "chart.xyaxis.line", description: Text(o.why ?? "dmain couldn't fold the logs"))
                } else {
                    ProgressView("Reading the logs").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(16)
            Divider()
            if let h = shown { Legend(history: h, hiddenText: $hiddenText, colours: colours(h), drawMotion: $drawMotion, drawHumidity: $drawHumidity, drawOutdoorMotion: $drawOutdoorMotion) }
        }
        .navigationSubtitle(title)
        .toolbar {
            ToolbarItemGroup {
                Button { step(-1) } label: { Label("Earlier", systemImage: "chevron.left") }
                Picker("Span", selection: $span) {
                    ForEach(ChartSpan.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: span) { custom = nil }
                Button("Range…") { choosingRange = true }
                    .popover(isPresented: $choosingRange) { RangePicker(range: $custom, isPresented: $choosingRange) }
                Button { step(1) } label: { Label("Later", systemImage: "chevron.right") }
                    .disabled(custom == nil && anchor >= Calendar.current.startOfDay(for: Date()))
                Picker("Values", selection: $raw) {
                    Text("Corrected").tag(false)
                    Text("Raw").tag(true)
                }
                .pickerStyle(.segmented)
                Button { refresh() } label: { Label("Fetch the newest", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r")
                    .disabled(isBusy)
            }
        }
        .task { refresh() }
        // The screen can open before the app has connected.
        .onChange(of: house.command) { if shown == nil { refresh() } }
        .onChange(of: foldKey) { fold() }
    }

    // MARK: Range

    private var range: ClosedRange<Date> {
        if let custom { return custom }
        let cal = Calendar.current
        let end = cal.date(byAdding: .day, value: 1, to: anchor)!
        return cal.date(byAdding: .day, value: -span.days, to: end)!...end
    }

    private var title: String {
        let r = range
        if custom == nil, span == .day { return r.lowerBound.formatted(date: .complete, time: .omitted) }
        let end = r.upperBound.addingTimeInterval(-1)
        return "\(r.lowerBound.formatted(date: .abbreviated, time: .omitted)) to \(end.formatted(date: .abbreviated, time: .omitted))"
    }

    private func step(_ direction: Int) {
        if let c = custom {
            let width = c.upperBound.timeIntervalSince(c.lowerBound) * Double(direction)
            custom = c.lowerBound.addingTimeInterval(width)...c.upperBound.addingTimeInterval(width)
            return
        }
        let today = Calendar.current.startOfDay(for: Date())
        let next = Calendar.current.date(byAdding: .day, value: direction * span.days, to: anchor)!
        anchor = min(next, today)
    }

    // MARK: Loading

    private var foldKey: String { "\(range.lowerBound.ms)-\(range.upperBound.ms)-\(raw)" }
    private var isBusy: Bool { mirroring?.isRunning == true || folding?.isRunning == true }

    /// Tops up the mirror, then folds. A failed mirror still folds what's here.
    private func refresh() {
        mirroring = house.request(["mirror"]) { _ in fold() }
        if mirroring == nil { fold() }
    }

    private func fold() {
        var words = ["history", String(range.lowerBound.ms), String(range.upperBound.ms)]
        if raw { words.append("raw") }
        folding = house.request(words) { r in
            if let h = r.history { shown = h }
        }
    }

    @ViewBuilder private var status: some View {
        if let o = mirroring?.outcome, !o.ok {
            Label("Not fetched from \(house.command?.host ?? "the server"): \(o.why ?? "it failed"). What's shown is this Mac's copy.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange).font(.callout)
        } else if isBusy {
            Label(mirroring?.isRunning == true ? "Fetching the newest records…" : "Folding the logs…", systemImage: "clock")
                .foregroundStyle(.secondary).font(.callout)
        } else if let n = shown?.newest {
            Text("Newest record \(Date.fromMs(n).formatted(date: .abbreviated, time: .standard))\(shown?.raw == true ? ". Raw values, as the sensors gave them" : "")")
                .foregroundStyle(.secondary).font(.callout)
        }
    }

    // MARK: What's drawn

    private var hidden: Set<String> { Set(hiddenText.split(separator: "\u{1F}").map(String.init)) }

    private func visible(_ list: [HistorySeries]) -> [HistorySeries] {
        list.filter { !hidden.contains($0.label) }
    }

    /// Motion for the rooms drawn, and the outdoor sensors only when asked for.
    private func motionRows(_ h: History) -> [MotionSeries] {
        h.motion.filter { m in
            m.outdoor ? drawOutdoorMotion : !hidden.contains(m.label)
        }
    }

    /// A colour per room, by its place in the list, so a room keeps its colour
    /// whatever else is hidden. Outside is always the primary colour, dashed.
    private func colours(_ h: History) -> [String: Color] {
        var out: [String: Color] = [:]
        var i = 0
        for s in h.temperature + h.humidity where out[s.label] == nil {
            if s.outside { out[s.label] = .primary; continue }
            out[s.label] = Palette.colours[i % Palette.colours.count]
            i += 1
        }
        return out
    }
}

enum Palette {
    static let colours: [Color] = [
        Color(red: 0.04, green: 0.39, blue: 0.84), Color(red: 0.76, green: 0.25, blue: 0.05),
        Color(red: 0.18, green: 0.49, blue: 0.20), Color(red: 0.48, green: 0.25, blue: 0.71),
        Color(red: 0.0, green: 0.55, blue: 0.55), Color(red: 0.55, green: 0.35, blue: 0.17),
        Color(red: 0.85, green: 0.25, blue: 0.52), Color(red: 0.25, green: 0.32, blue: 0.71),
        Color(red: 0.50, green: 0.50, blue: 0.0), Color(red: 0.0, green: 0.60, blue: 0.85),
    ]
}

/// Temperature: a stepped line per sensor, broken at every gap, the gaps
/// shaded and named, today stopped at the newest record.
private struct TemperatureChart: View {
    let history: History
    let hidden: Set<String>
    let range: ClosedRange<Date>

    var body: some View {
        LineChart(series: history.temperature.filter { !hidden.contains($0.label) }, unit: "°", range: range, newest: history.newest, colours: colours)
    }

    private var colours: [String: Color] {
        var out: [String: Color] = [:]
        var i = 0
        for s in history.temperature + history.humidity where out[s.label] == nil {
            if s.outside { out[s.label] = .primary; continue }
            out[s.label] = Palette.colours[i % Palette.colours.count]
            i += 1
        }
        return out
    }
}

private struct LineChart: View {
    let series: [HistorySeries]
    let unit: String
    let range: ClosedRange<Date>
    let newest: Int64?
    let colours: [String: Color]

    var body: some View {
        Chart {
            ForEach(series, id: \.dev) { s in
                let colour = colours[s.label] ?? .gray
                ForEach(Array(s.segments.enumerated()), id: \.offset) { i, segment in
                    ForEach(Array(segment.enumerated()), id: \.offset) { _, p in
                        LineMark(x: .value("Time", max(p.date, range.lowerBound)), y: .value(unit, p.v), series: .value("Line", "\(s.dev)#\(i)"))
                            .foregroundStyle(colour)
                            .lineStyle(s.outside ? StrokeStyle(lineWidth: 1.6, dash: [5, 3]) : StrokeStyle(lineWidth: 1.8))
                            .interpolationMethod(.stepEnd)
                    }
                }
                ForEach(Array(s.gaps.enumerated()), id: \.offset) { _, g in
                    let end = g.to.map(Date.fromMs) ?? min(range.upperBound, newest.map(Date.fromMs) ?? range.upperBound)
                    if end > Date.fromMs(g.from) {
                        RectangleMark(xStart: .value("From", max(Date.fromMs(g.from), range.lowerBound)), xEnd: .value("To", end))
                            .foregroundStyle(colour.opacity(0.08))
                            .annotation(position: .bottom, alignment: .leading) {
                                Text("\(s.label): \(g.why == "link_lost" ? "link lost" : "no reports")").font(.caption2).foregroundStyle(colour)
                            }
                    }
                }
            }
            if let n = newest.map(Date.fromMs), range.contains(n) {
                RuleMark(x: .value("Newest", n))
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text(n.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.orange)
                    }
            }
        }
        .chartXScale(domain: range)
        .chartXAxis { TimeAxis(range).marks }
        .chartYScale(domain: yDomain)
        .chartYAxis { AxisMarks(position: .leading, values: ticks) { _ in AxisGridLine() } }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            EndLabels(series: series, colours: colours, proxy: proxy)
            SideLabels(labels: ticks.map { ("\($0.formatted())\(unit)", $0) }, proxy: proxy)
        }
        .padding(.leading, ChartLayout.axisWidth)
        .padding(.trailing, ChartLayout.endLabelWidth)
    }

    /// Round steps across the domain: 1, 2 or 5 apart, about six of them.
    private var ticks: [Double] {
        let d = yDomain
        let raw = (d.upperBound - d.lowerBound) / 6
        let step = [1.0, 2, 5, 10, 20].first { $0 >= raw } ?? 20
        // `+ 0` turns a -0 into 0, which would otherwise print as "-0°".
        return stride(from: (d.lowerBound / step).rounded(.up) * step, through: d.upperBound, by: step).map { $0 + 0 }
    }

    /// The readings' own span, a little either side, so the lines aren't squashed.
    private var yDomain: ClosedRange<Double> {
        let values = series.flatMap { $0.segments.flatMap { $0.map(\.v) } }
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let pad = max(0.5, (hi - lo) * 0.08)
        return (lo - pad).rounded(.down)...(hi + pad).rounded(.up)
    }
}

/// Shared by the stacked charts, so their time axes line up.
enum ChartLayout {
    static let axisWidth: CGFloat = 120
    static let endLabelWidth: CGFloat = 110
}

/// The time axis, from how long the range is: a day has a line every hour and a
/// label every three, a week a line every six hours and a label each day, a month a
/// line each day and a label each week. Swift Charts' own choice left a day with a
/// mark only every six hours, which made times hard to read off.
struct TimeAxis {
    let grid: Calendar.Component
    let gridCount: Int
    let label: Calendar.Component
    let labelCount: Int
    let format: Date.FormatStyle

    init(_ range: ClosedRange<Date>) {
        let hours = range.upperBound.timeIntervalSince(range.lowerBound) / 3600
        if hours <= 36 {
            (grid, gridCount, label, labelCount) = (.hour, 1, .hour, 3)
            format = .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        } else if hours <= 8 * 24 {
            (grid, gridCount, label, labelCount) = (.hour, 6, .day, 1)
            format = .dateTime.weekday(.abbreviated).day()
        } else {
            (grid, gridCount, label, labelCount) = (.day, 1, .day, 7)
            format = .dateTime.day().month(.abbreviated)
        }
    }

    @AxisContentBuilder var marks: some AxisContent {
        AxisMarks(values: .stride(by: grid, count: gridCount)) { _ in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(.secondary.opacity(0.35))
            AxisTick(length: 3)
        }
        AxisMarks(values: .stride(by: label, count: labelCount)) { _ in
            AxisGridLine()
            AxisTick(length: 6)
            AxisValueLabel(format: format)
        }
    }
}

/// A chart's side labels, drawn in the fixed column left of its plot, so charts
/// stacked above each other keep their time axes in line.
private struct SideLabels<Y: Plottable>: View {
    let labels: [(String, Y)]
    let proxy: ChartProxy

    var body: some View {
        GeometryReader { geo in
            if let plot = proxy.plotFrame.map({ geo[$0] }) {
                ForEach(Array(labels.enumerated()), id: \.offset) { _, l in
                    if let y = proxy.position(forY: l.1) {
                        Text(l.0).font(.caption).foregroundStyle(.secondary)
                            .frame(width: ChartLayout.axisWidth - 8, alignment: .trailing)
                            .position(x: plot.minX - ChartLayout.axisWidth / 2, y: plot.minY + y)
                    }
                }
            }
        }
    }
}

/// Each line's name at its end, nudged apart when lines end close together.
private struct EndLabels: View {
    let series: [HistorySeries]
    let colours: [String: Color]
    let proxy: ChartProxy

    var body: some View {
        GeometryReader { geo in
            if let plot = proxy.plotFrame.map({ geo[$0] }) {
                ForEach(placed(plot), id: \.label) { l in
                    Text(l.label).font(.caption).foregroundStyle(colours[l.label] ?? .gray)
                        .fixedSize()
                        .position(x: l.x, y: l.y)
                }
            }
        }
    }

    private struct Placed { let label: String; var x: CGFloat; var y: CGFloat }

    private func placed(_ plot: CGRect) -> [Placed] {
        var out: [Placed] = []
        for s in series {
            guard let last = s.segments.last?.last,
                  let x = proxy.position(forX: last.date), let y = proxy.position(forY: last.v) else { continue }
            out.append(Placed(label: s.label, x: plot.minX + x + 6, y: plot.minY + y))
        }
        out.sort { $0.y < $1.y }
        let gap: CGFloat = 13
        for i in out.indices.dropFirst() where out[i].y - out[i - 1].y < gap {
            out[i].y = out[i - 1].y + gap
        }
        // Text is placed by its centre; start it just after the line's end.
        return out.map { var p = $0; p.x += textWidth(p.label) / 2; return p }
    }

    private func textWidth(_ s: String) -> CGFloat { CGFloat(s.count) * 6.5 }
}

/// Motion as bars on the temperature chart's time axis, a row per sensor.
private struct MotionChart: View {
    let rows: [MotionSeries]
    let range: ClosedRange<Date>
    let colours: [String: Color]

    var body: some View {
        if !rows.isEmpty {
            Chart {
                ForEach(rows, id: \.dev) { m in
                    ForEach(Array(m.spans.enumerated()), id: \.offset) { _, span in
                        RectangleMark(
                            xStart: .value("From", Date.fromMs(span.from)),
                            xEnd: .value("To", max(Date.fromMs(span.to), Date.fromMs(span.from).addingTimeInterval(range.upperBound.timeIntervalSince(range.lowerBound) / 1500))),
                            y: .value("Sensor", "\(m.label) motion"),
                            height: 12
                        )
                        .foregroundStyle(colours[m.label] ?? .gray)
                    }
                }
            }
            .chartXScale(domain: range)
            .chartXAxis { TimeAxis(range).marks }
            .chartYScale(domain: rows.map { "\($0.label) motion" })
            .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine() } }
            .chartLegend(.hidden)
            .chartOverlay { proxy in SideLabels(labels: rows.map { ("\($0.label) motion", "\($0.label) motion") }, proxy: proxy) }
            .frame(height: CGFloat(rows.count) * 26 + 30)
            .padding(.leading, ChartLayout.axisWidth)
            .padding(.trailing, ChartLayout.endLabelWidth)
        }
    }
}

/// Which rooms are drawn, and what else is.
private struct Legend: View {
    let history: History
    @Binding var hiddenText: String
    let colours: [String: Color]
    @Binding var drawMotion: Bool
    @Binding var drawHumidity: Bool
    @Binding var drawOutdoorMotion: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("TEMPERATURE").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                ForEach(history.temperature, id: \.dev) { s in
                    Toggle(isOn: shownBinding(s.label)) {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(colours[s.label] ?? .gray).frame(width: 10, height: 10)
                            Text(s.label)
                        }
                    }
                }
                Text("ALSO DRAW").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary).padding(.top, 10)
                Toggle("Motion", isOn: $drawMotion)
                Toggle("Humidity", isOn: $drawHumidity).disabled(history.humidity.isEmpty)
                Toggle("Outdoor motion", isOn: $drawOutdoorMotion)
            }
            .toggleStyle(.checkbox)
            .padding(14)
        }
        .frame(width: 190)
    }

    private func shownBinding(_ label: String) -> Binding<Bool> {
        Binding(
            get: { !Set(hiddenText.split(separator: "\u{1F}").map(String.init)).contains(label) },
            set: { show in
                var set = Set(hiddenText.split(separator: "\u{1F}").map(String.init))
                if show { set.remove(label) } else { set.insert(label) }
                hiddenText = set.sorted().joined(separator: "\u{1F}")
            }
        )
    }
}

private struct RangePicker: View {
    @Binding var range: ClosedRange<Date>?
    @Binding var isPresented: Bool
    @State private var from = Calendar.current.date(byAdding: .day, value: -3, to: Calendar.current.startOfDay(for: Date()))!
    @State private var to = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DatePicker("From", selection: $from, displayedComponents: [.date, .hourAndMinute])
            DatePicker("To", selection: $to, in: from..., displayedComponents: [.date, .hourAndMinute])
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Show") {
                    range = from...max(to, from.addingTimeInterval(3600))
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
