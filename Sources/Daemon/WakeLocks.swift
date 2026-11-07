import Core
import Foundation
import os

/// One lock per session for what changes whether its program runs: waking it, pausing it, stopping it, deleting it.
/// Per session, not one for the daemon: waiting for one program to exit (up to 3 s) or a slow host doesn't hold up
/// opening any other session.
final class WakeLocks: Sendable {
    /// Each with how many callers hold it or wait for it: gone once none do, so a deleted session leaves nothing behind.
    private let locks = OSAllocatedUnfairLock<[String: (lock: NSLock, users: Int)]>(initialState: [:])

    private func take(_ id: String) -> NSLock {
        locks.withLock { all in
            var e = all[id] ?? (NSLock(), 0)
            e.users += 1
            all[id] = e
            return e.lock
        }
    }

    private func letGo(_ id: String) {
        locks.withLock { all in
            guard var e = all[id] else { return }
            e.users -= 1
            all[id] = e.users > 0 ? e : nil
        }
    }

    /// Sessions with a lock kept now (tests).
    var count: Int { locks.withLock { $0.count } }

    func withLock<T>(_ id: String, _ body: () throws -> T) rethrows -> T {
        let l = take(id)
        defer { letGo(id) }
        return try l.withLock(body)
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
