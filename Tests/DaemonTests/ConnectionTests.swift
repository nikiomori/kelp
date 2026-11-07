import Core
import Foundation
import Testing
import os

@testable import Daemon

/// One reply bigger than 16 MiB (a monorepo's file list) reaches a client that reads it; it used to hang that client up.
@Test func aHugeReplyReachesAClientThatReads() async throws {
    var sv: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sv) == 0)
    Unix.noSigPipe(sv[0])   // as the daemon does for every client
    let c = Connection(id: 1, fd: sv[0])
    let big = Data(repeating: 0x61, count: 20 << 20), tail = Data("\n".utf8)
    let fd = sv[1], want = big.count + tail.count
    let reader = Task.detached { () -> Int in
        var total = 0, b = [UInt8](repeating: 0, count: 1 << 16)
        while total < want {
            let n = read(fd, &b, b.count)
            if n <= 0 { break }
            total += n
        }
        return total
    }
    c.send(big)
    c.send(tail)
    #expect(await reader.value == want)
    c.close()
    close(fd)
}

/// What's queued for a client goes out before the daemon hangs up on it to hand over (`daemon.upgrade`): its own reply
/// was cut off on a loaded Mac, and the app, thinking the upgrade failed, offered a restart that ended every agent.
@Test func aHandOverSendsWhatsQueuedFirst() async throws {
    var sv: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sv) == 0)
    Unix.noSigPipe(sv[0])
    let c = Connection(id: 1, fd: sv[0])
    let reply = Data(repeating: 0x61, count: 4 << 20)   // more than the socket holds: it's still being written
    let fd = sv[1]
    var t = timeval(tv_sec: 15, tv_usec: 0)   // a lost EOF fails the test instead of hanging the run
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &t, socklen_t(MemoryLayout<timeval>.size))
    c.send(reply)
    let reader = Task.detached { () -> Int in
        try? await Task.sleep(for: .milliseconds(200))   // a client slow to read
        var total = 0, b = [UInt8](repeating: 0, count: 1 << 16)
        while case let n = read(fd, &b, b.count), n > 0 { total += n }
        return total
    }
    c.drain(within: 5)
    c.hangUp()
    #expect(await reader.value == reply.count)
    c.close()
    close(fd)
}

/// A `kelp browser` request asked of Kelp's window ends when that window hangs up, not a minute later: nobody is left to
/// answer it.
@Test(.timeLimit(.minutes(1))) func aBrowserRequestEndsWhenItsWindowGoes() async throws {
    var sv: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sv) == 0)
    Unix.noSigPipe(sv[0])
    defer { close(sv[1]) }
    let clients = Clients(), app = clients.add(fd: sv[0]).id
    let sent = OSAllocatedUnfairLock(initialState: false)
    let asked = Task { try await clients.reply(to: "r1", from: [app], within: 60) { sent.withLock { $0 = true } } }
    #expect(try await waitFor(5) { sent.withLock { $0 } })   // asked: its answer is waited for
    clients.remove(app)
    await #expect(throws: RPCError.internalError("Kelp's window closed before it answered")) { try await asked.value }
}
