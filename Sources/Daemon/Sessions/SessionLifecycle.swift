import AgentData
import Agents
import Core
import Foundation
import GRDB
import GitKit

/// Pausing and waking a session, saving and announcing its record, its titles, and what its output tells the daemon
/// (`callbacks`). What it starts with (its manifest, environment, hooks and account) is up to `SessionSetup`.
extension Sessions {
    /// Whether a session is paused, not ended, when its program stops with the daemon or sits idle, and wakes where it
    /// was. That holds for an agent that resumes its conversation, and for a tmux terminal, which a wake reattaches.
    static func resumable(_ session: Session, _ manifests: [AgentManifest]) -> Bool {
        tmuxName(session) != nil || manifests.first { $0.id == session.agent }?.resumeArgs.isEmpty == false
    }

    /// Runs the ticker's round (every 0.5 s): the live sessions with something to do, then what spans them all (sleep,
    /// pauses and updates, which touch sessions at rest too and only read flags). Returns the count of sessions ticked.
    @discardableResult
    func tick(now: Date = Date()) -> Int {
        let ticked = live.all.count { $0.tick() }
        applyKeepAwake()
        if idlePauseDue(now) { hibernateIdle(now: now) }
        updates.restartOutdated()
        return ticked
    }

    /// Pauses agents idle for `hibernateMinutes` with nobody watching, never an agent asking something, because a pause
    /// would end the question unanswered and its Needs You row would say Paused. Tests move `now`, the ticker's clock.
    func hibernateIdle(now: Date = Date()) {
        let minutes = settings[SettingKeys.hibernateMinutes]
        guard minutes > 0 else { return }
        // Only sessions a pause can bring back (`LiveSession.resumable`, known from the start, so the tick reads none).
        let all = live.all.map { ($0, $0.snapshot) }   // each record copied once, under its lock
        let parents = Set(all.compactMap(\.1.parent))   // what their children report next would reach nobody
        let candidates = all.filter { ls, session in
            // A pause also stops what the session left in the background, and a server someone uses isn't idle.
            !parents.contains(session.id) && ls.resumable && [.done, .idle].contains(session.status)
                && session.continueAt == nil && (session.background ?? []).isEmpty && !ls.isAttached
                && ls.idleSeconds(at: now) > minutes * 60
        }.map { ls, _ in (ls, ls.inputs) }
        // Off the ticker: waiting for programs to exit (up to 10 s each) must not hold up status for everyone else.
        let start = pausingIdle.withLock { idle -> Bool in
            guard !idle.busy, !candidates.isEmpty else { return false }
            idle.busy = true
            return true
        }
        guard start else { return }
        Thread.detachNewThread { [self] in
            for (ls, seen) in candidates { pauseIdle(ls, inputs: seen) }
            pausingIdle.withLock { $0.busy = false }
        }
    }

    /// Pauses an idle session under its wake lock, as a wake does, so a wake meanwhile waits until this program is gone
    /// and two never write one log. The session leaves `live` only if nobody attached and no input came since the check
    /// (`seen`), so no input reaches a stopping program. Later input waits for the pause and wakes it (`lettingGo`).
    func pauseIdle(_ ls: LiveSession, inputs seen: Int) {
        let id = ls.snapshot.id
        wakeLocks.withLock(id) {
            guard live.letGo(ls, if: { $0.letGoIdle(seen: seen) }) else { return }
            defer { live.letGone(id) }
            hangUpStreams(ls)   // the check found none; one attached just after ends too
            ls.markHibernated()
            Self.waitGone(ls.pty.terminate())   // SIGKILL after `PTY.grace` for what ignores the hangup: a wake must not start a second copy
            publishLast(ls)
        }
    }

    /// Whether a session is paused, by its record or, when that couldn't be saved (a full disk), by what's known here
    /// (`SessionTable.Phase`).
    func isPaused(_ session: Session) -> Bool {
        if case .paused = live.phase(session.id, record: { session }) { return true }
        return false
    }

    /// Brings a paused session back under the same id (layout and links stay), resuming its conversation, or one whose
    /// host connection dropped (`connectionLost`), attached again to its tmux session there with its turns kept.
    func wake(_ id: String, cols: UInt16 = 120, rows: UInt16 = 32) throws -> LiveSession {
        wakeTries.withLock { $0 += 1 }
        guard var rec = try store.session(id) else { throw RPCError.noSession(id) }
        guard isPaused(rec) || rec.connectionLost else { throw RPCError.notRunning(id) }
        rec.exitCode = nil
        let manifest = try setup.manifest(rec.agent, command: nil, fallbackArgv: rec.argv)
        let argv = setup.resumeArgv(rec, manifest)
        rec.argv = argv   // the conversation it found is this session's from now on
        let env = setup.launchEnv(manifest, rec)
        rec.status = .idle
        let ls = try LiveSession(
            record: rec,
            manifest: setup.liveManifest(manifest, cwd: rec.cwd, worktreeId: rec.worktreeId, env: env, argv: argv),
            argv: try setup.launchArgv(argv, cwd: rec.cwd, manifest: manifest, tmux: rec.tmux, env: env), env: env,
            historyDir: root.appendingPathComponent("history"), cols: cols, rows: rows,
            callbacks: callbacks(for: rec, limits: manifest.limitScreen))
        if rec.tmux != nil { ls.attachedToRunning() }
        do { try live.add(ls) } catch {   // its record stays paused
            ls.discard()
            ls.start()
            throw error
        }
        giveBackOwed(ls)
        publish(ls)
        ls.start()
        return ls
    }

    /// Makes the conversation the hooks name the one the session continues. After /resume or /clear in Claude Code, a
    /// wake must bring back that conversation, not the id Kelp started with (an old conversation under the new title).
    func follow(_ ls: LiveSession, transcript: String) {
        let conversation = URL(fileURLWithPath: transcript).deletingPathExtension().lastPathComponent
        let session = ls.snapshot
        // Only a conversation's own file counts (a subagent's is agent-….jsonl); the manifest is read when changed.
        guard UUID(uuidString: conversation) != nil,
            !session.argv.contains(where: { $0.lowercased() == conversation.lowercased() }),
            let manifest = try? setup.manifest(session.agent, command: nil, fallbackArgv: session.argv)
        else { return }
        let argv = manifest.following(session.argv, conversation: conversation)
        guard argv != session.argv else { return }
        _ = ls.update { $0.argv = argv }
        publish(ls)
    }

    /// Saves a running session's record as it is when written, in order with its status changes (see LiveSession.emit).
    /// A copy taken on a request's thread could otherwise land after a newer status and put an old one back. The
    /// closure holds the session until it ran, so a session that just ended and left `live` still has its record saved.
    func publish(_ ls: LiveSession) {
        ls.inOrder { [weak self] in
            guard let self, !ls.isFinal else { return }
            save(ls)
        }
    }

    /// Saves the record right away; call it on the session's status queue itself (its status callback). Queued again,
    /// the save would land after a pause queued meanwhile, and over the record of the wake that followed.
    func publishHere(_ ls: LiveSession) { if !ls.isFinal { save(ls) } }

    /// Saves and announces a pause or an end now, after every status change queued before it. A change that read the
    /// record just before would otherwise write "working" over it, and a paused agent would never wake.
    func publishLast(_ ls: LiveSession) {
        let done = DispatchSemaphore(value: 0)
        ls.inOrder { [self] in
            save(ls)
            ls.finish()
            done.signal()
        }
        done.wait()
    }

    /// Changes a session's record wherever it lives: a running session's in its LiveSession, published from there, and
    /// any other's in the store, then announced. With `publish(ls)` for a running session's own changes, these are the
    /// only ways a record is written and sent. It runs under the session's wake lock (`held`: the caller has it), so a
    /// paused record read and saved back here can't land over a wake started meanwhile, whose live record counts.
    func edit(_ id: String, held: Bool = false, _ body: @escaping @Sendable (inout Session) -> Void) throws {
        func apply() throws {
            if let ls = existing(id) {
                if ls.change(body) { publish(ls) }
            } else if let session = try store.update(Session.self, id, body) {
                said(session)
            }
        }
        if held { try apply() } else { try wakeLocks.withLock(id, apply) }
    }

    /// Marks a session read or unread, live or not. An agent that ended or paused unread can be read at a glance too
    /// (its record only).
    func setUnread(_ id: String, _ on: Bool) throws { try edit(id) { $0.unread = on } }

    /// Call it only on the session's status queue (`publish(ls)`, `publishLast`), where the snapshot is the latest. The
    /// saved revision goes back into the running record before anyone hears of it. `session.list` gives that record,
    /// and the app drops a record older than its copy, so otherwise a list read after a reconnect would miss a change.
    private func save(_ ls: LiveSession) {
        let saved: Session
        do { saved = try store.update(ls.snapshot) } catch {
            // A session deleted meanwhile (closed, its project removed) isn't brought back. Any other error (a full
            // disk) is logged, and the change is still news, because the row, reports and waits follow what happened,
            // not what reached the disk.
            guard !(error is RecordError) else { return }
            Log.store.error("couldn't save session \(ls.snapshot.id, privacy: .public): \(error)")
            let unsaved = ls.snapshot
            live.saved(unsaved.id, paused: unsaved.status == .paused, written: false)
            said(unsaved)
            return
        }
        live.saved(saved.id, paused: saved.status == .paused, written: true)
        let revision = saved.revision
        _ = ls.update { $0.revision = revision }
        said(saved)
    }

    private func said(_ session: Session) {
        notify(session)
        let turn = session.status.rawValue   // a turn ended or began: news for its context and its (slowed) work map
        [WatchTopic.context, .work].forEach { watches.touched(.init(topic: $0, key: session.id), tag: turn) }
        if let ls = existing(session.id) { touchCommands(ls) }   // a command may end with its turn or its program
        if let agent = session.agent, [.working, .done, .waiting].contains(session.status) {
            agentUsage.planSeen(agent, working: session.status == .working)
            if session.status != .working { agentUsage.planUsed(agent) }
        }
        familyHeard(session)
        events.heard(session)
        phone.hear(.session(session))
    }

    /// The session's edits (and, below, its commands) changed, so whoever watches them reads them again.
    func touchEdits(_ ls: LiveSession) {
        watches.touched(.init(topic: .edits, key: ls.snapshot.id), tag: "\(ls.lastEdit.count)")
    }

    func touchCommands(_ ls: LiveSession) {
        watches.touched(.init(topic: .commands, key: ls.snapshot.id), tag: "\(ls.commandChanges)")
    }

    /// Name a session (and optionally its fresh branch) from the first prompt; a manual title always wins.
    /// Runs git: call it off the cooperative pool (it's called on GCD).
    func autoTitle(session id: String, prompt: String) {
        guard let ls = existing(id), !ls.snapshot.titleManual, ls.topic == nil else { return }   // the agent's own topic is better
        let title = Naming.title(prompt)
        let session = ls.update { if !$0.titleManual { $0.title = title } }
        publish(ls)
        guard let wid = session.worktreeId else { return }
        do {
            let renamed = try store.update(Worktree.self, wid) { worktree in
                if worktree.note.range(of: Workspaces.placeholderName, options: .regularExpression) != nil {
                    worktree.note = title
                }
            }
            if renamed?.note == title { notify(ChangedEvent.worktree) }
            try nameBranch(wid, prompt: prompt, title: title)
        } catch {
            Log.session.error("couldn't name the workspace of \(id, privacy: .public) from its first prompt: \(error)")
        }
    }

    /// Settings › Git: what goes before the branches Kelp names.
    var branchPrefix: String { settings[SettingKeys.branchPrefix] }

    /// A placeholder branch (task-123, wip, new-worktree…) gets a real name from what the agent was asked to do. The
    /// folder and the record agree afterwards either way, because a failed save puts the old branch name back.
    private func nameBranch(_ wid: String, prompt: String, title: String) throws {
        guard let worktree = try store.worktree(wid),
            worktree.branch.range(
                of: #"^(task|wip|tmp|new|new-worktree|untitled|ws)(-\d+)?$"#, options: .regularExpression)
                != nil,
            let repo = try store.repo(worktree.repoId), worktree.path != repo.path
        else { return }
        let slug = Naming.slug(prompt)
        guard !slug.isEmpty else { return }
        let base = branchPrefix + slug, folders = Git.checkouts(project: repo.path, folder: worktree.path).map(\.folder)
        var branch = base, number = 2
        while folders.contains(where: { Git.branchExists($0, branch, remotes: remotes) }) {
            branch = "\(base)-\(number)"
            number += 1
        }
        try Git.renameBranch(in: folders, from: worktree.branch, to: branch, remotes: remotes)
        do {
            try store.update(Worktree.self, worktree.id) {
                $0.branch = branch
                if $0.note.isEmpty { $0.note = title }
            }
        } catch {
            do { try Git.renameBranch(in: folders, from: branch, to: worktree.branch, remotes: remotes) } catch {
                let recorded = worktree.branch
                Log.session.error(
                    "branch \(branch, privacy: .public) kept, its record says \(recorded, privacy: .public): \(error)")
            }
            throw error
        }
        notify(ChangedEvent.worktree)
    }

    /// The agent's own short topic (Claude Code's terminal title) names the session instead of its prompt, and its
    /// workspace while that still has the name the session gave it (or a placeholder). A title set by hand stays.
    func retitle(session id: String, topic: String) {
        guard let ls = existing(id), !ls.snapshot.titleManual, ls.snapshot.title != topic else { return }
        let old = ls.snapshot.title
        let session = ls.update { if !$0.titleManual { $0.title = topic } }
        publish(ls)
        let renamed =
            Log.store.attempt("naming the workspace after its first prompt") {
                try store.update(Worktree.self, session.worktreeId ?? "") { worktree in
                    if (!old.isEmpty && worktree.note == old)
                        || worktree.note.range(of: Workspaces.placeholderName, options: .regularExpression) != nil
                    {
                        worktree.note = topic
                    }
                }
            } ?? nil
        if renamed?.note == topic { notify(ChangedEvent.worktree) }
    }

    /// Pauses a workspace going out of sight, with nothing lost: agents that can resume their conversation pause, the
    /// rest stop, and its tabs stay. Returns once their programs are gone, so nothing writes into the folder after.
    func pauseSessions(of wid: String) throws {
        let manifests = AgentManifest.load(dir: Paths.agents(in: root))
        var pids: [pid_t] = []
        // This runs under their wake locks, as idle pausing does, so a wake that comes meanwhile waits until the
        // programs are gone instead of starting a second one (on the same log, in a folder about to be removed).
        let sessions = try store.sessions().filter { $0.worktreeId == wid }
        wakeLocks.withLocks(sessions.map(\.id)) {
            for s in sessions { if let ls = live.remove(s.id) { pids += pause(ls, manifests) } }
            Self.waitGone(pids)
        }
    }

    /// Pauses one session as a workspace pauses, to come back with its conversation when shown (a chat moved away).
    func pauseOne(_ id: String) {
        let manifests = AgentManifest.load(dir: Paths.agents(in: root))
        wakeLocks.withLocks([id]) {
            if let ls = live.remove(id) { Self.waitGone(pause(ls, manifests)) }
        }
    }

    /// Pauses a session already out of `live`: recorded as paused (a resumable agent) or ended, saved and announced now
    /// since nothing records its exit any more, then stopped with all it started. Returns its pids for `waitGone`.
    func pause(_ ls: LiveSession, _ manifests: [AgentManifest]) -> [pid_t] {
        hangUpStreams(ls)
        let comesBack = Self.resumable(ls.snapshot, manifests)
        if comesBack { ls.markHibernated() } else { ls.overrideStatus(.exited) }
        publishLast(ls)
        if comesBack {
            Log.session.attempt("keeping what \(ls.snapshot.id) hadn't typed") { try store.owe(ls.takeOwed()) }
        }
        return ls.pty.terminate()   // SIGKILL after `PTY.grace` for what ignores the hangup, which waitGone waits for
    }

    /// Gives the session the input that waited in the store while it didn't run.
    func giveBackOwed(_ ls: LiveSession) {
        let id = ls.snapshot.id
        ls.giveBack(Log.session.attempt("reading what \(id) hadn't typed") { try store.takeOwed(id) } ?? [])
    }

    /// Waits until these processes have exited and are reaped. A process ignoring the hangup gets SIGKILL 2 s later,
    /// from a timer a busy machine runs late, so the wait gives up only after 10 s (a process stuck in the kernel).
    static func waitGone(_ pids: [pid_t]) {
        let end = Date().addingTimeInterval(10)
        while Date() < end, pids.contains(where: { kill($0, 0) == 0 }) { usleep(20_000) }
    }

    /// What a session tells the daemon, from its first byte on. An ended session leaves `live`, because its fd and pid
    /// belong to nobody now, and its log still shows what it printed. With `devServerIn`, the first local URL the
    /// session prints opens in that workspace's browser.
    func callbacks(
        for rec: Session, limits screen: AgentManifest.LimitScreen?, devServerIn worktree: String? = nil
    ) -> LiveSession.Callbacks {
        let sid = rec.id
        var callbacks = LiveSession.Callbacks()
        callbacks.output = { [weak self] id, data, subs in self?.deliver(id, data, to: subs) }
        callbacks.status = { [weak self] ls, snapshot in
            guard let self, !ls.isFinal else { return }
            // The record as it is now, not the snapshot from when this change was queued: a title set meanwhile stays.
            // The turn bookkeeping gets each change, in order.
            publishHere(ls)
            ls.noteTurn(snapshot.status, remotes: remotes)
            // A question answered in the terminal lets its hook go with no answer. The status read is the current one,
            // because a change queued before a new question's hook registered its wait mustn't end that wait.
            if ls.snapshot.status != .waiting { permissions.answerPermission(sid, nil) }
            if snapshot.status == .exited { _ = live.remove(ls) }
        }
        switch screen {
        case .claude: callbacks.limits = { [weak self] r in self?.agentUsage.recordLimits(r) }
        case .cursor: callbacks.limits = { [weak self] r in self?.agentUsage.recordPlanHit(rec.agent ?? "", r) }
        case .codex, nil: break   // Codex's usage comes from its app-server: its screen only says the plan ran out
        }
        // Naming follows the session however it started (created, or woken from a pause).
        callbacks.firstPrompt = { [weak self] text in self?.autoTitle(session: sid, prompt: text) }
        callbacks.turnStarted = { [weak self] t, staged in self?.turns.keep(t, staged: staged) }
        callbacks.turnEnded = { [weak self] prompt, sent in
            self?.keepArtifactVersions(session: sid, worktree: rec.worktreeId, prompt: prompt, sent: sent)
        }
        if rec.isAgent {
            callbacks.topic = { [weak self] topic in
                guard let self else { return }
                DispatchQueue.global(qos: .utility).async { self.retitle(session: sid, topic: topic) }
            }
        }
        if let worktree {
            // On a remote project's host, the port comes to this Mac first: the page opens here.
            let remote = remotes.of(rec.cwd)
            callbacks.localURL = { [weak self] url in
                guard let self else { return }
                guard let remote else {
                    notify(DevServerEvent(worktree: worktree, url: url, session: sid))
                    return
                }
                DispatchQueue.global(qos: .utility).async {
                    self.notify(
                        DevServerEvent(
                            worktree: worktree, url: self.processes.forwards.forward(url: url, in: worktree, remote),
                            session: sid
                        ))
                }
            }
            callbacks.busyPort = { [weak self] port in
                self?.notify(PortBusyEvent(worktree: worktree, port: port, session: sid))
            }
        }
        return callbacks
    }
}
