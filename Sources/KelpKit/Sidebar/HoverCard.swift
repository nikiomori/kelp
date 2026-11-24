import Agents
import AppKit
import Core
import DesignKit
import SwiftUI
import WorkbenchKit

/// A card that shows in full what a sidebar row or an agent's tab holds when the pointer rests on it, so the row
/// itself can stay one line. The card appears after half a second. While a card is open, moving to another row shows
/// that row's card at once. Typing, ⌘W included, puts it away.
@MainActor
final class HoverCard {
    private let app: AppModel
    /// True for a card under a tab. The card then hangs below the tab and leaves out the place, because the tab is in
    /// this workspace.
    private let underTabs: Bool
    private let card = HoverPopover()
    private(set) var shownKind: SidebarItem.Kind?
    private var shown: CardModel?
    private weak var anchor: NSWindow?

    init(app: AppModel, underTabs: Bool = false) {
        self.app = app
        self.underTabs = underTabs
        card.onClose = { [weak self] in
            self?.shown?.stop()
            self?.shownKind = nil
        }
        // The rows' pointer events stop when the window loses focus, so the event that would close the card may never
        // come. A card left open costs a tenth of a core for as long as it stays, because SwiftUI lays it out over and
        // over.
        resignWatch = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated { if window === self?.anchor { self?.card.closeUnlessInside() } }   // queue: .main
        }
    }
    /// Watches for the window losing focus, for as long as the card's owner (a sidebar, a tab strip) is there.
    private var resignWatch: NSObjectProtocol?
    isolated deinit { resignWatch.map(NotificationCenter.default.removeObserver) }

    /// Called when the pointer is over a row (a workspace's, an agent's…), or over nothing.
    func hover(_ kind: SidebarItem.Kind?, rect: NSRect, in view: NSView) {
        guard kind != shownKind || !card.isShown else { return }
        guard let kind else {
            card.closeSoon(unlessInside: true)
            return
        }
        card.open { [weak self, weak view] in
            if let view { self?.show(kind, rect: rect, in: view) }
        }
    }

    func close() { card.close() }

    /// Opens a row's card without the wait, because a click asked for it.
    func open(_ kind: SidebarItem.Kind, rect: NSRect, in view: NSView) {
        card.cancel()
        if kind != shownKind || !card.isShown { show(kind, rect: rect, in: view) }
    }

    private func show(_ kind: SidebarItem.Kind, rect: NSRect, in view: NSView) {
        // Events come only while the window is key.
        guard view.window != nil, let model = CardModel(kind, app: app, placed: !underTabs) else {
            close()
            return
        }
        shown?.stop()
        shown = model
        shownKind = kind
        anchor = view.window
        model.closeCard = { [weak self] in self?.close() }
        let host = NSHostingController(rootView: CardView(model: model))
        host.sizingOptions = .preferredContentSize   // else the popover is placed at a pre-layout size and grows down from its top, off the row
        card.show(host, relativeTo: rect, of: view, edge: underTabs ? .minY : .maxX)
        model.load()
    }
}

/// The card's contents: what the sidebar knows now, the folder's git status and PR as they are pushed, and then what
/// the agent's transcript adds.
@MainActor
@Observable
final class CardModel {
    let title: String, subtitle: String
    let agents: [Session]
    let workspaceId: String
    let agentOnly: Bool
    let app: AppModel
    /// On a project's card with several screens, each screen's name by its id: the chats are listed under them.
    var screenNames: [String: String] = [:]
    /// The screen's name to show above the chat at `index`, where the list moves on to another screen.
    func heading(at index: Int) -> String? {
        guard let id = agents[index].worktreeId, let name = screenNames[id] else { return nil }
        return index > 0 && agents[index - 1].worktreeId == id ? nil : name
    }
    /// On a chat's card, the branch of its own it works on (`SidebarItem.branch`).
    var branch: Worktree?
    /// On an empty group's card, when it closes by itself (`WorkspaceActions.closesAt`).
    var closes: Date?
    /// On a project's card, the project. `worktrees` holds the disk its other worktrees take (nil while `du` runs).
    let repo: Repo?
    /// The ids whose mute the card shows, which are the row's. A workspace alone in its project is also that
    /// project's row.
    let muteIds: [String]
    var worktrees: [RepoWorktreeSizes.Item]?
    /// On a workspace's card, the folder whose git and PR the card shows (`gitFolder`), read while the card is up.
    let folder: String?
    var changes: LineStats? { folder.flatMap { app.latest(GitEvent.self, $0)?.stats } }
    var turn: String?
    var context: SessionContextWindow.Usage?
    var parts: SessionContextParts.Parts?
    var pages: [ServedPage] = []
    /// On a remote project's card, the host whose state the card shows.
    let server: String?
    /// Puts the card away (a button in it opened something else).
    @ObservationIgnored var closeCard: () -> Void = {}
    /// Watches what the agent's subagents did last and the folder's git, while the card is up.
    private var watches: [Watched] = []

    /// With `placed`, the subtitle says where the agent is (group · project). A tab's card leaves it out.
    init?(_ kind: SidebarItem.Kind, app: AppModel, placed: Bool = true) {
        self.app = app
        switch kind {
        case .agent(let id):
            guard let session = app.session(id) else { return nil }
            title = app.catalog.displayName(session)
            let worktree = app.worktree(session.worktreeId)
            subtitle =
                placed
                ? [app.groupName(worktree), app.projectName(worktree?.repoId)].compactMap { $0 }.joined(
                    separator: " · ") : ""
            agents = [session]
            workspaceId = session.worktreeId ?? ""
            agentOnly = true
            repo = nil
            muteIds = [session.id]
            server = nil
            // A chat working on a branch of its own: its card shows that branch, its changes and its PR.
            // The same one the row marks: the first of the project's groups the chat made on a folder of its own,
            // with no chats in it (`SidebarTree.build`).
            let own = app.repo(worktree?.repoId ?? "").flatMap { project in
                app.workspaces(of: project).first {
                    SidebarTree.maker($0) == session.id && $0.path != project.path && app.liveChats(in: $0.id).isEmpty
                }
            }
            folder = own?.id
            branch = own
        case .project(let id):
            guard let project = app.repo(id) else { return nil }
            title = app.projectName(project.id) ?? project.name
            subtitle = app.projectPlace(project)
            // Every screen's chats, screen by screen, each screen's under its name.
            let screens = app.workspaces(of: project)
            agents = screens.flatMap { app.liveChats(in: $0.id) }
            if screens.count > 1 {
                screenNames = Dictionary(
                    screens.map { ($0.id, app.groupName($0) ?? app.gitState.branch($0.id) ?? $0.branch) }
                ) { first, _ in first }
            }
            workspaceId = ""
            agentOnly = false
            repo = project
            muteIds = [project.id]
            server = RemoteHost.of(project.path)?.host
            folder = nil
        case .workspace(let id):
            guard let worktree = app.worktree(id) else { return nil }
            let project = app.repo(worktree.repoId)
            // A project's own screen has no name of its own, because the row stands for the project.
            let group = app.groupName(worktree)
            title = group ?? app.projectName(project?.id) ?? worktree.displayName
            let branch = worktree.path == project?.path ? nil : String(localized: "branch \(worktree.branch)")
            subtitle = [group == nil ? nil : app.projectName(project?.id), branch].compactMap { $0 }.joined(
                separator: " · ")
            agents = app.liveChats(in: worktree.id)
            workspaceId = worktree.id
            agentOnly = false
            repo = nil
            let alone = app.worktrees.filter { $0.repoId == worktree.repoId && !$0.archived }.count == 1
            muteIds = [worktree.id] + (alone ? [worktree.repoId] : [])
            server = project.flatMap { RemoteHost.of($0.path)?.host }
            folder = app.gitFolder(of: worktree.id)?.id
            closes = WorkspaceActions(app).closesAt(worktree)
        case .host, .parked:
            return nil
        }
    }

    func load() {
        watches = agents.filter { app.catalog.manifest($0.agent)?.transcript == .claude }.map { agent in
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

    /// Loads what filled the context. That reads the whole transcript, so it runs only once someone opens it.
    func loadParts() async {
        if parts == nil, let agent = agents.first { parts = await app.quiet(SessionContextParts(id: agent.id)) ?? nil }
    }

    func stop() {
        watches = []
        if folder != nil { app.extensions.all.ci?.carded(nil) }
    }

    /// Types `text` into the agent and sends it, as a reply from the banner does. When the agent refuses it (a
    /// half-typed line in its prompt), a banner says why.
    func reply(_ text: String, to id: String) {
        let app = self.app
        Task { await app.call(SessionSend(id: id, text: text, enter: true)) }
    }

    /// The Compact Now action. It is offered once the ring turns orange, while the agent is at its prompt (a question's
    /// menu would take the text).
    var compact: (() -> Void)? {
        guard let usage = context, ContextMeter.level(usage) >= 2, let agent = agents.first,
            [.done, .idle, .error].contains(app.session(agent.id)?.status)
        else { return nil }
        let app = self.app
        return { Task { await app.call(SessionSend(id: agent.id, text: "/compact", enter: true)) } }
    }
}

extension CardModel {
    /// What the next message will pay for while the agent rests. It shows from 15 minutes before the cache goes cold.
    var coldCache: String? {
        guard let usage = context, let until = usage.cacheUntil, let agent = agents.first,
            [.done, .idle, .error].contains(app.session(agent.id)?.status)
        else { return nil }
        return Self.coldCache(until: until, used: usage.used, now: Date())
    }

    static func coldCache(until: Date, used: Int, now: Date) -> String? {
        let left = until.timeIntervalSince(now), size = shortTokens(used)
        if left <= 0 { return String(localized: "Cache is cold: the next message writes \(size) again") }
        let minutes = Int((left / 60).rounded(.up))
        return minutes <= 15
            ? String(localized: "Cache goes cold in \(minutes) min: then the next message writes \(size) again") : nil
    }
}
