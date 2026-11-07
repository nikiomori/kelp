import Core
import DesignKit
import KelpKit
import SwiftUI

/// In a remote project's hover card: its server, how the machine is doing now, and the way into the server's tab.
struct ServerSection: View {
    let app: AppModel, host: String
    let close: () -> Void

    var body: some View {
        let stats = app.latest(HostEvent.self, host)?.stats
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "server.rack").font(.symbol(Metrics.iconSmall)).foregroundStyle(.secondary)
                Text(host).font(.ui(12, weight: .semibold)).lineLimit(1)
                if let word = ServerActions.serverWord(app, host) {
                    Text(word.text).font(.ui(11)).foregroundStyle(Color(nsColor: word.color))
                }
            }
            Text(serverLine(stats)).font(.ui(11)).foregroundStyle(.secondary).lineLimit(2)
            if let stats, stats.connected { ServerMeters(stats: stats) }
            HStack(spacing: Metrics.gapWide) {
                Button(String(localized: "Open Server")) {
                    close()
                    app.workbench.openServer(host)
                }
                Button("htop") {
                    close()
                    ServerActions.openHtop(app, host)
                }
            }
            .controlSize(.small)
        }
    }
}

/// "Ubuntu 24.04.5 LTS · 2 cores · up 3 d 10 h", or why there's nothing to say.
func serverLine(_ stats: HostStats?) -> String {
    guard let stats else { return String(localized: "Reading…") }
    guard stats.connected else {
        return stats.error.map { String(localized: "Can't reach: \($0)") }
            ?? String(localized: "Not connected. Opening it connects.")
    }
    let cores = stats.cores.map { String(localized: "\($0) cores") }
    return [stats.os, cores, stats.uptime.map { String(localized: "up \(serverDuration($0))") }].compactMap { $0 }
        .joined(
            separator: " · ")
}

/// CPU, memory, swap and disk as bars with their numbers; orange past 90 %.
struct ServerMeters: View {
    let stats: HostStats
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            if let cpu = stats.cpu {
                row("CPU", cpu / 100, String(localized: "\(Int(cpu.rounded()))% · load \(load)"))
            }
            meter("Memory", stats.memory, stats.memoryTotal)
            meter("Swap", stats.swap, stats.swapTotal)
            meter("Disk /", stats.disk, stats.diskTotal)
        }
    }

    private var load: String { stats.load?.first.map { String(format: "%.2f", $0) } ?? "–" }

    @ViewBuilder private func meter(_ label: LocalizedStringKey, _ used: Int?, _ total: Int?) -> some View {
        if let used, let total, total > 0 {
            row(label, Double(used) / Double(total), "\(serverBytes(used)) / \(serverBytes(total))")
        }
    }

    private func row(_ label: LocalizedStringKey, _ share: Double, _ value: String) -> some View {
        GridRow {
            Text(label).font(.ui(11)).foregroundStyle(.secondary)
            ServerBar(share: share).frame(height: 4)
            Text(value).font(.ui(11).monospacedDigit()).lineLimit(1).gridColumnAlignment(.trailing)
        }
    }
}

/// A thin bar: grey, orange from 90 %.
struct ServerBar: View {
    let share: Double
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: .quaternaryLabelColor))
                Capsule().fill(share >= 0.9 ? Color.orange : Color.secondary)
                    .frame(width: max(2, geometry.size.width * min(1, max(0, share))))
            }
        }
    }
}
