import Core
import Foundation
import os

/// A client of the socket. Writes leave in order from the connection's own queue, so no caller waits on a client that
/// reads slowly (or not at all). The fd closes only after the writes, so a reply can't land in a later connection or a
/// PTY that got the same fd number.
final class Connection: Sendable {
    let id: Int
    let fd: Int32
    private let queue = DispatchQueue(label: "kelp.connection")   // writes, in order
    private struct State { var queued = 0, closing = false, closed = false }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// A client with more than this many bytes queued costs too much memory, even if it still reads, so it's hung up
    /// on. This is far above any one reply (a monorepo's file list, a big diff). A client that stopped reading is
    /// noticed by time instead (`stall`).
    static let backlogLimit = 256 << 20
    /// When a write makes no progress for this long (plus `writeAll`'s own 5 s), nobody is reading, so the client is
    /// hung up on.
    static let stall = timeval(tv_sec: 25, tv_usec: 0)

    /// The program that connected (`Unix.peerExecutable`), read once when it's accepted, so an exec after that changes
    /// nothing. It decides what only Kelp's window may do.
    let peer: String?
    /// The pid of the program that connected, to tell which session a report comes from (`Fence.reportsFor`).
    let peerPID: pid_t?
    /// Who that process is (`Callers.caller`). It is looked up once, because its pid and parents stay while it's
    /// connected, and is nil until then.
    let owner = OSAllocatedUnfairLock<Caller?>(initialState: nil)

    init(id: Int, fd: Int32) {
        self.id = id
        self.fd = fd
        peer = Unix.peerExecutable(fd)
        peerPID = Unix.peerPID(fd)
        var timeout = Self.stall
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    func send(_ data: Data) {
        // The write is queued under the lock that `close` takes too. A write checked before the close is then also
        // queued before it, so it never runs after the fd was closed (and its number given to a new client or a PTY).
        let behind = state.withLock { current -> Int? in
            guard !current.closing else { return nil }
            current.queued += data.count
            queue.async { [self] in
                if !Unix.writeAll(fd, data) { hangUp() }
                state.withLock { $0.queued -= data.count }
            }
            return current.queued
        }
        if let behind, behind > Self.backlogLimit { hangUp() }
    }

    /// Waits until what's queued so far is written, or until `seconds` pass (for a client that stopped reading).
    func drain(within seconds: Double) {
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        _ = done.wait(timeout: .now() + seconds)
    }

    /// Stops reading and writing now (a stalled client, the daemon quitting). The reader sees EOF, and queued writes
    /// fail fast.
    func hangUp() { state.withLock { if !$0.closed { _ = shutdown(fd, SHUT_RDWR) } } }

    /// Stops sending. The fd closes once what's queued is out.
    func close() {
        state.withLock { current in
            current.closing = true
            queue.async { [self] in
                state.withLock {
                    $0.closed = true
                    _ = Darwin.close(fd)
                }
            }
        }
    }
}
