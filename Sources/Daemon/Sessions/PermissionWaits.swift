import Foundation
import os

/// Permission questions' hooks waiting for Allow or Deny, by session (`session.permissionWait`).
final class PermissionWaits: Sendable {
    let waits = OSAllocatedUnfairLock<[String: (UUID, CheckedContinuation<String?, Never>)]>(initialState: [:])
    /// Questions Kelp asks on behalf of an agent's commands (such as a database change), by session, oldest first. A
    /// status change doesn't end a question, since the agent's screen changes while the command runs. A question ends
    /// with an answer, the agent's Stop, the end of the command's program (Esc, or a tool's time limit: nobody is left
    /// to run it for), or its timeout. Two commands asking at once (parallel tool calls) wait their turn, oldest first.
    struct KelpWait: Sendable {
        let question: String, token: UUID
        /// The database run the question is for, if any (`SessionChoose.run`).
        let run: String?
        let answer: CheckedContinuation<String?, Never>
        let exit: DispatchSourceProcess?
    }
    let kelpWaits = OSAllocatedUnfairLock<[String: [KelpWait]]>(initialState: [:])
    /// What `waitForKelp` gives when the asking program ended first.
    static let askerGone = "gone"

    /// Waits for the answer (Allow or Deny) to Kelp's question `question` for `id`. Returns nil when nobody answered,
    /// or `askerGone` when `asker` (the program the command runs in) ended before an answer. `run` is the database run
    /// the question is for, so an answer can name it.
    func waitForKelp(
        _ id: String, question: String, within seconds: TimeInterval, asker: pid_t? = nil, run: String? = nil
    ) async -> String? {
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
                    KelpWait(question: question, token: token, run: run, answer: continuation, exit: exit))
            }
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

    /// Ends every question Kelp asks for `id`'s commands with no answer, because the turn and its commands are over.
    func endKelpQuestions(_ id: String) {
        let all = kelpWaits.withLock { $0.removeValue(forKey: id) } ?? []
        for wait in all {
            wait.exit?.cancel()
            wait.answer.resume(returning: nil)
        }
    }

    /// Waits for Allow or Deny for the hook of `id`'s permission question; a newer wait lets the older go unanswered.
    func waitForPermission(_ id: String, within seconds: TimeInterval) async -> String? {
        let token = UUID()
        return await withCheckedContinuation { continuation in
            waits.withLock { w in w.updateValue((token, continuation), forKey: id) }?.1.resume(returning: nil)
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.answerPermission(id, nil, only: token)
            }
        }
    }

    /// Hands `answer` to the hook waiting for `id`'s question (nil means no answer: the question went on some other
    /// way). Returns whether one was waiting.
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
