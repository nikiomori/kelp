import Foundation
import os
import Core
import GitKit
import Agents
import AgentData

/// The long-running process: owns PTYs, state and the JSON-RPC socket.
/// Running sessions and who is connected each keep their own lock; the order they're taken in is in `Clients`.
public final class Daemon: Sendable {
    public let store: Store
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
    let settings: SettingsStore
    let agentUsage: AgentUsage   // what the agents left on disk: conversations, token usage, plan limits
    let offloads = Slots(Daemon.offloadLimit)   // what `offload` runs at once
    let forges: Forges   // pull requests by branch, running clones, the trackers' clients
    let lsp: LSPHost   // language servers: one per project and server command, shared by every client
    let watches: Watches   // what clients watch (watch.start), read while anyone does and pushed when it changed
    let sessions: Sessions   // which run, starting, waking, pausing and deleting them
    let settingsEvents: SettingsEvents   // event.settings in order: the last one is the settings now
    let workspaces: Workspaces   // desks, the branches they follow, the .kelp.yaml files the user trusts
    var files: FileService { FileService(remotes: remotes) }   // files.*: read, written, moved here or on a remote project's host
    let remotes: Remotes   // which project folders stand for one on a host (only those in this home's remote/), and how to reach it

    public convenience init(root: URL, store: Store? = nil) throws { try self.init(root: root, store: store, lspDelays: (retry: 30, idle: 60)) }

    /// `lspDelays`: how soon a broken language server is started again, and how long one with no open file keeps running
    /// (tests shorten them).
    init(root: URL, store: Store?, lspDelays: (retry: TimeInterval, idle: TimeInterval)) throws {
        // a client that hangs up mid-write fails that write; it must not end the process (kelpd does this too, tests host a Daemon themselves)
        signal(SIGPIPE, SIG_IGN)
        self.root = root
        try Paths.ensure(root)
        self.store = try store ?? Store(path: root.appendingPathComponent("kelp.sqlite").path)
        self.settings = SettingsStore(root: root)
        self.remotes = Remotes(home: root)
        self.agentUsage = AgentUsage(root: root, settings: settings, store: self.store, remotes: remotes)
        self.forges = Forges(offloads: offloads, store: self.store, clients: clients, remotes: remotes)
        self.lsp = LSPHost(store: self.store, remotes: remotes, retryDelay: lspDelays.retry, idleDelay: lspDelays.idle)
        self.watches = Watches(store: self.store, clients: clients, remotes: remotes)
        self.sessions = Sessions(root: root, socketPath: root.appendingPathComponent("kelp.sock").path, store: self.store, remotes: remotes,
                                 settings: settings, agentUsage: agentUsage, clients: clients, watches: watches, offloads: offloads)
        self.workspaces = Workspaces(root: root, store: self.store, remotes: remotes, sessions: sessions, clients: clients)
        self.settingsEvents = SettingsEvents(store: settings, clients: clients, sessions: sessions)
        // Remote projects' shared SSH connections; without it, they fail.
        do { try Paths.ensure(URL(fileURLWithPath: remotes.controlDir)) } catch { Log.start.error("no folder for ssh connections: \(error)") }
        watches.reading.withLock { $0.read = { [weak self] k, fast in await self?.sample(k, fast: fast) ?? (nil, nil) } }
        self.store.changed.withLock {
            $0.tell = { [weak self] c in
                self?.recordChanged(c)   // records go to the clients as they change
                switch c {   // and a project added, moved or removed is followed (watchHeads) from then on
                case .repo, .repoRemoved: self?.workspaces.headQueue.async { self?.workspaces.watchHeads() }
                default: break
                }
            }
        }
    }

    /// kelpd couldn't start: the reason goes to the log and to `Paths.daemonError(in:)`, where the app reads it for its
    /// "background service isn't running" banner (the app starts kelpd with its output thrown away). The file goes once a
    /// daemon starts. Limit: a KELP_HOME that can't be written can't hold it either; then only the log and stderr have it.
    public static func startFailed(_ error: Error, root: URL) -> String {
        let why = (error as? RPCError)?.message ?? "\(error)"
        Log.start.fault("kelpd didn't start: \(why, privacy: .public)")
        try? Data((why + "\n").utf8).write(to: Paths.daemonError(in: root))
        return why
    }

    /// The binary this process runs: the one an update replaces.
    static var executable: String { (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).path }

    /// When this binary was built; the app compares it with the kelpd it ships to spot a stale daemon after an update.
    static let binaryMTime = Upgrade.modified(executable)

    /// `handover`: what the kelpd this process ran before (an update, `daemon.upgrade`) left open for this one to take over.
    public func start(adopting handover: Handover? = nil) throws {
        // One daemon per KELP_HOME: a second one (launchd's KeepAlive, a CLI that couldn't connect) would take the socket
        // over and mark the first one's running agents paused. A handover's lock is held already.
        let lockFD = handover?.lock ?? open(root.appendingPathComponent("kelpd.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
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
            for var s in try store.sessions() where s.status != .exited && !adopted.contains(s.id) {
                s.status = Sessions.resumable(s, manifests) ? .hibernated : .exited
                s.progress = nil   // what ran there isn't getting any further
                try store.save(s)
            }
        } catch { Log.store.error("couldn't mark the last run's sessions paused or ended: \(error)") }
        handover?.sessions.forEach(sessions.adopt)   // before the first connection: it finds them running
        _ = Self.binaryMTime   // read now: after an update the file on disk is already the new one
        DispatchQueue.global().async { _ = LoginPath.value }   // warm up so the first agent doesn't wait for the shell
        // The usage index reads gigabytes the first time: do it in the background now, not when Usage is opened.
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 30) { [self] in
            let since = Calendar.current.date(byAdding: .day, value: -89, to: Calendar.current.startOfDay(for: Date())) ?? Date()
            _ = agentUsage.usageIndex.rows(roots: agentUsage.agentRoots().claude.filter { FileManager.default.fileExists(atPath: $0.path) }, since: since)
        }
        let listenFD: Int32
        do { listenFD = try handover?.socket ?? Unix.listen(socketPath) } catch {
            running.withLock { if $0.instanceLock >= 0 { close($0.instanceLock); $0.instanceLock = -1 } }   // not ours to keep
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
                if errno == EMFILE || errno == ENFILE, let src { src.suspend(); DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { src.resume() } }
                return
            }
            if Unix.peerIsUs(fd) { Unix.noSigPipe(fd); serve(fd) } else { close(fd) }
        }
        settingsEvents.watch()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "kelp.ticker"))
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [self] in
            sessions.live.all.forEach { $0.tick() }
            sessions.applyKeepAwake()
            sessions.hibernateIdle()
        }
        let prune = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        prune.schedule(deadline: .now() + 60, repeating: 86400)   // ended sessions past `keepEnded`
        prune.setEventHandler { [self] in sessions.pruneEnded() }
        running.withLock {
            $0.listenFD = listenFD
            $0.accept = src
            $0.ticker = t
            $0.prune = prune
        }
        src.resume()
        t.resume()
        prune.resume()
        workspaces.routines.start(desks: workspaces)
        // not once stopped
        workspaces.headQueue.async { [weak self] in
            if self?.running.withLock({ $0.accept != nil }) == true { self?.workspaces.followHeads() }
        }
        try? FileManager.default.removeItem(at: Paths.daemonError(in: root))   // an earlier failure is over
        Log.start.info("kelpd \(getpid()) serves \(self.socketPath, privacy: .public)")
    }

    public func stop() {
        let r = running.withLock { r in defer { r = Running() }; return r }
        r.successor?.stop()
        // The accept source's cancel closes the socket
        r.accept?.cancel()
        r.ticker?.cancel()
        r.prune?.cancel()
        if r.accept == nil, r.listenFD >= 0 { close(r.listenFD) }
        // Every program ends with the daemon, whole trees (a job in a process group of its own, an agent that ignores the
        // hangup), each recorded as pausing records it: a resumable agent comes back paused, not as a second copy.
        workspaces.routines.stop()
        sessions.pauseAll()
        lsp.stopAll()
        watches.stopAll()
        workspaces.stopWatching()
        settingsEvents.stopWatching()
        clients.everyone().forEach { $0.hangUp() }
        unlink(socketPath)
        if r.instanceLock >= 0 { close(r.instanceLock) }
    }

    /// As `stop()`, except every running session goes on, handed over with copies of the socket and the lock to the kelpd
    /// this process runs next (`upgrade`). Connections made meanwhile wait in the socket's queue for it. Nil when not running.
    func handOver() -> Handover? {
        let r = running.withLock { r in defer { r = Running() }; return r }
        guard let accept = r.accept else { return nil }
        let socket = dup(r.listenFD)
        // The accept source's cancel closes its own fd, not the copy
        accept.cancel()
        r.ticker?.cancel()
        r.prune?.cancel()
        workspaces.routines.stop()
        let h = Handover(socket: socket, lock: dup(r.instanceLock), sessions: sessions.handOver())
        lsp.stopAll()
        watches.stopAll()
        workspaces.stopWatching()
        settingsEvents.stopWatching()
        // daemon.upgrade's own reply is out first: an app that never got it would think the upgrade failed and offer a
        // restart that ends the agents just handed over.
        drainReplies()
        clients.everyone().forEach { $0.hangUp() }
        close(r.instanceLock)
        return h
    }

    /// What's queued for every client goes out first (a stop's or an update's own reply among it), 2 s at most each.
    private func drainReplies() {
        let everyone = clients.everyone()
        DispatchQueue.concurrentPerform(iterations: everyone.count) { everyone[$0].drain(within: 2) }
    }

    /// `daemon.upgrade`: this process runs the kelpd now at `executable`, which takes every running session over. Returns
    /// only if it couldn't: refused before anything was given up (nil), or with the daemon that took the sessions back
    /// here after the exec failed. `exec`: the exec itself (tests make it fail).
    @discardableResult
    /// `checked`: daemon.upgrade's handler asked the new kelpd and waited for running git before it answered.
    func upgrade(to executable: String = Daemon.executable, checked: Bool = false,
                 exec: (Handover, _ executable: String, _ file: String) throws -> Void = { try $0.exec($1, file: $2) }) -> Daemon? {
        // Nothing is given up to a kelpd that couldn't take it: every agent would end with this process. The reason is
        // kept, so the app's next daemon.upgrade is refused and it asks the user instead of trying again.
        guard checked || Handover.adoptable(executable, home: root) else {
            Log.start.error("not updating in place: \(executable, privacy: .public) doesn't adopt this hand-over")
            Upgrade.refuse(root: root, executable: executable, "The new background service can't take the running sessions over.")
            return nil
        }
        // A clone or a worktree being made finishes, not cut off mid-way; none starts from here (a client is told why).
        offloads.close()
        offloads.waitIdle(seconds: checked ? 3 : 5)
        guard let h = handOver() else { return nil }
        let file = root.appendingPathComponent("handover.json")
        do {
            try JSONEncoder().encode(h).write(to: file)
            try exec(h, executable, file.path)
        } catch {
            Log.start.fault("kelpd couldn't run its update: \(error)")
        }
        Log.start.attempt("removing the hand-over no kelpd read") { try FileManager.default.removeItem(at: file) }
        // Still here: this process takes the sessions back, as the new kelpd would have, and every agent goes on.
        do {
            let back = try Daemon(root: root, store: store)   // the same database: one writer, not two in one process
            try back.start(adopting: h)
            running.withLock { $0.successor = back }
            Log.start.notice("the update didn't run: this kelpd took its sessions back")
            return back
        } catch {
            Log.start.fault("kelpd couldn't take its sessions back: \(error)")
            exit(1)
        }
    }

    // MARK: connections

    /// A request as it comes: JSON-RPC lets the id be a string too, and the reply carries it back as it came.
    struct Request: Decodable {
        let id: JSONValue?
        let method: String
        let params: JSONValue?
        var isNotification: Bool { id == nil || id == .null }
    }
    struct Reply: Encodable {
        var jsonrpc = "2.0"
        let id: JSONValue
        let result: JSONValue?
        let error: RPCError?
    }

    private func serve(_ fd: Int32) {
        let client = clients.add(fd: fd)
        // Accepted as this one stopped or handed over (its cancel doesn't stop an accept already running): added first,
        // then looked at, so either the stop's hang-up has it or it's hung up here (its reader then reads the end and
        // cleans up as for any other), and connects to the next one.
        if !running.withLock({ $0.accept != nil }) { client.hangUp() }
        Thread.detachNewThread { [self] in
            var received = LineBuffer()
            var buf = [UInt8](repeating: 0, count: 65536)
            var spoke = false
            // Requests of this client still being answered: past `pendingLimit` more are refused, not queued for good.
            let pending = OSAllocatedUnfairLock(initialState: 0)
            reading: while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                let lines = received.append(Data(buf[0..<n]))
                // A line past any request's size (a 50 MB file saved, escaped) isn't one: hang up rather than keep it all.
                guard received.pending <= Self.lineLimit else {
                    Log.rpc.error("hung up on a client whose line passed \(Self.lineLimit) bytes with no end")
                    break reading
                }
                for (i, line) in lines.enumerated() {
                    guard let req = try? JSONDecoder().decode(Request.self, from: line) else { refuse(line, client); continue }
                    // A JSON-RPC client after all (it came in raw, Clients.add): events from now on.
                    if !spoke { spoke = true; if req.method != "session.stream" { clients.setRaw(client.id, false) } }
                    if let handler = Self.methods[req.method] as? any Handled.Type, handler.inOrder { answerInOrder(handler, req, client); continue }
                    // The one method by name: it ends JSON-RPC on this connection, which becomes a raw byte pipe (kelp attach).
                    if req.method == "session.stream" {
                        // What came after its line in the same read is the stream's already: its whole lines, then the rest.
                        let after = lines[(i + 1)...].reduce(Data()) { $0 + $1 + Data("\n".utf8) }
                        stream(client, session: req.params?["id"]?.string ?? "", size: req.params, leftover: after + received.takeRemainder())
                        break reading
                    }
                    let admitted = pending.withLock { n -> Bool in
                        guard n < Self.pendingLimit else { return false }
                        n += 1
                        return true
                    }
                    guard admitted else {
                        let refusal = Self.errorLine(id: req.id ?? .null, RPCError.internalError("Too many requests at once."))
                        if !req.isNotification, let refusal { client.send(refusal) }
                        continue
                    }
                    Task {
                        await self.respond(req, conn: client)
                        pending.withLock { $0 -= 1 }
                    }
                }
            }
            hungUp(client)
        }
    }

    /// Not a request: say so to whoever sent an id, rather than leave it waiting.
    private func refuse(_ line: Data, _ client: Connection) {
        guard let id = (try? JSONDecoder().decode(JSONValue.self, from: line))?["id"], id != .null,
              let refusal = try? Wire.line(Reply(id: id, result: nil, error: RPCError(code: -32600, message: "invalid request"))) else { return }
        client.send(refusal)
    }

    /// Quick, and only right in the order they were sent (keystrokes, a setting dragged, two sends; a saved layout or a
    /// terminal size that finished second must not win over the newer one): applied on the reader thread, one after
    /// another, calls and notifications alike (`Handled.inOrder`); a call's reply goes out in that order.
    private func answerInOrder(_ handler: any Handled.Type, _ req: Request, _ client: Connection) {
        let id = req.id ?? .null, notification = req.isNotification, method = req.method
        let reply: @Sendable (Swift.Result<Data, Error>) -> Void = { result in
            if case .failure(let e) = result { Self.log(method, failed: e, notification: notification) }
            guard !notification else { return }
            switch result {
            case .success(let data): client.send(Self.replyLine(id: id, result: data))
            case .failure(let e): if let line = Self.errorLine(id: id, e) { client.send(line) }
            }
        }
        // Input for a session answers once the session has it (`SessionInput`), maybe from its lane.
        if let input = handler as? any SessionInput.Type {
            let conn = client.id
            input.answerInOrder(req.params ?? .null, sessions, allowed: { [self] in try allow($0, conn: conn) }, done: reply)
            return
        }
        let answered = Swift.Result { try answerNow(handler, req.params ?? .null, conn: client.id) }
        reply(answered)
        // daemon.upgrade: its reply is queued now, and the hand-over sends it before hanging up.
        if handler == DaemonUpgrade.self, case .success = answered { Thread.detachNewThread { Upgrade.of(self).run() } }
        if handler == DaemonShutdown.self, case .success = answered {
            Thread.detachNewThread { [self] in
                drainReplies()
                stop()
                exit(0)
            }
        }
    }

    /// The connection ended: what it held goes with it.
    private func hungUp(_ client: Connection) {
        clients.remove(client.id)   // first: an attach finishing now sees it gone (Clients.isConnected)
        watches.drop(client.id)
        sessions.live.all.forEach { $0.detach(client.id) }
        lsp.closeAll(conn: client.id)   // its files: a server left with none stops a while later
        client.close()
    }

    /// Raw attach (`kelp attach`, the libghostty terminal): history then live output as plain bytes; whatever the client
    /// writes is the user's typing. Terminal replies (DA, kitty keyboard) flow back the same way, so the agent sees a real terminal.
    /// `size`: the attaching terminal's cols / rows, so a paused agent wakes at the size it's shown at.
    /// An ended session shows what it last printed (from its log), then the attach ends.
    private func stream(_ client: Connection, session: String, size: JSONValue?, leftover: Data) {
        // Before waking: its status events must not land in the byte stream. It stays raw until `hungUp` removes it.
        clients.setRaw(client.id, true)
        if sessions.existing(session) == nil, (try? store.session(session))?.status == .exited {
            client.send(TerminalReplies.withoutQueries((try? sessions.liveSessionOrLog(session, bytes: LiveSession.ringLimit)) ?? Data())); return
        }
        let (cols, rows) = Sessions.Launch.size(cols: size?["cols"]?.int, rows: size?["rows"]?.int)
        let ls: LiveSession
        do { ls = try sessions.liveSession(session, cols: cols, rows: rows) } catch {
            // One Kelp has that didn't wake says why (its agent's CLI gone, its folder deleted), here and in the log.
            guard (try? store.session(session)) != nil else { client.send(Data("kelp: no such session\r\n".utf8)); return }
            let why = (error as? RPCError)?.message ?? "\(error)"
            Log.session.error("\(session, privacy: .public) didn't wake for a terminal: \(why)")
            client.send(Data("kelp: \(why)\r\n".utf8)); return
        }
        // Queued under the session's lock: no live output gets ahead of it. One paused at this moment ends the attach,
        // as the pause does for those already attached (`letGo`).
        guard ls.attach(client.id, send: { client.send($0) }) != nil else { return }
        if !leftover.isEmpty { ls.userInput(leftover) }
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(client.fd, &buf, buf.count)
            if n <= 0 { break }
            ls.userInput(Data(buf[0..<n]))
        }
        ls.detach(client.id)
    }

    private func respond(_ req: Request, conn client: Connection) async {
        let id = req.id ?? .null
        // Attach: the reply with the history is queued in the same step that subscribes, so no live output can reach this
        // connection ahead of it (the screen would show the newest bytes before the history they follow).
        // The one method that answers itself (SessionAttach's own handler serves an ended session): its reply has to be
        // queued inside the session's lock, which `Handled` can't express.
        if req.method == SessionAttach.name, !req.isNotification, let sid = (try? SessionAttach.checked(req.params ?? .null, self, conn: client.id))?.id,
           sessions.existing(sid) != nil || (try? store.session(sid))?.status == .hibernated {
            // A wake that fails says why, once: falling through would wake it a second time, in the slow lane.
            let ls: LiveSession
            do { ls = try await offloads.runNow({ [self] in try sessions.liveSession(sid) }) } catch {
                Self.log(req.method, failed: error, notification: false)
                if let line = Self.errorLine(id: id, error) { client.send(line) }
                return
            }
            // Subscribed, then looked at: one that closed while the session woke is detached again (it would count as
            // watching for good, and the session would never pause). Its end removes it from `clients` before it detaches
            // from every session, so one of the two always detaches it. The history (up to 1 MiB) is built under the
            // session's lock only, not the one every event goes through.
            let attached = ls.attach(client.id) { history in
                if let reply = try? JSONEncoder().encode(SessionAttach.Result(history: history.base64EncodedString())) {
                    client.send(Self.replyLine(id: id, result: reply))
                }
            } != nil
            if attached, !clients.isConnected(client.id) { ls.detach(client.id); return }
            if !attached, let line = Self.errorLine(id: id, Sessions.pausedAsAttached) { client.send(line) }
            return
        }
        do {
            let answered = try await answer(req.method, req.params ?? .null, conn: client.id)
            if !req.isNotification { client.send(Self.replyLine(id: id, result: answered)) }
        } catch {
            Self.log(req.method, failed: error, notification: req.isNotification)
            if !req.isNotification, let line = Self.errorLine(id: id, error) { client.send(line) }
        }
    }

    /// A call's refusal went back to its caller; a notification's failure (a layout or UI state not saved) and anything
    /// unexpected has only the log.
    static func log(_ method: String, failed error: Error, notification: Bool) {
        if let e = error as? RPCError, !notification { Log.rpc.debug("\(method, privacy: .public) failed: \(e.message)") }
        else { Log.rpc.error("\(method, privacy: .public) failed: \((error as? RPCError)?.message ?? "\(error)")") }
    }

    /// A reply line around a result already encoded: the result isn't decoded and encoded again on its way out.
    static func replyLine(id: JSONValue, result: Data) -> Data {
        var d = Data(#"{"jsonrpc":"2.0","id":"#.utf8)
        d.append((try? JSONEncoder().encode(id)) ?? Data("null".utf8))
        d.append(Data(#","result":"#.utf8))
        d.append(result)
        d.append(Data("}\n".utf8))
        return d
    }
    static func errorLine(id: JSONValue, _ error: Error) -> Data? {
        try? Wire.line(Reply(id: id, result: nil, error: (error as? RPCError) ?? .internalError("\(error)")))
    }

    /// Not ordered with replies on other threads: an event can reach a client before the reply it follows from. Events
    /// that carry state carry all of it (a session's record, a revision), so the later one read wins either way.
    func notify(_ e: some RPCEvent, to only: Set<Int>? = nil) { clients.notify(e, to: only) }

}
