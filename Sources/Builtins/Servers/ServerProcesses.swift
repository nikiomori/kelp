import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI

/// The busiest processes, and what each is part of (a Kelp agent, a container, a service): what htop can't tell. One
/// program's processes fold into a line ("nginx ×3") that opens to show them. All, or Kelp's alone when Kelp has any
/// there; sorted by a click on a column's title. Plain rows, not a `Table`: its NSTableView took the reading every 2 s
/// as an update in the middle of its own (AppKit's "reentrant operation" warning).
struct ServerProcesses: View {
    let app: AppModel, stats: HostStats
    @State private var kelpOnly = false
    @State private var sort = Sort.cpu
    /// The folded lines opened, by `Line.id`.
    @State private var open: Set<String> = []

    enum Sort { case command, user, cpu, memory, running }

    /// One program's processes in one place (agent, container or unit: two python3 in two services stay two), the busiest
    /// first.
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

    private var lines: [Line] {
        let shown = (stats.processes ?? []).filter { !(kelpOnly && hasKelp) || $0.session != nil }
        let lines = Dictionary(grouping: shown) {
            [$0.command, $0.session ?? "", ServerReading.place($0)?.name ?? ""].joined(separator: "\u{1F}")
        }.map { id, members in
            Line(id: id, members: members.sorted { ($0.cpu, $0.memory) > ($1.cpu, $1.memory) })
        }
        switch sort {
        case .command:
            return lines.sorted {
                $0.members[0].command.localizedStandardCompare($1.members[0].command) == .orderedAscending
            }
        case .user: return lines.sorted { ($0.users, $1.cpu) < ($1.users, $0.cpu) }
        case .cpu: return lines.sorted { ($0.cpu, $0.memory) > ($1.cpu, $1.memory) }
        case .memory: return lines.sorted { $0.memory > $1.memory }
        case .running: return lines.sorted { $0.seconds > $1.seconds }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Metrics.gapWide) {
                Text("Processes").sectionTitle()
                Text("\(stats.processes?.count ?? 0) busiest of \(stats.processCount ?? 0) · htop shows the rest")
                    .font(.ui(TextSize.caption)).foregroundStyle(.tertiary).lineLimit(1)
                Spacer()
                if hasKelp {
                    Picker("", selection: $kelpOnly) {
                        Text("All").tag(false)
                        Text("Kelp").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
                }
            }
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(lines) { line in
                        if line.members.count == 1 {
                            ProcessRow(app: app, process: line.members[0])
                        } else {
                            FoldedRow(app: app, line: line, open: openBinding(line.id))
                            if open.contains(line.id) {
                                ForEach(line.members, id: \.pid) { ProcessRow(app: app, process: $0, inside: true) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func openBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { open.contains(id) }, set: { if $0 { open.insert(id) } else { open.remove(id) } })
    }

    private var header: some View {
        HStack(spacing: 8) {
            title("Command", .command).frame(maxWidth: .infinity, alignment: .leading)
            Text("Part of").frame(width: ProcessRow.part, alignment: .leading)
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
        .buttonStyle(PointerButtonStyle(flush: true))
    }
}

/// One process: its name, pid and arguments, what it's part of, who runs it, and what it takes. Double-click goes to its
/// agent. `inside`: one of a folded line's, set in under it.
struct ProcessRow: View {
    static let part: CGFloat = 140, user: CGFloat = 96, number: CGFloat = 64
    /// The narrowest a row is whole: its fixed columns, the gaps and padding, and a little of the command.
    static let least: CGFloat = part + user + 3 * number + 5 * 8 + 2 * 8 + 80
    let app: AppModel, process: HostStats.Process
    var inside = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(process.command).lineLimit(1).layoutPriority(1)
                Text(verbatim: "\(process.pid)").font(.ui(TextSize.caption).monospacedDigit()).foregroundStyle(
                    .tertiary
                )
                .fixedSize()
                Text(ServerReading.arguments(process)).foregroundStyle(.tertiary).lineLimit(1)
            }
            .padding(.leading, inside ? Metrics.indentStep + Metrics.iconSmall : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            PartOf(app: app, process: process).frame(width: Self.part, alignment: .leading)
            Text(process.user).foregroundStyle(.secondary).lineLimit(1).frame(width: Self.user, alignment: .leading)
            Text(ServerReading.percent(process.cpu)).frame(width: Self.number, alignment: .trailing)
            Text(process.memory > 0 ? bytes(process.memory) : "–").frame(width: Self.number, alignment: .trailing)
            Text(shortSpan(Double(process.seconds), units: 2, smallest: .second)).foregroundStyle(.secondary).frame(
                width: Self.number, alignment: .trailing)
        }
        .font(.ui(TextSize.row).monospacedDigit())
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
            Button(String(localized: "Copy Command Line")) { copyText(process.args) }
            Button(String(localized: "Copy PID")) { copyText("\(process.pid)") }
        }
    }
}

/// One program's processes folded into a line: their count, and what they take together. A click opens it.
private struct FoldedRow: View {
    let app: AppModel, line: ServerProcesses.Line
    @Binding var open: Bool
    @State private var hovering = false

    var body: some View {
        let first = line.members[0]
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.symbol(Metrics.iconTiny))
                    .foregroundStyle(.secondary).frame(width: Metrics.iconSmall)
                Text(first.command).lineLimit(1)
                Text(verbatim: "×\(line.members.count)").font(.ui(TextSize.caption).monospacedDigit())
                    .foregroundStyle(.secondary).padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: Metrics.radiusXS).fill(Color(nsColor: .fillHover)))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            PartOf(app: app, process: first).frame(width: ProcessRow.part, alignment: .leading)
            Text(line.users).foregroundStyle(.secondary).lineLimit(1).frame(width: ProcessRow.user, alignment: .leading)
            Text(ServerReading.percent(line.cpu)).frame(width: ProcessRow.number, alignment: .trailing)
            Text(line.memory > 0 ? bytes(line.memory) : "–").frame(width: ProcessRow.number, alignment: .trailing)
            Text(shortSpan(Double(line.seconds), units: 2, smallest: .second)).foregroundStyle(.secondary).frame(
                width: ProcessRow.number, alignment: .trailing)
        }
        .font(.ui(TextSize.row).monospacedDigit())
        .padding(.horizontal, 8)
        .frame(height: Metrics.row)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusSM).fill(hovering ? Color(nsColor: .fillHover) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { withAnimation(.easeInOut(duration: Motion.fast)) { open.toggle() } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(open ? String(localized: "Collapse") : String(localized: "Expand"))
    }
}

/// What a process is part of: its Kelp agent (with its status), its container or its systemd unit.
private struct PartOf: View {
    let app: AppModel, process: HostStats.Process

    var body: some View {
        if let sid = process.session, let session = app.session(sid) {
            HStack(spacing: 4) {
                StatusIcon(status: session.markStatus, waitsForCommand: session.waitsForCommand).frame(
                    width: 12, height: 12)
                Text(app.catalog.displayName(session)).lineLimit(1)
            }
        } else if process.session != nil {
            Text("Kelp").foregroundStyle(.secondary)
        } else if let place = ServerReading.place(process) {
            HStack(spacing: 4) {
                Image(systemName: place.symbol).font(.symbol(Metrics.iconSmall)).foregroundStyle(.secondary)
                Text(place.name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .help(process.container.map { String(localized: "Container \($0)") } ?? process.unit ?? "")
        }
    }
}
