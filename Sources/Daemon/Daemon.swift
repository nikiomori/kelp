import AgentData
import Agents
import Core
import Foundation
import GitKit
import os

/// The long-running process: owns PTYs, state and the JSON-RPC socket.
/// Running sessions and who is connected each keep their own lock; the order they're taken in is in `Clients`.
public final class Daemon: Sendable {
    let store: Store
    var socketPath: String { root.appendingPathComponent("kelp.sock").path }
    let root: URL
    let clients = Clients()
    /// What start() opens and stop() closes: the socket, the flock on kelpd.lock (one daemon per KELP_HOME), the sources.
    private struct Running: @unchecked Sendable {   // the sources are only set up and cancelled, under `running`'s lock
        var listenFD: Int32 = -1, instanceLock: Int32 = -1
        var accept: DispatchSourceRead?, ticker: DispatchSourceTimer?, prune: DispatchSourceTimer?
        /// An update whose exec failed: the daemon in this process that took the sessions back (`upgrade`), stopped with it.
        var successor: Daemon?
    }
    private let running = OSAllocatedUnfairLock(initialState: Running())
    /// Accepting connections: started, and not stopped or handed over.
    var isServing: Bool { running.withLock { $0.accept != nil } }
    let settings: SettingsStore
    let agentUsage: AgentUsage   // what the agents left on disk: conversations, token usage, plan limits
    let offloads = Slots(Daemon.offloadLimit)   // what `offload` runs at once
    let forges: Forges   // pull requests by branch, running clones, the trackers' clients
    let lsp: LSPHost   // language servers: one per project and server command, shared by every client
    let watches: Watches   // what clients watch (watch.start), read while anyone does and pushed when it changed
    let sessions: Sessions   // which run, starting, waking, pausing and deleting them
    /// Who calls, by the program on each connection (CallerLookup.swift): what `allow` holds a call to.
    let callers: Callers
    let settingsEvents: SettingsEvents   // event.settings in order: the last one is the settings now
    let workspaces: Workspaces   // workspaces, the branches they follow, the .kelp.yaml files the user trusts
    var files: FileService { FileService(remotes: remotes) }   // files.*: read, written, moved here or on a remote project's host
    /// git.*, the files lists and review comments: the workspaces' checkouts, here or on a remote project's host.
    var sourceControl: SourceControl {
        SourceControl(root: root, store: store, remotes: remotes, sessions: sessions)
    }
    let remotes: Remotes   // which project folders stand for one on a host (only those in this home's remote/), and how to reach it
    /// The virtual machines agents run commands in (vm.*), each run by its own kelp-vm, the one beside kelpd.
    var vms: VMService {
        VMService(home: root, helper: VMService.helper(beside: Daemon.executable))
    }

    public convenience init(root: URL) throws { try self.init(root: root, store: nil) }

    /// `store`: one this process has open already (an update that took its sessions back).
    convenience init(root: URL, store: Store?) throws {
        try self.init(root: root, store: store, lspDelays: (retry: 30, idle: 60))
    }

    /// kelpd's own: a caller is the user's only when Kelp can tell (`Callers.session(running:)`); anything else, its own
    /// programs' leftovers included, is held to an agent's rules. Not in a test's daemon, whose process is the test's.
    public func strict() { callers.strict.withLock { $0 = true } }

    /// `lspDelays`: how soon a broken language server is started again, and how long one with no open file keeps running
    /// (tests shorten them).
    init(root: URL, store: Store?, lspDelays: (retry: TimeInterval, idle: TimeInterval)) throws {
        // a client that hangs up mid-write fails that write; it must not end the process (kelpd's, or a test's hosting one)
        signal(SIGPIPE, SIG_IGN)
        self.root = root
        try Paths.ensure(root)
        self.store = try store ?? Store(path: root.appendingPathComponent("kelp.sqlite").path)
        self.settings = SettingsStore(root: root)
        self.remotes = Remotes(home: root)
        self.agentUsage = AgentUsage(root: root, settings: settings, store: self.store, remotes: remotes)
        self.forges = Forges(offloads: offloads, store: self.store, clients: clients, remotes: remotes)
        self.lsp = LSPHost(
            store: self.store, remotes: remotes, offloads: offloads, retryDelay: lspDelays.retry,
            idleDelay: lspDelays.idle)
        self.watches = Watches(store: self.store, clients: clients, remotes: remotes)
        lsp.whenProblemsChange { [watches] path in
            watches.touched(.init(topic: .file, key: path), tag: UUID().uuidString)
        }
        self.sessions = Sessions(
            root: root, socketPath: root.appendingPathComponent("kelp.sock").path, store: self.store, remotes: remotes,
            settings: settings, agentUsage: agentUsage, clients: clients, watches: watches, offloads: offloads)
        self.callers = Callers(live: sessions.live, clients: clients, store: self.store)
        self.workspaces = Workspaces(
            root: root, store: self.store, remotes: remotes, sessions: sessions, clients: clients)
        self.settingsEvents = SettingsEvents(store: settings, clients: clients, sessions: sessions)
        SourceControl.sweepDiscards(root)   // what an earlier daemon kept for an Undo, past its minute
        // Remote projects' shared SSH connections; without it, they fail.
        do { try Paths.ensure(URL(fileURLWithPath: remotes.controlDir)) } catch {
            Log.start.error("no folder for ssh connections: \(error)")
        }
        watches.reading.withLock {
            $0.topic = { [weak self] k in self?.topic(k) ?? Watches.Topic { _ in (nil, nil) } }
        }
        self.store.changed.withLock {
            $0.tell = { [weak self] c in
                self?.recordChanged(c)   // records go to the clients as they change
                switch c {   // and a project added, moved or removed is followed (watchHeads) from then on
                case .repo, .repoRemoved: if let ws = self?.workspaces { ws.headQueue.async { ws.watchHeads() } }
                // The last agent of a branch an agent made is gone: nobody else is there to close it.
                case .sessionRemoved(_, let workspace?):
                    if let ws = self?.workspaces { ws.headQueue.async { ws.tidyAgentBranch(workspace) } }
                default: break
                }
            }
        }
    }

    /// kelpd couldn't start: the reason goes to the log and to `Paths.daemonError(in:)`, where the app reads it for its
    /// "background service isn't running" banner (the app starts kelpd with its output thrown away). The file goes once a
    /// daemon starts. Limit: a KELP_HOME that can't be written can't hold it either; then only the log and stderr have it.
    public static func startFailed(_ error: Error, root: URL) -> String {
        let why = error.rpcMessage
        Log.start.fault("kelpd didn't start: \(why, privacy: .public)")
        Log.start.attempt("saving why kelpd didn't start") {
            try Data((why + "\n").utf8).write(to: Paths.daemonError(in: root))
        }
        return why
    }

    /// The binary this process runs: the one an update replaces.
    static var executable: String { (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).path }

    /// When this binary was built; the app compares it with the kelpd it ships to spot a stale daemon after an update.
    static let binaryMTime = Upgrade.modified(executable)

    /// `handover`: what the kelpd this process ran before (an update, `daemon.upgrade`) left open for this one to take over.
    /// `takingBack`: this process's own sessions, after an update's exec failed (its makings of machines still run here).
    public func start(adopting handover: Handover? = nil, takingBack: Bool = false) throws {
        // One daemon per KELP_HOME: a second one (launchd's KeepAlive, a CLI that couldn't connect) would take the socket
        // over and mark the first one's running agents paused. A handover's lock is held already.
        let lockFD =
            handover?.lock ?? open(root.appendingPathComponent("kelpd.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard lockFD >= 0, handover != nil || flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { close(lockFD) }
            throw RPCError.internalError("another kelpd is already running for \(root.path)")
        }
        if handover != nil { _ = fcntl(lockFD, F_SETFD, FD_CLOEXEC) }   // as opened: a program started here must not keep the home locked
        running.withLock { $0.instanceLock = lockFD }
        // Sessions from a previous daemon run lost their PTYs, unless it handed them over; resumable ones come back as
        // paused, the rest as exited.
        let manifests = AgentManifest.load(dir: root.appendingPathComponent("agents"))
        let adopted = Set(handover?.sessions.map(\.id) ?? [])
        do {
            for var session in try store.sessions() where session.status != .exited && !adopted.contains(session.id) {
                session.status = Sessions.resumable(session, manifests) ? .paused : .exited
                session.progress = nil   // what ran there isn't getting any further
                try store.save(session)
            }
        } catch { Log.store.error("couldn't mark the last run's sessions paused or ended: \(error)") }
        handover?.sessions.forEach(sessions.adopt)   // before the first connection: it finds them running
        // Machines a kelpd before this one was making (it quit or was upgraded midway): only once this one holds the home,
        // a second kelpd (launchd's, a CLI's) going away right after must not touch them, and on a thread of its own.
        if !takingBack {
            let vms = self.vms
            Thread.detachNewThread { vms.resumeMaking() }
        }
        _ = Self.binaryMTime   // read now: after an update the file on disk is already the new one
        DispatchQueue.global().async { _ = LoginPath.value }   // warm up so the first agent doesn't wait for the shell
        // The usage index reads gigabytes the first time: do it in the background now, not when Usage is opened.
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 30) { [self] in
            let since =
                Calendar.current.date(byAdding: .day, value: -89, to: Calendar.current.startOfDay(for: Date()))
                ?? Date()
            _ = agentUsage.usageIndex.rows(
                roots: agentUsage.agentRoots().claude.filter { FileManager.default.fileExists(atPath: $0.path) },
                since: since)
        }
        let listenFD: Int32
        do { listenFD = try handover?.socket ?? Unix.listen(socketPath) } catch {
            running.withLock {
                if $0.instanceLock >= 0 {
                    close($0.instanceLock)
                    $0.instanceLock = -1
                }
            }   // not ours to keep
            throw error
        }
        // Accept and the ticker have queues of their own (serial queues get a thread even when every pooled one is held
        // by a slow git or ssh in `offload`), so new connections and status keep going whatever is stuck.
        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: DispatchQueue(label: "kelp.accept"))
        src.setCancelHandler { close(listenFD) }   // after any accept still running, not under it
        src.setEventHandler { [self, weak src] in
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else {
                // Out of fds, the socket stays readable and this would run again at once, spinning: wait for some to free.
                if errno == EMFILE || errno == ENFILE, let src {
                    src.suspend()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { src.resume() }
                }
                return
            }
            if Unix.peerIsUs(fd) {
                Unix.noSigPipe(fd)
                serve(fd)
            } else {
                close(fd)
            }
        }
        settingsEvents.watch()
        // Its calls are answered as the daemon's own (`conn` -1): the user's, as a phone's Allow has to be.
        sessions.phone.hear(
            .started { [weak self] method, params in
                guard let self else { throw RPCError.internalError("The background service stopped.") }
                return try await answer(method, params, conn: -1)
            })
        let ticker = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "kelp.ticker"))
        ticker.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))   // woken with the Mac's other timers
        ticker.setEventHandler { [self] in tick() }
        let prune = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        prune.schedule(deadline: .now() + 60, repeating: 86400)   // ended sessions past `keepEnded`
        prune.setEventHandler { [self] in sessions.pruneEnded() }
        running.withLock {
            $0.listenFD = listenFD
            $0.accept = src
            $0.ticker = ticker
            $0.prune = prune
        }
        src.resume()
        ticker.resume()
        prune.resume()
        workspaces.routines.start(workspaces: workspaces)
        // not once stopped
        workspaces.headQueue.async { [weak self] in
            if self?.isServing == true {
                self?.workspaces.followHeads()
                self?.workspaces.tidyAgentBranches()
            }
        }
        FileManager.default.removeIfAny(Paths.daemonError(in: root))   // an earlier failure is over
        Log.start.info("kelpd \(getpid()) serves \(self.socketPath, privacy: .public)")
    }

    public func stop() {
        let previous = running.withLock { state in
            defer { state = Running() }
            return state
        }
        previous.successor?.stop()
        // The accept source's cancel closes the socket
        previous.accept?.cancel()
        previous.ticker?.cancel()
        previous.prune?.cancel()
        if previous.accept == nil, previous.listenFD >= 0 { close(previous.listenFD) }
        // Every program ends with the daemon, whole trees (a job in a process group of its own, an agent that ignores the
        // hangup), each recorded as pausing records it: a resumable agent comes back paused, not as a second copy.
        workspaces.routines.stop()
        let probes = agentUsage.openProbes.endAll()   // a usage probe half done: its agent would outlive us
        sessions.phone.hear(.stop)
        sessions.pauseAll()
        Sessions.waitGone(probes)
        lsp.stopAll()
        watches.stopAll()
        workspaces.stopWatching()
        settingsEvents.stopWatching()
        clients.everyone().forEach { $0.hangUp() }
        unlink(socketPath)
        if previous.instanceLock >= 0 { close(previous.instanceLock) }
    }

    /// As `stop()`, except every running session goes on, handed over with copies of the socket and the lock to the kelpd
    /// this process runs next (`upgrade`). Connections made meanwhile wait in the socket's queue for it. Nil when not running.
    func handOver() -> Handover? {
        let previous = running.withLock { state in
            defer { state = Running() }
            return state
        }
        guard let accept = previous.accept else { return nil }
        let socket = dup(previous.listenFD)
        // The accept source's cancel closes its own fd, not the copy
        accept.cancel()
        previous.ticker?.cancel()
        previous.prune?.cancel()
        workspaces.routines.stop()
        sessions.phone.hear(.stop)
        let handover = Handover(socket: socket, lock: dup(previous.instanceLock), sessions: sessions.handOver())
        Sessions.waitGone(agentUsage.openProbes.endAll())   // a probe's terminal doesn't go over: its agent would be left
        lsp.stopAll()
        watches.stopAll()
        workspaces.stopWatching()
        settingsEvents.stopWatching()
        // daemon.upgrade's own reply is out first: an app that never got it would think the upgrade failed and offer a
        // restart that ends the agents just handed over.
        drainReplies()
        clients.everyone().forEach { $0.hangUp() }
        close(previous.instanceLock)
        return handover
    }

    /// What's queued for every client goes out first (a stop's or an update's own reply among it), 2 s at most each.
    func drainReplies() {
        let everyone = clients.everyone()
        DispatchQueue.concurrentPerform(iterations: everyone.count) { everyone[$0].drain(within: 2) }
    }

    /// `daemon.upgrade`: this process runs the kelpd now at `executable`, which takes every running session over. Returns
    /// only if it couldn't: refused before anything was given up (nil), or with the daemon that took the sessions back
    /// here after the exec failed. `exec`: the exec itself (tests make it fail).
    @discardableResult
    /// `checked`: daemon.upgrade's handler asked the new kelpd and waited for running git before it answered.
    func upgrade(
        to executable: String = Daemon.executable, checked: Bool = false,
        exec: (Handover, _ executable: String, _ file: String) throws -> Void = { try $0.exec($1, file: $2) }
    ) -> Daemon? {
        // Nothing is given up to a kelpd that couldn't take it: every agent would end with this process. The reason is
        // kept, so the app's next daemon.upgrade is refused and it asks the user instead of trying again.
        guard checked || Handover.adoptable(executable, home: root) else {
            Log.start.error("not updating in place: \(executable, privacy: .public) doesn't adopt this hand-over")
            Upgrade.refuse(
                root: root, executable: executable, "The new background service can't take the running sessions over.")
            return nil
        }
        // A clone or a worktree being made finishes, not cut off mid-way; none starts from here (a client is told why). A
        // clone that takes longer is cancelled: past the exec nothing here would remove its half-made folder.
        // Limit: past here its steps can't be undone from outside if one hangs. It's written down, and the app sees a daemon
        // that stopped answering (`watchLife`) and offers to restart it.
        let late = DispatchWorkItem { Log.start.fault("the hand-over hasn't reached its exec in 30 s") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: late)
        defer { late.cancel() }
        offloads.close()
        offloads.waitIdle(seconds: checked ? 3 : 5)
        forges.clones.cancelAll()
        offloads.waitIdle(seconds: 2)
        guard let handover = handOver() else { return nil }
        let file = root.appendingPathComponent("handover.json")
        do {
            try JSONEncoder().encode(handover).write(to: file)
            try exec(handover, executable, file.path)
        } catch {
            Log.start.fault("kelpd couldn't run its update: \(error)")
        }
        Log.start.attempt("removing the hand-over no kelpd read") { try FileManager.default.removeItem(at: file) }
        // Still here: this process takes the sessions back, as the new kelpd would have, and every agent goes on.
        do {
            let back = try Daemon(root: root, store: store)   // the same database: one writer, not two in one process
            if callers.strict.withLock({ $0 }) { back.strict() }   // held to the same rules as this one
            try back.start(adopting: handover, takingBack: true)
            running.withLock { $0.successor = back }
            Log.start.notice("the update didn't run: this kelpd took its sessions back")
            return back
        } catch {
            Log.start.fault("kelpd couldn't take its sessions back: \(error)")
            exit(1)
        }
    }

    /// Not ordered with replies on other threads: an event can reach a client before the reply it follows from. Events
    /// that carry state carry all of it (a session's record, a revision), so the later one read wins either way.
    func notify(_ event: some RPCEvent, to only: Set<Int>? = nil) { clients.notify(event, to: only) }

    /// One round of the 0.5 s ticker. With no session running there's nothing to tick, pause or restart: only the Mac's
    /// keep-awake is applied, so the last session's ending lets it go (and "always" keeps it). Whether the round ran.
    @discardableResult
    func tick() -> Bool {
        guard !sessions.live.all.isEmpty else {
            sessions.applyKeepAwake()
            return false
        }
        _ = sessions.tick()
        return true
    }
}
