import Core
import Foundation
import Testing
import os

@testable import Daemon

/// Quick work has a cap of its own: past it, more waits for a turn instead of each starting a thread.
@Test func quickWorkWaitsPastItsOwnCap() async throws {
    let slots = Slots(8, quick: 2)
    let running = OSAllocatedUnfairLock(initialState: (now: 0, most: 0))
    try await withThrowingTaskGroup(of: Void.self) { g in
        for _ in 0..<6 {
            g.addTask {
                try await slots.run(quick: true) {
                    running.withLock {
                        $0.now += 1
                        $0.most = max($0.most, $0.now)
                    }
                    usleep(100_000)
                    running.withLock { $0.now -= 1 }
                }
            }
        }
        try await g.waitForAll()
    }
    #expect(running.withLock { $0.most } == 2)
}

/// What the user is waiting on (a paused tab waking) runs at once, not after every held slot.
@Test func workRunNowDoesntWaitForASlot() async throws {
    let slots = Slots(1), held = DispatchSemaphore(value: 0)
    let slow = Task { try await slots.run { held.wait() } }
    try await Task.sleep(for: .milliseconds(100))   // the one slot is taken
    #expect(try await slots.runNow { 42 } == 42)
    held.signal()
    try await slow.value
}

/// A client that sends without ever ending its line is hung up on past the line limit, not kept in memory for good.
@Test func aLineThatNeverEndsIsHungUpOn() async throws {
    let (d, _, root) = try daemon()
    defer { d.stop() }
    let fd = try Unix.connect(root.appendingPathComponent("kelp.sock").path)
    defer { close(fd) }
    Unix.noSigPipe(fd)
    let chunk = Data(repeating: 0x61, count: 1 << 20)
    var sent = 0
    while sent <= Daemon.lineLimit + (8 << 20), Unix.writeAll(fd, chunk) { sent += chunk.count }
    #expect(sent <= Daemon.lineLimit + (8 << 20))   // a write failed: the daemon hung up
}

/// A session's wake lock is kept only while someone holds or waits for it: a deleted session leaves none behind.
@Test func wakeLocksGoWhenNobodyHoldsThem() {
    let locks = WakeLocks()
    locks.withLock("a") { #expect(locks.count == 1) }
    locks.withLocks(["a", "b"]) { #expect(locks.count == 2) }
    #expect(locks.count == 0)
}

/// A session's input lane goes once nothing waits on it: one per session ever typed into doesn't stay for good.
@Test func inputLanesGoWhenIdle() {
    let lanes = SessionLanes()
    lanes.runHere("a") { #expect(lanes.count == 1) }
    #expect(lanes.count == 0)
}

/// Once the daemon stopped its watches, a watch.start still on its way (a reader applying it in order) starts none.
@Test func noWatchStartsAfterStopAll() throws {
    let (d, _, _) = try daemon()
    defer { d.stop() }
    d.watches.stopAll()
    d.watches.start(.init(topic: .activity, key: ""), conn: 1)
    #expect(d.watches.count == 0)
}

/// What the user waits on has a cap of its own too (a client looping on attach), apart from slow work's and quick work's.
@Test func workRunNowHasACapOfItsOwn() async throws {
    let slots = Slots(8, quick: 4)   // runNow: 2 at once
    let running = OSAllocatedUnfairLock(initialState: (now: 0, most: 0))
    try await withThrowingTaskGroup(of: Void.self) { g in
        for _ in 0..<5 {
            g.addTask {
                try await slots.runNow {
                    running.withLock {
                        $0.now += 1
                        $0.most = max($0.most, $0.now)
                    }
                    usleep(100_000)
                    running.withLock { $0.now -= 1 }
                }
            }
        }
        try await g.waitForAll()
    }
    #expect(running.withLock { $0.most } == 2)
}

/// Closed for an update: what has a slot finishes, what waits for one and what comes later is refused, not started.
@Test func closedSlotsFinishWhatRunsAndStartNothing() async throws {
    let slots = Slots(1), held = DispatchSemaphore(value: 0)
    let running = Task {
        try await slots.run {
            held.wait()
            return 1
        }
    }
    try await Task.sleep(for: .milliseconds(50))   // the one slot is taken
    let waiting = Task { try await slots.run { 2 } }
    try await Task.sleep(for: .milliseconds(50))   // queued behind the one running (refused either way)
    slots.close()
    held.signal()
    #expect(try await running.value == 1)
    await #expect(throws: RPCError.self) { _ = try await waiting.value }
    await #expect(throws: RPCError.self) { _ = try await slots.run { 3 } }
}

/// A lane holds at most `limit` waiting inputs: past that it says it's full.
@Test func aSessionLaneSaysWhenItsFull() {
    let lanes = SessionLanes(), gate = DispatchSemaphore(value: 0)
    for _ in 0..<SessionLanes.limit { lanes.run("s") { gate.wait() } }
    #expect(lanes.isFull("s") && !lanes.isFull("other"))
    for _ in 0..<SessionLanes.limit { gate.signal() }
}
