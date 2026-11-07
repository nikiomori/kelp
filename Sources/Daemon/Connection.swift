import Core
import Foundation
import os

/// A client of the socket. Writes leave in order from the connection's own queue, so no caller waits on a client that
/// reads slowly (or not at all), and its fd closes only after them: a reply can't land in a later connection or a
/// PTY that got the same number.
final class Connection: Sendable {
    let id: Int
    let fd: Int32
    private let q = DispatchQueue(label: "kelp.connection")   // writes, in order
    private struct State { var queued = 0, closing = false, closed = false }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// More than this queued costs too much memory even from a client that still reads: it's hung up on. Far above any
    /// one reply (a monorepo's file list, a big diff); a client that stopped reading is noticed by time instead (`stall`).
    static let backlogLimit = 256 << 20
    /// A write that makes no progress this long (then `writeAll`'s own 5 s): nobody reads, the client is hung up on.
    static let stall = timeval(tv_sec: 25, tv_usec: 0)

    /// The program that connected (`Unix.peerExecutable`), for what only Kelp's window may do.
    let peer: String?
    /// Its process, to tell which session a report comes from (`Answered.reportsFor`).
    let peerPID: pid_t?
    /// Who that process is (`Callers.caller`), looked up once: its pid and parents stay while it's connected. nil until then.
    let owner = OSAllocatedUnfairLock<Caller?>(initialState: nil)

    init(id: Int, fd: Int32) {
        self.id = id
        self.fd = fd
        peer = Unix.peerExecutable(fd)
        peerPID = Unix.peerPID(fd)
        var t = Self.stall
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &t, socklen_t(MemoryLayout<timeval>.size))
    }

    func send(_ d: Data) {
        // Queued under the lock that `close` takes too: a write checked before the close is also queued before it, so
        // it never runs after the fd was closed (and its number given to a new client or a PTY).
        let behind = state.withLock { s -> Int? in
            guard !s.closing else { return nil }
            s.queued += d.count
            q.async { [self] in
                if !Unix.writeAll(fd, d) { hangUp() }
                state.withLock { $0.queued -= d.count }
            }
            return s.queued
        }
        if let behind, behind > Self.backlogLimit { hangUp() }
    }

    /// Until what's queued so far is written, or `seconds` pass (a client that stopped reading).
    func drain(within seconds: Double) {
        let done = DispatchSemaphore(value: 0)
        q.async { done.signal() }
        _ = done.wait(timeout: .now() + seconds)
    }

    /// Reading and writing stop now (a stalled client, the daemon quitting): its reader sees EOF, queued writes fail fast.
    func hangUp() { state.withLock { if !$0.closed { _ = shutdown(fd, SHUT_RDWR) } } }

    /// Nothing more is sent; the fd closes once what's queued is out.
    func close() {
        state.withLock { s in
            s.closing = true
            q.async { [self] in
                state.withLock {
                    $0.closed = true
                    _ = Darwin.close(fd)
                }
            }
        }
    }
}
