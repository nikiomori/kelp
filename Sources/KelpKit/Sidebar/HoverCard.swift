import AppKit
import SwiftUI
import Core
import DesignKit

/// What a sidebar row holds, in full, when the pointer rests on it: the row itself stays one line.
/// After half a second the card appears; while one is open, moving to another row shows that row's card at once.
@MainActor
final class HoverCard {
    private let app: AppModel
    private let popover = NSPopover()
    private let pending = Debounce()
    private(set) var shownKey: String?
    private var warmUntil = Date.distantPast

    init(app: AppModel) {
        self.app = app
        popover.behavior = .applicationDefined
        popover.animates = false
    }

    /// The pointer is over a row (`key` "w:…" / "a:…"), or over nothing.
    func hover(_ key: String?, rect: NSRect, in view: NSView) {
        guard key != shownKey || !popover.isShown else { return }
        guard let key else { pending.after(Motion.hoverClose) { [weak self] in self?.closeUnlessInside() }; return }
        let warm = popover.isShown || Date() < warmUntil
        pending.after(warm ? Motion.hoverOpenWarm : Motion.hoverOpen) { [weak self, weak view] in if let view { self?.show(key, rect: rect, in: view) } }
    }

    /// The pointer went into the card, whose buttons are for clicking: it stays, looked at again until the pointer leaves.
    private func closeUnlessInside() {
        guard popover.contentViewController?.view.window?.frame.contains(NSEvent.mouseLocation) == true else { close(); return }
        pending.after(Motion.hoverClose) { [weak self] in self?.closeUnlessInside() }
    }

    func close() {
        pending.cancel()
        if popover.isShown { warmUntil = Date().addingTimeInterval(0.8); popover.close() }
        shownKey = nil
    }

    private func show(_ key: String, rect: NSRect, in view: NSView) {
        guard view.window != nil, let model = CardModel(key, app: app) else { close(); return }   // events come only while the window is key
        shownKey = key
        let host = NSHostingController(rootView: CardView(model: model))
        host.sizingOptions = .preferredContentSize   // else the popover is placed at a pre-layout size and grows down from its top, off the row
        popover.contentViewController = host
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxX)
        model.load()
    }
}

/// The card's contents: what the sidebar knows now, then what git, GitHub and the agent's transcript add.
@MainActor
@Observable
final class CardModel {
    struct Agent: Identifiable { let id: String; let session: Session }
    let title: String, subtitle: String
    let agents: [Agent]
    let workspaceId: String
    let agentOnly: Bool
    let app: AppModel
    /// A project's card: the disk its other worktrees take (nil while `du` runs).
    let repo: Repo?
    /// Whose mute the card shows: the row's. A workspace alone in its project is that project's row too.
    let muteIds: [String]
    var worktrees: [RepoWorktreeSizes.Item]?
    var changes: LineStats?
    var pr: GitHub.PullRequest?
    var turn: String?
    var context: (used: Int, window: Int)?
    var parts: SessionContextParts.Parts?
    var ports: [Int] = []

    init?(_ key: String, app: AppModel) {
        self.app = app
        let m = app
        if key.hasPrefix("a:"), let s = m.session(String(key.dropFirst(2))) {
            title = app.catalog.displayName(s)
            let w = m.worktree(s.worktreeId)
            subtitle = [w?.displayName, m.projectName(w?.repoId)].compactMap { $0 }.joined(separator: " · ")
            agents = [Agent(id: s.id, session: s)]
            workspaceId = s.worktreeId ?? ""
            agentOnly = true
            repo = nil
            muteIds = [s.id]
        } else if key.hasPrefix("p:"), let r = m.repo(String(key.dropFirst(2))) {
            title = m.projectName(r.id) ?? r.name; subtitle = m.projectPlace(r)
            agents = []
            workspaceId = ""
            agentOnly = false
            repo = r
            muteIds = [r.id]
        } else if key.hasPrefix("w:"), let w = m.worktree(String(key.dropFirst(2))) {
            let r = m.repo(w.repoId)
            title = w.displayName
            subtitle = [m.projectName(r?.id), w.path == r?.path ? nil : String(localized: "branch \(w.branch)")].compactMap { $0 }.joined(separator: " · ")
            agents = m.sessions.filter { $0.worktreeId == w.id && $0.agent != "shell" && $0.status != .exited }.map { Agent(id: $0.id, session: $0) }
            workspaceId = w.id
            agentOnly = false
            repo = nil
            let alone = m.worktrees.filter { $0.repoId == w.repoId && !$0.archived }.count == 1
            muteIds = [w.id] + (alone ? [w.repoId] : [])
        } else { return nil }
    }

    func load() {
        let m = app
        Task {
            if let repo { worktrees = await m.quiet(RepoWorktreeSizes(id: repo.id)) ?? []; return }
            if !agentOnly {
                changes = await m.quiet(GitLineStats(id: workspaceId))
                if let p = await m.quiet(GitHubBranchPR(worktreeId: workspaceId)) ?? nil { pr = p }
                ports = (await m.quiet(PortsList(worktreeId: workspaceId)) ?? []).map(\.port)
            }
            guard agentOnly, let a = agents.first else { return }
            if let t = (await m.quiet(SessionTurn(id: a.id)) ?? nil)?.turn {
                let files = t.files
                let add = files.reduce(0) { $0 + $1.added }, del = files.reduce(0) { $0 + $1.removed }
                let took = shortSpan(t.seconds, smallest: .second)
                turn = files.isEmpty ? String(localized: "Last turn changed no files · \(took)")
                    : files.count == 1 ? String(localized: "Last turn: 1 file +\(add) −\(del) · \(took)")
                    : String(localized: "Last turn: \(files.count) files +\(add) −\(del) · \(took)")
            }
            if let u = await m.quiet(SessionContextWindow(id: a.id)) ?? nil { context = (u.used, u.window) }
            if context != nil { parts = await m.quiet(SessionContextParts(id: a.id)) ?? nil }
        }
    }

    /// Compact Now, from 90 %, while the agent is at its prompt (a question's menu would take the text).
    var compact: (() -> Void)? {
        guard let c = context, Double(c.used) >= 0.9 * Double(c.window), let a = agents.first,
              [.done, .idle, .error].contains(app.session(a.id)?.status) else { return nil }
        let app = self.app
        return { Task { await app.call(SessionSend(id: a.id, text: "/compact", enter: true)) } }
    }
}

struct CardView: View {
    let model: CardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.system(size: TextSize.of(13), weight: .semibold)).lineLimit(2)
                if !model.subtitle.isEmpty { Text(model.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
            }
            if let r = model.repo { WorktreeSizes(items: model.worktrees, root: r.path) }
            if let pr = model.pr { PRLine(pr: pr) }
            if let c = model.changes, c.totalAdded + c.totalRemoved > 0 {
                (Text("Not committed  ") + Text(c.totalAdded > 0 ? "+\(c.totalAdded)" : "").foregroundColor(.textGreen)
                    + Text(c.totalAdded > 0 && c.totalRemoved > 0 ? " " : "") + Text(c.totalRemoved > 0 ? "−\(c.totalRemoved)" : "").foregroundColor(.textRed))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ForEach(model.agents) { a in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        StatusIcon(status: a.session.markStatus).font(.caption)
                        Text(model.agentOnly ? a.session.statusWords : model.app.catalog.displayName(a.session)).font(.callout).lineLimit(1)
                        if !model.agentOnly { Text(a.session.statusWords).font(.caption).foregroundStyle(.secondary) }
                        Spacer(minLength: 8)
                        Text(shortAgo(a.session.statusAt ?? a.session.createdAt)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    if !a.session.summary.isEmpty {
                        Text(a.session.summary).font(.caption).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    }
                    if let r = a.session.running, [.working, .waiting].contains(a.session.status) {
                        Text("Running: \(AgentCommand.short(r))").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if let g = a.session.goal { Text("Goal: \(g)").font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                    if let b = a.session.background, !b.isEmpty {
                        Text("In the background: \(b.joined(separator: ", "))").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if let w = a.session.workingElsewhere { Text(w).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                }
            }
            if !model.ports.isEmpty {
                Text(String(localized: "Serving \(model.ports.map { "localhost:\($0)" }.joined(separator: ", "))"))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let until = model.app.mutedUntil(model.muteIds) {
                HStack(spacing: 8) {
                    Text(Mutes.line(until: until)).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Unmute") { model.app.mute(model.muteIds, until: nil) }.controlSize(.small)
                }
            }
            if let t = model.turn { Text(t).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            if let c = model.context { ContextLine(used: c.used, window: c.window) }
            if let c = model.context, let p = model.parts { ContextParts(parts: p, window: c.window, compact: model.compact) }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
    }
}

/// "#123 Fix login · Open · ✓ 5 checks": a PR in GitHub's own colours (open green, draft grey, merged purple, closed red).
struct PRLine: View {
    let pr: GitHub.PullRequest
    var body: some View {
        let state = pr.isDraft ? String(localized: "Draft") : pr.state.capitalized
        let color: Color = state == String(localized: "Draft") ? .secondary : state == "Merged" ? .textPurple : state == "Closed" ? .textRed : .textGreen
        let failed = pr.checks.failed, pending = pr.checks.pending, passed = pr.checks.passed
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: state == "Merged" ? "arrow.triangle.merge" : "arrow.triangle.pull").foregroundStyle(color)
                Text("#\(pr.number)").font(.callout.monospacedDigit())
                Text(pr.title).font(.callout).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(state).foregroundStyle(color)
                if failed > 0 { Text("✕ \(failed) failing").foregroundStyle(Color.textRed) }
                else if pending > 0 { Text("● \(pending) running").foregroundStyle(Color.textOrange) }
                else if passed > 0 { Text("✓ checks passed").foregroundStyle(Color.textGreen) }
            }.font(.caption)
        }
    }
}

/// "Worktrees 20.1 GB" over the biggest ones, named inside the project when they're in it (`.claude/worktrees/…`).
struct WorktreeSizes: View {
    let items: [RepoWorktreeSizes.Item]?, root: String
    var body: some View {
        if let items, !items.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Worktrees")
                    Spacer(minLength: 8)
                    Text(Self.size(items.reduce(0) { $0 + $1.bytes })).monospacedDigit()
                }.font(.callout)
                ForEach(items.prefix(8), id: \.path) { w in
                    HStack(spacing: 6) {
                        Text(Self.name(w.path, root: root)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(Self.size(w.bytes)).monospacedDigit()
                    }.font(.caption).foregroundStyle(.secondary)
                }
                if items.count > 8 { Text("\(items.count - 8) more").font(.caption).foregroundStyle(.tertiary) }
            }
        } else {
            (items == nil ? Text("Measuring worktrees…") : Text("No other git worktrees")).font(.caption).foregroundStyle(.secondary)
        }
    }
    static func name(_ p: String, root: String) -> String {
        p.hasPrefix(root + "/") ? String(p.dropFirst(root.count + 1)) : (p as NSString).abbreviatingWithTildeInPath
    }
    static func size(_ b: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file) }
}

/// How full the agent's conversation is; amber from three quarters, red from nine tenths.
struct ContextLine: View {
    let used: Int, window: Int
    var body: some View {
        let share = min(1, Double(used) / Double(max(1, window)))
        let color: Color = share >= 0.9 ? .red : share >= 0.75 ? .orange : .secondary
        HStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                Circle().trim(from: 0, to: share).stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
            }.frame(width: 11, height: 11)
            Text("Context \(Int(share * 100))% · \(used / 1000)k of \(window / 1000)k tokens").font(.caption.monospacedDigit()).foregroundStyle(color)
        }
    }
}
