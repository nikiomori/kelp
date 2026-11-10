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
        // Kelp's own question (a database change): its command waits on it, whatever the screen says meanwhile.
        if sessions.permissions.answerKelp(id, question: question, answer == "allow" ? "allow" : "deny") { return true }
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
    /// Questions Kelp asks itself for the agent's commands (a database change), by session, oldest first: not ended by a
    /// status change, which the agent's own screen makes while that command runs; ended by an answer, the agent's Stop,
    /// the command's program ending (Esc, a tool's time limit: nobody is left to run it for), or the time running out.
    /// Two commands asking at once (parallel tool calls) each wait their turn: an answer goes to the oldest.
    struct KelpWait: Sendable {
        let question: String, token: UUID
        let answer: CheckedContinuation<String?, Never>
        let exit: DispatchSourceProcess?
    }
    let kelpWaits = OSAllocatedUnfairLock<[String: [KelpWait]]>(initialState: [:])
    /// What `waitForKelp` gives when the asking program ended first.
    static let askerGone = "gone"

    /// Kelp's question `question` for `id`, waiting for Allow or Deny; nil when nobody answered, `askerGone` when `asker`
    /// (the program the command runs in) ended before an answer.
    func waitForKelp(_ id: String, question: String, within seconds: TimeInterval, asker: pid_t? = nil) async -> String?
    {
        let token = UUID()
        return await withCheckedContinuation { continuation in
            let exit = asker.map { pid in
                let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
                source.setEventHandler { [weak self] in
                    self?.answerKelp(id, question: nil, Self.askerGone, only: token)
                }
                return source
            }
            kelpWaits.withLock {
                $0[id, default: []].append(
                    KelpWait(
                        question: question, token: token,
                        answer: continuation, exit: exit))
            }
            exit?.activate()
            // Gone before the watch began: its exit was before the source and won't come
            if let asker, kill(asker, 0) != 0, errno == ESRCH {
                answerKelp(id, question: nil, Self.askerGone, only: token)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.answerKelp(id, question: nil, nil, only: token)
            }
        }
    }

    /// Hands `answer` to Kelp's oldest question of `id` (the oldest that is `question`, when given; the one of `token`);
    /// whether one was waiting.
    @discardableResult
    func answerKelp(_ id: String, question: String?, _ answer: String?, only token: UUID? = nil) -> Bool {
        let waiting = kelpWaits.withLock { waits -> KelpWait? in
            guard var queue = waits[id],
                let index = queue.firstIndex(where: {
                    (token == nil || $0.token == token) && (question == nil || $0.question == question)
                })
            else { return nil }
            let wait = queue.remove(at: index)
            waits[id] = queue.isEmpty ? nil : queue
            return wait
        }
        waiting?.exit?.cancel()
        waiting?.answer.resume(returning: answer)
        return waiting != nil
    }

    /// Every question Kelp asks for `id`'s commands goes unanswered: its turn is over, and every command of it.
    func endKelpQuestions(_ id: String) {
        let all = kelpWaits.withLock { $0.removeValue(forKey: id) } ?? []
        for wait in all {
            wait.exit?.cancel()
            wait.answer.resume(returning: nil)
        }
    }

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

extension SessionLastReply: Handled {
    func handle(_ sessions: Sessions) throws -> String? {
        sessions.existing(id).flatMap(sessions.agentUsage.conversations.lastReply(of:))
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
