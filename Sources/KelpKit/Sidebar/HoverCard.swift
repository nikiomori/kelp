import AppKit
import SwiftUI
import Core
import DesignKit
import WorkbenchKit

/// What a sidebar row or an agent's tab holds, in full, when the pointer rests on it: the row itself stays one line.
/// After half a second the card appears; while one is open, moving to another row shows that row's card at once.
/// Typing, ⌘W included, puts it away.
@MainActor
final class HoverCard {
    private let app: AppModel
    /// Under a tab: the card hangs below it and leaves out the place (the tab is in this workspace).
    private let underTabs: Bool
    private var keys: Any?
    private let popover = NSPopover()
    private let pending = Debounce()
    private(set) var shownKey: String?
    private var shown: CardModel?
    private var warmUntil = Date.distantPast
    private weak var anchor: NSWindow?

    init(app: AppModel, underTabs: Bool = false) {
        self.app = app
        self.underTabs = underTabs
        popover.behavior = .applicationDefined
        popover.animates = false
        // The rows' pointer events stop when the window loses focus, so the one that would close the card may never come:
        // a card left open costs a core's tenth for as long as it stays, SwiftUI laying it out over and over.
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] n in
            let window = n.object as? NSWindow
            MainActor.assumeIsolated { if window === self?.anchor { self?.closeUnlessInside() } }   // queue: .main
        }
    }

    /// The pointer is over a row (`key` "w:…" / "a:…"), or over nothing.
    func hover(_ key: String?, rect: NSRect, in view: NSView) {
        guard key != shownKey || !popover.isShown else { return }
        guard let key else { pending.after(Motion.hoverClose) { [weak self] in self?.closeUnlessInside() }; return }
        let warm = popover.isShown || Date() < warmUntil
        pending.after(warm ? Motion.hoverOpenWarm : Motion.hoverOpen) { [weak self, weak view] in if let view { self?.show(key, rect: rect, in: view) } }
    }

    /// The pointer went into the card, whose buttons are for clicking: it stays, looked at again until the pointer leaves.
    func closeUnlessInside() {
        guard popover.contentViewController?.view.window?.frame.contains(NSEvent.mouseLocation) == true else { close(); return }
        pending.after(Motion.hoverClose) { [weak self] in self?.closeUnlessInside() }
    }

    func close() {
        pending.cancel()
        shown?.stop()
        if popover.isShown { warmUntil = Date().addingTimeInterval(0.8); popover.close() }
        shownKey = nil
        if let keys { NSEvent.removeMonitor(keys); self.keys = nil }
    }

    /// A row's card without the wait: a click asked for it.
    func open(_ key: String, rect: NSRect, in view: NSView) {
        pending.cancel()
        if key != shownKey || !popover.isShown { show(key, rect: rect, in: view) }
    }

    private func show(_ key: String, rect: NSRect, in view: NSView) {
        // Events come only while the window is key.
        guard view.window != nil, let model = CardModel(key, app: app, placed: !underTabs) else { close(); return }
        shown?.stop()
        shown = model
        shownKey = key
        anchor = view.window
        model.closeCard = { [weak self] in self?.close() }
        let host = NSHostingController(rootView: CardView(model: model))
        host.sizingOptions = .preferredContentSize   // else the popover is placed at a pre-layout size and grows down from its top, off the row
        popover.contentViewController = host
        popover.show(relativeTo: rect, of: view, preferredEdge: underTabs ? .minY : .maxX)
        model.load()
        keys = keys ?? NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainActor.assumeIsolated { self?.close() }   // local monitors run on the main thread
            return e
        }
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
    var context: SessionContextWindow.Usage?
    var parts: SessionContextParts.Parts?
    var pages: [ServedPage] = []
    /// The host a remote project's card shows how it's doing.
    let server: String?
    /// Puts the card away (a button in it opened something else).
    @ObservationIgnored var closeCard: () -> Void = {}
    /// What its subagents did last, read while the card is up.
    private var watches: [Watched] = []

    /// `placed`: the subtitle says where the agent is (group · project); a tab's card leaves it out.
    init?(_ key: String, app: AppModel, placed: Bool = true) {
        self.app = app
        let m = app
        if key.hasPrefix("a:"), let s = m.session(String(key.dropFirst(2))) {
            title = app.catalog.displayName(s)
            let w = m.worktree(s.worktreeId)
            subtitle = placed ? [m.groupName(w), m.projectName(w?.repoId)].compactMap { $0 }.joined(separator: " · ") : ""
            agents = [Agent(id: s.id, session: s)]
            workspaceId = s.worktreeId ?? ""
            agentOnly = true
            repo = nil
            muteIds = [s.id]
            server = nil
        } else if key.hasPrefix("p:"), let r = m.repo(String(key.dropFirst(2))) {
            title = m.projectName(r.id) ?? r.name; subtitle = m.projectPlace(r)
            agents = []
            workspaceId = ""
            agentOnly = false
            repo = r
            muteIds = [r.id]
            server = RemoteHost.of(r.path)?.host
        } else if key.hasPrefix("w:"), let w = m.worktree(String(key.dropFirst(2))) {
            let r = m.repo(w.repoId)
            // A project's own screen has no name of its own: the row stands for the project.
            let group = m.groupName(w)
            title = group ?? m.projectName(r?.id) ?? w.displayName
            let branch = w.path == r?.path ? nil : String(localized: "branch \(w.branch)")
            subtitle = [group == nil ? nil : m.projectName(r?.id), branch].compactMap { $0 }.joined(separator: " · ")
            agents = m.sessions.filter { $0.worktreeId == w.id && $0.isChat && $0.status != .exited }.map { Agent(id: $0.id, session: $0) }
            workspaceId = w.id
            agentOnly = false
            repo = nil
            let alone = m.worktrees.filter { $0.repoId == w.repoId && !$0.archived }.count == 1
            muteIds = [w.id] + (alone ? [w.repoId] : [])
            server = r.flatMap { RemoteHost.of($0.path)?.host }
        } else { return nil }
    }

    func load() {
        let m = app
        watches = agents.filter { $0.session.agent == "claude" }.map { a in
            let w = Watched(.subagents, in: m)
            w.key = a.id
            return w
        }
        Task {
            if let repo { worktrees = await m.quiet(RepoWorktreeSizes(id: repo.id)) ?? []; return }
            if !agentOnly {
                changes = await m.quiet(GitLineStats(id: workspaceId))
                if let p = await m.quiet(GitHubBranchPR(worktreeId: workspaceId)) ?? nil { pr = p }
                pages = ServedPages.list(printed: [], ports: await m.quiet(PortsList(worktreeId: workspaceId)) ?? [])
            }
            guard agentOnly, let a = agents.first else { return }
            if !workspaceId.isEmpty {
                pages = ServedPages.list(printed: [], ports: (await m.quiet(PortsList(worktreeId: workspaceId)) ?? []).filter { $0.session == a.id })
            }
            if let t = (await m.quiet(SessionTurn(id: a.id)) ?? nil)?.turn {
                let files = t.files
                let add = files.reduce(0) { $0 + $1.added }, del = files.reduce(0) { $0 + $1.removed }
                let took = shortSpan(t.seconds, smallest: .second)
                turn = files.isEmpty ? String(localized: "Last turn changed no files · \(took)")
                    : files.count == 1 ? String(localized: "Last turn: 1 file +\(add) −\(del) · \(took)")
                    : String(localized: "Last turn: \(files.count) files +\(add) −\(del) · \(took)")
            }
            if let u = await m.quiet(SessionContextWindow(id: a.id)) ?? nil { context = u }
        }
    }

    /// What filled the context reads all of the transcript: only once someone opens it.
    func loadParts() async {
        if parts == nil, let a = agents.first { parts = await app.quiet(SessionContextParts(id: a.id)) ?? nil }
    }

    func stop() { watches = [] }

    /// Compact Now, once the ring turns orange, while the agent is at its prompt (a question's menu would take the text).
    var compact: (() -> Void)? {
        guard let c = context, ContextMeter.level(c) >= 2, let a = agents.first,
              [.done, .idle, .error].contains(app.session(a.id)?.status) else { return nil }
        let app = self.app
        return { Task { await app.call(SessionSend(id: a.id, text: "/compact", enter: true)) } }
    }
}

extension CardModel {
    /// What the next message will pay for, while the agent rests: said from 15 minutes before the cache goes cold.
    var coldCache: String? {
        guard let c = context, let until = c.cacheUntil, let a = agents.first,
              [.done, .idle, .error].contains(app.session(a.id)?.status) else { return nil }
        return Self.coldCache(until: until, used: c.used, now: Date())
    }

    static func coldCache(until: Date, used: Int, now: Date) -> String? {
        let left = until.timeIntervalSince(now), size = ContextParts.k(used)
        if left <= 0 { return String(localized: "Cache is cold: the next message writes \(size) again") }
        let minutes = Int((left / 60).rounded(.up))
        return minutes <= 15 ? String(localized: "Cache goes cold in \(minutes) min: then the next message writes \(size) again") : nil
    }
}

struct CardView: View {
    let model: CardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.ui(13, weight: .semibold)).lineLimit(2)
                if !model.subtitle.isEmpty { Text(model.subtitle).font(.ui(11)).foregroundStyle(.secondary).lineLimit(1) }
            }
            if let h = model.server { ServerSection(app: model.app, host: h, close: model.closeCard) }
            if let r = model.repo { WorktreeSizes(items: model.worktrees, root: r.path) }
            if let pr = model.pr { PRLine(pr: pr) }
            if let c = model.changes, c.totalAdded + c.totalRemoved > 0 {
                (Text("Not committed  ") + Text(c.totalAdded > 0 ? "+\(c.totalAdded)" : "").foregroundColor(.textGreen)
                    + Text(c.totalAdded > 0 && c.totalRemoved > 0 ? " " : "") + Text(c.totalRemoved > 0 ? "−\(c.totalRemoved)" : "").foregroundColor(.textRed))
                    .font(.ui(11).monospacedDigit()).foregroundStyle(.secondary)
            }
            ForEach(model.agents) { a in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        StatusIcon(status: a.session.markStatus, waitsForCommand: a.session.waitsForCommand).font(.ui(11))
                        Text(model.agentOnly ? a.session.statusWords : model.app.catalog.displayName(a.session)).font(.ui(12)).lineLimit(1)
                        if !model.agentOnly { Text(a.session.statusWords).font(.ui(11)).foregroundStyle(.secondary) }
                        Spacer(minLength: 8)
                        Text(shortAgo(a.session.statusAt ?? a.session.createdAt)).font(.ui(11).monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    if !a.session.summary.isEmpty {
                        Text(Self.linked(a.session.summary)).font(.ui(11)).foregroundStyle(.secondary).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let g = a.session.goal { Text("Goal: \(g)").font(.ui(11)).foregroundStyle(.secondary).lineLimit(3) }
                    if let q = a.session.quietSince, a.session.status == .working {
                        Text("No news for \(shortSpan(Date().timeIntervalSince(q)))").font(.ui(11)).foregroundStyle(.secondary)
                    }
                    if a.session.guessed == true, [.working, .done].contains(a.session.status) {
                        Text("Read off the screen: a guess, so Kelp won't call it done or notify").font(.ui(11)).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let w = a.session.workingElsewhere { Text(w).font(.ui(11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                    if model.agentOnly, let b = a.session.browser {
                        Text("Browser \(BrowserSkillWords.line(b))").font(.ui(11)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                AgentWork(model: model, id: a.id)
            }
            if !model.pages.isEmpty {
                HStack(spacing: 8) {
                    ForEach(model.pages, id: \.port) { p in
                        Button(p.address) { model.app.scripts.open(p, in: model.workspaceId) }
                            .buttonStyle(PointerButtonStyle()).font(.ui(11).monospacedDigit()).foregroundStyle(Color.accentColor)
                    }
                }
            }
            if let until = model.app.mutedUntil(model.muteIds) {
                HStack(spacing: 8) {
                    Text(Mutes.line(until: until)).font(.ui(11)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Unmute") { model.app.mute(model.muteIds, until: nil) }.controlSize(.small)
                }
            }
            if let t = model.turn { Text(t).font(.ui(11).monospacedDigit()).foregroundStyle(.secondary) }
            if let c = model.context { ContextBlock(model: model, used: c.used, window: c.window) }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
    }

    /// An agent's summary often ends with a Markdown link ("Plan ready: [Plan](https://…)"): its words, clickable.
    static func linked(_ text: String) -> AttributedString {
        do { return try AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) }
        catch { return AttributedString(text) }   // not Markdown: as written
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
                Text("#\(pr.number)").font(.ui(12).monospacedDigit())
                Text(pr.title).font(.ui(12)).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(state).foregroundStyle(color)
                if failed > 0 { Text("✕ \(failed) failing").foregroundStyle(Color.textRed) }
                else if pending > 0 { Text("● \(pending) running").foregroundStyle(Color.textOrange) }
                else if passed > 0 { Text("✓ checks passed").foregroundStyle(Color.textGreen) }
            }.font(.ui(11))
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
                }.font(.ui(12))
                ForEach(items.prefix(8), id: \.path) { w in
                    HStack(spacing: 6) {
                        Text(Self.name(w.path, root: root)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(Self.size(w.bytes)).monospacedDigit()
                    }.font(.ui(11)).foregroundStyle(.secondary)
                }
                if items.count > 8 { Text("\(items.count - 8) more").font(.ui(11)).foregroundStyle(.tertiary) }
            }
        } else {
            (items == nil ? Text("Measuring worktrees…") : Text("No other git worktrees")).font(.ui(11)).foregroundStyle(.secondary)
        }
    }
    static func name(_ p: String, root: String) -> String {
        p.hasPrefix(root + "/") ? String(p.dropFirst(root.count + 1)) : (p as NSString).abbreviatingWithTildeInPath
    }
    static func size(_ b: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file) }
}

/// How full the agent's conversation is, and what filled it under a click, remembered: it's a long table, so it stays out
/// of the way until someone wants it, or until Compact Now, which stands in it, is an answer.
struct ContextBlock: View {
    let model: CardModel, used: Int, window: Int
    @AppStorage("sidebar.card.contextOpen") private var opened = false

    var body: some View {
        let open = opened || model.compact != nil
        VStack(alignment: .leading, spacing: 6) {
            Button { opened.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right").font(.symbol(Metrics.iconTiny)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    ContextLine(used: used, window: window)
                }
            }
            .buttonStyle(PointerButtonStyle()).padding(.horizontal, -4)
            if let cold = model.coldCache { Text(cold).font(.ui(11)).foregroundStyle(.secondary) }
            if open, let parts = model.parts { ContextParts(parts: parts, window: window, compact: model.compact) }
        }
        .task(id: open) { if open { await model.loadParts() } }
    }
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
            Text("Context \(Int(share * 100))% · \(used / 1000)k of \(window / 1000)k tokens").font(.ui(11).monospacedDigit()).foregroundStyle(color)
        }
    }
}
