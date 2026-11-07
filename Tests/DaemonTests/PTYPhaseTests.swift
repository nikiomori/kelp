import Foundation
import Testing

@testable import Daemon

/// A terminal's phases go one way: waiting → reading → handed over or hung up; its program running → handed over or
/// reaped. Nothing comes back from an end.
@Test func aTerminalHandedOverStaysHandedOver() throws {
    let p = try PTY(argv: ["/bin/sh", "-c", "cat"], cwd: "/tmp", env: [:])
    #expect(p.phases.terminal == .waiting && p.phases.program == .running)
    p.start()
    #expect(p.phases.terminal == .reading)
    let fd = try #require(p.handOver())
    defer {
        kill(p.pid, SIGKILL)
        close(fd)
    }
    #expect(p.phases.terminal == .handedOver && p.phases.program == .handedOver)
    #expect(p.handOver() == nil)   // once
    p.start()
    #expect(p.phases.terminal == .handedOver)   // and never read here again
}

@Test func aTerminalWhoseProgramEndedIsHungUpAndReaped() async throws {
    let p = try PTY(argv: ["/bin/sh", "-c", "exit 3"], cwd: "/tmp", env: [:])
    let box = Box()
    p.onExit = { box.exit($0) }
    p.start()
    #expect(try await waitFor(10) { box.code != nil })
    #expect(p.phases.terminal == .hungUp && p.phases.program == .reaped)
    #expect(p.handOver() == nil && p.tree().isEmpty)
}

/// A program that let go of its terminal (its output ended) but runs on is still handed over: left out, it would run
/// on unseen, its record "working".
@Test func aProgramThatLetGoOfItsTerminalIsStillHandedOver() async throws {
    let p = try PTY(
        argv: ["/bin/sh", "-c", "exec </dev/null >/dev/null 2>&1; sleep 30"], cwd: "/tmp", env: [:], trampoline: nil)
    p.start()
    #expect(try await waitFor(5) { p.phases.terminal == .reading && !p.reading })   // its output ended, its program runs on
    let fd = try #require(p.handOver())
    kill(p.pid, SIGKILL)
    close(fd)
}

/// Input to a program that never reads is kept only up to the limit; what's past it is dropped, not held for good.
@Test func inputToAProgramThatDoesntReadIsCapped() async throws {
    let p = try PTY(argv: ["/bin/sh", "-c", "exec sleep 30"], cwd: "/tmp", env: [:], trampoline: nil)
    p.start()
    defer { _ = p.terminate(grace: 0) }
    let chunk = Data(repeating: 0x61, count: 1 << 20)
    for _ in 0..<(PTY.queueLimit >> 20) + 16 { p.write(chunk) }
    #expect(p.queued.withLock { $0 } <= PTY.queueLimit)
}

/// A program that has already ended when its exit starts being watched (a process source misses a zombie) is still
/// seen: its exit is reported and it's reaped.
@Test func aProgramThatEndedBeforeItWasWatchedIsSeen() async throws {
    let p = try PTY(argv: ["/bin/sh", "-c", "exit 7"], cwd: "/tmp", env: [:], trampoline: nil)
    try await Task.sleep(for: .milliseconds(300))   // long gone by now: a zombie
    let box = Box()
    p.onExit = { box.exit($0) }
    p.start()
    #expect(try await waitFor(5) { box.code != nil })
    #expect(p.phases.program == .reaped)
}

/// A terminal handed over and then dropped (an update whose exec failed takes its sessions back in a new PTY) leaves
/// its program to the one that took it: only that one reaps it, and reads its real exit status.
@Test func aDroppedHandedOverTerminalLeavesTheReapingToItsSuccessor() async throws {
    var old: PTY? = try PTY(argv: ["/bin/sh", "-c", "read l; exit 3"], cwd: "/tmp", env: [:], trampoline: nil)
    old?.start()
    let pid = try #require(old?.pid), fd = try #require(old?.handOver())
    old = nil
    let next = PTY(adopting: pid, fd: fd), box = Box()
    next.onExit = { box.exit($0) }
    next.start()
    next.write(Data("go\n".utf8))
    #expect(try await waitFor(5) { box.code != nil })
    #expect(box.code.map { ($0 >> 8) & 0xff } == 3)
}
