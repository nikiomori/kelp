import AgentData
import Agents
import Core
import Foundation
import GitKit
import os

// Sessions: listing, attaching, typing into, stopping, reading.

extension SessionList: Handled {
    static var quick: Bool { true }
    func handle(_ sessions: Sessions) throws -> [Session] {
        let all = try sessions.store.sessions().map { s -> Session in sessions.existing(s.id)?.snapshot ?? s }
        return all.filter { worktreeId == nil || $0.worktreeId == worktreeId }
    }
}

extension SessionAttach: Handled {
    func handle(_ sessions: Sessions) throws -> Result { try handle(sessions, conn: -1) }
    func handle(_ sessions: Sessions, conn: Int) throws -> Result {
        if sessions.existing(id) == nil, try sessions.store.session(id)?.status == .exited {   // ended: what it last printed, from its log
            return Result(
                history: TerminalReplies.withoutQueries(try sessions.liveSessionOrLog(id, bytes: LiveSession.ringLimit))
                    .base64EncodedString())
        }
        // Showing a tab isn't reading it: the app marks it read once it was looked at (or typed into).
        guard let history = try sessions.liveSession(id).attach(conn) else { throw Sessions.pausedAsAttached }
        return Result(history: history.base64EncodedString())
    }
}

extension SessionDetach: Handled {
    func handle(_ sessions: Sessions) throws -> Done { try handle(sessions, conn: -1) }
    func handle(_ sessions: Sessions, conn: Int) throws -> Done {
        sessions.existing(id)?.detach(conn)
        return Done()
    }
}

extension SessionWrite: SessionInput {
    static var inOrder: Bool { true }   // keystrokes
    var actsOn: String? { id }
    var typesInto: String? { id }
    func apply(to session: LiveSession) throws -> Done {
        let data: Data
        if let base64, let decoded = Data(base64Encoded: base64) {
            data = decoded
        } else if let text {
            data = Data(text.utf8)
        } else {
            throw RPCError.invalidParams("missing text")
        }
        // Keystrokes count as the user's typing; text goes to the program as it is.
        if base64 != nil { session.userInput(data) } else { session.write(data) }
        return Done()
    }
}

extension SessionSend: SessionInput {
    /// Two sends in a row reach the session in that order (`submit` only queues: nothing here waits on the agent).
    static var inOrder: Bool { true }
    var actsOn: String? { id }
    /// An agent's send to a session that asks something (a hookless agent's "(y/n)" read off its screen included) is
    /// refused, not queued: `submit` holds text only for a question an agent said, and its Enter would answer this one.
    var typesInto: String? { id }
    func apply(to session: LiveSession) throws -> Done {
        // Still starting (woken just now, by this send or anyone else), a question open, an unread draft in the box, or
        // text still waiting ahead: queued, and typed once the program is ready for it (`LiveSession.submit`). A paused
        // one wakes on its lane, not on the reader thread (`SessionInput`).
        try session.submit(text, enter: enter != false)
        return Done()
    }
}

/// A running one only: a size never wakes a paused agent (a wake gets the size it's shown at anyway).
extension SessionResize: Handled {
    static var inOrder: Bool { true }
    func handle(_ sessions: Sessions) throws -> Done {
        let (width, height) = Sessions.Launch.size(cols: cols, rows: rows)
        sessions.existing(id)?.resize(cols: width, rows: height)
        return Done()
    }
}

/// Under its wake lock, as waking is: a paused session marked ended here can't be woken halfway through, nor this kill land
/// on the old copy while a wake starts a new one.
extension SessionKill: Handled {
    var actsOn: String? { id }
    func handle(_ sessions: Sessions) throws -> Done {
        // A remote agent's tmux session ends with it, and its record then names none: it reads as ended, not as an agent
        // still running on the host (`connectionLost`). The live record too, before its exit is saved.
        let before = try sessions.store.session(id)
        try sessions.wakeLocks.withLock(id) {
            if let ls = sessions.existing(id) {
                _ = ls.update { $0.tmux = nil }
                ls.pty.terminate()
            } else if try sessions.store.session(id)?.status == .paused {
                try sessions.change(id) { $0.status = .exited }
            }   // don't wake just to kill
        }
        guard let before else { return Done() }
        sessions.endOwnTmux(before)
        if before.tmux != nil { try sessions.change(id) { $0.tmux = nil } }
        return Done()
    }
}

extension SessionChoose: Handled {
    var actsOn: String? { id }
    var answersQuestion: Bool { true }
    func handle(_ sessions: Sessions) throws -> Bool {
        guard let ls = sessions.existing(id) else { return false }
        // A question cut short (a long or many-line command) is answered where it shows whole: in the agent's dialog.
        if let question, !Hooks.shownWhole(question) { return false }
        // Its hook waits for the answer (`session.permissionWait`): given there, not typed into the menu. A banner's answer
        // goes only to the question it showed: the hook waiting now may be a newer one's.
        if ls.asks(question), sessions.permissions.answerPermission(id, answer == "allow" ? "allow" : "deny") {
            _ = ls.answeredThroughHook()
            sessions.publish(ls)
            return true
        }
        guard ls.choose(answer, to: question) != nil else { return false }
        sessions.publish(ls)
        return true
    }
}

extension SessionPermissionWait: AsyncHandled {
    var reportsFor: String? { id }   // only the session's own hook waits for its answer
    func handle(_ permissions: PermissionWaits) async throws -> String? {
        await permissions.waitForPermission(id, within: 600)
    }
}

/// Permission questions' hooks waiting for Allow or Deny, by session (`session.permissionWait`).
final class PermissionWaits: Sendable {
    let waits = OSAllocatedUnfairLock<[String: (UUID, CheckedContinuation<String?, Never>)]>(initialState: [:])

    /// The hook of `id`'s permission question, waiting for Allow or Deny; a newer one lets the older go with no answer.
    func waitForPermission(_ id: String, within seconds: TimeInterval) async -> String? {
        let token = UUID()
        return await withCheckedContinuation { continuation in
            waits.withLock { w in w.updateValue((token, continuation), forKey: id) }?.1.resume(returning: nil)
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.answerPermission(id, nil, only: token)
            }
        }
    }

    /// Hands `answer` to the hook waiting for `id`'s question (nil: none, it went on otherwise); whether one was waiting.
    @discardableResult
    func answerPermission(_ id: String, _ answer: String?, only token: UUID? = nil) -> Bool {
        let waiting = waits.withLock { waits -> CheckedContinuation<String?, Never>? in
            guard let (waitToken, continuation) = waits[id], token == nil || waitToken == token else { return nil }
            waits[id] = nil
            return continuation
        }
        waiting?.resume(returning: answer)
        return waiting != nil
    }
}

extension AgentSetSecret: Handled {
    func handle(_: NoService) throws -> Done {
        let account = AgentManifest.secretAccount(agent: agent, key: key)
        if let value, !value.isEmpty { try Keychain.set(value, account: account) } else { Keychain.delete(account) }
        return Done()
    }
}

extension PortsList: Handled {
    func handle(_ processes: SessionProcesses) throws -> [Port] { processes.ports(worktree: worktreeId) }
}
extension SessionUsage: Handled {
    func handle(_ processes: SessionProcesses) throws -> [Usage] { processes.usage() }
}

extension PortsStop: Handled {
    var inWorkspace: String? { worktreeId }   // said, not left to the walk: it stops a process, and an id of no workspace finds none
    func handle(_ processes: SessionProcesses) throws -> Done {
        let pid = Int32(clamping: pid ?? 0)
        guard pid > 0, processes.ports(worktree: worktreeId).contains(where: { $0.pid == pid }) else {
            throw RPCError.invalidParams("That process isn't running in this workspace.")
        }
        if let (_, remote) = processes.remote(worktreeId) {
            _ = try Git.run(
                remote.sshArgs(tty: false) + ["kill \(pid)"], cwd: NSHomeDirectory(), executable: remote.ssh)
        } else {
            kill(pid, SIGTERM)
        }
        return Done()
    }
}

extension PortsForward: Handled {
    func handle(_ processes: SessionProcesses) throws -> Forwarded {
        guard let (worktree, remote) = processes.remote(worktreeId) else {
            throw RPCError.invalidParams("Only a remote project's ports are forwarded.")
        }
        let forwards = processes.forwards
        let goal = try target.map(Forwards.target) ?? port.map { forwards.target(port: $0, in: worktree.id) }
        guard let goal else { throw RPCError.invalidParams("missing port") }
        return Forwarded(port: try forwards.forward(goal, in: worktree.id, remote, manual: target != nil))
    }
}

extension PortsUnforward: Handled {
    func handle(_ processes: SessionProcesses) throws -> Done {
        if let (worktree, remote) = processes.remote(worktreeId) {
            processes.forwards.drop(port: port, in: worktree.id, remote)
        }
        return Done()
    }
}

extension SessionBusy: Handled {
    func handle(_ sessions: Sessions) throws -> String? {
        guard let ls = sessions.existing(id) else { return nil }
        // In a terminal's own tmux session tmux is always in front: what runs is in its panes (closing ends them).
        if let name = Tmux.session(ls.snapshot.argv), Tmux.isOwn(name) {
            return sessions.tmuxBusy(name, cwd: ls.snapshot.cwd)
        }
        return ls.pty.foregroundProgram
    }
}

extension SessionCommands: Handled {
    static var quick: Bool { true }
    func handle(_ sessions: Sessions) throws -> [AgentCommand] { sessions.existing(id)?.commands ?? [] }
}
extension SessionWhy: Handled {
    static var quick: Bool { true }
    func handle(_ sessions: Sessions) throws -> String? { sessions.existing(id)?.statusWhy }
}
extension SessionTrail: Handled {
    func handle(_ sessions: Sessions) throws -> String {
        guard let trail = try sessions.trail(id) else { throw RPCError.invalidParams("no session \(id)") }
        return trail.read()
    }
}
extension SessionRead: Handled {
    func handle(_ sessions: Sessions) throws -> String { try sessions.printed(id, bytes: bytes ?? 8192) }
}
extension SessionContext: Handled {
    func handle(_ sessions: Sessions) throws -> String { try sessions.printed(id, bytes: bytes ?? 24_000) }
}

/// Never re-inserts a deleted one (publish and change only update).
extension SessionMarkRead: Handled {
    // Not `quick`: they wait for a wake of the same session (`Sessions.setUnread`), as long as a locked keychain can take.
    func handle(_ sessions: Sessions) throws -> Done {
        try sessions.setUnread(id, false)
        return Done()
    }
}
extension SessionMarkUnread: Handled {
    func handle(_ sessions: Sessions) throws -> Done {
        try sessions.setUnread(id, true)
        return Done()
    }
}

extension SessionContinueAt: Handled {
    var actsOn: String? { id }   // it types "continue" into the session later
    func handle(_ sessions: Sessions) throws -> Done {
        guard let ls = sessions.existing(id) else { throw RPCError.invalidParams("no session") }
        ls.continueAt(at)
        return Done()
    }
}

extension SessionTurnUndo: Handled {
    var actsOn: String? { id }   // an agent undoes only its own turns and its children's
    func handle(_ turns: Turns) throws -> Result {
        let (mark, dir) = try turns.place(session: id, turn: turn), remotes = turns.remotes
        let plan = try Git.changed(since: mark.tree, cwd: dir, remotes: remotes)
        guard apply == true else { return Plan(files: plan.files, state: plan.now) }
        let before = state ?? ""
        guard plan.now == before else {
            throw RPCError.invalidParams("The files changed since you looked; nothing was put back.")
        }
        // What it was before stays reachable for Redo (git gc keeps it), each undo's in the ref's log.
        try Git.run(
            ["update-ref", "--create-reflog", "-m", "undo turn " + turn, Turns.undoneRef(id), before], cwd: dir,
            remotes: remotes)
        do { try Git.restore(plan.files, from: mark.tree, now: before, cwd: dir, remotes: remotes) } catch {
            // Stopped part way (a file the Trash refused): the files it touched go back as they were, not half undone.
            let back: Void? = Log.session.attempt("putting a stopped undo back") {
                let changed = try Git.changed(since: before, cwd: dir, remotes: remotes)
                try Git.restore(
                    changed.files.filter(plan.files.contains), from: before, now: changed.now, cwd: dir,
                    remotes: remotes)
            }
            let why = (error as? GitError)?.stderr ?? "\(error)"
            let now = back != nil ? "The files are as they were." : "Some went back; Redo puts them as they were."
            throw RPCError.invalidParams("The turn wasn't undone (\(why)). " + now)
        }
        return Plan(files: plan.files, state: try Git.snapshotTree(dir, remotes: remotes))
    }
}

extension SessionTurnRedo: Handled {
    var actsOn: String? { id }
    func handle(_ turns: Turns) throws -> Done {
        let (_, dir) = try turns.place(session: id, turn: turn), remotes = turns.remotes, ref = Turns.undoneRef(id)
        let before = try Git.run(["rev-parse", "--verify", "-q", ref], cwd: dir, ok: [0, 1], remotes: remotes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !before.isEmpty else { throw RPCError.invalidParams("There's no undo to take back here.") }
        let plan = try Git.changed(since: before, cwd: dir, remotes: remotes)
        try Git.restore(plan.files, from: before, now: state, cwd: dir, remotes: remotes)
        try Git.run(["update-ref", "-d", ref], cwd: dir, remotes: remotes)
        return Done()
    }
}

/// The turns agents take: the snapshot each began with, kept under refs/kelp/turns/ for its diff, and undoing or redoing
/// one (`session.turnUndo`).
struct Turns: Sendable {
    let live: SessionTable, store: Store, remotes: Remotes

    /// The folder before the session's last undone turn.
    static func undoneRef(_ session: String) -> String { "refs/kelp/undone/" + session }

    /// The turn and the checkout's top, when a turn may be undone or redone there: the agent rests, no commits since the
    /// turn began, no other agent in the checkout, and its snapshot still there.
    func place(session id: String, turn: String) throws -> (SessionTurns.Mark, String) {
        guard try store.session(id) != nil else { throw RPCError.invalidParams("No such agent.") }
        let status = live[id]?.snapshot.status   // nil: paused, so not in a turn
        guard let mark = try store.turns(session: id).first(where: { $0.id == turn }) else {
            throw RPCError.invalidParams("No such turn.")
        }
        let remotes = remotes, dir = try Git.root(of: mark.folder, remotes: remotes)   // paths count from the top, whatever folder it was in
        guard status != .working, status != .waiting else {
            throw RPCError.invalidParams("The agent is still in its turn: stop it first.")
        }
        let head = try Git.run(["rev-parse", "--verify", "-q", "HEAD"], cwd: dir, ok: [0, 1], remotes: remotes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard (head.isEmpty ? nil : head) == mark.head else {
            throw RPCError.invalidParams("Commits were made since that turn began; undoing it now would mix them up.")
        }
        let top = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
        let others = live.all.filter { other in   // anywhere in the checkout, by any path to it
            let snapshot = other.snapshot,
                at = URL(fileURLWithPath: other.turnDir ?? snapshot.cwd).resolvingSymlinksInPath().path
            return snapshot.id != id && snapshot.status != .exited && snapshot.isAgent
                && (at == top || at.hasPrefix(top + "/"))
        }
        guard others.isEmpty else {
            throw RPCError.invalidParams("Another agent works in this folder: its changes would go too.")
        }
        guard
            try !Git.run(["rev-parse", "--verify", "-q", mark.tree + "^{tree}"], cwd: dir, ok: [0, 1], remotes: remotes)
                .isEmpty
        else {
            throw RPCError.invalidParams("That turn's snapshot is gone: git cleaned it up.")
        }
        return (mark, dir)
    }

    /// A turn that began, kept with its snapshot under refs/kelp/turns/ so `git gc` doesn't take it while the turn is listed;
    /// the turns that drop off the list let theirs go.
    /// Its session deleted while the snapshot was taken: no turn, and no ref. Deleted between the two, the delete's own
    /// `dropRefs` may have run before the ref was made: it's dropped here.
    func keep(_ mark: SessionTurns.Mark) {
        Log.store.attempt("keeping a turn") {
            guard let dropped = try store.addTurn(mark), remotes.of(mark.folder) == nil else { return }   // no snapshots on a host
            let ref = "refs/kelp/turns/" + mark.id
            try Git.run(["update-ref", ref, mark.tree], cwd: mark.folder, remotes: remotes)
            delete(
                dropped.map { ("refs/kelp/turns/" + $0.id, $0.folder) }
                    + (try store.session(mark.session) == nil ? [(ref, mark.folder)] : []))
        }
    }

    /// A session going: its turns' snapshots and its last undone state needn't be kept any more. `repo`: where to drop
    /// them when their folder, a removed worktree, is gone; the refs are in the project's repository, which it shared.
    func dropRefs(of session: String, in repo: String? = nil) {
        Log.store.attempt("dropping \(session)'s turn refs") {
            dropRefs(try store.turns(session: session), of: session, in: repo)
        }
    }
    func dropRefs(_ marks: [SessionTurns.Mark], of session: String, in repo: String? = nil) {
        delete(
            marks.map { ("refs/kelp/turns/" + $0.id, repo ?? $0.folder) }
                + marks.prefix(1).map { (Self.undoneRef(session), repo ?? $0.folder) })
    }

    /// Deletes each ref in its folder's repository, one git run per repository; one already gone, or a folder that is,
    /// stops none of the others.
    private func delete(_ refs: [(ref: String, folder: String)]) {
        for (folder, group) in Dictionary(grouping: refs, by: \.folder)
        where remotes.of(folder) == nil && FileManager.default.fileExists(atPath: folder) {
            Log.store.attempt("dropping turn refs in \(folder)") {
                _ = try Git.run(
                    ["update-ref", "--stdin"], cwd: folder, stdin: group.map { "delete \($0.ref)\n" }.joined(),
                    remotes: remotes)
            }
        }
    }
}

extension SessionTurns: Handled {
    func handle(_ turns: Turns) throws -> Result { try turns.store.turns(session: id) }
}

extension SessionTurn: Handled {
    static var quick: Bool { true }
    func handle(_ turns: Turns) throws -> Info? {
        guard let ls = turns.live[id] else { return nil }
        let turn = ls.lastTurn.map { last in
            Turn(
                files: last.files.map { .init(path: $0.path, added: $0.added, removed: $0.removed) },
                seconds: last.seconds)
        }
        return Info(turn: turn, hasBase: ls.turnBase != nil)
    }
}

extension SessionLastReply: Handled {
    func handle(_ sessions: Sessions) throws -> String? {
        sessions.existing(id).flatMap(sessions.agentUsage.lastReply(of:))
    }
}

extension Methods {
    static let sessionMethods: [any Handled.Type] = [
        SessionList.self, SessionAttach.self, SessionDetach.self, SessionWrite.self, SessionSend.self,
        SessionResize.self, SessionKill.self, SessionChoose.self, AgentSetSecret.self, PortsList.self, PortsStop.self,
        PortsForward.self,
        PortsUnforward.self, SessionUsage.self, HostStatsRead.self, HostDisconnect.self,
        SessionBusy.self, SessionRead.self, SessionContext.self, SessionMarkRead.self, SessionMarkUnread.self,
        SessionTurn.self, SessionLastReply.self,
        SessionCommands.self, SessionContinueAt.self, SessionWhy.self, SessionTrail.self, SessionTurns.self,
        SessionTurnUndo.self, SessionTurnRedo.self
    ]
}
