import AppKit
import Core
import DesignKit
import SwiftUI
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
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) {
            [weak self] notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated { if window === self?.anchor { self?.closeUnlessInside() } }   // queue: .main
        }
    }

    /// The pointer is over a row (`key` "w:…" / "a:…"), or over nothing.
    func hover(_ key: String?, rect: NSRect, in view: NSView) {
        guard key != shownKey || !popover.isShown else { return }
        guard let key else {
            pending.after(Motion.hoverClose) { [weak self] in self?.closeUnlessInside() }
            return
        }
        let warm = popover.isShown || Date() < warmUntil
        pending.after(warm ? Motion.hoverOpenWarm : Motion.hoverOpen) { [weak self, weak view] in
            if let view { self?.show(key, rect: rect, in: view) }
        }
    }

    /// The pointer went into the card, whose buttons are for clicking: it stays, looked at again until the pointer leaves.
    func closeUnlessInside() {
        guard popover.contentViewController?.view.window?.frame.contains(NSEvent.mouseLocation) == true else {
            close()
            return
        }
        pending.after(Motion.hoverClose) { [weak self] in self?.closeUnlessInside() }
    }

    func close() {
        pending.cancel()
        shown?.stop()
        if popover.isShown {
            warmUntil = Date().addingTimeInterval(0.8)
            popover.close()
        }
        shownKey = nil
        if let keys {
            NSEvent.removeMonitor(keys)
            self.keys = nil
        }
    }

    /// A row's card without the wait: a click asked for it.
    func open(_ key: String, rect: NSRect, in view: NSView) {
        pending.cancel()
        if key != shownKey || !popover.isShown { show(key, rect: rect, in: view) }
    }

    private func show(_ key: String, rect: NSRect, in view: NSView) {
        // Events come only while the window is key.
        guard view.window != nil, let model = CardModel(key, app: app, placed: !underTabs) else {
            close()
            return
        }
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
        keys =
            keys
            ?? NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated { self?.close() }   // local monitors run on the main thread
                return event
            }
    }
}

/// The card's contents: what the sidebar knows now, the folder's git and PR as they're pushed, then what the agent's
/// transcript adds.
@MainActor
@Observable
final class CardModel {
    struct Agent: Identifiable {
        let id: String
        let session: Session
    }
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
    /// A workspace's card: the folder whose git and PR it shows (`gitFolder`), read while the card is up.
    let folder: String?
    var changes: LineStats? { folder.flatMap { app.latest(GitEvent.self, $0)?.stats } }
    var turn: String?
    var context: SessionContextWindow.Usage?
    var parts: SessionContextParts.Parts?
    var pages: [ServedPage] = []
    /// The host a remote project's card shows how it's doing.
    let server: String?
    /// Puts the card away (a button in it opened something else).
    @ObservationIgnored var closeCard: () -> Void = {}
    /// What its subagents did last and its folder's git, read while the card is up.
    private var watches: [Watched] = []

    /// `placed`: the subtitle says where the agent is (group · project); a tab's card leaves it out.
    init?(_ key: String, app: AppModel, placed: Bool = true) {
        self.app = app
        if key.hasPrefix("a:"), let session = app.session(String(key.dropFirst(2))) {
            title = app.catalog.displayName(session)
            let worktree = app.worktree(session.worktreeId)
            subtitle =
                placed
                ? [app.groupName(worktree), app.projectName(worktree?.repoId)].compactMap { $0 }.joined(
                    separator: " · ") : ""
            agents = [Agent(id: session.id, session: session)]
            workspaceId = session.worktreeId ?? ""
            agentOnly = true
            repo = nil
            muteIds = [session.id]
            server = nil
            folder = nil
        } else if key.hasPrefix("p:"), let project = app.repo(String(key.dropFirst(2))) {
            title = app.projectName(project.id) ?? project.name
            subtitle = app.projectPlace(project)
            agents = []
            workspaceId = ""
            agentOnly = false
            repo = project
            muteIds = [project.id]
            server = RemoteHost.of(project.path)?.host
            folder = nil
        } else if key.hasPrefix("w:"), let worktree = app.worktree(String(key.dropFirst(2))) {
            let project = app.repo(worktree.repoId)
            // A project's own screen has no name of its own: the row stands for the project.
            let group = app.groupName(worktree)
            title = group ?? app.projectName(project?.id) ?? worktree.displayName
            let branch = worktree.path == project?.path ? nil : String(localized: "branch \(worktree.branch)")
            subtitle = [group == nil ? nil : app.projectName(project?.id), branch].compactMap { $0 }.joined(
                separator: " · ")
            agents = app.sessions.filter { $0.worktreeId == worktree.id && $0.isChat && $0.status != .exited }.map {
                Agent(id: $0.id, session: $0)
            }
            workspaceId = worktree.id
            agentOnly = false
            repo = nil
            let alone = app.worktrees.filter { $0.repoId == worktree.repoId && !$0.archived }.count == 1
            muteIds = [worktree.id] + (alone ? [worktree.repoId] : [])
            server = project.flatMap { RemoteHost.of($0.path)?.host }
            folder = app.gitFolder(of: worktree.id)?.id
        } else {
            return nil
        }
    }

    func load() {
        watches = agents.filter { $0.session.agent == "claude" }.map { agent in
            let watched = Watched(.subagents, in: app)
            watched.key = agent.id
            return watched
        }
        if let folder {
            let git = Watched(.git, in: app)
            git.key = folder
            watches.append(git)
            app.extensions.all.ci?.carded(folder)
        }
        Task {
            if let repo {
                worktrees = await app.quiet(RepoWorktreeSizes(id: repo.id)) ?? []
                return
            }
            if !agentOnly {
                pages = ServedPages.list(printed: [], ports: await app.quiet(PortsList(worktreeId: workspaceId)) ?? [])
            }
            guard agentOnly, let agent = agents.first else { return }
            if !workspaceId.isEmpty {
                pages = ServedPages.list(
                    printed: [],
                    ports: (await app.quiet(PortsList(worktreeId: workspaceId)) ?? []).filter { $0.session == agent.id }
                )
            }
            if let lastTurn = (await app.quiet(SessionTurn(id: agent.id)) ?? nil)?.turn {
                let files = lastTurn.files
                let add = files.reduce(0) { $0 + $1.added }, del = files.reduce(0) { $0 + $1.removed }
                let took = shortSpan(lastTurn.seconds, smallest: .second)
                turn =
                    files.isEmpty
                    ? String(localized: "Last turn changed no files · \(took)")
                    : files.count == 1
                        ? String(localized: "Last turn: 1 file +\(add) −\(del) · \(took)")
                        : String(localized: "Last turn: \(files.count) files +\(add) −\(del) · \(took)")
            }
            if let usage = await app.quiet(SessionContextWindow(id: agent.id)) ?? nil { context = usage }
        }
    }

    /// What filled the context reads all of the transcript: only once someone opens it.
    func loadParts() async {
        if parts == nil, let agent = agents.first { parts = await app.quiet(SessionContextParts(id: agent.id)) ?? nil }
    }

    func stop() {
        watches = []
        if folder != nil { app.extensions.all.ci?.carded(nil) }
    }

    /// Typed and sent, as a reply from the banner is; refused (a half-typed line in its prompt), a banner says why.
    func reply(_ text: String, to id: String) {
        let app = self.app
        Task { await app.call(SessionSend(id: id, text: text, enter: true)) }
    }

    /// Compact Now, once the ring turns orange, while the agent is at its prompt (a question's menu would take the text).
    var compact: (() -> Void)? {
        guard let usage = context, ContextMeter.level(usage) >= 2, let agent = agents.first,
            [.done, .idle, .error].contains(app.session(agent.id)?.status)
        else { return nil }
        let app = self.app
        return { Task { await app.call(SessionSend(id: agent.id, text: "/compact", enter: true)) } }
    }
}

extension CardModel {
    /// What the next message will pay for, while the agent rests: said from 15 minutes before the cache goes cold.
    var coldCache: String? {
        guard let usage = context, let until = usage.cacheUntil, let agent = agents.first,
            [.done, .idle, .error].contains(app.session(agent.id)?.status)
        else { return nil }
        return Self.coldCache(until: until, used: usage.used, now: Date())
    }

    static func coldCache(until: Date, used: Int, now: Date) -> String? {
        let left = until.timeIntervalSince(now), size = ContextParts.k(used)
        if left <= 0 { return String(localized: "Cache is cold: the next message writes \(size) again") }
        let minutes = Int((left / 60).rounded(.up))
        return minutes <= 15
            ? String(localized: "Cache goes cold in \(minutes) min: then the next message writes \(size) again") : nil
    }
}

struct CardView: View {
    let model: CardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.ui(13, weight: .semibold)).lineLimit(2)
                if !model.subtitle.isEmpty {
                    Text(model.subtitle).font(.ui(11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let host = model.server, let servers = model.app.extensions.all.servers {
                servers.section(host, model.closeCard)
            }
            if let repo = model.repo { WorktreeSizes(items: model.worktrees, root: repo.path) }
            if let folder = model.folder, let pr = model.app.extensions.all.ci?.card(folder) { pr }
            if let changes = model.changes, changes.totalAdded + changes.totalRemoved > 0 {
                (Text("Not committed  ")
                    + Text(changes.totalAdded > 0 ? "+\(changes.totalAdded)" : "").foregroundColor(.textGreen)
                    + Text(changes.totalAdded > 0 && changes.totalRemoved > 0 ? " " : "")
                    + Text(changes.totalRemoved > 0 ? "−\(changes.totalRemoved)" : "").foregroundColor(.textRed))
                    .font(.ui(11).monospacedDigit()).foregroundStyle(.secondary)
            }
            ForEach(model.agents) { agent in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        StatusIcon(status: agent.session.markStatus, waitsForCommand: agent.session.waitsForCommand)
                            .font(
                                .ui(11))
                        Text(model.agentOnly ? agent.session.statusWords : model.app.catalog.displayName(agent.session))
                            .font(
                                .ui(12)
                            ).lineLimit(1)
                        if !model.agentOnly {
                            Text(agent.session.statusWords).font(.ui(11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(shortAgo(agent.session.statusAt ?? agent.session.createdAt)).font(
                            .ui(11).monospacedDigit()
                        )
                        .foregroundStyle(.tertiary)
                    }
                    if !agent.session.summary.isEmpty {
                        Text(Self.linked(agent.session.summary)).font(.ui(11)).foregroundStyle(.secondary).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let goal = agent.session.goal {
                        Text("Goal: \(goal)").font(.ui(11)).foregroundStyle(.secondary).lineLimit(3)
                    }
                    if let quietSince = agent.session.quietSince, agent.session.status == .working {
                        Text("No news for \(shortSpan(Date().timeIntervalSince(quietSince)))").font(.ui(11))
                            .foregroundStyle(
                                .secondary)
                    }
                    if agent.session.guessed == true, [.working, .done].contains(agent.session.status) {
                        Text("Read off the screen: a guess, so Kelp won't call it done or notify").font(.ui(11))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let elsewhere = agent.session.workingElsewhere {
                        Text(elsewhere).font(.ui(11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    if model.agentOnly, let browser = agent.session.browser {
                        Text("Browser \(BrowserSkillWords.line(browser))").font(.ui(11)).foregroundStyle(.tertiary)
                            .lineLimit(
                                1)
                    }
                }
                AgentWork(model: model, id: agent.id)
                if QuickReply.fits(agent.session) {
                    HStack(spacing: 6) {
                        ForEach(QuickReply.all) { r in
                            Button(r.title) { model.reply(r.text, to: agent.id) }.controlSize(.small)
                        }
                    }
                }
            }
            if !model.pages.isEmpty, let runs = model.app.extensions.all.runs {
                HStack(spacing: 8) {
                    ForEach(model.pages, id: \.port) { page in
                        Button(page.address) { runs.open(page, model.workspaceId) }
                            .buttonStyle(PointerButtonStyle()).font(.ui(11).monospacedDigit()).foregroundStyle(
                                Color.accentColor)
                    }
                }
            }
            if let until = model.app.arrangement.mutedUntil(model.muteIds) {
                HStack(spacing: 8) {
                    Text(Mutes.line(until: until)).font(.ui(11)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Unmute") { model.app.arrangement.mute(model.muteIds, until: nil) }.controlSize(.small)
                }
            }
            if let turn = model.turn { Text(turn).font(.ui(11).monospacedDigit()).foregroundStyle(.secondary) }
            if let usage = model.context { ContextBlock(model: model, used: usage.used, window: usage.window) }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
    }

    /// An agent's summary often ends with a Markdown link ("Plan ready: [Plan](https://…)"): its words, clickable.
    static func linked(_ text: String) -> AttributedString {
        do {
            return try AttributedString(
                markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        } catch { return AttributedString(text) }   // not Markdown: as written
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
                ForEach(items.prefix(8), id: \.path) { worktree in
                    HStack(spacing: 6) {
                        Text(Self.name(worktree.path, root: root)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(Self.size(worktree.bytes)).monospacedDigit()
                    }.font(.ui(11)).foregroundStyle(.secondary)
                }
                if items.count > 8 { Text("\(items.count - 8) more").font(.ui(11)).foregroundStyle(.tertiary) }
            }
        } else {
            (items == nil ? Text("Measuring worktrees…") : Text("No other git worktrees")).font(.ui(11))
                .foregroundStyle(.secondary)
        }
    }
    static func name(_ path: String, root: String) -> String {
        path.hasPrefix(root + "/")
            ? String(path.dropFirst(root.count + 1)) : (path as NSString).abbreviatingWithTildeInPath
    }
    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// How full the agent's conversation is, and what filled it under a click, remembered: it's a long table, so it stays out
/// of the way until someone wants it, or until Compact Now, which stands in it, is an answer.
struct ContextBlock: View {
    let model: CardModel, used: Int, window: Int
    @AppStorage("sidebar.card.contextOpen") private var opened = false

    var body: some View {
        let open = opened || model.compact != nil
        VStack(alignment: .leading, spacing: 6) {
            Button {
                opened.toggle()
            } label: {
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
                Circle().trim(from: 0, to: share).stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }.frame(width: 11, height: 11)
            Text("Context \(Int(share * 100))% · \(used / 1000)k of \(window / 1000)k tokens").font(
                .ui(11).monospacedDigit()
            ).foregroundStyle(color)
        }
    }
}
