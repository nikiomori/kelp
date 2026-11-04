import AppKit
import SwiftUI
import Core
import DesignKit
import KelpKit

/// The busiest processes, and which of Kelp's agents each runs under: what htop can't tell. All, or Kelp's alone.
struct ServerProcesses: View {
    let app: AppModel, stats: HostStats
    @State private var kelpOnly = false
    @State private var order = [KeyPathComparator(\HostStats.Process.cpu, order: .reverse)]
    @State private var picked: Set<Int> = []

    private var rows: [HostStats.Process] {
        (stats.processes ?? []).filter { !kelpOnly || $0.session != nil }.sorted(using: order)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Processes").font(.ui(11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $kelpOnly) {
                    Text("All").tag(false)
                    Text("Kelp").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
            }
            Table(rows, selection: $picked, sortOrder: $order) {
                TableColumn("Command", value: \.command) { p in
                    (Text(p.command) + Text(verbatim: "  \(p.pid)").foregroundColor(Color(nsColor: .tertiaryLabelColor)).font(.ui(11).monospacedDigit()))
                        .help(p.args)
                }
                .width(min: 120, ideal: 240)
                TableColumn("Kelp") { p in agent(p) }.width(min: 40, ideal: 90)
                TableColumn("User", value: \.user) { p in Text(p.user).foregroundStyle(.secondary) }.width(min: 40, ideal: 60)
                TableColumn("CPU", value: \.cpu) { p in Text(String(format: "%.1f%%", p.cpu)).monospacedDigit() }
                    .width(min: 44, ideal: 52).alignment(.trailing)
                TableColumn("Memory", value: \.memory) { p in Text(p.memory > 0 ? serverBytes(p.memory) : "–").monospacedDigit() }
                    .width(min: 56, ideal: 72).alignment(.trailing)
                TableColumn("Running", value: \.seconds) { p in Text(serverDuration(Double(p.seconds))).foregroundStyle(.secondary).monospacedDigit() }
                    .width(min: 52, ideal: 70).alignment(.trailing)
            }
            .font(.ui(12))
            .contextMenu(forSelectionType: Int.self) { pids in
                if let p = rows.first(where: { pids.contains($0.pid) }) {
                    if let sid = p.session { Button(String(localized: "Show Agent")) { app.workbench.focus(session: sid) } }
                    Button(String(localized: "Copy Command Line")) { copy(p.args) }
                    Button(String(localized: "Copy PID")) { copy("\(p.pid)") }
                }
            } primaryAction: { pids in
                if let sid = rows.first(where: { pids.contains($0.pid) })?.session { app.workbench.focus(session: sid) }
            }
            Text("The \(stats.processes?.count ?? 0) busiest of \(stats.processCount ?? 0). htop shows the rest.")
                .font(.ui(11)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func agent(_ p: HostStats.Process) -> some View {
        if let sid = p.session, let s = app.session(sid) {
            HStack(spacing: 4) {
                StatusIcon(status: s.markStatus, waitsForCommand: s.waitsForCommand)
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

extension HostStats.Process: Identifiable { public var id: Int { pid } }
