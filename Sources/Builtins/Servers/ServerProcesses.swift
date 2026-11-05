import AppKit
import SwiftUI
import Core
import DesignKit
import KelpKit

/// The busiest processes, and which of Kelp's agents each runs under: what htop can't tell. All, or Kelp's alone; sorted
/// by a click on a column's title. Plain rows, not a `Table`: its NSTableView took the reading every 2 s as an update in
/// the middle of its own (AppKit's "reentrant operation" warning).
struct ServerProcesses: View {
    let app: AppModel, stats: HostStats
    @State private var kelpOnly = false
    @State private var sort = Sort.cpu

    enum Sort { case command, user, cpu, memory, running }

    private var rows: [HostStats.Process] {
        let shown = (stats.processes ?? []).filter { !kelpOnly || $0.session != nil }
        switch sort {
        case .command: return shown.sorted { $0.command.localizedStandardCompare($1.command) == .orderedAscending }
        case .user: return shown.sorted { $0.user < $1.user }
        case .cpu: return shown.sorted { ($0.cpu, $0.memory) > ($1.cpu, $1.memory) }
        case .memory: return shown.sorted { $0.memory > $1.memory }
        case .running: return shown.sorted { $0.seconds > $1.seconds }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Processes").sectionTitle()
                Spacer()
                Picker("", selection: $kelpOnly) {
                    Text("All").tag(false)
                    Text("Kelp").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
            }
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows, id: \.pid) { p in ProcessRow(app: app, p: p) }
                }
            }
            Text("The \(stats.processes?.count ?? 0) busiest of \(stats.processCount ?? 0). htop shows the rest.")
                .font(.ui(11)).foregroundStyle(.secondary)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            title("Command", .command).frame(maxWidth: .infinity, alignment: .leading)
            Text("Kelp").frame(width: ProcessRow.kelp, alignment: .leading)
            title("User", .user).frame(width: ProcessRow.user, alignment: .leading)
            title("CPU", .cpu).frame(width: ProcessRow.number, alignment: .trailing)
            title("Memory", .memory).frame(width: ProcessRow.number, alignment: .trailing)
            title("Running", .running).frame(width: ProcessRow.number, alignment: .trailing)
        }
        .sectionTitle()
        .padding(.horizontal, 8)
    }

    private func title(_ text: LocalizedStringKey, _ by: Sort) -> some View {
        Button { sort = by } label: {
            HStack(spacing: 2) {
                Text(text)
                if sort == by { Image(systemName: "chevron.down").font(.symbol(Metrics.iconTiny)) }
            }
            .foregroundStyle(sort == by ? .primary : .secondary)
        }
        .buttonStyle(.plain)
    }
}

/// One process: its name and pid, whose agent, who runs it, and what it takes. Double-click goes to its agent.
private struct ProcessRow: View {
    static let kelp: CGFloat = 110, user: CGFloat = 64, number: CGFloat = 64
    let app: AppModel, p: HostStats.Process
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(p.command).lineLimit(1)
                Text(verbatim: "\(p.pid)").font(.ui(11).monospacedDigit()).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            agent.frame(width: Self.kelp, alignment: .leading)
            Text(p.user).foregroundStyle(.secondary).lineLimit(1).frame(width: Self.user, alignment: .leading)
            Text(String(format: "%.1f%%", p.cpu)).frame(width: Self.number, alignment: .trailing)
            Text(p.memory > 0 ? serverBytes(p.memory) : "–").frame(width: Self.number, alignment: .trailing)
            Text(serverDuration(Double(p.seconds))).foregroundStyle(.secondary).frame(width: Self.number, alignment: .trailing)
        }
        .font(.ui(12).monospacedDigit())
        .padding(.horizontal, 8)
        .frame(height: Metrics.row)
        .background(RoundedRectangle(cornerRadius: Metrics.radiusSM).fill(hovering ? Color(nsColor: .fillHover) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(p.args)
        .onTapGesture(count: 2) { if let sid = p.session { app.workbench.focus(session: sid) } }
        .contextMenu {
            if let sid = p.session { Button(String(localized: "Show Agent")) { app.workbench.focus(session: sid) } }
            Button(String(localized: "Copy Command Line")) { copy(p.args) }
            Button(String(localized: "Copy PID")) { copy("\(p.pid)") }
        }
    }

    @ViewBuilder private var agent: some View {
        if let sid = p.session, let s = app.session(sid) {
            HStack(spacing: 4) {
                StatusIcon(status: s.markStatus, waitsForCommand: s.waitsForCommand).frame(width: 12, height: 12)
                Text(app.catalog.displayName(s)).lineLimit(1)
            }
        } else if p.session != nil {
            Text("Kelp").foregroundStyle(.secondary)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
