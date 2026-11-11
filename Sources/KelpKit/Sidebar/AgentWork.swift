import Agents
import Core
import DesignKit
import SwiftUI
import WorkbenchKit

/// What runs under an agent, in a hover card: who asks, who works, its commands, then who finished. Agents it started,
/// subagents and commands are one row's drawing and differ in their mark and in what a click opens.
struct AgentWork: View {
    let model: CardModel, id: String
    @State private var everyone = false
    @State private var finishedShown = false
    private static let atOnce = 5
    /// How long a transcript stands still before its row says so: a long command, or a subagent that hangs.
    private static let quietAfter: TimeInterval = 300

    var body: some View {
        if let session = model.app.session(id) {
            let rows = rows(session), finished = session.finishedSubagents
            if !rows.isEmpty || !finished.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if !rows.isEmpty {
                        heading(finished: finished.count, of: finished.count + session.runningSubagents.count)
                    }
                    ForEach(everyone ? rows : Array(rows.prefix(Self.atOnce))) { AgentWorkRow(row: $0) }
                    if !everyone, rows.count > Self.atOnce {
                        Button {
                            everyone = true
                        } label: {
                            Text("\(rows.count - Self.atOnce) more").font(.ui(TextSize.caption)).foregroundStyle(
                                .secondary
                            ).frame(
                                maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(PointerButtonStyle(flush: true))
                    }
                    if !finished.isEmpty { finishedRows(finished, in: session) }
                }
            }
        }
    }

    private func heading(finished: Int, of total: Int) -> some View {
        HStack(spacing: 6) {
            Text("At work").sectionTitle()
            if finished > 0 { Text("\(finished) of \(total) finished").font(.ui(TextSize.caption).monospacedDigit()) }
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private func finishedRows(_ finished: [Subagent], in session: Session) -> some View {
        let from = finished.map(\.started).min() ?? Date(), to = finished.compactMap(\.ended).max() ?? Date()
        Button {
            finishedShown.toggle()
        } label: {
            AgentWorkRow(
                row: .init(
                    id: "finished", mark: .status(.done), title: String(localized: "Finished \(finished.count)"),
                    time: shortSpan(to.timeIntervalSince(from), smallest: .second), chevron: finishedShown ? 90 : 0))
        }
        .buttonStyle(PointerButtonStyle(flush: true))
        if finishedShown {
            ForEach(finished) { run in
                let took = (run.ended ?? run.started).timeIntervalSince(run.started)
                AgentWorkRow(
                    row: .init(
                        id: run.id, mark: .none, title: run.title, kind: run.shownKind,
                        time: shortSpan(took, smallest: .second), open: opener(run, in: session)))
            }
        }
    }

    private func rows(_ session: Session) -> [AgentWorkRow.Row] {
        let all =
            model.app.children(of: session.id).map(kid)
            + session.runningSubagents.map { subagent($0, in: session) }
        return all.filter { $0.mark == .status(.waiting) } + all.filter { $0.mark == .status(.working) }
            + commands(session)
            + all.filter { $0.mark != .status(.waiting) && $0.mark != .status(.working) }
    }

    private func kid(_ child: Session) -> AgentWorkRow.Row {
        let app = model.app, id = child.id, status = ChildrenBadge.status(child), name = app.catalog.displayName(child)
        let stop = child.status == .done ? app.extensions.all.plans?.title(name, child) : nil
        let asks = status == .waiting ? stop ?? child.statusWords : nil
        return .init(
            id: id, mark: .status(status), title: name, kind: app.catalog.name(child.agent),
            time: shortAgo(child.statusAt ?? child.createdAt), detail: asks, warns: asks != nil,
            open: { app.workbench.focus(session: id) })
    }

    private func subagent(_ run: Subagent, in session: Session) -> AgentWorkRow.Row {
        .init(
            id: run.id, mark: .status(run.asks == true ? .waiting : .working), title: run.title, kind: run.shownKind,
            since: run.started,
            detail: run.asks == true ? String(localized: "Asks for permission") : step(of: run),
            warns: run.asks == true, code: run.asks != true,
            open: opener(run, in: session))
    }

    private func step(of run: Subagent) -> String? {
        guard let last = model.app.latest(SubagentsEvent.self, id)?.steps[run.id] else { return nil }
        let text = last.step.tool + "  " + last.step.detail, quiet = Date().timeIntervalSince(last.touched)
        return quiet < Self.quietAfter ? text : String(localized: "\(text) · quiet for \(shortSpan(quiet))")
    }

    private func commands(_ session: Session) -> [AgentWorkRow.Row] {
        let now = [.working, .waiting].contains(session.status) ? session.running : nil
        let background = (session.background ?? []).map(AgentCommand.short)
        return ((now.map { [AgentCommand.short($0)] } ?? []) + background).enumerated().map {
            .init(id: "command \($0.offset)", mark: .command, title: $0.element, code: true)
        }
    }

    /// A subagent's journal, where its agent keeps one.
    private func opener(_ run: Subagent, in session: Session) -> (@MainActor () -> Void)? {
        guard model.app.catalog.manifest(session.agent)?.transcript == .claude else { return nil }
        let app = model.app, uri = TabURI.subagent(session: session.id, id: run.id), workspace = session.worktreeId
        return { app.workbench.open(uri, workspace: workspace) }
    }
}

struct AgentWorkRow: View {
    struct Row: Identifiable {
        enum Mark: Equatable { case status(AgentStatus), command, none }
        var id: String, mark: Mark, title: String
        var kind: String?
        /// Running: its time counts up from here. Else `time`.
        var since: Date?
        var time: String?
        var detail: String?
        var warns = false
        /// Text from the agent's world: `title` for a command, `detail` for a step.
        var code = false
        var chevron: Double?
        var open: (@MainActor () -> Void)?
    }
    let row: Row

    var body: some View {
        if let open = row.open {
            Button(action: open) { content }.buttonStyle(PointerButtonStyle(flush: true))
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                mark.frame(width: 12, height: 12)
                Text(row.title).font(row.code && row.mark == .command ? .uiMono(TextSize.caption) : .ui(TextSize.row))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let kind = row.kind {
                    Text(kind).font(.ui(TextSize.caption)).foregroundStyle(.secondary).lineLimit(1).layoutPriority(-1)
                }
                Spacer(minLength: 8)
                if let angle = row.chevron {
                    Image(systemName: "chevron.right").font(.symbol(Metrics.iconTiny)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(angle))
                }
                time.font(.ui(TextSize.caption).monospacedDigit()).foregroundStyle(.secondary)
            }
            if let detail = row.detail {
                Text(detail).font(row.code ? .uiMono(TextSize.caption) : .ui(TextSize.caption)).foregroundStyle(
                    row.warns ? Color.textOrange : .secondary
                )
                .lineLimit(1).truncationMode(.middle).padding(.leading, 18)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var mark: some View {
        switch row.mark {
        case .status(let status): StatusIcon(status: status)
        case .command: Image(systemName: "apple.terminal").font(.symbol(Metrics.iconSmall)).foregroundStyle(.secondary)
        case .none: EmptyView()
        }
    }

    @ViewBuilder private var time: some View {
        if let since = row.since { Text(since, style: .timer) } else if let time = row.time { Text(time) }
    }
}
