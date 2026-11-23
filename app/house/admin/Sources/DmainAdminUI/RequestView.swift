import DmainAdminCore
import SwiftUI

/// What a request said and how it ended, for a sheet.
struct RequestOutput: View {
    let request: Request

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if request.isRunning {
                    ProgressView().controlSize(.small)
                    Text(request.phase.map { "\($0.prefix(1).uppercased())\($0.dropFirst())…" } ?? "Waiting for the server…")
                } else if let o = request.outcome {
                    Image(systemName: o.ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(o.ok ? .green : .red)
                    Text(o.ok ? "Done" : (o.why ?? "It failed")).foregroundStyle(o.ok ? Color.primary : .red)
                }
            }
            if !request.lines.isEmpty {
                ScrollView {
                    Text(request.lines.joined(separator: "\n"))
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 220)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

/// A box of fixed-width lines, kept scrolled to the newest.
struct LinesBox: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                        Text(l).id(i).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .onChange(of: lines.count, initial: true) { _, n in
                if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
            }
        }
    }
}
