import Agents
import Core
import Foundation
import os

/// The sessions: which run now (`live`), starting, waking, pausing and deleting them, what they tell the clients, and
/// keeping the Mac awake while agents work (`keepAwake`). Paused and ended sessions are only in the store.
final class Sessions: Sendable, WorkspaceSessions {
    let live = SessionTable()
    let reports = ChildReports()
    /// What extensions run and the phone hears when an agent asks, finishes or fails (ExtensionEvents.swift).
    let events: ExtensionEvents
    let wakeLocks = WakeLocks()   // one wake per session, however many clients open it at once; pausing locks too
    /// Wakes tried so far (tests: one attach wakes once, even when it fails).
    let wakeTries = OSAllocatedUnfairLock(initialState: 0)
    let permissions = PermissionWaits()   // a permission question's hook, waiting for Allow or Deny
    let lanes = SessionLanes()   // input for a paused session wakes it off the reader thread, in order
    /// One round of idle pausing at a time, off the ticker (`busy`), and when the ticker last looked (`idleCheckDue`).
    let pausingIdle = OSAllocatedUnfairLock(initialState: (busy: false, lookedAt: Date.distantPast))
    let updates: AgentUpdates   // Claude Code restarted into the update it installed (AgentUpdates.swift)
    let keepAwake = KeepAwake()   // the Mac kept awake while agents work (`applyKeepAwake`)
    let store: Store
    let settings: SettingsStore
    let root: URL
    let agentUsage: AgentUsage
    let clients: Clients
    let watches: Watches

    let remotes: Remotes
    /// What a session starts with: its manifest, command line, environment, hooks and account (SessionSetup.swift).
    let setup: SessionSetup
    /// What runs under the sessions: ports, CPU and memory, forwarded ports, a host's load (Processes.swift).
    let processes: SessionProcesses
    let turns: Turns   // the snapshot each agent's turn began with, kept for its diff and its undo
    let offloads: Slots   // the daemon's slots, for work that waits on programs (`AgentsVersions`)
    let recaps = OSAllocatedUnfairLock<Set<String>>(initialState: [])   // sessions with a recap running: one at a time each

    init(
        root: URL, socketPath: String, store: Store, remotes: Remotes, settings: SettingsStore, agentUsage: AgentUsage,
        clients: Clients,
        watches: Watches, offloads: Slots
    ) {
        self.root = root
        self.store = store
        self.remotes = remotes
        self.settings = settings
        self.agentUsage = agentUsage
        self.clients = clients
        self.watches = watches
        self.offloads = offloads
        setup = SessionSetup(
            root: root, socketPath: socketPath, store: store, settings: settings, remotes: remotes,
            agentUsage: agentUsage)
        events = ExtensionEvents(
            root: root, live: live, store: store, settings: settings, clients: clients, setup: setup,
            phone: PhoneBridge(
                store: store, settings: settings, setup: setup, live: live,
                conversations: agentUsage.conversations, offloads: offloads, root: root))
        processes = SessionProcesses(live: live, store: store, remotes: remotes, forwards: setup.hostBrowser.forwards)
        turns = Turns(live: live, store: store, remotes: remotes)
        updates = AgentUpdates(live: live, settings: settings)
    }

    /// `kelp` (hooks, the ctty trampoline) first, then the user's login-shell PATH.
    static var childPath: String {
        [Bundle.main.executableURL?.deletingLastPathComponent().path ?? "", LoginPath.value].filter { !$0.isEmpty }
            .joined(separator: ":")
    }

    func notify(_ event: some RPCEvent, to only: Set<Int>? = nil) { clients.notify(event, to: only) }

    var phone: PhoneBridge { events.phone }   // the agents on a phone, through a relay (PhoneBridge.swift)
    /// What asking the user on an agent's row takes, for a service that does only that.
    var asks: AgentAsks { AgentAsks(store: store, live: live, permissions: permissions, clients: clients) }

    func existing(_ id: String) -> LiveSession? { live[id] }   // a running session, without waking a paused one

    static let pausedAsAttached = RPCError.invalidParams("The session was paused as it was opened. Open it again.")

    func liveSession(_ id: String, cols: UInt16 = 120, rows: UInt16 = 32) throws -> LiveSession {
        if let session = live[id] { return session }
        return try wakeLocks.withLock(id) {   // paused sessions wake on first use
            if let session = live[id] { return session }
            return try wake(id, cols: cols, rows: rows)
        }
    }

    /// Throws unless the session is running, or paused (or being paused) so it can be woken for input.
    func mustWake(_ id: String) throws {
        switch try live.phase(id, record: { try store.session(id) }) {
        case .running, .lettingGo, .paused: return
        case .ended: throw RPCError.notRunning(id)
        case .deleted: throw RPCError.noSession(id)
        }
    }

    /// Runs `work` with the running session `id`, woken first if paused. It never gets a session an idle pause is
    /// stopping, because that one is out of `live` by then, so the next look waits for the pause and wakes it.
    func withInput<T>(_ id: String, _ work: (LiveSession) throws -> T) throws -> T {
        for _ in 0..<3 {
            let ls = try liveSession(id)
            if let result = try ls.input({ try work(ls) }) { return result }
        }
        throw RPCError.notRunning(id)
    }

    /// The last `bytes` (0 to 16 MB) the session printed.
    func liveSessionOrLog(_ id: String, bytes: Int) throws -> Data {
        let bytes = max(0, min(bytes, 16 << 20))
        if let ls = existing(id) { return ls.tail(bytes) }
        // Only a session Kelp has: the id names a file, and "../../x" would name any .log the user can read.
        guard store.look("session \(id)", { try $0.session(id) }) != nil,
            let data = Data(tail: bytes, of: root.appendingPathComponent("history/\(id).log"))
        else {
            throw RPCError.invalidParams(
                "No output kept for session \(id): it never ran here, or its history was cleaned up.")
        }
        return data
    }

    /// The last `bytes` a session printed, as text, lossy on purpose because a byte window can cut a UTF-8 sequence.
    func printed(_ id: String, bytes: Int) throws -> String {
        // swiftlint:disable:next optional_data_string_conversion
        StatusDetector.stripANSI(String(decoding: try liveSessionOrLog(id, bytes: bytes), as: UTF8.self))
    }

    /// The trail of a session Kelp has: the id names a file, as in `liveSessionOrLog`.
    func trail(_ id: String) throws -> StatusTrail? {
        if let ls = existing(id) { return ls.trail }
        return try store.session(id) == nil
            ? nil : StatusTrail(history: root.appendingPathComponent("history"), session: id)
    }

    struct Launch {
        var model: String?, effort: String?
        var prompt: String?, title: String?
        var draft = false   // type the prompt, don't send it
        var profile: String?
        var openURLs = false   // the first local URL it prints opens in the workspace's browser (event.devserver)
        var cols: UInt16 = 120, rows: UInt16 = 32
        var argv: [String]?   // restart: reuse exactly
        var tmux: String?   // restart: the host's tmux session the old one's agent still runs in
        var onHostInTmux = false   // a command (run.start) that outlives a dropped connection, as agents do
        var parent: String?   // the agent that started it
        var startedBy: String?   // the agent whose line shows this command
        var origin: String?   // the old session's origin on a restart; else the caller's session (`Sessions.asker`)
        var role: SessionRole?   // the job it's started for (a reviewer); a restart keeps the old one's
        var env: [String: String]?   // on top of the agent's own (`Session.env`); a restart keeps the old one's

        init() {}

        init(_ options: some LaunchOptions) {
            model = options.model
            effort = options.effort
            prompt = options.prompt
            title = options.title
            profile = options.profile
            draft = options.draft == true
            openURLs = options.openURLs == true
            (cols, rows) = Self.size(cols: options.cols, rows: options.rows)
        }

        /// A terminal size: anything out of range is clamped, nothing (or 0) is 120 × 32.
        static func size(cols: Int?, rows: Int?) -> (cols: UInt16, rows: UInt16) {
            let width = UInt16(clamping: cols ?? 0), height = UInt16(clamping: rows ?? 0)
            return (width > 0 ? width : 120, height > 0 ? height : 32)
        }
    }

    /// The session whose program the call being answered came from (`caller`, as `Caller.origin`), bound around each
    /// handler and carried into `offload`, so whatever the call starts, on any path, belongs to it (`Session.origin`).
    @TaskLocal static var asker: String?

    @discardableResult
    func spawn(cwd: String, manifest: AgentManifest, worktreeId: String?, _ launch: Launch = Launch()) throws -> Session
    {
        var argv = launch.argv ?? manifest.argv(model: launch.model, effort: launch.effort)
        var rec = Session(
            worktreeId: worktreeId, cwd: cwd, command: argv.joined(separator: " "), agent: manifest.id,
            title: launch.title ?? "", titleManual: launch.title != nil, argv: argv)
        // A remote project's sessions run on its host (see `launchArgv`). Kelp's hooks and skills are files on this Mac,
        // so they stay out: status comes from what the agent reports, and from the screen.
        let remote = remotes.of(cwd), local = remote == nil
        // An account profile is a folder on this Mac, so an agent on a host signs in on the host instead.
        if !local, launch.profile != nil, let host = remote?.host {
            throw RPCError.invalidParams(
                "Account profiles are for agents on this Mac: one on \(host) signs in there, in a terminal of the project."
            )
        }
        if local, case .settingsFlag(let flag)? = manifest.hooks {
            argv = try setup.withSettings(
                argv, flag: flag, manifest: manifest, worktreeId: worktreeId, fresh: launch.argv == nil)
        }
        if local, manifest.id == Session.codexAgent { argv = setup.withCodexSwitches(argv, worktreeId: worktreeId) }
        var manifest = manifest
        if local, manifest.id == "opencode", setup.openCode2.runs(argv) {
            let v2 = OpenCode2.argv(argv)
            argv = v2.argv
            if manifest.env[OpenCode2.serverConfig] == nil { manifest.env[OpenCode2.serverConfig] = v2.config }
        }
        if local, manifest.id == Session.claudeAgent { argv = setup.withServers(argv, flag: "--mcp-config") }
        // Kelp's skills (written by the app into this home) are for this session only; nothing goes into ~/.claude. A
        // restart's argv carries the old skills, chosen again as for a new chat (the browser skill may differ by now).
        if local, let flag = manifest.pluginDirFlag, launch.argv == nil || SessionSetup.hasSkills(argv, root: root) {
            argv = SessionSetup.withoutSkills(argv, root: root, flag: flag, contextFlag: manifest.contextFlag)
            let skills = setup.skillArgs(
                flag: flag, contextFlag: manifest.contextFlag, worktreeId: worktreeId, cwd: cwd, profile: launch.profile
            )
            argv += skills.argv
            rec.browser = skills.browser
        }
        // An agent with no such flag reads them from the folder it works in.
        if local, manifest.pluginDirFlag == nil, Session.isAgent(manifest.id) {
            rec.browser = setup.writeProjectSkills(worktreeId: worktreeId, cwd: cwd)
        }
        // The session gets its own id, unless it resumes one (a restart's argv carries none: see session.restart). A
        // remote project's session gets one too, because the flag needs no file here and it names the conversation on
        // the host (`Conversations.remoteTail`).
        if let flag = manifest.sessionIdFlag, !argv.contains(flag), !manifest.resumes(argv) {
            argv += [flag, rec.id.lowercased()]
        }
        rec.argv = argv
        rec.profile = launch.profile
        rec.parent = launch.parent
        rec.startedBy = launch.startedBy
        rec.origin = launch.origin ?? Self.asker
        rec.role = launch.role
        rec.env = launch.env
        // A remote agent runs in its own tmux on the host, so a dropped connection or a daemon restart doesn't stop it.
        if !local, launch.onHostInTmux || Session.isAgent(manifest.id) {
            rec.tmux = launch.tmux ?? Tmux.own()
        }
        let env = setup.launchEnv(manifest, rec)
        let ls = try LiveSession(
            record: rec, manifest: setup.liveManifest(manifest, cwd: cwd, worktreeId: worktreeId, env: env, argv: argv),
            argv: try setup.launchArgv(argv, cwd: cwd, manifest: manifest, tmux: rec.tmux, env: env), env: env,
            historyDir: root.appendingPathComponent("history"), cols: launch.cols, rows: launch.rows,
            // A dev server's URL (e.g. Jupyter Lab's) opens in the workspace's browser.
            callbacks: callbacks(
                for: rec, limits: manifest.limitScreen, devServerIn: launch.openURLs ? worktreeId : nil))
        if launch.tmux != nil { ls.attachedToRunning() }
        rec = ls.snapshot
        let sid = rec.id
        // The record first: a program nobody has a record of could be neither seen nor stopped.
        do { rec = try store.save(rec) } catch {
            ls.discard()
            ls.start()   // so its exit is reaped, no zombie
            throw error
        }
        do { try live.add(ls) } catch {
            ls.discard()
            ls.start()
            Log.store.attempt("deleting \(rec.id), not started") { try store.delete(rec) }
            throw error
        }
        if let prompt = launch.prompt {
            ls.queuePrompt(prompt, draft: launch.draft)
            if launch.title == nil {
                DispatchQueue.global(qos: .utility).async { [weak self] in self?.autoTitle(session: sid, prompt: prompt)
                }
            }
        }
        ls.start()   // after the record is saved: its first status must not be overwritten
        publish(ls)
        return rec
    }

    /// Output to attached connections: raw ones get bytes, the rest a JSON event.
    func deliver(_ id: String, _ data: Data, to subs: Set<Int>) {
        let (raw, json) = clients.split(subs)
        raw.forEach { $0.send(data) }
        if !json.isEmpty { notify(OutputEvent(session: id, data: data), to: json) }
    }

    /// A session taken out of `live` with its program still to stop (paused, deleted): the terminals streaming it are
    /// hung up, so `kelp attach` ends instead of showing a screen nothing reaches any more (the app attaches again when
    /// the tab is shown). JSON subscribers just stop getting output; the record's status tells them why.
    /// A program that ended by itself keeps its terminals attached on purpose: they show its last screen and exit code.
    func hangUpStreams(_ ls: LiveSession) { clients.split(ls.letGo()).raw.forEach { $0.hangUp() } }

    /// Deletes a session for good: it stops, its record and log go, and its exit can't save it again.
    /// This runs under its wake lock, as a wake does, so a paused session being opened at this moment can't come back
    /// after its record and log are gone (it would restart an agent for a deleted project and save the record again). A
    /// terminal's own tmux session ends with it unless `keepTmux` (a restart, whose new session attaches to it).
    func discard(_ session: Session, keepTmux: Bool = false) { discard([session], keepTmux: keepTmux) }

    /// Discards sessions that stopped together (a project's, a workspace's) with one wait for all, not up to 10 s each.
    func discard(_ all: [Session], keepTmux: Bool = false) {
        if !keepTmux { all.forEach(endOwnTmux) }
        wakeLocks.withLocks(all.map(\.id)) {
            let pids = all.compactMap { live.remove($0.id) }.flatMap { ls in
                hangUpStreams(ls)
                return ls.discard()
            }
            Self.waitGone(pids)   // gone before their project or folder goes (SIGKILL after 2 s)
            for session in all {
                live.forget(session.id)
                // The turns are dropped as the delete took them, so a turn kept meanwhile (`Turns.keep`) is either
                // among them or refused.
                do { turns.dropRefs(try store.deleteSession(session), of: session.id) } catch {
                    Log.store.error("couldn't delete session \(session.id, privacy: .public): \(error)")
                }
                for name in ["\(session.id).log", "\(session.id).trail"] {
                    let file = root.appendingPathComponent("history/\(name)")   // none when it never ran
                    if FileManager.default.fileExists(atPath: file.path) {
                        Log.store.attempt("removing \(session.id)'s history") {
                            try FileManager.default.removeItem(at: file)
                        }
                    }
                }
            }
        }
        familyLeft(all)
    }

    /// Stops every running session as the daemon stops: each is paused (a resumable agent comes back paused, not as a
    /// second copy) or ended, its whole process tree gone before this returns. No session starts or wakes after this.
    func pauseAll() {
        let manifests = AgentManifest.load(dir: Paths.agents(in: root))
        Self.waitGone(live.close().flatMap { ls in live.remove(ls.snapshot.id).map { pause($0, manifests) } ?? [] })
    }

    /// Hands every running session to the kelpd that takes over (`Daemon.handOver`). Each is taken out of `live` with
    /// its program left running and its last record saved. A session ending right now isn't handed over, because its
    /// record says what became of it. No session starts or wakes from now on.
    func handOver() -> [Handover.Session] {
        keepAwake.release()   // the next kelpd takes its own
        let all = live.close()
        reports.settle(within: 5)   // a child's report on its way: typed into its parent below, or owed
        // Input not yet written goes in first (a send's Enter trails its text by 0.3 s): the next kelpd can't send it.
        DispatchQueue.concurrentPerform(iterations: all.count) { all[$0].drainInput(within: 2) }
        return all.compactMap { ls in
            guard live.remove(ls.snapshot.id) != nil, let fd = ls.pty.handOver() else { return nil }
            publishLast(ls)
            return ls.handedOver(fd: fd)
        }
    }

    /// Takes over a session the kelpd before this one ran (`Handover`), live here from now on; its program never
    /// stopped. A session that can't be taken over (its record gone) is stopped rather than left running unseen.
    func adopt(_ handed: Handover.Session) {
        let pty = PTY(adopting: handed.pid, fd: handed.fd)
        do {
            guard let rec = try store.session(handed.id) else {
                throw RPCError.noSession(handed.id)
            }
            var adoptedManifest = try setup.manifest(rec.agent, command: nil, fallbackArgv: rec.argv)
            // As in `liveManifest`, but past startup nothing is answered for it.
            adoptedManifest = setup.wiredHooks(
                adoptedManifest, env: setup.hookedEnv(adoptedManifest, rec, secrets: false), argv: rec.argv)
            let ls = LiveSession(
                record: rec, manifest: adoptedManifest, pty: pty, historyDir: root.appendingPathComponent("history"),
                callbacks: callbacks(for: rec, limits: adoptedManifest.limitScreen))
            ls.adopted(
                modes: handed.modes, bytes: handed.bytes, pending: handed.pending ?? [], reports: handed.reports ?? [],
                status: handed.status)
            try live.add(ls)
            giveBackOwed(ls)
            ls.start()
            SessionHook.waitAgain(ls)
        } catch {
            Log.session.error("\(handed.id, privacy: .public) wasn't taken over: \(error)")
            pty.terminate()
            pty.start()   // started so that its exit is reaped
        }
    }

    /// The idle pause counts in minutes, so idle agents are looked for every 15 s, not on each 0.5 s tick.
    static let idleCheckEvery: TimeInterval = 15

    /// Whether the ticker should look for idle agents now. It looks at least every 15 s, and more often when a quarter
    /// of Settings › hibernateMinutes is shorter, so a pause is late by a quarter of the setting at most. With the
    /// setting off, it never looks.
    func idlePauseDue(_ now: Date) -> Bool {
        let minutes = settings[SettingKeys.hibernateMinutes]
        return minutes > 0 && idleCheckDue(now, every: min(Self.idleCheckEvery, minutes * 15))
    }

    /// Whether a look for idle agents is due: `every` seconds have passed since the last look, or the clock went back.
    func idleCheckDue(_ now: Date, every: TimeInterval = idleCheckEvery) -> Bool {
        pausingIdle.withLock { idle in
            guard now.timeIntervalSince(idle.lookedAt) >= every || now < idle.lookedAt else {
                return false
            }
            idle.lookedAt = now
            return true
        }
    }

    /// Applies Settings › keepAwake, while an agent works or always (`KeepAwake.apply`).
    func applyKeepAwake() {
        keepAwake.apply(
            settings[SettingKeys.keepAwake],
            working: live.all.contains { ls in
                let session = ls.snapshot
                return session.status == .working && !session.isTerminal
            })
    }
}
