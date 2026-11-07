import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI
import WorkbenchKit

/// A connected server: the meters over the processes, and Kelp's side of it on the right.
struct ServerDetail: View {
    let app: AppModel, host: String, stats: HostStats
    let history: [(cpu: Double, memory: Double)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            meters
            // Too narrow for both side by side (a process row needs `ProcessRow.least`): the side column goes under the
            // processes, which SwiftUI otherwise centres past the left edge.
            GeometryReader { g in
                if g.size.width >= ProcessRow.least + 20 + 240 {
                    HStack(alignment: .top, spacing: 20) {
                        ServerProcesses(app: app, stats: stats).frame(minWidth: ProcessRow.least, maxWidth: .infinity)
                        side.frame(minWidth: 240, idealWidth: 300, maxWidth: 340)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        ServerProcesses(app: app, stats: stats)
                        side.frame(maxHeight: g.size.height * 0.4)
                    }
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var side: some View {
        ScrollView { ServerSide(app: app, host: host, stats: stats).frame(maxWidth: .infinity, alignment: .leading) }
    }

    private var meters: some View {
        let s = stats
        return Grid(horizontalSpacing: 12) {
            GridRow {
                Tile(
                    label: "CPU", value: s.cpu.map { "\(Int($0.rounded()))%" } ?? "–",
                    detail: s.load.map {
                        String(localized: "load \($0.map { String(format: "%.2f", $0) }.joined(separator: " · "))")
                    } ?? "",
                    share: s.cpu.map { $0 / 100 }, trend: history.map(\.cpu))
                Tile(
                    label: "Memory", value: s.memory.map(serverBytes) ?? "–", detail: of(s.memory, s.memoryTotal),
                    share: share(s.memory, s.memoryTotal), trend: history.map(\.memory))
                Tile(
                    label: "Swap", value: s.swap.map(serverBytes) ?? "–", detail: of(s.swap, s.swapTotal),
                    share: share(s.swap, s.swapTotal))
                Tile(
                    label: "Disk /", value: s.disk.map(serverBytes) ?? "–", detail: of(s.disk, s.diskTotal),
                    share: share(s.disk, s.diskTotal))
            }
        }
    }

    private func share(_ used: Int?, _ total: Int?) -> Double? {
        HostStats.percent(used, total).map { Double($0) / 100 }
    }
    private func of(_ used: Int?, _ total: Int?) -> String {
        guard let total, let p = HostStats.percent(used, total) else { return String(localized: "Linux only") }
        return String(localized: "of \(serverBytes(total)) · \(p)%")
    }
}

/// One meter: the number, what it's out of, and the last two minutes (or a bar where history says little: disk, swap).
private struct Tile: View {
    let label: LocalizedStringKey, value: String, detail: String
    let share: Double?
    var trend: [Double]?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.ui(11, weight: .semibold)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(.ui(20, weight: .semibold).monospacedDigit())
                    .foregroundStyle((share ?? 0) >= 0.9 ? Color(nsColor: .textOrange) : .primary)
                Text(detail).font(.ui(11).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            if let trend, trend.count > 1 {
                Sparkline(values: trend).frame(height: 32)
            } else if let share {
                ProgressView(value: min(1, share)).progressViewStyle(.linear).controlSize(.small)
                    .tint(share >= 0.9 ? .orange : .secondary).padding(.top, 10)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, maxHeight: 92, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Metrics.radiusLG).fill(Color(nsColor: .fillRest)))
    }
}

/// The last readings, 0–1, oldest first: a line over a faint fill, its last point marked.
private struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { g in
            let pts = values.enumerated().map { i, v in
                CGPoint(
                    x: g.size.width * CGFloat(i) / CGFloat(max(1, values.count - 1)),
                    y: g.size.height * (1 - CGFloat(min(1, max(0, v)))))
            }
            let line = Path { p in p.addLines(pts) }
            let color = (values.last ?? 0) >= 0.9 ? Color.orange : Color.secondary
            ZStack {
                Path { p in
                    p.addLines(pts)
                    p.addLine(to: CGPoint(x: g.size.width, y: g.size.height))
                    p.addLine(to: CGPoint(x: 0, y: g.size.height))
                    p.closeSubpath()
                }.fill(Color.primary.opacity(0.06))
                line.stroke(color, lineWidth: 1.3)
                if let last = pts.last { Circle().fill(color).frame(width: 4, height: 4).position(last) }
            }
        }
    }
}
