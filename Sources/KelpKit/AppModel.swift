import Agents
import AppKit
import Core
import DesignKit
import WorkbenchKit

/// UI-side mirror of daemon state (observable: views follow what they read with `track`, and redraw only on its change).
/// The app talks to the daemon only through JSON-RPC.
@MainActor
@Observable
package final class AppModel {
    /// What's on screen, settings.json and the extensions: this app's, handed down with it (`app.workbench`…) to the
    /// window, the built-ins' contributions and their views.
    /// The built-in extensions the app was made with (the app's target lists them: KelpKit names none).
    @ObservationIgnored let builtins: [Builtin]
    init(builtins: [Builtin] = []) {
        self.builtins = builtins
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lookForFolders() }   // queue: .main
        }
    }

    private func reposChanged() {
        repoBy = nil
        lookForFolders()
    }

    private func lookForFolders() {
        let paths = repos.map(\.path)
        Task {
            let missing = await Task.detached(priority: .utility) {
                Set(paths.filter { !FileManager.default.fileExists(atPath: $0) })
            }.value
            if missing != missingFolders { missingFolders = missing }
        }
    }

    /// What the shell does with each new reading it lands, beside showing it: that one reading, as it arrives (a parked
    /// agent comes back on its own workspace's failed run, not on every run stored), and the built-ins hear it too.
    func landed(_ e: any Pushed) {
        if let ci = e as? CIEvent { arrangement.followParked(ci) }
        for hear in extensions.all.pushed { hear(e) }
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
    /// The agents it offers (see `AgentCatalog`), and file icons in the theme it's set to: views over the parts above.
    package var catalog: AgentCatalog { AgentCatalog(app: self) }
    package var fileIcons: FileIcon { FileIcon(app: self) }
    @ObservationIgnored private(set) lazy var quickOpen = QuickOpen(app: self)
    @ObservationIgnored private(set) lazy var noProject = NoProject(app: self)
    @ObservationIgnored private(set) lazy var switcher = WorkspaceSwitcher(app: self)
    /// What a built-in keeps once per app (its windows, what it asked about), made when first asked for: the app holds
    /// them by type without naming them (see `part`).
    @ObservationIgnored private var parts: [ObjectIdentifier: AnyObject] = [:]
    /// Banners and the dock badge: the running app's (its delegate sets it), none in tests.
    @ObservationIgnored var notifier: Notifier?
    @ObservationIgnored let updates = Updates()
    /// The app's one `T`, made by `make` the first time.
    package func part<T: AnyObject>(_ make: () -> T) -> T {
        if let existing = parts[ObjectIdentifier(T.self)] as? T { return existing }
        let made = make()
        parts[ObjectIdentifier(T.self)] = made
        return made
    }

    /// The connection to kelpd: opened, watched and restarted there.
    @ObservationIgnored private(set) lazy var daemon = DaemonLink(app: self)
    /// The connection calls go through (`daemon`'s); nil while there's none.
    var client: RPCClient? { daemon.client }
    /// Whether there's a connection to the daemon now (calls fail at once without one).
    var hasDaemon: Bool { client != nil }
    package var connected = false
    /// Connections made so far: each new one may be a new daemon, whose streams (`kelp attach`) start over.
    private(set) package var connections = 0
    package var repos: [Repo] = [] { didSet { reposChanged() } }
    /// The projects' folders that aren't there (moved, deleted, a disk unplugged), by path: looked for off the main thread
    /// when the projects change and when Kelp comes to the front, not by each row on each update.
    private(set) var missingFolders: Set<String> = []
    package var worktrees: [Worktree] = [] { didSet { worktreeBy = nil } }
    package var sessions: [Session] = [] {
        didSet {
            sessionAt = nil
            sessionsIn = nil
            startedBy = nil
        }
    }
    /// Where each session is in `sessions`, made on the first lookup after a change: `session(_:)` is asked for every row
    /// and tab on every session event, and a scan per lookup (copying each 45-field record) took half the main thread.
    @ObservationIgnored private var sessionAt: [String: Int]?
    /// Each workspace's sessions, made the same way: every workspace row asks on every update.
    @ObservationIgnored private var sessionsIn: [String: [Session]]?
    /// The agents each agent started that haven't ended, made the same way: every agent's row asks for its own.
    @ObservationIgnored private var startedBy: [String: [Session]]?
    /// Projects and workspaces by id, made the same way: asked for inside loops over every session and workspace.
    @ObservationIgnored private var repoBy: [String: Repo]?
    @ObservationIgnored private var worktreeBy: [String: Worktree]?
    /// What the connection in use has been told to watch (`tell`): the daemon reads a topic again, and CI often for 45 s,
    /// when one connection starts it twice, so a connection hears each once.
    @ObservationIgnored weak var toldTo: RPCClient?
    @ObservationIgnored var told: Set<WatchStart> = []
    /// How many of the app's views watch each topic and key: the daemon is told on the first and after the last.
    @ObservationIgnored var watching: [WatchStart: Int] = [:]
    /// What lets go of each topic's latest values once nothing watches a key (`latest`, `Pushed.forgottenWith`).
    @ObservationIgnored var forgetters: [WatchTopic: [(String) -> Void]] = [:]
    /// `event.repo` / `event.worktree` / `event.removed` handled since the last refresh, per id: a list asked for before
    /// one may be older. Emptied as each refresh ends (nothing compares with them until the next begins), or they'd keep
    /// every record that ever was.
    @ObservationIgnored var recordEvents: [String: Int] = [:]
    @ObservationIgnored package var agents: [AgentManifest] = AgentManifest.load(dir: Paths.agents)

    /// `event.session`s handled since the last refresh, per session, the same way.
    @ObservationIgnored private(set) var sessionEvents: [String: Int] = [:]
    /// Sessions a restart is replacing: their removal waits for the new one, which takes their tab.
    @ObservationIgnored var restarting: Set<String> = []
    /// The refresh under way, and whether another was asked for meanwhile (a burst of `event.changed` makes one more).
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshAgain = false

    /// Workspaces of a project in the order they were opened: Workspace 1, 2, 3… (older ones on their own branch
    /// included), unless dragged into another in the sidebar.
    func workspaces(of r: Repo) -> [Worktree] {
        ordered(worktrees.filter { $0.repoId == r.id && !$0.archived }.sorted { $0.createdAt < $1.createdAt })
    }

    /// Projects as the sidebar lists them: by name, unless dragged into another order, and No Project last.
    var projects: [Repo] { ordered(repos.filter { !NoProject.holds($0) }) + repos.filter(NoProject.holds) }

    /// How the user arranged the sidebar: its own observed model, not the daemon's mirror (`Arrangement`).
    @ObservationIgnored private(set) lazy var arrangement = Arrangement(app: self)
    /// Puts these (siblings) in this order.
    func reorder(_ ids: [String]) { arrangement.order = ids + arrangement.order.filter { !ids.contains($0) } }
    private func ordered<T: Identifiable>(_ xs: [T]) -> [T] where T.ID == String {
        let rank = arrangement.rank
        return xs.enumerated().sorted { (rank[$0.1.id] ?? .max, $0.0) < (rank[$1.1.id] ?? .max, $1.0) }.map(\.1)
    }

    /// A session as a reply or an event has it; an older copy than the one here (a reply that an event overtook) is dropped.
    package func upsert(_ s: Session) {
        if let index = sessionIndex(s.id) {
            if !s.isOlder(than: sessions[index]) {
                let places = sessionAt
                sessions[index] = s
                sessionAt = places   // replaced where it was: every session's place holds
            }
        } else {
            sessions.append(s)
        }
        availability.sessionChanged(s)
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
            focusedSession: workbench.focusedSession, focusedFile: workbench.focusedFile,
            editor: workbench.editor?.stateForAgents,
            extensions: reg.extensions.map {
                ShownUI.Extension(
                    id: $0.id, name: $0.name, enabled: $0.enabled, builtin: $0.builtin, path: $0.path?.path,
                    error: $0.error)
            },
            commands: reg.all.commands.map { ShownUI.Item(id: $0.id, title: $0.title) },
            panels: reg.all.panels.map { ShownUI.Item(id: $0.id, title: $0.title) })
        guard state != published else { return }
        published = state
        // A call (applied in order all the same): a daemon that isn't this app's own copy refuses it, and agents' `kelp open`
        // would then say Kelp isn't running. Said once per connection.
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

    /// Up to ~5 s for the first connection (and the lists it brings), for things asked for at launch.
    func waitForConnection() async {
        for _ in 0..<50 where !connected { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// A new connection (`DaemonLink`), maybe to a new daemon: its state, settings and lists read anew, then what the
    /// views watch told to it.
    func opened(_ connection: RPCClient) async {
        await uiState.load()
        if uiState.strings("sidebar.order") != arrangement.order {
            arrangement.order = uiState.strings("sidebar.order")
        }
        if Mutes.read(uiState[Mutes.key]) != arrangement.mutes { arrangement.mutes = Mutes.read(uiState[Mutes.key]) }
        if Mutes.read(uiState[Parking.key]) != arrangement.parked {
            arrangement.parked = Mutes.read(uiState[Parking.key])
        }
        let colors = ProjectColor.read(uiState[ProjectColor.key])
        if colors != arrangement.projectColors { arrangement.projectColors = colors }
        await settings.load()
        await refresh()
        connected = client === connection   // after the lists: what waits for the connection finds the projects in
        if connected {
            connections += 1
            // Again, as the daemon's state is read anew: an extension changed meanwhile waits to be allowed (`ExtensionTrust`),
            // and one that waited for the state to be known (a first connection that failed) doesn't any more.
            if connections > 1 || extensions.loadedWithoutState { extensions.reload() }
        }
        published = nil
        publishRefused = false   // a new daemon knows nothing yet
        publishUIState()
        tellWatches(connection)   // what the views watch and this connection hasn't heard yet (a new daemon: all of it)
    }

    /// One at a time: two lists asked for together could come back the older last. A caller gets a list read after it asked.
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
            refreshTask = nil   // with the last check: no await between, so a later caller starts a new one
        }
        refreshTask = task
        await task.value
    }

    private func refreshOnce() async {
        // Assign only what changed: every assignment re-renders the views that read it. Quiet: a failed read keeps the
        // lists on screen, and a dropped connection says so itself (and refreshes again once it's back).
        let records = recordEvents
        func newer() -> Set<String> { Set(recordEvents.keys.filter { recordEvents[$0] != records[$0] }) }
        if let listed = await quiet(RepoList()) {
            let merged = Self.merge(list: listed, local: repos, newer: newer())
            if merged != repos { repos = merged }
        }
        if let listed = await quiet(WorktreeList()) {
            let merged = Self.merge(list: listed, local: worktrees, newer: newer())
            if merged != worktrees { worktrees = merged }
        }
        let before = sessionEvents
        if let listed = await quiet(SessionList()) {
            let merged = Self.merge(
                list: listed, local: sessions, newer: Set(sessionEvents.keys.filter { sessionEvents[$0] != before[$0] })
            )
            let missed = Self.caughtUp(merged, local: sessions)
            if merged != sessions { sessions = merged }
            for (now, was) in missed { notifier?.statusChanged(now, was) }
        }
        if let routines = await quiet(RoutineList()) { land(routines) }
        syncContextWatches()
        recordEvents = [:]
        sessionEvents = [:]
    }

    /// The daemon's list, except records in `newer`: an event about them came while the list was on its way (on the
    /// same connection, so after the list was read, or as it was), and what it said stays; one removed meanwhile stays out.
    /// Of a record in both, the newer by revision.
    static func merge<T: Revised & Equatable>(list: [T], local: [T], newer: Set<T.ID>) -> [T] {
        let here = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let kept = here.filter { newer.contains($0.key) }
        let listed = Set(list.map(\.id))
        return list.compactMap { x in newer.contains(x.id) ? kept[x.id] : x.isOlder(than: here[x.id]) ? here[x.id] : x }
            + local.filter { kept[$0.id] != nil && !listed.contains($0.id) }
    }

    /// Sessions whose status the list knows and no event told: it changed while the connection was down, during an update
    /// say, and a turn that finished then must still be heard of. One this window has never shown isn't news.
    static func caughtUp(_ merged: [Session], local: [Session]) -> [(now: Session, was: Session)] {
        let here = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return merged.compactMap { s in here[s.id].flatMap { $0.status != s.status ? (s, $0) : nil } }
    }

    /// The daemon's events, decoded as their types on the client's reader thread, handled on the main actor.
    /// One stream and one reader: events are handled in the order the daemon sent them, by construction (a task each
    /// would rely on the main queue running tasks in the order they were made).
    /// Returns what ends the reader once the connection is gone.
    @discardableResult
    func listen(_ c: RPCClient) -> @Sendable () -> Void {
        let (events, feed) = AsyncStream<any RPCEvent>.makeStream()
        c.onEvent = { feed.yield($0) }
        Task { @MainActor [weak self] in for await e in events { self?.handle(e) } }
        let stop: @Sendable () -> Void = { feed.finish() }
        stopListening = stop
        return stop
    }

    /// Ends the reader of the connection last listened to (`listen`).
    @ObservationIgnored private var stopListening: (@Sendable () -> Void)?

    /// A connection this model stops hearing, before a restart that reconnects itself (a second client would hear every
    /// event twice): its close does nothing more, and its events' reader ends.
    func stopHearing(_ c: RPCClient?) {
        c?.onClose = nil
        stopListening?()
        stopListening = nil
    }

    func handle(_ event: any RPCEvent) {
        switch event {
        case let session as Session:
            sessionEvents[session.id, default: 0] += 1
            let old = self.session(session.id)
            if session.isOlder(than: old) { return }
            if old != session { upsert(session) }   // views follow `sessions`
            notifier?.statusChanged(session, old)
            if old?.status != session.status {
                syncContextWatches()
                arrangement.followParked(session)
            }
        case let devServer as DevServerEvent: extensions.all.runs?.served(devServer)
        case let busy as PortBusyEvent: extensions.all.runs?.portBusy(busy)
        case let repo as Repo: record(repo)
        case let worktree as Worktree: record(worktree)
        case let removal as RemovedEvent: removed(removal)
        case let clone as CloneEvent: CloneSheet.cloneProgress(id: clone.id, line: clone.line)
        case let change as SettingsEvent: settings.received(change.settings)
        case let request as UIEvent: UIRequests(self).handle(request)
        case let request as UIBrowserEvent: UIRequests(self).browse(request)
        default: watched(event)   // event.changed is left: the records themselves follow (event.repo / .worktree / .removed)
        }
    }

    /// A session gone for good (deleted, its workspace removed, pruned): its tab and row go with it. One being restarted
    /// is replaced in its tab by `AgentActions(app).restart` when the new one comes back.
    func removed(session id: String) {
        sessionEvents[id, default: 0] += 1
        guard !restarting.contains(id), let index = sessionIndex(id) else { return }
        sessions.remove(at: index)
        syncContextWatches()
    }

    // MARK: calls

    /// Errors show as a banner, never a blocking alert. Only typed methods: a renamed field must not compile.
    @discardableResult
    package func call<M: RPCMethod>(_ m: M) async -> M.Result? { Self.banner(await tryCall(m)) }
    private static func banner<T>(_ r: (value: T?, error: String?)) -> T? {
        if let error = r.error { Banner.show(error, style: .error) }
        return r.value
    }

    /// Like `call`, but a failure comes back as its message (for actions that offer a way out) instead of a banner. A
    /// cancelled caller isn't waiting for an answer: nil, and no message.
    package func tryCall<M: RPCMethod>(_ m: M) async -> (value: M.Result?, error: String?) {
        do { return (try await get(m), nil) } catch is CancellationError { return (nil, nil) } catch {
            return (nil, Self.message(error))
        }
    }
    /// `tryCall` for a chain of calls that one `catch` turns into the panel's error state.
    package func get<M: RPCMethod>(_ m: M) async throws -> M.Result {
        guard let client else { throw RPCError.internalError(DaemonLink.noService) }
        return try await client.call(m)
    }
    package static func message(_ e: Error) -> String { (e as? RPCError)?.message ?? e.localizedDescription }

    /// For what decorates rather than answers the user: a badge, a hover card's extras, a notification's summary, a poll
    /// that asks again in a few seconds. Its failure says nothing (nil), since an error there would be noise about
    /// something nobody asked for, and the next read tries again. `timeout`: a reply that never comes ends this read,
    /// not the loop that makes it.
    @discardableResult
    package func quiet<M: RPCMethod>(_ m: M, timeout: TimeInterval = 30) async -> M.Result? {
        try? await client?.call(m, timeout: timeout)
    }

    /// Fire-and-forget, for what streams (an editor's text, a state write): nothing comes back, so there's nothing to say.
    /// Without a daemon it's made and dropped; a new connection reads it again. `queue`: made and written from there, in
    /// the order sent, for what's too big to encode on the main thread; `message` nil sends nothing.
    package func notify<M: RPCMethod>(on queue: DispatchQueue? = nil, _ message: @escaping @Sendable () -> M?) {
        let client = client
        guard let queue else {
            if let made = message() { client?.notify(made) }
            return
        }
        queue.async { if let made = message() { client?.notify(made) } }
    }

    /// What `notify` queued goes out now: before the process ends, the last layout or state set written.
    func flush() { client?.flush() }

    package func worktree(_ id: String?) -> Worktree? {
        let all = worktrees   // read through the observed property, as `session(_:)` does
        if worktreeBy == nil { worktreeBy = Dictionary(all.map { ($0.id, $0) }) { first, _ in first } }
        return id.flatMap { worktreeBy?[$0] }
    }
    /// The workspace whose folder holds `path`: the innermost, for a branch's folder inside its project's.
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
        let all = sessions   // read through the observed property: a `track` that asks follows `sessions`
        if sessionAt == nil { sessionAt = Dictionary(all.indices.map { (all[$0].id, $0) }) { first, _ in first } }
        return sessionAt?[id]
    }

    /// The chats running in a workspace (not exited), in `sessions`' order.
    func liveChats(in worktreeId: String) -> [Session] {
        let all = sessions   // read through the observed property, as `session(_:)` does
        if sessionsIn == nil { sessionsIn = Dictionary(grouping: all) { $0.worktreeId ?? "" } }
        return (sessionsIn?[worktreeId] ?? []).filter { $0.status != .exited && $0.isChat }
    }

    /// The project's name wherever it's shown: a remote one has its machine after it while another project has the same
    /// name ("infra · beet"), so the two tell apart; the one on this Mac and every unique name stay as they are.
    /// A group's name; nil for a project's own screen, which goes by its project's.
    package func groupName(_ worktree: Worktree?) -> String? {
        guard let worktree else { return nil }
        return repo(worktree.repoId).flatMap { mainWorkspace(of: $0, among: worktrees) }?.id == worktree.id
            ? nil : worktree.displayName
    }

    package func projectName(_ id: String?) -> String? {
        guard let project = repo(id) else { return nil }
        // what the row holds: chats outside any project
        if NoProject.holds(project) { return String(localized: "Chats") }
        guard repos.contains(where: { $0.id != project.id && $0.name == project.name }),
            let host = RemoteHost.of(project.path)?.host
        else { return project.name }
        return "\(project.name) · \(host)"
    }
    /// Where the project is: "host:path" for a remote one (not the local folder that stands for it), else its path.
    func projectPlace(_ r: Repo) -> String {
        RemoteHost.of(r.path).map { "\($0.host):\($0.path)" } ?? (r.path as NSString).abbreviatingWithTildeInPath
    }
}

extension AppModel {
    /// The agents `id` started that haven't ended, and those they started (`[Session].children(of:)`, from an index).
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
