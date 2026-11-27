import Agents
import Foundation
import os

/// Permission questions' hooks waiting for Allow or Deny, by session (`session.permissionWait`).
final class PermissionWaits: Sendable {
    private let live: SessionTable
    struct HookWait: Sendable {
        let token: UUID, menuID: UUID?, answer: CheckedContinuation<String?, Never>
    }
    let waits = OSAllocatedUnfairLock<[String: HookWait]>(initialState: [:])

    init(live: SessionTable) { self.live = live }

    /// Questions Kelp asks on behalf of an agent's commands (such as a database change), by session, oldest first. A
    /// status change doesn't end a question, since the agent's screen changes while the command runs. A question ends
    /// with an answer, the agent's Stop, the end of the command's program (Esc, or a tool's time limit: nobody is left
    /// to run it for), or its timeout. Two commands asking at once (parallel tool calls) wait their turn, oldest first.
    struct KelpWait: Sendable {
        let question: String, token: UUID
        /// The database run the question is for, or the login question's (`AgentSites.run`), if any
        /// (`SessionChoose.run`).
        let run: String?
        let answer: CheckedContinuation<String?, Never>
        let exit: DispatchSourceProcess?
    }
    let kelpWaits = OSAllocatedUnfairLock<[String: [KelpWait]]>(initialState: [:])
    /// What `waitForKelp` gives when the asking program ended first.
    static let askerGone = "gone"

    /// The wait that owns the question shown on the phone, or the current terminal menu when it has no waiting hook.
    func questionId(_ session: LiveSession, for question: String) -> UUID? {
        session.state.withLock { state in
            guard state.record.asksPermission, state.record.summary == question else { return nil }
            let id = state.record.id
            if let asked = state.kelpQuestions.first { return asked.id }
            guard state.asksOnly(question) else { return nil }
            let menu = state.menuID
            return waits.withLock { waits in
                guard let wait = waits[id], wait.menuID == menu else { return menu }
                return wait.token
            }
        }
    }

    /// Waits for the answer (Allow or Deny) to Kelp's question `question` for `id`. Returns nil when nobody answered,
    /// or `askerGone` when `asker` (the program the command runs in) ended before an answer. `run` is the database run
    /// the question is for, so an answer can name it.
    func waitForKelp(
        _ session: LiveSession, question: String, within seconds: TimeInterval, asker: pid_t? = nil, run: String? = nil
    ) async -> String? {
        let token = UUID(), id = session.snapshot.id
        defer { session.kelpAsked(token) }
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
                    KelpWait(question: question, token: token, run: run, answer: continuation, exit: exit))
            }
            session.askForKelp(question, id: token)
            exit?.activate()
            // If the asker was gone before the watch began, its exit came before the source and won't be seen.
            if let asker, kill(asker, 0) != 0, errno == ESRCH {
                answerKelp(id, question: nil, Self.askerGone, only: token)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.answerKelp(id, question: nil, nil, only: token)
            }
        }
    }

    /// Hands `answer` to Kelp's oldest question for `id` (the oldest that is `question`, when given; the one with
    /// `token`, or for `run`, when given). Returns whether one was waiting.
    @discardableResult
    func answerKelp(
        _ id: String, question: String?, _ answer: String?, only token: UUID? = nil, run: String? = nil
    ) -> Bool {
        let waiting = kelpWaits.withLock { waits -> KelpWait? in
            guard var queue = waits[id],
                let index = queue.firstIndex(where: {
                    (token == nil || $0.token == token) && (question == nil || $0.question == question)
                        && (run == nil || $0.run == run)
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

    /// The sites whose login the user denied an agent, by session, until its turn ends: it isn't asked again meanwhile.
    let deniedLogins = OSAllocatedUnfairLock<[String: Set<String>]>(initialState: [:])

    /// Ends every question Kelp asks for `id`'s commands with no answer, because the turn and its commands are over.
    func endKelpQuestions(_ id: String) {
        deniedLogins.withLock { $0[id] = nil }
        let all = kelpWaits.withLock { $0.removeValue(forKey: id) } ?? []
        for wait in all {
            wait.exit?.cancel()
            wait.answer.resume(returning: nil)
        }
    }

    /// Waits for Allow or Deny for the hook of `id`'s permission question; a newer wait lets the older go unanswered.
    func waitForPermission(_ id: String, at: TimeInterval?, within seconds: TimeInterval) async -> String? {
        guard let session = live[id] else { return nil }
        let token = UUID()
        return await withCheckedContinuation { continuation in
            let registered = session.state.withLock { state in
                if let at, at != state.permissionHookAt || state.record.status != .waiting { return false }
                return waits.withLockUnchecked { waits in
                    // An older CLI has no hook timestamp. Its wait is still answerable from the desktop.
                    if at == nil, let current = waits[id]?.menuID, current == state.menuID { return false }
                    if at != nil { state.menuID = UUID() }
                    let wait = HookWait(token: token, menuID: at == nil ? nil : state.menuID, answer: continuation)
                    waits.updateValue(wait, forKey: id)?.answer.resume(returning: nil)
                    if state.record.status == .waiting { session.emit(state.record) }
                    return true
                }
            }
            guard registered else { return continuation.resume(returning: nil) }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.answerPermission(id, nil, only: token)
            }
        }
    }

    /// Hands `answer` to the hook waiting for `id`'s question (nil means no answer: the question went on some other
    /// way). Returns whether one was waiting.
    @discardableResult
    func answerPermission(_ id: String, _ answer: String?, only token: UUID? = nil, menuID: UUID? = nil) -> Bool {
        let waiting = waits.withLock { waits -> CheckedContinuation<String?, Never>? in
            guard let wait = waits[id], token == nil || wait.token == token, menuID == nil || wait.menuID == menuID
            else { return nil }
            waits[id] = nil
            return wait.answer
        }
        waiting?.resume(returning: answer)
        return waiting != nil
    }
}
