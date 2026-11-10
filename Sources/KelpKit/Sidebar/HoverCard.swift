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
        resignWatch = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated { if window === self?.anchor { self?.closeUnlessInside() } }   // queue: .main
        }
    }
    /// The window losing focus, watched while the card's owner (a sidebar, a tab strip) is there.
    private var resignWatch: NSObjectProtocol?
    isolated deinit { resignWatch.map(NotificationCenter.default.removeObserver) }

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
            agents = app.liveChats(in: worktree.id).map {
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
