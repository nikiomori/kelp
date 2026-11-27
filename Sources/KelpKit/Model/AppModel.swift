import Agents
import AppKit
import Core
import DesignKit
import WorkbenchKit

/// The UI's mirror of the daemon's state. It is observable, so views follow what they read with `track` and redraw
/// only when that changes.
/// The app talks to the daemon only through JSON-RPC.
@MainActor
@Observable
package final class AppModel {
    /// The app's own state: what is on screen, settings.json and the extensions. The model is handed down
    /// (`app.workbench`…) to the window, to the built-ins' contributions and to their views. The built-in extensions
    /// come from the app's target, which lists them, so KelpKit names none of them.
    @ObservationIgnored let builtins: [Builtin]
    init(builtins: [Builtin] = []) {
        self.builtins = builtins
        activated = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lookForFolders() }   // queue: .main
        }
    }
    /// Observes Kelp coming to the front, which looks for the projects' folders again. The observer is removed when
    /// the model ends, because a test makes many models.
    @ObservationIgnored private var activated: NSObjectProtocol?
    isolated deinit { activated.map(NotificationCenter.default.removeObserver) }

    private func reposChanged() {
        repoBy = nil
        // A record that changed (a revision, a name) keeps its folder: only folders new to the list are looked for,
        // and coming to the front looks at them all.
        let paths = Set(repos.map(\.path)), new = paths.subtracting(listedFolders)
        guard paths != listedFolders else { return }
        listedFolders = paths
        lookForFolders(new)
    }
    @ObservationIgnored private var listedFolders: Set<String> = []

    /// Looks for `paths` (all the projects' folders by default) off the main thread, keeping what's known of the rest.
    private func lookForFolders(_ paths: Set<String>? = nil) {
        let paths = paths ?? Set(repos.map(\.path))
        Task {
            let gone = await Task.detached(priority: .utility) {
                Set(paths.filter { !FileManager.default.fileExists(atPath: $0) })
            }.value
            let missing = missingFolders.subtracting(paths).union(gone).intersection(repos.map(\.path))
            if missing != missingFolders { missingFolders = missing }
        }
    }

    /// Handles each new pushed reading as it arrives, besides showing it. A CI run can bring a parked agent back (only
    /// a new failed run in the agent's own workspace, not every stored run), and the built-ins hear every reading too.
    func landed(_ pushed: any Pushed) {
        if let ci = pushed as? CIEvent { arrangement.followParked(ci) }
        for hear in extensions.all.pushed { hear(pushed) }
    }

    @ObservationIgnored private(set) package lazy var workbench = Workbench(app: self)
    @ObservationIgnored private(set) package lazy var settings = SettingsStore(app: self)
    @ObservationIgnored private(set) package lazy var extensions = ExtensionRegistry(app: self)
    @ObservationIgnored private(set) lazy var gitState = GitFolders(app: self)
    @ObservationIgnored private(set) package lazy var uiState = UIState(app: self)
    /// The rest of what the app is made of, each made when first used.
    @ObservationIgnored private(set) package lazy var themes = ThemeManager(app: self)
    @ObservationIgnored private(set) package lazy var availability = AgentAvailability(app: self)
    @ObservationIgnored private(set) lazy var agentIcons = AgentIcons()
    /// The agents the app offers (see `AgentCatalog`) and the file icons in the chosen icon theme. Both are views
    /// over the parts above.
    package var catalog: AgentCatalog { AgentCatalog(app: self) }
    package var fileIcons: FileIcon { FileIcon(app: self) }
    @ObservationIgnored private(set) lazy var quickOpen = QuickOpen(app: self)
    @ObservationIgnored private(set) lazy var noProject = NoProject(app: self)
    @ObservationIgnored private(set) lazy var switcher = WorkspaceSwitcher(app: self)
    /// The objects a built-in keeps once per app, such as its windows or what it asked about. Each is made when first
    /// asked for, and the app holds them by type without naming them (see `part`).
    @ObservationIgnored private var parts: [ObjectIdentifier: AnyObject] = [:]
    /// Shows banners and the dock badge. The app delegate sets it in the running app; tests have none.
    @ObservationIgnored var notifier: Notifier?
    @ObservationIgnored let updates = Updates()
    /// Returns the app's one `T`, made by `make` the first time it is asked for.
    package func part<T: AnyObject>(_ make: () -> T) -> T {
        if let existing = parts[ObjectIdentifier(T.self)] as? T { return existing }
        let made = make()
        parts[ObjectIdentifier(T.self)] = made
        return made
    }

    /// The connection to kelpd. `DaemonLink` opens it, watches it and restarts it.
    @ObservationIgnored private(set) lazy var daemon = DaemonLink(app: self)
    /// The connection that calls go through (from `daemon`), or nil while there is none.
    var client: RPCClient? { daemon.client }
    /// Whether there's a connection to the daemon now (calls fail at once without one).
    var hasDaemon: Bool { client != nil }
    package var connected = false
    /// True while a new connection's state and settings are read (`opened`). The extensions they change load once, at
    /// the end.
    @ObservationIgnored private(set) var opening = false
    /// The number of connections made so far. Each new one may be to a new daemon, whose streams (`kelp attach`)
    /// start over.
    private(set) package var connections = 0
    package var repos: [Repo] = [] { didSet { reposChanged() } }
    /// The paths of project folders that are missing (moved, deleted, or on an unplugged disk). They are looked for off
    /// the main thread when the projects change and when Kelp comes to the front, not by each row on each update.
    private(set) var missingFolders: Set<String> = []
    package var worktrees: [Worktree] = [] { didSet { worktreeBy = nil } }
    package var sessions: [Session] = [] {
        didSet {
            sessionAt = nil
            sessionsIn = nil
            startedBy = nil
            commandsOf = nil
            untitled = nil
        }
    }
    /// The index of each session in `sessions`, built on the first lookup after a change. `session(_:)` is called for
    /// every row and tab on every session event, and a scan per lookup (copying each 45-field record) took half the
    /// main thread.
    @ObservationIgnored private var sessionAt: [String: Int]?
    /// The sessions in each workspace, built the same way, because every workspace row asks on every update.
    @ObservationIgnored private var sessionsIn: [String: [Session]]?
    /// The unfinished agents that each agent started, built the same way, because every agent's row asks for them.
    @ObservationIgnored private var startedBy: [String: [Session]]?
    /// The sessions each agent started from its command line (`Session.startedBy`), built the same way, because each
    /// agent's bar asks for them.
    @ObservationIgnored private var commandsOf: [String: [Session]]?
    /// The number of each untitled chat among the untitled chats of the same agent in a workspace
    /// (`AgentCatalog.displayName`).
    @ObservationIgnored private var untitled: [String: Int]?
    /// Projects and workspaces by id, built the same way, because loops over every session and workspace ask for them.
    @ObservationIgnored private var repoBy: [String: Repo]?
    @ObservationIgnored private var worktreeBy: [String: Worktree]?
    /// The watches the current connection has been told about (`tell`). A connection hears each watch only once,
    /// because the daemon reads a topic again when one connection starts it twice, and for CI that often takes 45 s.
    @ObservationIgnored weak var toldTo: RPCClient?
    @ObservationIgnored var told: Set<WatchStart> = []
    /// How many of the app's views watch each topic and key. The daemon is told when the first view starts watching
    /// and after the last one stops.
    @ObservationIgnored var watching: [WatchStart: Int] = [:]
    /// Closures that drop a topic's latest values once nothing watches a key (`latest`, `Pushed.forgottenWith`).
    @ObservationIgnored var forgetters: [WatchTopic: [(String) -> Void]] = [:]
    /// Counts, per id, the `event.repo` / `event.worktree` / `event.removed` events handled since the last refresh,
    /// because a list asked for before such an event may be older than it. Emptied as each refresh ends (nothing
    /// compares with them until the next one begins), or they would keep every record that ever existed.
    @ObservationIgnored var recordEvents: [String: Int] = [:]
    @ObservationIgnored package var agents: [AgentManifest] = AgentManifest.load(dir: Paths.agents)

    /// Counts the `event.session` events handled since the last refresh, per session, for the same reason.
    @ObservationIgnored private(set) var sessionEvents: [String: Int] = [:]
    /// Sessions that a restart is replacing. Their removal waits for the new session, which takes over their tab.
    @ObservationIgnored var restarting: Set<String> = []
    /// The refresh under way, and whether another was asked for meanwhile (a burst of `event.changed` asks for one
    /// more).
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshAgain = false

    /// Returns a project's workspaces in the order they were opened (Workspace 1, 2, 3…, including older ones on their
    /// own branch), unless the user dragged them into another order in the sidebar.
    func workspaces(of repo: Repo) -> [Worktree] {
        ordered(worktrees.filter { $0.repoId == repo.id && !$0.archived }.sorted { $0.createdAt < $1.createdAt })
    }

    /// The projects as the sidebar lists them: by name unless dragged into another order, with No Project last.
    var projects: [Repo] { ordered(repos.filter { !NoProject.holds($0) }) + repos.filter(NoProject.holds) }

    /// How the user arranged the sidebar. It is its own observed model (`Arrangement`), not part of the daemon's
    /// mirror.
    @ObservationIgnored private(set) lazy var arrangement = Arrangement(app: self)
    /// Returns sessions in about the order the sidebar lists them: by project and workspace, then as dragged among
    /// their siblings, then oldest first.
    package func inSidebarOrder(_ sessions: [Session]) -> [Session] {
        let place = Dictionary(
            projects.flatMap(workspaces(of:)).enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rank = arrangement.rank
        return sessions.sorted {
            (place[$0.worktreeId ?? ""] ?? .max, rank[$0.id] ?? .max, $0.createdAt)
                < (place[$1.worktreeId ?? ""] ?? .max, rank[$1.id] ?? .max, $1.createdAt)
        }
    }

    /// Puts the given sibling ids in the given order.
    func reorder(_ ids: [String]) { arrangement.order = ids + arrangement.order.filter { !ids.contains($0) } }
    private func ordered<T: Identifiable>(_ xs: [T]) -> [T] where T.ID == String {
        let rank = arrangement.rank
        return xs.enumerated().sorted { (rank[$0.1.id] ?? .max, $0.0) < (rank[$1.1.id] ?? .max, $1.0) }.map(\.1)
    }

    /// Stores a session from a reply or an event. A copy older than the one already here (a reply that an event
    /// overtook) is dropped.
    package func upsert(_ session: Session) {
        if let index = sessionIndex(session.id) {
            if !session.isOlder(than: sessions[index]) {
                let places = sessionAt
                sessions[index] = session
                sessionAt = places   // replaced in place, so every session's index still holds
            }
        } else {
            sessions.append(session)
        }
        availability.sessionChanged(session)
    }

    /// Tells the daemon what's on screen, so agents can ask (`kelp ui state`). Every tab and focus change calls it:
    /// a burst sends one notification, and only when the state differs from the last one sent.
    func publishUIState() {
        guard !publishQueued else { return }
        publishQueued = true
        DispatchQueue.main.async { [self] in
            publishQueued = false
            sendUIState()
        }
    }
    @ObservationIgnored private var publishQueued = false
    @ObservationIgnored private var published: ShownUI?

    private func sendUIState() {
        guard let connection = client else { return }
        let shown = worktree(workbench.workspaceId)
        let reg = extensions
        let state = ShownUI(
            workspace: shown.map {
                ShownUI.Workspace(id: $0.id, name: $0.displayName, path: $0.path, branch: $0.branch)
            },
            focusedSession: workbench.lastSession, focusedFile: workbench.focusedFile,
            editor: workbench.editor?.stateForAgents,
            extensions: reg.extensions.map {
                ShownUI.Extension(
                    id: $0.id, name: $0.name, enabled: $0.enabled, builtin: $0.builtin, path: $0.path?.path,
                    error: $0.error)
            },
            commands: reg.all.commands.map { ShownUI.Item(id: $0.id, title: $0.title) },
            panels: reg.all.panels.map { ShownUI.Item(id: $0.id, title: $0.title) }, away: away ? true : nil)
        guard state != published else { return }
        published = state
        // This is a call, not a notification, though it is still applied in order. A daemon that isn't this app's own
        // copy refuses it, and agents' `kelp open` would then say Kelp isn't running. That is said once per connection.
        Task {
            guard let error = await tryCall(UIPublish(state: state)).error, !publishRefused, client === connection
            else {
                return
            }
            publishRefused = true
            Banner.show(error, style: .error)
        }
    }
    @ObservationIgnored private var publishRefused = false

    /// Waits up to ~5 s for the first connection (and the lists it brings), for things asked for at launch.
    func waitForConnection() async {
        for _ in 0..<50 where !connected { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// Handles a new connection from `DaemonLink`, which may be to a new daemon. It reads the state, settings and lists
    /// anew, then tells the daemon what the views watch.
    func opened(_ connection: RPCClient) async {
        opening = true
        defer { opening = false }
        // Both are read at once, because neither depends on the other and launch waited for the sum.
        async let stateRead: Void = uiState.load()
        async let settingsRead: Void = settings.load()
        _ = await (stateRead, settingsRead)
        if uiState.strings(StateKeys.sidebarOrder) != arrangement.order {
            arrangement.order = uiState.strings(StateKeys.sidebarOrder)
        }
        if Mutes.read(uiState[StateKeys.muted]) != arrangement.mutes {
            arrangement.mutes = Mutes.read(uiState[StateKeys.muted])
        }
        if Mutes.read(uiState[Parking.key]) != arrangement.parked {
            arrangement.parked = Mutes.read(uiState[Parking.key])
        }
        let colors = ProjectColor.read(uiState[ProjectColor.key])
        if colors != arrangement.projectColors { arrangement.projectColors = colors }
        await refresh()
        connected = client === connection   // set after the lists, so whoever waits for it finds the projects loaded
        if connected {
            connections += 1
            // Reload the extensions, because the daemon's state was read anew. An extension changed meanwhile must
            // wait to be allowed (`ExtensionTrust`), and one that waited for the state (after a failed first
            // connection) no longer has to. This runs once for that and for any extensions settings.json switched on
            // or off (`ExtensionRegistry.follow` waits for this).
            let switched = extensions.disabled != extensions.disabledLoaded
            if connections > 1 || extensions.loadedWithoutState || switched { extensions.reload() }
        }
        published = nil
        publishRefused = false   // a new daemon hasn't refused anything yet
        publishUIState()
        tellWatches(connection)   // tells what the views watch that this connection hasn't heard (all of it, if new)
    }

    /// Reads the lists again, one refresh at a time, because two lists asked for together could come back with the
    /// older one last. A caller always gets lists read after it asked.
    func refresh() async {
        if let running = refreshTask {
            refreshAgain = true
            await running.value
            return
        }
        let task = Task { @MainActor in
            repeat {
                refreshAgain = false
                await refreshOnce()
            } while refreshAgain
            refreshTask = nil   // no await since the last check, so a later caller starts a new refresh
        }
        refreshTask = task
        await task.value
    }

    private func refreshOnce() async {
        // Assign only what changed, because every assignment re-renders the views that read it. The reads are quiet,
        // so a failed read keeps the lists on screen, and a dropped connection reports itself (and refreshes again
        // once it's back). The four lists are asked for at once, because one after another made launch wait for the
        // sum. They are applied in the same order.
        let records = recordEvents, before = sessionEvents
        func newer() -> Set<String> { Set(recordEvents.keys.filter { recordEvents[$0] != records[$0] }) }
        async let repoList = quiet(RepoList()), worktreeList = quiet(WorktreeList())
        async let sessionList = quiet(SessionList()), routineList = quiet(RoutineList())
        if let listed = await repoList {
            let merged = Self.merge(list: listed, local: repos, newer: newer())
            if merged != repos { repos = merged }
        }
        if let listed = await worktreeList {
            let merged = Self.merge(list: listed, local: worktrees, newer: newer())
            if merged != worktrees { worktrees = merged }
        }
        if let listed = await sessionList {
            let merged = Self.merge(
                list: listed, local: sessions, newer: Set(sessionEvents.keys.filter { sessionEvents[$0] != before[$0] })
            )
            let missed = Self.caughtUp(merged, local: sessions)
            if merged != sessions { sessions = merged }
            for (now, was) in missed { notifier?.statusChanged(now, was) }
        }
        if let routines = await routineList { land(routines) }
        recordEvents = [:]
        sessionEvents = [:]
    }

    /// Returns the daemon's list, except for records in `newer`. An event about those came while the list was on its
    /// way (on the same connection, so after the list was read, or while it was), and the event's version stays. A
    /// record removed meanwhile stays out. When a record is in both, the newer revision wins.
    static func merge<T: Revised & Equatable>(list: [T], local: [T], newer: Set<T.ID>) -> [T] {
        let here = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let kept = here.filter { newer.contains($0.key) }
        let listed = Set(list.map(\.id))
        return list.compactMap { x in newer.contains(x.id) ? kept[x.id] : x.isOlder(than: here[x.id]) ? here[x.id] : x }
            + local.filter { kept[$0.id] != nil && !listed.contains($0.id) }
    }

    /// Returns the sessions whose status changed in the list without an event saying so. That happens while the
    /// connection was down (during an update, say), and a turn that finished then must still be announced. A session
    /// this window has never shown isn't news.
    static func caughtUp(_ merged: [Session], local: [Session]) -> [(now: Session, was: Session)] {
        let here = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return merged.compactMap { s in here[s.id].flatMap { $0.status != s.status ? (s, $0) : nil } }
    }

    /// Listens to the daemon's events, decoded as their types on the client's reader thread and handled on the main
    /// actor. With one stream and one reader, events are handled in the order the daemon sent them by construction
    /// (a task per event would rely on the main queue running tasks in the order they were made).
    /// Returns a closure that ends the reader once the connection is gone.
    @discardableResult
    func listen(_ client: RPCClient) -> @Sendable () -> Void {
        let (events, feed) = AsyncStream<any RPCEvent>.makeStream()
        client.onEvent = { feed.yield($0) }
        Task { @MainActor [weak self] in for await e in events { self?.arrived(e) } }
        let stop: @Sendable () -> Void = { feed.finish() }
        stopListening = stop
        return stop
    }

    /// Takes one daemon event. An agent's session changes a few times a second while it works (each command, each
    /// subagent), and every view that reads `sessions` looks again after each change. So session events that come
    /// within 50 ms are applied in one turn, and the views look once. Any other event applies the held sessions first,
    /// so everything still lands in the order it was sent.
    func arrived(_ rpcEvent: any RPCEvent) {
        guard let session = rpcEvent as? Session else {
            applyHeld()
            return handle(rpcEvent)
        }
        held.append(session)
        guard held.count == 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.gathers) { [weak self] in self?.applyHeld() }
    }
    func applyHeld() {
        let sessions = held
        held = []
        sessions.forEach(handle)
    }
    @ObservationIgnored private(set) var held: [Session] = []
    /// True while Kelp's window can't be seen (`setAway`).
    @ObservationIgnored var away = false
    /// How long session events are gathered before they apply: enough for a burst, and well under the time it takes to
    /// see a row change.
    static let gathers: TimeInterval = 0.05

    /// Ends the reader of the connection last listened to (`listen`).
    @ObservationIgnored private var stopListening: (@Sendable () -> Void)?

    /// Stops hearing a connection, before a restart that reconnects by itself (a second client would hear every event
    /// twice). Closing the connection then does nothing more, and its event reader ends.
    func stopHearing(_ client: RPCClient?) {
        client?.onClose = nil
        stopListening?()
        stopListening = nil
    }

    func handle(_ event: any RPCEvent) {
        switch event {
        case let session as Session:
            sessionEvents[session.id, default: 0] += 1
            let old = self.session(session.id)
            if session.isOlder(than: old) { return }
            if old != session { upsert(session) }   // the views follow `sessions`
            notifier?.statusChanged(session, old)
            workbench.noteTurn(session, was: old)
            if old?.status != session.status { arrangement.followParked(session) }
        case let repo as Repo: record(repo, in: \.repos)
        case let worktree as Worktree: record(worktree, in: \.worktrees)
        case let removal as RemovedEvent: removed(removal)
        // The banner says where the row was, because the row went away without the user asking.
        case let landed as LandedEvent:
            Banner.show(
                landed.archived
                    ? String(
                        localized:
                            "“\(landed.name)” is in \(landed.base) now: put away with its chats. Window › Archived Groups brings it back."
                    )
                    : String(
                        localized: "“\(landed.name)” is in \(landed.base) now: its folder and branch were removed."))
        case let clone as CloneEvent: CloneSheet.cloneProgress(id: clone.id, line: clone.line)
        case let change as SettingsEvent: settings.received(change.settings)
        case let request as UIEvent: UIRequests(self).handle(request)
        default:
            if extensions.all.events.contains(where: { $0(event) }) { return }
            if let request = event as? UIBrowserEvent {   // the Browser built-in is off, so tell the agent now
                let off = "Kelp's Browser is turned off: the user turns it on in Settings › Extensions."
                Task { _ = await quiet(UIBrowserReply(request: request.request, error: off)) }
            }
            watched(event)   // event.changed is ignored: event.repo / .worktree / .removed bring the records
        }
    }

    /// Removes a session that is gone for good (deleted, pruned, or its workspace removed), with its tab and row. A
    /// session being restarted stays, and `AgentActions(app).restart` replaces it in its tab when the new one comes
    /// back.
    func removed(session id: String) {
        sessionEvents[id, default: 0] += 1
        guard !restarting.contains(id), let index = sessionIndex(id) else { return }
        sessions.remove(at: index)
    }

    // MARK: calls

    /// Calls a daemon method and shows an error as a banner, never a blocking alert. It takes only typed methods, so a
    /// renamed field fails to compile.
    @discardableResult
    package func call<M: RPCMethod>(_ method: M) async -> M.Result? { Self.banner(await tryCall(method)) }
    private static func banner<T>(_ result: (value: T?, error: String?)) -> T? {
        if let error = result.error { Banner.show(error, style: .error) }
        return result.value
    }

    /// Like `call`, but a failure comes back as its message instead of a banner, for actions that offer a way out. A
    /// cancelled caller isn't waiting for an answer, so it gets nil and no message.
    package func tryCall<M: RPCMethod>(_ method: M) async -> (value: M.Result?, error: String?) {
        do { return (try await get(method), nil) } catch is CancellationError { return (nil, nil) } catch {
            return (nil, Self.message(error))
        }
    }
    /// A throwing `tryCall`, for a chain of calls that one `catch` turns into the panel's error state.
    package func get<M: RPCMethod>(_ method: M) async throws -> M.Result {
        guard let client else { throw RPCError.internalError(DaemonLink.noService) }
        return try await client.call(method)
    }
    package static func message(_ error: Error) -> String {
        (error as? RPCError)?.message ?? error.localizedDescription
    }

    /// Calls a method for something that decorates rather than answers the user: a badge, the extras on a hover card,
    /// a notification's summary, or a poll that asks again in a few seconds. A failure returns nil and says nothing,
    /// because an error there would be noise about something nobody asked for, and the next read tries again. With
    /// `timeout`, a reply that never comes ends this read, not the loop that makes it.
    @discardableResult
    package func quiet<M: RPCMethod>(_ method: M, timeout: TimeInterval = 30) async -> M.Result? {
        try? await client?.call(method, timeout: timeout)
    }

    /// Sends a fire-and-forget message, for things that stream (an editor's text, a state write). Nothing comes back,
    /// so there is nothing to report. Without a daemon the message is made and dropped, and the next connection reads
    /// the state again. With `queue`, the message is made and written from that queue in the order sent, for messages
    /// too big to encode on the main thread. A nil `message` sends nothing.
    package func notify<M: RPCMethod>(on queue: DispatchQueue? = nil, _ message: @escaping @Sendable () -> M?) {
        let client = client
        guard let queue else {
            if let made = message() { client?.notify(made) }
            return
        }
        queue.async { if let made = message() { client?.notify(made) } }
    }

    /// Sends what `notify` queued right now, so the last layout or state write goes out before the process ends.
    func flush() { client?.flush() }

    package func worktree(_ id: String?) -> Worktree? {
        let all = worktrees   // read through the observed property, as `session(_:)` does
        if worktreeBy == nil { worktreeBy = Dictionary(all.map { ($0.id, $0) }) { first, _ in first } }
        return id.flatMap { worktreeBy?[$0] }
    }
    /// A folder the git marks name by id: a workspace, or a chat's own branch folder (`Session.branchKey`), made up
    /// here as the daemon makes it up for its reads (`Store.gitPlace`). Only marks and their reads take it: no group.
    func gitPlace(_ id: String?) -> Worktree? {
        guard let id, id.hasPrefix(Session.branchKeyPrefix) else { return worktree(id) }
        guard let chat = session(String(id.dropFirst(Session.branchKeyPrefix.count))), let folder = chat.branchFolder,
            let home = worktree(chat.worktreeId)
        else { return nil }
        let branch = gitState.branch(id) ?? (folder as NSString).lastPathComponent
        return Worktree(id: id, repoId: home.repoId, branch: branch, path: folder)
    }
    /// Returns the workspace whose folder holds `path`. It picks the innermost one, because a branch's folder can sit
    /// inside its project's folder.
    package func worktree(holding path: String) -> Worktree? {
        worktrees.filter { Paths.inside(path, $0.path) }.max { $0.path.count < $1.path.count }
    }
    package func repo(_ id: String?) -> Repo? {
        let all = repos   // read through the observed property, as `session(_:)` does
        if repoBy == nil { repoBy = Dictionary(all.map { ($0.id, $0) }) { first, _ in first } }
        return id.flatMap { repoBy?[$0] }
    }
    package func session(_ id: String) -> Session? { sessionIndex(id).map { sessions[$0] } }
    private func sessionIndex(_ id: String) -> Int? {
        let all = sessions   // read through the observed property, so a `track` that asks follows `sessions`
        if sessionAt == nil { sessionAt = Dictionary(all.indices.map { (all[$0].id, $0) }) { first, _ in first } }
        return sessionAt?[id]
    }

    /// The chats running in a workspace (not exited), in `sessions`' order.
    func liveChats(in worktreeId: String) -> [Session] {
        let all = sessions   // read through the observed property, as `session(_:)` does
        if sessionsIn == nil { sessionsIn = Dictionary(grouping: all) { $0.worktreeId ?? "" } }
        return (sessionsIn?[worktreeId] ?? []).filter { $0.status != .exited && $0.isChat }
    }

    /// Returns the agent that stands for a workspace in its sidebar row and its ⌃Tab row. Among the workspace's live
    /// chats with the most urgent state (asking, then working, then done), it is the one that changed last.
    func lead(in worktreeId: String) -> Session? {
        let agents = liveChats(in: worktreeId)
        let top = AgentStatus.mostUrgent(agents.map(\.shownStatus))
        return agents.filter { $0.shownStatus == top }.max {
            ($0.statusAt ?? $0.createdAt) < ($1.statusAt ?? $1.createdAt)
        }
    }

    /// Returns a group's name, or nil for a project's own screen, which goes by the project's name.
    package func groupName(_ worktree: Worktree?) -> String? {
        guard let worktree else { return nil }
        return repo(worktree.repoId).flatMap { mainWorkspace(of: $0, among: worktrees) }?.id == worktree.id
            ? nil : worktree.displayName
    }

    /// Returns the project's name, wherever it is shown. While another project has the same name, a remote project
    /// gets its machine after its name ("infra · beet"), so the two can be told apart. A project on this Mac and every
    /// unique name stay as they are.
    package func projectName(_ id: String?) -> String? {
        guard let project = repo(id) else { return nil }
        // The No Project row holds the chats that are outside any project.
        if NoProject.holds(project) { return String(localized: "Chats") }
        guard repos.contains(where: { $0.id != project.id && $0.name == project.name }),
            let host = RemoteHost.of(project.path)?.host
        else { return project.name }
        return "\(project.name) · \(host)"
    }
    /// Returns where the project is: "host:path" for a remote one (not the local folder that stands for it), else its
    /// path.
    func projectPlace(_ repo: Repo) -> String {
        RemoteHost.of(repo.path).map { "\($0.host):\($0.path)" } ?? (repo.path as NSString).abbreviatingWithTildeInPath
    }
}

extension AppModel {
    /// Returns the agent whose command line shows the command session `s`. It is nil for any other session, and once
    /// that agent has ended or gone away.
    func owner(of chat: Session) -> Session? {
        guard let id = chat.startedBy, let agent = session(id), agent.status != .exited,
            agent.worktreeId == chat.worktreeId
        else { return nil }
        return agent
    }

    /// Returns the sessions that agent `id` started from its command line, ended or not, in the order of `sessions`.
    func started(by id: String) -> [Session] {
        let all = sessions   // read through the observed property, as `session(_:)` does
        if commandsOf == nil {
            commandsOf = Dictionary(grouping: all.filter { $0.startedBy != nil }) { $0.startedBy ?? "" }
        }
        return commandsOf?[id] ?? []
    }

    /// Returns the number of a live untitled chat among the same agent's chats in its workspace, counting the oldest
    /// first. It is nil for the first or only one.
    func untitledNumber(_ id: String) -> Int? {
        let all = sessions   // read through the observed property, as `session(_:)` does
        if untitled == nil {
            var numbers: [String: Int] = [:]
            let live = all.filter { $0.status != .exited && $0.title.isEmpty }
            for same in Dictionary(grouping: live, by: { [$0.worktreeId, $0.agent] }).values where same.count > 1 {
                for (index, chat) in same.sorted(by: { $0.createdAt < $1.createdAt }).enumerated() where index > 0 {
                    numbers[chat.id] = index + 1
                }
            }
            untitled = numbers
        }
        return untitled?[id]
    }

    /// Returns the unfinished agents that `id` started, and the ones they started in turn (`[Session].children(of:)`,
    /// read from an index).
    func children(of id: String) -> [Session] {
        let all = sessions   // read through the observed property, as `session(_:)` does
        if startedBy == nil {
            startedBy = Dictionary(grouping: all.filter { $0.parent != nil && $0.status != .exited }) {
                $0.parent ?? ""
            }
        }
        func under(_ id: String) -> [Session] { (startedBy?[id] ?? []).flatMap { [$0] + under($0.id) } }
        return under(id)
    }
}
