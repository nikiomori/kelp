import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI

/// The busiest processes, and what each is part of (a Kelp agent, a container, a service), which htop can't tell. One
/// program's processes fold into a line that opens to show them. It lists all processes, or Kelp's alone when Kelp
/// has any there, in the order its table's header asks for (`ProcessTable`).
struct ServerProcesses: View {
    let app: AppModel, stats: HostStats
    @State private var kelpOnly = 0
    @State private var order = Order(by: .cpu, ascending: false)

    enum Sort: String { case command, user, cpu, memory, running }

    /// What the rows are sorted by, and which way: the busiest first until a header is clicked.
    struct Order: Equatable {
        var by: Sort, ascending: Bool
        var descriptor: NSSortDescriptor { NSSortDescriptor(key: by.rawValue, ascending: ascending) }
    }

    /// One program's processes in one place (an agent, a container or a unit, so two python3 in two services stay
    /// two), the busiest first.
    struct Line: Identifiable {
        let id: String, members: [HostStats.Process]
        var cpu: Double { members.reduce(0) { $0 + $1.cpu } }
        var memory: Int { members.reduce(0) { $0 + $1.memory } }
        var seconds: Int { members.map(\.seconds).max() ?? 0 }
        var users: String {
            members.map(\.user).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(
                separator: ", ")
        }
    }

    private var hasKelp: Bool { stats.processes?.contains { $0.session != nil } == true }

    /// The lines of `processes` in `order`. Lines that are equal by what they're sorted by keep one order from
    /// reading to reading (by id), so rows at 0.0 % don't trade places every two seconds under a chosen row.
    nonisolated static func lines(_ processes: [HostStats.Process], kelpOnly: Bool, order: Order) -> [Line] {
        let shown = processes.filter { !kelpOnly || $0.session != nil }
        let lines = Dictionary(grouping: shown) {
            [$0.command, $0.session ?? "", ServerReading.place($0)?.name ?? ""].joined(separator: "\u{1F}")
        }.map { id, members in
            Line(id: id, members: members.sorted { ($0.cpu, $0.memory, $1.pid) > ($1.cpu, $1.memory, $0.pid) })
        }
        let before: (Line, Line) -> Bool =
            switch order.by {
            case .command:
                { $0.members[0].command.localizedStandardCompare($1.members[0].command) == .orderedAscending }
            case .user: { ($0.users, $1.cpu) < ($1.users, $0.cpu) }
            case .cpu: { ($0.cpu, $0.memory) < ($1.cpu, $1.memory) }
            case .memory: { $0.memory < $1.memory }
            case .running: { $0.seconds < $1.seconds }
            }
        return lines.sorted { a, b in
            let (first, second) = order.ascending ? (a, b) : (b, a)
            if before(first, second) { return true }
            return before(second, first) ? false : a.id < b.id
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gapWide) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.gapWide) {
                Text("Processes").font(.ui(TextSize.body, weight: .semibold))
                Text("\(stats.processes?.count ?? 0) busiest of \(stats.processCount ?? 0) · htop shows the rest")
                    .font(.ui(TextSize.caption)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if hasKelp {
                    Segments(labels: [String(localized: "All"), String(localized: "Kelp")], selection: $kelpOnly)
                        .controlSize(.small).accessibilityLabel(Text("Processes shown"))
                }
            }
            ProcessTable(
                app: app,
                lines: Self.lines(stats.processes ?? [], kelpOnly: kelpOnly == 1 && hasKelp, order: order),
                order: $order)
        }
    }
}
