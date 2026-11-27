import AppKit
import Charts
import Core
import DesignKit
import KelpKit
import SwiftUI

/// A connected server: the meters over the processes, and Kelp's side of it on the right.
struct ServerDetail: View {
    let app: AppModel, host: String, stats: HostStats
    /// The last hour's readings, oldest first.
    let history: [HostStats.Sample]

    /// The side column's width: it gives way to the processes down to `least`.
    private static let side: (least: CGFloat, ideal: CGFloat, most: CGFloat) = (240, 300, 340)

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.blockGap) {
            meters
            // When the view is too narrow for both side by side (the table needs `ProcessTable.least`), the side
            // column goes under the processes, which SwiftUI otherwise centres past the left edge.
            GeometryReader { geometry in
                if geometry.size.width >= ProcessTable.least + Metrics.blockGap + Self.side.least {
                    HStack(alignment: .top, spacing: Metrics.blockGap) {
                        ServerProcesses(app: app, stats: stats).frame(minWidth: ProcessTable.least, maxWidth: .infinity)
                        side.frame(minWidth: Self.side.least, idealWidth: Self.side.ideal, maxWidth: Self.side.most)
                    }
                } else {
                    VStack(alignment: .leading, spacing: Metrics.blockGap) {
                        ServerProcesses(app: app, stats: stats)
                        side.frame(maxHeight: geometry.size.height * 0.4)
                    }
                }
            }
        }
        .padding(.horizontal, Metrics.pageInset).padding(.vertical, Metrics.pageTop)
    }

    private var side: some View { ServerSide(app: app, host: host, stats: stats) }

    /// The four readings as one group with a line between neighbours, the way Activity Monitor sums a Mac up: one
    /// strip to read across, where four cards in a row were a web dashboard's.
    private var meters: some View {
        HStack(spacing: 0) {
            Meter(
                label: "CPU", value: stats.cpu.map { "\(Int($0.rounded()))%" } ?? "–", detail: load,
                share: stats.cpu.map { $0 / 100 }, trend: trend(\.cpu), foot: cpuFoot)
            Divider()
            Meter(
                label: "Memory",
                value: stats.memory.map { ServerReading.amount($0, like: stats.memoryTotal ?? $0) } ?? "–",
                detail: of(stats.memory, stats.memoryTotal), share: share(stats.memory, stats.memoryTotal),
                trend: trend(\.memory), foot: swap.text, footStrained: swap.strained)
            Divider()
            Meter(
                label: "Disk /",
                value: stats.disk.map { ServerReading.amount($0, like: stats.diskTotal ?? $0) } ?? "–",
                detail: of(stats.disk, stats.diskTotal), share: share(stats.disk, stats.diskTotal))
            if let network = stats.network {
                Divider()
                Meter(
                    label: "Network", value: ServerReading.rate(network.received),
                    detail: ServerReading.rate(network.sent), share: nil, trend: traffic,
                    foot: network.interface, arrows: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)   // every reading as tall as the tallest
        .background(RoundedRectangle(cornerRadius: Metrics.radiusMD).fill(Color(nsColor: .fillRest)))
    }

    private var load: String {
        ServerReading.load(stats, separator: " · ").map { String(localized: "load \($0)") } ?? ""
    }
    /// The cores the load is shared by (the load says little without them), and where the time went.
    private var cpuFoot: String? {
        let parts = [
            stats.cores.map { $0 == 1 ? String(localized: "1 core") : String(localized: "\($0) cores") },
            stats.iowait.map { String(localized: "iowait \(ServerReading.percent($0))") },
            stats.steal.map { String(localized: "steal \(ServerReading.percent($0))") }
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    private var swap: (text: String?, strained: Bool) {
        guard let used = stats.swap, let total = stats.swapTotal else { return (nil, false) }
        guard total > 0, let percent = HostStats.percent(used, total) else {
            return (String(localized: "No swap"), false)
        }
        return (
            String(localized: "Swap \(ServerReading.amount(used, like: total)) of \(bytes(total)) · \(percent)%"),
            ServerReading.strained(Double(percent) / 100)
        )
    }

    private func trend(_ value: KeyPath<HostStats.Sample, Double?>) -> [Trend.Point] {
        history.compactMap { sample in sample[keyPath: value].map { Trend.Point(at: sample.at, value: $0) } }
    }
    /// Traffic in and out together, scaled against the hour's busiest moment.
    private var traffic: [Trend.Point] {
        let points = history.compactMap { s in s.received.map { Trend.Point(at: s.at, value: $0 + (s.sent ?? 0)) } }
        let top = max(1, points.map(\.value).max() ?? 1)
        return points.map { Trend.Point(at: $0.at, value: $0.value / top) }
    }

    private func share(_ used: Int?, _ total: Int?) -> Double? {
        HostStats.percent(used, total).map { Double($0) / 100 }
    }
    private func of(_ used: Int?, _ total: Int?) -> String {
        guard let total, let percent = HostStats.percent(used, total) else { return String(localized: "Linux only") }
        return String(localized: "of \(bytes(total)) · \(percent)%")
    }
}

/// One reading of the group: the number, what it's out of, the last hour (or a bar for disk, where history says
/// little), and a line under it.
private struct Meter: View {
    let label: LocalizedStringKey, value: String, detail: String
    let share: Double?
    var trend: [Trend.Point]?
    var foot: String?
    var footStrained = false
    /// Network's: the number is what came in and the detail what went out, each after its arrow symbol.
    var arrows = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.ui(TextSize.caption)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if trend != nil {
                    Text("1 h").font(.ui(TextSize.caption)).foregroundStyle(.secondary).help(
                        String(localized: "The line is the last hour"))
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: Metrics.gap) {
                if arrows { arrow("arrow.down", Metrics.iconLarge, said: String(localized: "Received")) }
                Text(value).font(.ui(TextSize.title, weight: .semibold).monospacedDigit()).lineLimit(1).fixedSize()
                    .foregroundStyle(ServerReading.strained(share ?? 0) ? ServerReading.strainedColor : .primary)
                if arrows { arrow("arrow.up", Metrics.iconSmall, said: String(localized: "Sent")) }
                Text(detail).font(.ui(TextSize.caption).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            if let trend, trend.count > 1 {
                // Two caption lines tall, and taller with Text size, as the numbers over it grow.
                Trend(points: trend, strained: ServerReading.strained(share ?? 0)).frame(height: TextSize.of(28))
            } else if let share {
                ProgressView(value: min(1, share)).progressViewStyle(.linear).controlSize(.small)
                    .tint(ServerReading.strained(share) ? ServerReading.strainedColor : .secondary).padding(
                        .top, Metrics.gapWide)
            }
            Spacer(minLength: 0)
            if let foot {
                Text(foot).font(.ui(TextSize.caption).monospacedDigit()).lineLimit(1)
                    .foregroundStyle(footStrained ? ServerReading.strainedColor : .secondary)
            }
        }
        .padding(Metrics.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func arrow(_ symbol: String, _ size: CGFloat, said: String) -> some View {
        Image(systemName: symbol).font(.symbol(size)).foregroundStyle(.secondary).accessibilityLabel(said)
    }
}

/// The last hour of a reading, 0–1, placed by time: a line over a faint fill, dashed half-way, with the last point
/// marked. A gap of over a minute (not connected, not watched) breaks the line.
private struct Trend: View {
    struct Point { let at: Double, value: Double }
    let points: [Point]
    let strained: Bool

    var body: some View {
        let end = points.last?.at ?? 0, color = strained ? ServerReading.strainedColor : Color.secondary
        // A point older than the hour is placed at its start.
        let x = { (p: Point) in PlottableValue.value("At", max(p.at, end - 3600)) }
        let y = { (p: Point) in PlottableValue.value("Value", min(1, max(0, p.value))) }
        Chart {
            RuleMark(y: .value("Half", 0.5)).foregroundStyle(Color(nsColor: .separatorColor))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            ForEach(Array(runs(points).enumerated()), id: \.offset) { run, part in
                ForEach(part, id: \.at) { point in
                    AreaMark(x: x(point), y: y(point), series: .value("Run", run))
                        .foregroundStyle(Color.primary.opacity(0.06))
                    LineMark(x: x(point), y: y(point), series: .value("Run", run))
                        .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.3))
                }
            }
            if let last = points.last { PointMark(x: x(last), y: y(last)).foregroundStyle(color).symbolSize(16) }
        }
        .chartXScale(domain: (end - 3600)...end).chartYScale(domain: 0...1)
        .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
    }

    private func runs(_ points: [Point]) -> [[Point]] {
        var runs: [[Point]] = []
        for point in points {
            if let previous = runs.last?.last, point.at - previous.at <= 60 {
                runs[runs.count - 1].append(point)
            } else {
                runs.append([point])
            }
        }
        return runs
    }
}
