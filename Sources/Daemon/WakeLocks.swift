import Core
import Foundation
import os

/// One lock per session for what changes whether its program runs: waking it, pausing it, stopping it, deleting it.
/// Per session, not one for the daemon: waiting for one program to exit (up to 10 s) or a slow host doesn't hold up
/// opening any other session.
final class WakeLocks: Sendable {
    /// Each with how many callers hold it or wait for it: gone once none do, so a deleted session leaves nothing behind.
    private let locks = OSAllocatedUnfairLock<[String: (lock: NSLock, users: Int)]>(initialState: [:])

    private func take(_ id: String) -> NSLock {
        locks.withLock { all in
            var entry = all[id] ?? (NSLock(), 0)
            entry.users += 1
            all[id] = entry
            return entry.lock
        }
    }

    private func letGo(_ id: String) {
        locks.withLock { all in
            guard var entry = all[id] else { return }
            entry.users -= 1
            all[id] = entry.users > 0 ? entry : nil
        }
    }

    /// Sessions with a lock kept now (tests).
    var count: Int { locks.withLock { $0.count } }

    func withLock<T>(_ id: String, _ body: () throws -> T) rethrows -> T {
        let lock = take(id)
        defer { letGo(id) }
        return try lock.withLock(body)
    }

    /// Several sessions' at once (a workspace's), taken in one order (by id) so two callers can't each hold what the
    /// other waits for.
    func withLocks<T>(_ ids: [String], _ body: () throws -> T) rethrows -> T {
        let ids = Set(ids).sorted()
        let held = ids.map(take)
        held.forEach { $0.lock() }
        defer {
            held.reversed().forEach { $0.unlock() }
            ids.forEach(letGo)
        }
        return try body()
    }
}
