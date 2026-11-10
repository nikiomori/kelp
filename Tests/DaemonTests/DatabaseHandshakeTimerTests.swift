import Core
import Foundation
import NIOCore
import Testing
import os

@testable import Daemon

/// A handshake that answered in time is over: its timer says nothing later. It used to run on and close the
/// connection it had timed (`late`), mid-call, once its seconds had passed.
@Test func aHandshakeAnsweredInTimeIsntClosedLater() async throws {
    let loop = DatabaseWire.eventLoop, late = OSAllocatedUnfairLock(initialState: false)
    let db = DatabaseInfo(name: "quick", engine: .mysql, host: "127.0.0.1", port: 1, user: "u")
    let got = try await DatabaseWire.first(loop.makeSucceededFuture(7), within: 0.05, db) {
        late.withLock { $0 = true }
    }
    #expect(got == 7)
    // On the timer's own loop and after its time: by this task's turn the timer's has come, if it was still to come.
    try await loop.scheduleTask(in: .milliseconds(200)) {}.futureResult.get()
    #expect(!late.withLock { $0 })
}

/// One that didn't answer fails at its time, and is closed then.
@Test func aHandshakeThatNeverAnswersIsClosedAtItsTime() async throws {
    let loop = DatabaseWire.eventLoop, late = OSAllocatedUnfairLock(initialState: false)
    let db = DatabaseInfo(name: "silent", engine: .mysql, host: "127.0.0.1", port: 1, user: "u")
    let never = loop.makePromise(of: Int.self)
    defer { never.succeed(0) }
    do {
        _ = try await DatabaseWire.first(never.futureResult, within: 0.05, db) { late.withLock { $0 = true } }
        Issue.record("it answered")
    } catch { #expect("\(error)".contains("No answer from silent")) }
    #expect(late.withLock { $0 })
}
