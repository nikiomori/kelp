import Core
import Foundation
import os

/// Runs what an in-order handler mustn't do on the connection's reader thread: waking a paused session (git, files, a
/// spawn can take seconds, and everything else that connection sends would wait behind it — the app's main thread too,
/// once the socket fills). Each session has a serial lane. Input for a paused session wakes it there, and later input
/// follows.
final class SessionLanes: Sendable {
    private struct Lane {
        let queue: DispatchQueue
        var waiting = 0
    }
    private let lanes = OSAllocatedUnfairLock<[String: Lane]>(initialState: [:])

    /// Whether nothing for `id` waits on its lane, so new input may go straight to the running session.
    func isClear(_ id: String) -> Bool { lanes.withLock { ($0[id]?.waiting ?? 0) == 0 } }
    /// Whether so much waits for `id` (a session slow to wake, sent to in a loop) that more is refused, not kept.
    func isFull(_ id: String) -> Bool { lanes.withLock { ($0[id]?.waiting ?? 0) >= Self.limit } }
    static let limit = 1024

    /// Runs `work` on `id`'s lane, after what's already there. A lane is removed once nothing waits on it (the next
    /// input makes a new one).
    func run(_ id: String, _ work: @escaping @Sendable () -> Void) {
        let queue = enter(id)
        queue.async { [self] in
            work()
            leave(id)
        }
    }

    /// Runs `work` on `id`'s lane after what's already there, with this thread waiting for it. Call it only from a
    /// thread that may block, not a reader.
    func runHere<T>(_ id: String, _ work: () throws -> T) rethrows -> T {
        let queue = enter(id)
        defer { leave(id) }
        return try queue.sync(execute: work)
    }

    private func enter(_ id: String) -> DispatchQueue {
        lanes.withLock { lanes in
            var lane = lanes[id] ?? Lane(queue: DispatchQueue(label: "kelp.session-lane"))
            lane.waiting += 1
            lanes[id] = lane
            return lane.queue
        }
    }
    private func leave(_ id: String) {
        lanes.withLock { lanes in
            lanes[id]?.waiting -= 1
            if lanes[id]?.waiting == 0 { lanes[id] = nil }
        }
    }

    /// Sessions with a lane kept now (tests).
    var count: Int { lanes.withLock { $0.count } }
}

/// Input for a session (keys, text), in the order sent. It goes to the running session right away when nothing for it
/// waits on its lane, or else on the lane after what's there, with a paused session woken first. Either way the reply
/// goes out once the session has it, or says why it couldn't (a wake that failed), and the reader thread reads on
/// meanwhile.
protocol SessionInput: Handled where Service == Sessions {
    var id: String { get }
    func apply(to session: LiveSession) throws -> Result
}

extension SessionInput {
    /// Called off the reader thread (another handler, a test). Applies the input here, in order with the session's
    /// other input.
    func handle(_ sessions: Sessions) throws -> Result {
        if let result = try now(sessions) { return result }
        try sessions.mustWake(id)
        return try sessions.lanes.runHere(id) { try sessions.withInput(id) { try apply(to: $0) } }
    }

    /// Runs on the connection's reader thread. `done` gets the reply's result, now or later from the lane, so this
    /// always takes the call and returns true. `allowed` refuses a caller the method doesn't accept (`Daemon.allow`),
    /// as for every
    /// other method, and is asked again in the lane once the session has woken.
    static func answerLater(
        _ params: JSONValue, _ sessions: Sessions, allowed: @escaping @Sendable (any Answered) throws -> Void,
        reply done: @escaping @Sendable (Swift.Result<Data, Error>) -> Void
    ) -> Bool {
        do {
            let method = try decoded(params)
            try allowed(method)
            if let result = try method.now(sessions) {
                done(.success(try JSONEncoder().encode(result)))
                return true
            }
            try sessions.mustWake(method.id)
            guard !sessions.lanes.isFull(method.id) else {
                throw RPCError.internalError("Too much input waits for this session to wake.")
            }
            // Checked again once the session is awake, because what it shows by then (a question) may refuse what was
            // let through (`typesInto`).
            sessions.lanes.run(method.id) {
                done(
                    Swift.Result {
                        try allowed(method)
                        return try JSONEncoder().encode(sessions.withInput(method.id) { try method.apply(to: $0) })
                    })
            }
        } catch { done(.failure(error)) }
        return true
    }

    /// Applies the input right away when nothing waits on its lane and the session runs. Returns nil when it has to
    /// wait.
    private func now(_ sessions: Sessions) throws -> Result? {
        guard sessions.lanes.isClear(id), let ls = sessions.existing(id) else { return nil }
        return try ls.input({ try apply(to: ls) })
    }
}
