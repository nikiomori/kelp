import Core
import Foundation
import os

/// The sessions whose program runs now, by id. Paused and ended ones are only in the store.
final class SessionTable: Sendable {
    private struct State { var live: [String: LiveSession] = [:], closed = false }
    private let table = OSAllocatedUnfairLock(initialState: State())

    subscript(id: String) -> LiveSession? { table.withLock { $0.live[id] } }
    var all: [LiveSession] { table.withLock { Array($0.live.values) } }
    /// Refused once the daemon is stopping (`close`): one started then would outlive it, running with nobody to pause it.
    func add(_ ls: LiveSession) throws {
        try table.withLock { t in
            guard !t.closed else { throw RPCError.internalError("Kelp's background service is stopping") }
            t.live[ls.snapshot.id] = ls
        }
    }
    /// No more from now on: what runs, for the daemon to pause as it stops.
    func close() -> [LiveSession] {
        table.withLock {
            $0.closed = true
            return Array($0.live.values)
        }
    }
    /// Out of the table (paused, deleted): what was there.
    func remove(_ id: String) -> LiveSession? { table.withLock { $0.live.removeValue(forKey: id) } }
    /// Out only if `ls` is still the one there and `ok` says so, checked under the same lock.
    func remove(_ ls: LiveSession, if ok: (LiveSession) -> Bool = { _ in true }) -> Bool {
        table.withLockUnchecked { t in   // `ok` runs here, never later
            let id = ls.snapshot.id
            guard t.live[id] === ls, ok(ls) else { return false }
            t.live[id] = nil
            return true
        }
    }
}
