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
            GeometryReader { geometry in
                if geometry.size.width >= ProcessRow.least + 20 + 240 {
                    HStack(alignment: .top, spacing: 20) {
                        ServerProcesses(app: app, stats: stats).frame(minWidth: ProcessRow.least, maxWidth: .infinity)
                        side.frame(minWidth: 240, idealWidth: 300, maxWidth: 340)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        ServerProcesses(app: app, stats: stats)
                        side.frame(maxHeight: geometry.size.height * 0.4)
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
        Grid(horizontalSpacing: 12) {
            GridRow {
                Tile(
                    label: "CPU", value: stats.cpu.map { "\(Int($0.rounded()))%" } ?? "–",
                    detail: ServerReading.load(stats, separator: " · ").map { String(localized: "load \($0)") } ?? "",
                    share: stats.cpu.map { $0 / 100 }, trend: history.map(\.cpu))
                Tile(
                    label: "Memory", value: stats.memory.map(bytes) ?? "–",
                    detail: of(stats.memory, stats.memoryTotal),
                    share: share(stats.memory, stats.memoryTotal), trend: history.map(\.memory))
                Tile(
                    label: "Swap", value: stats.swap.map(bytes) ?? "–", detail: of(stats.swap, stats.swapTotal),
                    share: share(stats.swap, stats.swapTotal))
                Tile(
                    label: "Disk /", value: stats.disk.map(bytes) ?? "–", detail: of(stats.disk, stats.diskTotal),
                    share: share(stats.disk, stats.diskTotal))
            }
        }
    }

    private func share(_ used: Int?, _ total: Int?) -> Double? {
        HostStats.percent(used, total).map { Double($0) / 100 }
    }
    private func of(_ used: Int?, _ total: Int?) -> String {
        guard let total, let percent = HostStats.percent(used, total) else { return String(localized: "Linux only") }
        return String(localized: "of \(bytes(total)) · \(percent)%")
    }
}

/// One meter: the number, what it's out of, and the last two minutes (or a bar where history says little: disk, swap).
private struct Tile: View {
    let label: LocalizedStringKey, value: String, detail: String
    let share: Double?
    var trend: [Double]?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.ui(TextSize.caption, weight: .semibold)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(.ui(20, weight: .semibold).monospacedDigit())
                    .foregroundStyle(ServerReading.strained(share ?? 0) ? ServerReading.strainedColor : .primary)
                Text(detail).font(.ui(TextSize.caption).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            if let trend, trend.count > 1 {
                Sparkline(values: trend).frame(height: 32)
            } else if let share {
                ProgressView(value: min(1, share)).progressViewStyle(.linear).controlSize(.small)
                    .tint(ServerReading.strained(share) ? ServerReading.strainedColor : .secondary).padding(.top, 10)
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
        GeometryReader { geometry in
            let pts = values.enumerated().map { index, value in
                CGPoint(
                    x: geometry.size.width * CGFloat(index) / CGFloat(max(1, values.count - 1)),
                    y: geometry.size.height * (1 - CGFloat(min(1, max(0, value)))))
            }
            let line = Path { path in path.addLines(pts) }
            let color = ServerReading.strained(values.last ?? 0) ? ServerReading.strainedColor : Color.secondary
            ZStack {
                Path { path in
                    path.addLines(pts)
                    path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height))
                    path.addLine(to: CGPoint(x: 0, y: geometry.size.height))
                    path.closeSubpath()
                }.fill(Color.primary.opacity(0.06))
                line.stroke(color, lineWidth: 1.3)
                if let last = pts.last { Circle().fill(color).frame(width: 4, height: 4).position(last) }
            }
        }
    }
}
