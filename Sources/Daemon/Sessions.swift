import Foundation
import os
import IOKit.pwr_mgt
import Core
import Agents

/// The sessions: which run now (`live`), starting, waking, pausing and deleting them, what they tell the clients, the
/// Mac kept awake while agents work. Paused and ended ones are only in the store.
final class Sessions: Sendable {
    let live = SessionTable()
    let wakeLocks = WakeLocks()   // one wake per session even when several clients open it at once; pausing holds it too
    /// Wakes tried so far (tests: one attach wakes once, even when it fails).
    let wakeTries = OSAllocatedUnfairLock(initialState: 0)
    let pausing = OSAllocatedUnfairLock<Set<String>>(initialState: [])   // sessions an idle pause is stopping: input waits, then wakes them
    let lanes = SessionLanes()   // input for a paused session wakes it off the reader thread, in order
    let pausingIdle = OSAllocatedUnfairLock(initialState: false)   // one round of idle pausing at a time, off the ticker
    /// The Mac kept awake while agents work (applyKeepAwake): the ticker and a settings change both apply it.
    let sleepAssertion = OSAllocatedUnfairLock<(id: UInt32, type: String?)>(initialState: (0, nil))
    let store: Store
    let settings: SettingsStore
    let root: URL
    let socketPath: String
    let agentUsage: AgentUsage
    let clients: Clients
    let watches: Watches

    let remotes: Remotes
    let offloads: Slots   // the daemon's, for what waits on programs (`AgentsVersions`)
    /// What Claude Code's /context counted, by folder and flags, and when (`claudeSetup`).
    let contextSetups = OSAllocatedUnfairLock<[String: (at: Date, setup: SessionContextParts.Setup?)]>(initialState: [:])

    init(root: URL, socketPath: String, store: Store, remotes: Remotes, settings: SettingsStore, agentUsage: AgentUsage, clients: Clients,
         watches: Watches, offloads: Slots) {
        self.root = root
        self.socketPath = socketPath
        self.store = store
        self.remotes = remotes
        self.settings = settings
        self.agentUsage = agentUsage
        self.clients = clients
        self.watches = watches
        self.offloads = offloads
    }

    /// `kelp` (hooks, the ctty trampoline) first, then the user's login-shell PATH.
    static var childPath: String {
        [Bundle.main.executableURL?.deletingLastPathComponent().path ?? "", LoginPath.value].filter { !$0.isEmpty }.joined(separator: ":")
    }

    func notify(_ e: some RPCEvent, to only: Set<Int>? = nil) { clients.notify(e, to: only) }

    /// A running session, without waking a paused one.
    func existing(_ id: String) -> LiveSession? { live[id] }

    func liveSession(_ id: String, cols: UInt16 = 120, rows: UInt16 = 32) throws -> LiveSession {
        if let s = live[id] { return s }
        return try wakeLocks.withLock(id) {   // paused sessions wake on first use
            if let s = live[id] { return s }
            return try wake(id, cols: cols, rows: rows)
        }
    }

    /// Not running: it has to be paused, to be woken for input.
    func mustWake(_ id: String) throws {
        guard try existing(id) != nil || pausing.withLock({ $0.contains(id) }) || store.session(id)?.status == .hibernated else {
            throw RPCError.invalidParams("no live session \(id)")
        }
    }

    /// `work` with the running session `id`, woken first if paused. Never one an idle pause is stopping: that one is out
    /// of `live` by then, so the next look waits for the pause and wakes it.
    func withInput<T>(_ id: String, _ work: (LiveSession) throws -> T) throws -> T {
        for _ in 0..<3 {
            let ls = try liveSession(id)
            if let r = try ls.input({ try work(ls) }) { return r }
        }
        throw RPCError.invalidParams("no live session \(id)")
    }

    /// The last `bytes` (0 to 16 MB) it printed.
    func liveSessionOrLog(_ id: String, bytes: Int) throws -> Data {
        let bytes = max(0, min(bytes, 16 << 20))
        if let ls = existing(id) { return ls.tail(bytes) }
        // Only a session Kelp has: the id names a file, and "../../x" would name any .log the user can read.
        guard (try? store.session(id)) != nil, let d = Data(tailOf: root.appendingPathComponent("history/\(id).log"), bytes: bytes) else {
            throw RPCError.invalidParams("no history for \(id)")
        }
        return d
    }

    struct Launch {
        var model: String?, effort: String?, resume = false
        var prompt: String?, title: String?
        var draft = false   // type the prompt, don't send it
        var profile: String?
        var openURLs = false   // the first local URL it prints opens in the workspace's browser (event.devserver)
        var cols: UInt16 = 120, rows: UInt16 = 32
        var argv: [String]?   // restart: reuse exactly
        var tmux: String?   // restart: the host's tmux session the old one's agent still runs in
        var onHostInTmux = false   // a command (run.start) that outlives a dropped connection, as agents do

        /// A terminal size: anything out of range is clamped, nothing (or 0) is 120 × 32.
        static func size(cols: Int?, rows: Int?) -> (cols: UInt16, rows: UInt16) {
            let c = UInt16(clamping: cols ?? 0), r = UInt16(clamping: rows ?? 0)
            return (c > 0 ? c : 120, r > 0 ? r : 32)
        }
    }

    /// The live session whose program `pid` is, or runs under (its own child, a shell's job…).
    func session(running pid: pid_t) -> String? {
        let mine = Dictionary(live.all.map { ($0.pty.pid, $0.snapshot.id) }) { a, _ in a }
        var p = pid
        for _ in 0..<64 {
            if let id = mine[p] { return id }
            guard let up = Subprocess.parent(p), up > 1, up != p else { return nil }
            p = up
        }
        return nil
    }

    @discardableResult
    func spawn(cwd: String, manifest: AgentManifest, worktreeId: String?, _ o: Launch = Launch()) throws -> Session {
        var argv = o.argv ?? manifest.argv(model: o.model, effort: o.effort, resume: o.resume)
        var rec = Session(worktreeId: worktreeId, cwd: cwd, command: argv.joined(separator: " "), agent: manifest.id,
                          title: o.title ?? "", titleManual: o.title != nil, argv: argv)
        // A remote project's sessions run on its host (see `launchArgv`). Kelp's hooks and skills are files on this Mac,
        // so they stay out: status comes from what the screen shows.
        let local = remotes.of(cwd) == nil
        if local, o.argv == nil, case .settingsFlag(let flag)? = manifest.hooks {
            let f = hooksDir(manifest).appendingPathExtension("json")
            try Hooks.writeSettings(to: f)
            argv += [flag, f.path]
        }
        // Kelp's skills (written by the app into this home, only the ones turned on), for this session only: nothing goes
        // into ~/.claude.
        let agentSkills = root.appendingPathComponent("agent-skills")
        if local, o.argv == nil, let flag = manifest.pluginDirFlag, Self.hasPlugins(agentSkills) {
            argv += [flag, agentSkills.path]
            // Without a word of context, "add a panel" reads as a request for the agent's own UI.
            if let ctx = manifest.contextFlag, let text = Self.kelpContext(agentSkills) { argv += [ctx, text] }
        }
        // Its own id, unless it resumes one (a restart's argv carries none: see session.restart).
        if local, let flag = manifest.sessionIdFlag, !argv.contains(flag), !manifest.resumes(argv) { argv += [flag, rec.id.lowercased()] }
        rec.argv = argv
        rec.profile = o.profile
        // A remote agent runs in a tmux session of its own on the host: a dropped connection or a daemon restart leaves it working.
        if !local, o.onHostInTmux || !["shell", "custom"].contains(manifest.id) { rec.tmux = o.tmux ?? Tmux.own() }
        let env = launchEnv(manifest, rec)
        let ls = try LiveSession(record: rec, manifest: liveManifest(manifest, cwd: cwd, worktreeId: worktreeId, env: env, argv: argv),
                                 argv: try launchArgv(argv, cwd: cwd, manifest: manifest, tmux: rec.tmux), env: env,
                                 historyDir: root.appendingPathComponent("history"), cols: o.cols, rows: o.rows,
                                 callbacks: callbacks(for: rec, devServerIn: o.openURLs ? worktreeId : nil))   // e.g. Jupyter Lab's URL
        if o.tmux != nil { ls.attachedToRunning() }
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
        if let p = o.prompt {
            ls.queuePrompt(p, draft: o.draft)
            if o.title == nil { DispatchQueue.global(qos: .utility).async { [weak self] in self?.autoTitle(session: sid, prompt: p) } }
        }
        ls.start()   // after the record is saved: its first status must not be overwritten
        publish(ls)
        return rec
    }

    /// What runs: `argv` itself, or for a remote project ssh running it in the project's folder on the host. Records
    /// keep the plain argv, so a restart or a wake wraps it once (older records kept the ssh line: that runs as it is).
    func launchArgv(_ argv: [String], cwd: String, manifest: AgentManifest, tmux: String? = nil) throws -> [String] {
        var run = argv
        if let remote = remotes.of(cwd), argv.first != remote.ssh {
            // A command line (`.custom`: zsh -lc "…") goes to sh there: the host may have no zsh.
            let onHost = manifest.id == "custom" && argv.count == 3 && argv[1] == "-lc" ? ["sh", "-c", argv[2]] : argv
            let loginShell = manifest.id == "shell" && Tmux.session(argv) == nil
            let command = tmux.map { remote.command(onHost, inTmux: $0) } ?? remote.command(loginShell ? nil : onHost)
            run = [remote.ssh] + remote.sshArgs(tty: true) + [command]
        }
        guard let exe = run.first else { throw RPCError.invalidParams("empty command") }
        return [try LoginPath.resolve(exe)] + run.dropFirst()
    }

    /// What a session tells the daemon, from its first byte on. An ended session leaves `live`: its fd and pid belong to
    /// nobody now, and its log still shows what it printed. `devServerIn`: the first local URL it prints opens in that
    /// workspace's browser.
    func callbacks(for rec: Session, devServerIn worktree: String? = nil) -> LiveSession.Callbacks {
        let sid = rec.id
        var c = LiveSession.Callbacks()
        c.output = { [weak self] id, data, subs in self?.deliver(id, data, to: subs) }
        c.status = { [weak self] ls, s in
            guard let self, !ls.isFinal else { return }
            // The record as it is now, not the snapshot from when this change was queued: a title set meanwhile stays.
            // The turn bookkeeping gets each change, in order.
            publishHere(ls); ls.noteTurn(s.status, remotes: remotes)
            if s.status == .exited { _ = live.remove(ls) }
        }
        if rec.agent == "claude" { c.limits = { [weak self] r in self?.agentUsage.recordLimits(r) } }
        if rec.agent == "cursor" { c.limits = { [weak self] r in self?.agentUsage.recordPlanHit("cursor", r) } }
        // Naming follows the session however it started (created, or woken from a pause).
        c.firstPrompt = { [weak self] text in self?.autoTitle(session: sid, prompt: text) }
        if !["shell", "custom"].contains(rec.agent ?? "custom") {
            c.topic = { [weak self] t in
                guard let self else { return }
                DispatchQueue.global(qos: .utility).async { self.retitle(session: sid, topic: t) }
            }
        }
        if let worktree {
            // On a remote project's host, the port comes to this Mac first: the page opens here.
            let remote = remotes.of(rec.cwd), forwarded = OSAllocatedUnfairLock<String?>(initialState: nil)
            c.localURL = { [weak self] url in
                guard let remote else { self?.notify(DevServerEvent(worktree: worktree, url: url, session: sid)); return }
                DispatchQueue.global(qos: .utility).async {
                    let (here, spec) = remote.forward(url)
                    forwarded.withLock { $0 = spec }
                    self?.notify(DevServerEvent(worktree: worktree, url: here, session: sid))
                }
            }
            let status = c.status
            c.status = { ls, s in
                status(ls, s)
                if s.status == .exited, let spec = forwarded.withLock({ $0 }) { DispatchQueue.global(qos: .utility).async { remote?.cancel(spec) } }
            }
        }
        return c
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
    /// Under its wake lock, as a wake is: a paused session being opened at this moment can't come back after its record and log
    /// are gone (it would restart an agent for a deleted project and save the record again). A terminal's own tmux session
    /// ends with it unless `keepTmux` (a restart, whose new session attaches to it).
    func discard(_ s: Session, keepTmux: Bool = false) { discard([s], keepTmux: keepTmux) }

    /// Several (a project's, a workspace's) stopped together: one wait for all, not up to 3 s each.
    func discard(_ all: [Session], keepTmux: Bool = false) {
        if !keepTmux { all.forEach(endOwnTmux) }
        wakeLocks.withLocks(all.map(\.id)) {
            let pids = all.compactMap { live.remove($0.id) }.flatMap { ls in hangUpStreams(ls); return ls.discard() }
            Self.waitGone(pids)   // gone before their project or folder goes (SIGKILL after 2 s)
            for s in all {
                do { try store.delete(s) } catch { Log.store.error("couldn't delete session \(s.id, privacy: .public): \(error)") }
                let log = root.appendingPathComponent("history/\(s.id).log")   // none when it never ran
                if FileManager.default.fileExists(atPath: log.path) {
                    Log.store.attempt("removing \(s.id)'s history") { try FileManager.default.removeItem(at: log) }
                }
            }
        }
    }

    /// Every running one, as the daemon stops: paused (a resumable agent comes back paused, not as a second copy) or
    /// ended, its whole tree gone before this returns. None starts or wakes from now on.
    func pauseAll() {
        let manifests = AgentManifest.load(dir: root.appendingPathComponent("agents"))
        Self.waitGone(live.close().flatMap { ls in live.remove(ls.snapshot.id).map { pause($0, manifests) } ?? [] })
    }

    /// Every running one, for the kelpd that takes over (`Daemon.handOver`): out of `live` with its program left running and
    /// its last record saved. One ending right now isn't handed over: its record says what became of it. None starts or
    /// wakes from now on.
    func handOver() -> [Handover.Session] {
        sleepAssertion.withLock { if $0.id != 0 { IOPMAssertionRelease($0.id); $0 = (0, nil) } }   // the next one takes its own
        let all = live.close()
        // What was sent and isn't written yet goes in first (a send's Enter comes 0.3 s behind its text): the program has
        // it before the next kelpd takes over, which couldn't send it.
        DispatchQueue.concurrentPerform(iterations: all.count) { all[$0].drainInput(within: 2) }
        return all.compactMap { ls in
            guard live.remove(ls.snapshot.id) != nil, let fd = ls.pty.handOver() else { return nil }
            publishLast(ls)
            return ls.handedOver(fd: fd)
        }
    }

    /// One the kelpd before this one ran (`Handover`), live here from now on: its program never stopped. One that can't be
    /// (its record gone) is stopped rather than left running unseen.
    func adopt(_ h: Handover.Session) {
        let pty = PTY(adopting: h.pid, fd: h.fd)
        do {
            guard let rec = try store.session(h.id) else { throw RPCError.invalidParams("no session \(h.id)") }
            var m = try manifest(rec.agent, command: nil, fallbackArgv: rec.argv)
            // As `liveManifest`; past startup, nothing is answered for it.
            m = wiredHooks(m, env: hookedEnv(m, rec), argv: rec.argv)
            let ls = LiveSession(record: rec, manifest: m, pty: pty, historyDir: root.appendingPathComponent("history"), callbacks: callbacks(for: rec))
            ls.adopted(modes: h.modes, bytes: h.bytes, pending: h.pending ?? [])
            try live.add(ls)
            ls.start()
        } catch {
            Log.session.error("\(h.id, privacy: .public) wasn't taken over: \(error)")
            pty.terminate(); pty.start()   // start: its exit is reaped
        }
    }

    // MARK: keep awake

    /// keepAwake: "always" | "agents" (only while an agent is working) | "off".
    /// "always" is Caffeine: the screen stays on too. Agents only need the Mac itself, so the screen may still sleep and lock.
    func applyKeepAwake() {
        let mode = settings["power.keepAwake"]?.string ?? "agents"
        let working = live.all.contains { $0.snapshot.status == .working && $0.snapshot.agent != "shell" }
        let want = mode == "always" ? kIOPMAssertPreventUserIdleDisplaySleep
            : mode == "agents" && working ? kIOPMAssertPreventUserIdleSystemSleep : nil
        sleepAssertion.withLock { held in   // the ticker and a settings change at once: one assertion
            guard held.type != want else { return }
            if held.id != 0 { IOPMAssertionRelease(held.id); held = (0, nil) }
            guard let want else { return }
            var id: IOPMAssertionID = 0
            let name = mode == "always" ? "Keep Mac Awake is on in Kelp" : "Kelp agents are working"
            if IOPMAssertionCreateWithName(want as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id) == kIOReturnSuccess {
                held = (id, want)
            }
        }
    }
}
