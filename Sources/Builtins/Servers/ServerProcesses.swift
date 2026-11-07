import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI

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
                    ForEach(rows, id: \.pid) { process in ProcessRow(app: app, process: process) }
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
        Button {
            sort = by
        } label: {
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
struct ProcessRow: View {
    static let kelp: CGFloat = 110, user: CGFloat = 64, number: CGFloat = 64
    /// The narrowest a row is whole: its fixed columns, the gaps and padding, and a little of the command.
    static let least: CGFloat = kelp + user + 3 * number + 5 * 8 + 2 * 8 + 80
    let app: AppModel, process: HostStats.Process
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(process.command).lineLimit(1)
                Text(verbatim: "\(process.pid)").font(.ui(11).monospacedDigit()).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            agent.frame(width: Self.kelp, alignment: .leading)
            Text(process.user).foregroundStyle(.secondary).lineLimit(1).frame(width: Self.user, alignment: .leading)
            Text(String(format: "%.1f%%", process.cpu)).frame(width: Self.number, alignment: .trailing)
            Text(process.memory > 0 ? serverBytes(process.memory) : "–").frame(width: Self.number, alignment: .trailing)
            Text(serverDuration(Double(process.seconds))).foregroundStyle(.secondary).frame(
                width: Self.number, alignment: .trailing)
        }
        .font(.ui(12).monospacedDigit())
        .padding(.horizontal, 8)
        .frame(height: Metrics.row)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusSM).fill(hovering ? Color(nsColor: .fillHover) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(process.args)
        .onTapGesture(count: 2) { if let sid = process.session { app.workbench.focus(session: sid) } }
        .contextMenu {
            if let sid = process.session {
                Button(String(localized: "Show Agent")) { app.workbench.focus(session: sid) }
            }
            Button(String(localized: "Copy Command Line")) { copy(process.args) }
            Button(String(localized: "Copy PID")) { copy("\(process.pid)") }
        }
    }

    @ViewBuilder private var agent: some View {
        if let sid = process.session, let session = app.session(sid) {
            HStack(spacing: 4) {
                StatusIcon(status: session.markStatus, waitsForCommand: session.waitsForCommand).frame(
                    width: 12, height: 12)
                Text(app.catalog.displayName(session)).lineLimit(1)
            }
        } else if process.session != nil {
            Text("Kelp").foregroundStyle(.secondary)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
