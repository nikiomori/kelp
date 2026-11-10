import Core
import Foundation
import os

/// The sessions whose program runs now, by id, and where every other one is in its life (`phase`). Paused and ended ones
/// are only in the store.
final class SessionTable: Sendable {
    /// Where a session is in its life: what decides whether input may wake it.
    enum Phase: Equatable, Sendable {
        /// Its program runs: in the table.
        case running
        /// Out of the table, its program stopping for an idle pause (`letGo`): input waits for the pause, then wakes it.
        case lettingGo
        /// Not running, and a wake brings it back. `saved` false: the pause couldn't be written (a full disk), so the
        /// record says otherwise; nothing runs all the same.
        case paused(saved: Bool)
        /// Not running, and nothing brings it back: it ended (or its record says it ran, and no program does).
        case ended
        /// No record.
        case deleted
    }

    private struct State {
        var live: [String: LiveSession] = [:], closed = false
        /// What the store can't tell: `lettingGo`, and `paused(saved: false)`.
        var held: [String: Phase] = [:]
    }
    private let table = OSAllocatedUnfairLock(initialState: State())

    subscript(id: String) -> LiveSession? { table.withLock { $0.live[id] } }
    var all: [LiveSession] { table.withLock { Array($0.live.values) } }
    /// Refused once the daemon is stopping (`close`): one started then would outlive it, running with nobody to pause it.
    func add(_ ls: LiveSession) throws {
        try table.withLock { state in
            guard !state.closed else { throw RPCError.internalError("Kelp's background service is stopping") }
            state.live[ls.snapshot.id] = ls
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
        table.withLockUnchecked { state in   // `ok` runs here, never later
            let id = ls.snapshot.id
            guard state.live[id] === ls, ok(ls) else { return false }
            state.live[id] = nil
            return true
        }
    }

    /// `remove(_:if:)` for an idle pause: out and `lettingGo` in one step, so input never finds it in neither.
    func letGo(_ ls: LiveSession, if ok: (LiveSession) -> Bool) -> Bool {
        table.withLockUnchecked { state in
            let id = ls.snapshot.id
            guard state.live[id] === ls, ok(ls) else { return false }
            state.live[id] = nil
            state.held[id] = .lettingGo
            return true
        }
    }

    /// The idle pause is over: its record says paused (or `saved` says it couldn't).
    func letGone(_ id: String) { table.withLock { if $0.held[id] == .lettingGo { $0.held[id] = nil } } }

    /// A record of `id` saved (`written`) or not, saying paused or not: a pause that couldn't be saved is still one here.
    func saved(_ id: String, paused: Bool, written: Bool) {
        table.withLock { state in
            if paused && !written {
                state.held[id] = .paused(saved: false)
            } else if state.held[id] != .lettingGo {
                state.held[id] = nil   // a status saved while it lets go is one queued before the pause
            }
        }
    }

    /// Deleted: nothing kept of it here.
    func forget(_ id: String) { table.withLock { _ = $0.held.removeValue(forKey: id) } }

    /// Where `id` is now. `record`: its record, read only when it isn't running (not under this lock).
    func phase(_ id: String, record: () throws -> Session?) rethrows -> Phase {
        let (running, held) = table.withLock { ($0.live[id] != nil, $0.held[id]) }
        if running { return .running }
        guard let record = try record() else { return .deleted }
        if let held { return held }
        return record.status == .paused ? .paused(saved: true) : .ended
    }
}
