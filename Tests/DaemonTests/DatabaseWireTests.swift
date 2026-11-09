import Core
import Foundation
import Testing
import os

@testable import Daemon

/// A server that stops answering (a network gone mid-read) doesn't hold a call past its time: the connection is
/// closed and the call says so; one that answers in time is answered.
@Test func aWireCallThatGetsNoAnswerEndsAtItsTime() async throws {
    let db = DatabaseInfo(name: "app", engine: .postgres, host: "db.example.com")
    let closed = OSAllocatedUnfairLock(initialState: false)
    let started = Date()
    do {
        _ = try await DatabaseWire.within(0.2, db, close: { closed.withLock { $0 = true } }) {
            try await Task.sleep(for: .seconds(60))
            return 1
        }
        Issue.record("answered")
    } catch let failure as DatabaseFailure {
        #expect(failure.message.contains("No answer from app"))
    }
    #expect(closed.withLock { $0 } && Date().timeIntervalSince(started) < 30)
    #expect(try await DatabaseWire.within(30, db, close: {}) { 7 } == 7)
}
