import Foundation
import Testing
@testable import Core
import TestSupport

/// A cancelled call stops waiting at once: it used to wait out its timeout, and one without (`files.copy`, `process.run`)
/// waited for good. One cancelled before it was sent isn't sent.
@Test func aCancelledCallStopsWaiting() async throws {
    let path = NSTemporaryDirectory() + "kelp-cancel-\(getpid()).sock"
    let server = try Unix.listen(path)
    defer { close(server); unlink(path) }
    let client = try RPCClient(socket: path)
    let peer = accept(server, nil, nil)   // and never answers
    defer { close(peer) }
    let call = Task { try await client.call("never", timeout: 20) }   // not forever, so the old way fails instead of hanging
    try await Task.sleep(for: .milliseconds(100))
    call.cancel()
    let started = Date()
    await #expect(throws: CancellationError.self) { try await call.value }
    #expect(Date().timeIntervalSince(started) < 5)
    let early = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await client.call("x", timeout: 20) }
    await #expect(throws: CancellationError.self) { try await early.value }
}

/// A write a daemon that stopped reading never took is cut off part way: the connection closes, so the next line isn't
/// glued to half of this one and refused (or taken for something else) for good.
@Test func aWriteThatGivesUpClosesTheConnection() async throws {
    let path = NSTemporaryDirectory() + "kelp-cut-\(getpid()).sock"
    let server = try Unix.listen(path)
    defer { close(server); unlink(path) }
    let client = try RPCClient(socket: path)
    let peer = accept(server, nil, nil)   // and never reads
    defer { close(peer) }
    let closed = Flag()
    client.onClose = { closed.set() }
    client.notify("big", .string(String(repeating: "x", count: 8 << 20)))
    // A partial write after the 10 s send timeout, another 10 s, then the 5 s poll: about 25 s.
    for _ in 0..<400 where !closed.value { try await Task.sleep(for: .milliseconds(100)) }
    #expect(closed.value)
}

/// A listener whose queue is full (a burst of clients while a new kelpd takes over) is tried again for a moment, not
/// taken for nobody answering at once.
@Test func aFullQueueIsTriedAgain() throws {
    let path = NSTemporaryDirectory() + "kelp-q-\(getpid()).sock"
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var a = sockaddr_un(); a.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &a.sun_path) { b in for (i, c) in path.utf8.enumerated() { b[i] = c } }
    _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    defer { close(fd); unlink(path) }
    // Bound, not listening yet: refused, as a full queue is. It starts listening a moment later.
    // Its own thread: on a busy runner the global queue started it later than the 2 s it was given.
    #expect(throws: SocketError.self) { _ = try Unix.connect(path) }
    Thread.detachNewThread { usleep(300_000); _ = listen(fd, 4) }
    let c = try Unix.connect(path, patience: 10)
    close(c)
}
