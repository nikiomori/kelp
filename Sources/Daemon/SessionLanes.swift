import Core
import Foundation
import os

/// What an in-order handler mustn't do on the connection's reader thread: wake a paused session (git, files, a spawn
/// can take seconds, and everything else that connection sends would wait behind it — the app's main thread too, once
/// the socket fills). Each session has a serial lane: input for a paused one wakes it there, and input after it follows.
final class SessionLanes: Sendable {
    private struct Lane {
        let queue: DispatchQueue
        var waiting = 0
    }
    private let lanes = OSAllocatedUnfairLock<[String: Lane]>(initialState: [:])

    /// Nothing for `id` waits on its lane: new input may go straight to the running session.
    func isClear(_ id: String) -> Bool { lanes.withLock { ($0[id]?.waiting ?? 0) == 0 } }
    /// So much waits for `id` (a session slow to wake, sent to in a loop) that more is refused, not kept.
    func isFull(_ id: String) -> Bool { lanes.withLock { ($0[id]?.waiting ?? 0) >= Self.limit } }
    static let limit = 1024

    /// `work` on `id`'s lane, after what's already there. A lane goes once nothing waits on it (the next input makes one).
    func run(_ id: String, _ work: @escaping @Sendable () -> Void) {
        let queue = enter(id)
        queue.async { [self] in
            work()
            leave(id)
        }
    }

    /// `work` on `id`'s lane after what's already there, this thread waiting for it (one that may block: not a reader).
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

/// Input for a session (keys, text), in the order sent: to the running session right away when nothing for it waits on
/// its lane, else on the lane after what's there, a paused session woken first. Either way the reply goes out once the
/// session has it, or with why it couldn't (a wake that failed): the reader thread reads on meanwhile.
protocol SessionInput: Handled where Service == Sessions {
    var id: String { get }
    func apply(to session: LiveSession) throws -> Result
}

extension SessionInput {
    /// Off the reader thread (another handler, a test): here, in order with the session's other input.
    func handle(_ sessions: Sessions) throws -> Result {
        if sessions.lanes.isClear(id), let ls = sessions.existing(id), let result = try ls.input({ try apply(to: ls) })
        {
            return result
        }
        try sessions.mustWake(id)
        return try sessions.lanes.runHere(id) { try sessions.withInput(id) { try apply(to: $0) } }
    }

    /// On the connection's reader thread: `done` with the reply's result, now or from the lane. `allowed` refuses a caller
    /// the method doesn't take (`Daemon.allow`), as for every other method, and again in the lane, once the session woke.
    static func answerInOrder(
        _ params: JSONValue, _ sessions: Sessions, allowed: @escaping @Sendable (any Answered) throws -> Void,
        done: @escaping @Sendable (Swift.Result<Data, Error>) -> Void
    ) {
        do {
            let method = try decoded(params)
            try allowed(method)
            if sessions.lanes.isClear(method.id), let ls = sessions.existing(method.id),
                let result = try ls.input({ try method.apply(to: ls) })
            {
                done(.success(try JSONEncoder().encode(result)))
                return
            }
            try sessions.mustWake(method.id)
            guard !sessions.lanes.isFull(method.id) else {
                throw RPCError.internalError("Too much input waits for this session to wake.")
            }
            // Asked again once it's awake: what it shows by then (a question) may refuse what was let through (`typesInto`).
            sessions.lanes.run(method.id) {
                done(
                    Swift.Result {
                        try allowed(method)
                        return try JSONEncoder().encode(sessions.withInput(method.id) { try method.apply(to: $0) })
                    })
            }
        } catch { done(.failure(error)) }
    }
}
