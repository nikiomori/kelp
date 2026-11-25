import Core
import Foundation
import os

/// The Stop of one statement the user runs (`db.cancel`). It is the task's (`current`), and `Slots.run` carries it to
/// the thread that blocks, so what blocks says how it is stopped while it runs (`during`): SQLite is interrupted, a
/// client program is ended (`program`), a wire's connection is closed (`DatabaseWire.within`).
final class DatabaseStop: Sendable {
    @TaskLocal static var current: DatabaseStop?

    private struct State {
        var stopped = false, next = 0, said = DatabaseCancel.stopped
        var actions: [Int: @Sendable () -> Void] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var stopped: Bool { state.withLock { $0.stopped } }
    /// What the stopped call says: `DatabaseCancel.stopped`, or what a Stop that only ends the wait leaves (`leaves`).
    var said: String { state.withLock { $0.said } }

    /// Says that a Stop of what runs now only ends Kelp's wait for it, and what it leaves running.
    func leaves(_ said: String) { state.withLock { $0.said = said } }

    /// Stops what runs now, and whatever starts after.
    func stop() {
        let actions = state.withLock { now in
            now.stopped = true
            defer { now.actions = [:] }
            return Array(now.actions.values)
        }
        for action in actions { action() }
    }

    /// Keeps `action` until `off`; once stopped, it runs at once instead. Returns nil then.
    func on(_ action: @escaping @Sendable () -> Void) -> Int? {
        let token = state.withLock { now -> Int? in
            guard !now.stopped else { return nil }
            now.next += 1
            now.actions[now.next] = action
            return now.next
        }
        if token == nil { action() }
        return token
    }

    func off(_ token: Int?) {
        guard let token else { return }
        state.withLock { _ = $0.actions.removeValue(forKey: token) }
    }

    /// Runs `body` with `action` as the way the current Stop ends it. A run stopped before it starts doesn't start,
    /// however close to its start the Stop came (SQLite ignores an interrupt before its statement runs).
    static func during<T>(_ action: @escaping @Sendable () -> Void, _ body: () throws -> T) throws -> T {
        guard let stop = current else { return try body() }
        guard let token = stop.on(action) else { throw DatabaseFailure.failed(DatabaseCancel.stopped) }
        defer { stop.off(token) }
        return try body()
    }

    /// `Subprocess.run` for a database's client program, which the current Stop ends with everything it started.
    static func program(
        _ argv: [String], env: [String: String], stdin: Data, timeLimit: TimeInterval
    ) throws -> Subprocess.Output {
        let pid = OSAllocatedUnfairLock<pid_t?>(initialState: nil)
        return try during({ pid.withLock { $0 }.map(Subprocess.stopTree) }) {
            try Subprocess.run(
                argv, cwd: NSHomeDirectory(), env: env, stdin: stdin, timeLimit: timeLimit,
                limit: DatabaseEngines.outputLimit
            ) { started in
                pid.withLock { $0 = started }
                if current?.stopped == true { Subprocess.stopTree(started) }   // stopped just before it started
            }
        }
    }
}

extension Databases {
    /// Runs `body` as the user's statement named `id` (`DatabaseQuery.cancelId`), which `cancel` stops. Whatever it
    /// fails with once stopped, it says it was stopped.
    func stoppable<T: Sendable>(_ id: String?, _ body: () async throws -> T) async throws -> T {
        guard let id else { return try await body() }
        let stop = DatabaseStop()
        stops.withLock { $0[id] = stop }
        defer { stops.withLock { _ = $0.removeValue(forKey: id) } }
        do { return try await DatabaseStop.$current.withValue(stop) { try await body() } } catch  where stop.stopped {
            throw RPCError.invalidParams(stop.said)
        }
    }

    func cancel(_ id: String) { stops.withLock { $0[id] }?.stop() }
}

extension DatabaseCancel: Handled {
    static var quick: Bool { true }
    func handle(_ dbs: Databases) throws -> Done {
        dbs.cancel(id)
        return Done()
    }
}
