import SwiftUI
import Core
import DesignKit

/// A server heading's hover card: how the machine is doing now, who on it wants you, and the way into its tab.
struct ServerCard: View {
    let app: AppModel, host: String
    let close: () -> Void

    var body: some View {
        let s = app.hostStats[host]
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(host).font(.ui(13, weight: .semibold)).lineLimit(1)
                Text(serverLine(s)).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            if let s, s.connected { ServerMeters(stats: s) }
            ForEach(waiting, id: \.id) { a in
                HStack(spacing: 6) {
                    StatusIcon(status: a.markStatus, waitsForCommand: a.waitsForCommand).font(.caption)
                    Text(app.catalog.displayName(a)).font(.callout).lineLimit(1)
                    Text(a.statusWords).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: Metrics.gapWide) {
                Button(String(localized: "Open Server")) { close(); app.openServer(host) }
                Button("htop") { close(); app.openHtop(host) }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
    }

    /// The agents on this host that want you.
    private var waiting: [Session] {
        let folders = Set(app.projects(onServer: host).map(\.id))
        let screens = Set(app.worktrees.filter { folders.contains($0.repoId) }.map(\.id))
        return app.sessions.filter { screens.contains($0.worktreeId ?? "") && SidebarCell.wantsYou($0) }
    }
}

/// "Ubuntu 24.04.5 LTS · 2 cores · up 3 d 10 h", or why there's nothing to say.
package func serverLine(_ s: HostStats?) -> String {
    guard let s else { return String(localized: "Reading…") }
    guard s.connected else { return s.error.map { String(localized: "Can't reach: \($0)") } ?? String(localized: "Not connected. Opening it connects.") }
    let cores = s.cores.map { String(localized: "\($0) cores") }
    return [s.os, cores, s.uptime.map { String(localized: "up \(serverDuration($0))") }].compactMap { $0 }.joined(separator: " · ")
}

/// CPU, memory, swap and disk as bars with their numbers; orange past 90 %.
struct ServerMeters: View {
    let stats: HostStats
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            if let c = stats.cpu {
                row("CPU", c / 100, String(localized: "\(Int(c.rounded()))% · load \(load)"))
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
            Text(label).font(.caption).foregroundStyle(.secondary)
            ServerBar(share: share).frame(height: 4)
            Text(value).font(.caption.monospacedDigit()).lineLimit(1).gridColumnAlignment(.trailing)
        }
    }
}

/// A thin bar: grey, orange from 90 %.
struct ServerBar: View {
    let share: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: .quaternaryLabelColor))
                Capsule().fill(share >= 0.9 ? Color.orange : Color.secondary)
                    .frame(width: max(2, g.size.width * min(1, max(0, share))))
            }
        }
    }
}
