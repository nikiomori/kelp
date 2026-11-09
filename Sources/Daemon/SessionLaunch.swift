import AgentData
import Agents
import Core
import Foundation
import GRDB
import GitKit

/// Pausing and waking a session, its record saved and said, and its titles. What it starts with (its manifest,
/// environment, hooks and account) is `SessionSetup`'s.
extension Sessions {
    /// Paused rather than ended when its program stops with the daemon or sits idle, and back where it was when woken: an
    /// agent that resumes its conversation, a tmux terminal (tmux keeps the session, the wake attaches again).
    static func resumable(_ session: Session, _ manifests: [AgentManifest]) -> Bool {
        tmuxName(session) != nil || manifests.first { $0.id == session.agent }?.resumeArgs.isEmpty == false
    }

    /// The ticker's round (every 0.5 s): the live sessions with something to do, then what spans them all (sleep, pauses
    /// and updates are for sessions at rest too, and read flags only). How many sessions were ticked.
    @discardableResult
    func tick() -> Int {
        let ticked = live.all.count { $0.tick() }
        applyKeepAwake()
        hibernateIdle()
        updates.restartOutdated()
        return ticked
    }

    /// Pause agents that have sat idle for `hibernateMinutes` with nobody watching. Not one that asks something: the pause would
    /// end the question unanswered, and its row, Needs You until then, would say Paused. `now`: the ticker's clock; a
    /// test moves it instead of waiting.
    func hibernateIdle(now: Date = Date()) {
        let minutes = settings[SettingKeys.hibernateMinutes]
        guard minutes > 0 else { return }
        // Only one a pause can bring back (`LiveSession.resumable`, known since its start: nothing is read on the tick).
        let parents = Set(live.all.compactMap(\.snapshot.parent))   // what their children say next would find nobody
        let candidates = live.all.filter { ls in
            // A pause stops what it left in the background too: a server someone uses isn't idle.
            !parents.contains(ls.snapshot.id) && ls.resumable && [.done, .idle].contains(ls.snapshot.status)
                && ls.snapshot.continueAt == nil
                && (ls.snapshot.background ?? []).isEmpty
                && !ls.isAttached && ls.idleSeconds(at: now) > minutes * 60
        }.map { ($0, $0.inputs) }
        // Off the ticker: waiting for programs to exit (up to 3 s each) must not hold up status for everyone else.
        let start = pausingIdle.withLock { busy -> Bool in
            guard !busy, !candidates.isEmpty else { return false }
            busy = true
            return true
        }
        guard start else { return }
        Thread.detachNewThread { [self] in
            for (ls, seen) in candidates { pauseIdle(ls, inputs: seen) }
            pausingIdle.withLock { $0 = false }
        }
    }

    /// Under its wake lock, as a wake is: one that comes meanwhile waits until this program is gone, so two never write one
    /// log. Taken out of `live` only if nobody attached and no input came since the check (`seen`): input never goes to a
    /// program that's about to be stopped. Input that comes once it's out waits for the pause and wakes it (`pausing`).
    func pauseIdle(_ ls: LiveSession, inputs seen: Int) {
        let id = ls.snapshot.id
        pausing.withLock { _ = $0.insert(id) }
        defer { pausing.withLock { _ = $0.remove(id) } }
        wakeLocks.withLock(id) {
            guard live.remove(ls, if: { $0.letGoIdle(seen: seen) }) else { return }
            hangUpStreams(ls)   // none by the check; one that came just after it ends too
            ls.markHibernated()
            Self.waitGone(ls.pty.terminate())   // SIGKILL after 2 s for what ignores the hangup: a wake must not start a second copy
            publishLast(ls)
        }
    }

    /// Paused, by its record or, when that couldn't be saved (a full disk), by what's known here.
    func isPaused(_ session: Session) -> Bool {
        session.status == .paused || pausedUnsaved.withLock { $0.contains(session.id) }
    }

    /// Bring a paused session back under the same id (layout and links stay), resuming its conversation.
    func wake(_ id: String, cols: UInt16 = 120, rows: UInt16 = 32) throws -> LiveSession {
        wakeTries.withLock { $0 += 1 }
        guard var rec = try store.session(id), isPaused(rec) else {
            throw RPCError.invalidParams("no live session \(id)")
        }
        let manifest = try setup.manifest(rec.agent, command: nil, fallbackArgv: rec.argv)
        let argv = setup.resumeArgv(rec, manifest)
        rec.argv = argv   // the conversation it found is this session's from now on
        let env = setup.launchEnv(manifest, rec)
        rec.status = .idle
        let ls = try LiveSession(
            record: rec,
            manifest: setup.liveManifest(manifest, cwd: rec.cwd, worktreeId: rec.worktreeId, env: env, argv: argv),
            argv: try setup.launchArgv(argv, cwd: rec.cwd, manifest: manifest, tmux: rec.tmux), env: env,
            historyDir: root.appendingPathComponent("history"), cols: cols, rows: rows, callbacks: callbacks(for: rec))
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

    /// The conversation its hooks name is the one it continues: after /resume or /clear in Claude Code, a wake must bring
    /// back that one, not the id Kelp started it with (an old conversation under the new one's title).
    func follow(_ ls: LiveSession, transcript: String) {
        let conversation = URL(fileURLWithPath: transcript).deletingPathExtension().lastPathComponent
        let session = ls.snapshot
        // Only a conversation's own file (a subagent's is agent-….jsonl), and the manifest read only when it changed: hooks come every turn.
        guard UUID(uuidString: conversation) != nil,
            !session.argv.contains(where: { $0.lowercased() == conversation.lowercased() }),
            let manifest = try? setup.manifest(session.agent, command: nil, fallbackArgv: session.argv)
        else { return }
        let argv = manifest.following(session.argv, conversation: conversation)
        guard argv != session.argv else { return }
        _ = ls.update { $0.argv = argv }
        publish(ls)
    }

    /// A running session's record as it is when written, in order with its status changes (see LiveSession.emit): a copy
    /// taken on a request's thread could otherwise land after a newer status and put an old one back.
    /// Holds the session until it ran: one that just ended and left `live` still gets its last record saved.
    func publish(_ ls: LiveSession) {
        ls.inOrder { [weak self] in
            guard let self, !ls.isFinal else { return }
            save(ls)
        }
    }

    /// On the session's status queue itself (its status callback): saved there and then. Queued again it would land after
    /// a pause queued meanwhile, and over the record of the wake that followed.
    func publishHere(_ ls: LiveSession) { if !ls.isFinal { save(ls) } }

    /// A pause or an end, saved and said now, after every status change queued before it: one that read the record just
    /// before would otherwise write "working" over it, and a paused agent would never wake.
    func publishLast(_ ls: LiveSession) {
        let done = DispatchSemaphore(value: 0)
        ls.inOrder { [self] in
            save(ls)
            ls.finish()
            done.signal()
        }
        done.wait()
    }

    /// A session that isn't running, changed in the store and said. A running one changes in its LiveSession and is
    /// published from there (`publish(ls)`): these are the only ways a session's record is written and sent.
    /// Read or unread, live or not: an agent that ended or paused unread is read at a glance too (its record only).
    func setUnread(_ id: String, _ on: Bool) throws {
        try wakeLocks.withLock(id) {   // not woken meanwhile: then the live session's own record would be the one
            if let ls = existing(id) {
                if ls.setUnread(on) != nil { publish(ls) }
            } else {
                try change(id) { $0.unread = on }
            }
        }
    }

    func change(_ id: String, _ body: (inout Session) -> Void) throws {
        if let session = try store.update(Session.self, id, body) { said(session) }
    }

    /// Only on the session's status queue (`publish(ls)`, `publishLast`), where the snapshot is the latest.
    /// Its revision goes back into the running record before anyone hears of it: `session.list` gives that record, and one
    /// older than the app's copy is dropped, so a list read after a reconnect couldn't bring back a change it missed.
    private func save(_ ls: LiveSession) {
        let saved: Session
        do { saved = try store.update(ls.snapshot) } catch {
            // Deleted meanwhile (closed, its project removed): not brought back. Anything else (a full disk) is logged, and
            // the change is still news: the row, reports and waits follow what happened, not what reached the disk.
            guard !(error is RecordError) else { return }
            Log.store.error("couldn't save session \(ls.snapshot.id, privacy: .public): \(error)")
            let unsaved = ls.snapshot
            pausedUnsaved.withLock {
                if unsaved.status == .paused { $0.insert(unsaved.id) } else { $0.remove(unsaved.id) }
            }
            said(unsaved)
            return
        }
        if saved.status != .paused { pausedUnsaved.withLock { _ = $0.remove(saved.id) } }
        let revision = saved.revision
        _ = ls.update { $0.revision = revision }
        said(saved)
    }

    private func said(_ session: Session) {
        notify(session)
        // a turn ended or began: how full now
        watches.touched(.init(topic: .context, key: session.id), tag: session.status.rawValue)
        if let ls = existing(session.id) { touchCommands(ls) }   // one ended with its turn or its program
        if session.status == .done || session.status == .waiting, let agent = session.agent {
            agentUsage.planUsed(agent)
        }
        familyHeard(session)
        events.heard(session)
    }

    /// Its commands changed: whoever watches them reads them again.
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

    /// A placeholder branch (task-123, wip, new-worktree…) gets a real name from what the agent was asked to do. Folder
    /// and record agree after it either way: a record that couldn't be saved puts the folder's old name back.
    private func nameBranch(_ wid: String, prompt: String, title: String) throws {
        guard let worktree = try store.worktree(wid),
            worktree.branch.range(
                of: #"^(task|wip|tmp|new|new-worktree|untitled|ws)(-\d+)?$"#, options: .regularExpression)
                != nil,
            let repo = try store.repo(worktree.repoId), worktree.path != repo.path
        else { return }
        let slug = Naming.slug(prompt)
        guard !slug.isEmpty else { return }
        let base = branchPrefix + slug
        var branch = base, number = 2
        while Git.branchExists(repo.path, branch, remotes: remotes) {
            branch = "\(base)-\(number)"
            number += 1
        }
        try Git.renameBranch(worktree.path, from: worktree.branch, to: branch, remotes: remotes)
        do {
            try store.update(Worktree.self, worktree.id) {
                $0.branch = branch
                if $0.note.isEmpty { $0.note = title }
            }
        } catch {
            do { try Git.renameBranch(worktree.path, from: branch, to: worktree.branch, remotes: remotes) } catch {
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

    /// Closing a workspace ends its agents and forgets its layout; the folder is untouched. The last one stays.
    /// Out of sight, nothing lost: its agents pause (they resume their conversations when it comes back), its tabs stay.
    /// A workspace going out of sight: agents that can resume their conversation pause (they come back with it), the
    /// rest stop. Returns once their programs are gone, so nothing writes into the folder after this.
    func pauseSessions(of wid: String) throws {
        let manifests = AgentManifest.load(dir: root.appendingPathComponent("agents"))
        var pids: [pid_t] = []
        // Under their wake locks, as idle pausing is: a wake that comes meanwhile waits until the programs are gone instead
        // of starting a second one (on the same log, in a folder about to be removed).
        let sessions = try store.sessions().filter { $0.worktreeId == wid }
        wakeLocks.withLocks(sessions.map(\.id)) {
            for s in sessions { if let ls = live.remove(s.id) { pids += pause(ls, manifests) } }
            Self.waitGone(pids)
        }
    }

    /// A session already out of `live`: recorded as paused (a resumable agent) or ended — said here and saved now, since
    /// nothing records its exit any more — then stopped with all it started. Its pids, for `waitGone`.
    func pause(_ ls: LiveSession, _ manifests: [AgentManifest]) -> [pid_t] {
        hangUpStreams(ls)
        let comesBack = Self.resumable(ls.snapshot, manifests)
        if comesBack { ls.markHibernated() } else { ls.overrideStatus(.exited) }
        publishLast(ls)
        if comesBack {
            Log.session.attempt("keeping what \(ls.snapshot.id) hadn't typed") { try store.owe(ls.takeOwed()) }
        }
        return ls.pty.terminate()   // SIGKILL after 2 s for what ignores the hangup, which waitGone waits for
    }

    /// What waited in the store while it didn't run.
    func giveBackOwed(_ ls: LiveSession) {
        let id = ls.snapshot.id
        ls.giveBack(Log.session.attempt("reading what \(id) hadn't typed") { try store.takeOwed(id) } ?? [])
    }

    /// Until these processes have exited and are reaped. What ignores the hangup gets SIGKILL 2 s after it, from a
    /// timer a busy machine runs late: given up on only after 10 s, for one even that doesn't end (stuck in the kernel).
    static func waitGone(_ pids: [pid_t]) {
        let end = Date().addingTimeInterval(10)
        while Date() < end, pids.contains(where: { kill($0, 0) == 0 }) { usleep(20_000) }
    }
}
