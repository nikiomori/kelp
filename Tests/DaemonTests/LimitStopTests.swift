import Agents
import Core
import Foundation
import TestSupport
import Testing

@testable import Daemon

private func stopped(_ p: World, _ s: Session) async throws {
    let said: JSONValue = .obj([
        "notification_type": "stop_failure",
        "message": "You've hit your 5-hour limit · resets 3:40pm (Europe/Helsinki)"
    ])
    _ = try await p.c.call("session.hook", .obj(["id": .string(s.id), "event": "working"]))
    _ = try await p.c.call("session.hook", .obj(["id": .string(s.id), "event": "done", "notification": said]))
}

/// A StopFailure that names a plan limit: the record says so, kept in the store, until the agent works again.
@Test func aLimitStaysOnTheRecordUntilTheAgentWorksAgain() async throws {
    let p = try await world()
    defer { p.d.stop() }
    let w = try await firstWorkspace(p)
    let s: Session = try await p.c.call(
        "session.create", .obj(["worktreeId": .string(w.id), "command": "sleep 30"]), as: Session.self)
    func record() async throws -> Session? {
        try await p.c.call("session.list", as: [Session].self).first { $0.id == s.id }
    }
    try await stopped(p, s)
    #expect(try await waitFor { try await record()?.status == .done })
    #expect(try await record()?.limitHit?.kind == "5-hour")
    #expect(try await record()?.limitHit?.resets == "3:40pm")
    #expect(try await waitFor { try p.d.store.session(s.id)?.limitHit?.kind == "5-hour" })
    _ = try await p.c.call("session.hook", .obj(["id": .string(s.id), "event": "working"]))
    #expect(try await waitFor { try await record()?.limitHit == nil })
    // A turn that ends any other way says nothing of limits.
    _ = try await p.c.call("session.hook", .obj(["id": .string(s.id), "event": "done"]))
    #expect(try await waitFor { try await record()?.status == .done })
    #expect(try await record()?.limitHit == nil)
    _ = try await p.c.call("session.kill", .obj(["id": .string(s.id)]))
}

/// Told to go on: "continue" once, at its time, while it still stands where the limit left it; taken back, or gone on by
/// itself, nothing is typed.
@Test func continueIsTypedOnceAtItsTime() async throws {
    let p = try await world()
    defer { p.d.stop() }
    let w = try await firstWorkspace(p)
    let s: Session = try await p.c.call(
        "session.create", .obj(["worktreeId": .string(w.id), "command": "cat"]), as: Session.self)
    func record() async throws -> Session? {
        try await p.c.call("session.list", as: [Session].self).first { $0.id == s.id }
    }
    func printed() async throws -> String {
        try await p.c.call("session.read", .obj(["id": .string(s.id)])).string ?? ""
    }
    let soon = Date().addingTimeInterval(1)

    // Not without a limit: there's nothing to go on from.
    _ = try await p.c.call(SessionContinueAt(id: s.id, at: soon))
    #expect(try await record()?.continueAt == nil)

    try await stopped(p, s)
    #expect(try await waitFor { try await record()?.limitHit != nil })
    _ = try await p.c.call(SessionContinueAt(id: s.id, at: soon.addingTimeInterval(600)))
    #expect(try await record()?.continueAt != nil)
    _ = try await p.c.call(SessionContinueAt(id: s.id, at: nil))   // Cancel
    #expect(try await record()?.continueAt == nil)

    // It went on by itself: what was set goes with the limit.
    _ = try await p.c.call(SessionContinueAt(id: s.id, at: soon.addingTimeInterval(600)))
    _ = try await p.c.call("session.hook", .obj(["id": .string(s.id), "event": "working"]))
    #expect(try await waitFor { try await record()?.continueAt == nil })

    try await stopped(p, s)
    #expect(try await waitFor { try await record()?.limitHit != nil })
    _ = try await p.c.call(SessionContinueAt(id: s.id, at: Date()))
    #expect(try await waitFor(10) { try await printed().contains("continue") })
    #expect(try await waitFor { try await record()?.continueAt == nil })
    try await Task.sleep(for: .seconds(1.2))   // a few ticks
    #expect(try await printed().components(separatedBy: "continue").count - 1 <= 2)   // once: the terminal's echo and cat's
    _ = try await p.c.call("session.kill", .obj(["id": .string(s.id)]))
}

/// An agent without hooks: the words count by a turn that stopped, not in the middle of one.
@Test func wordsCountOnlyByATurnThatStopped() throws {
    func state() -> LiveSession.State {
        LiveSession.State(
            record: Session(cwd: "/", command: "codex", agent: "codex"),
            manifest: AgentManifest(id: "codex", name: "Codex", command: "codex"),
            logSize: 0, callbacks: .init(), trail: .init(history: tmp(), session: "s"))
    }
    let words = Data("You've hit your usage limit. Try again at Oct 30, 2026 3:40 PM.".utf8)
    var s = state()
    s.ring = words
    _ = s.newLimits(words)
    #expect(s.record.limitHit == nil)   // still working
    s.detector.hook("done")
    #expect(s.sync()?.limitHit?.resets == "Oct 30, 2026 3:40 PM")

    var late = state()   // long after they scrolled by
    late.ring = words
    _ = late.newLimits(words)
    late.limitSeen?.at = Date().addingTimeInterval(-60)
    late.detector.hook("done")
    #expect(late.sync()?.limitHit == nil)

    var after = state()   // the turn stopped a moment before the words came
    after.detector.hook("done")
    _ = after.sync()
    after.ring = words
    _ = after.newLimits(words)
    #expect(after.record.limitHit?.kind == "usage")
}

/// A turn an API error ended didn't finish: the row says Failed and what went wrong, and the next prompt takes that back.
@Test func aTurnThatFailedSaysSo() async throws {
    let p = try await world()
    defer { p.d.stop() }
    let w = try await firstWorkspace(p)
    let s: Session = try await p.c.call(
        "session.create", .obj(["worktreeId": .string(w.id), "command": "sleep 30"]), as: Session.self)
    func record() async throws -> Session? {
        try await p.c.call("session.list", as: [Session].self).first { $0.id == s.id }
    }
    let said: JSONValue = .obj(["notification_type": "stop_failure", "message": "API Error: 529 overloaded"])
    _ = try await p.c.call("session.hook", .obj(["id": .string(s.id), "event": "working"]))
    _ = try await p.c.call("session.hook", .obj(["id": .string(s.id), "event": "done", "notification": said]))
    #expect(try await waitFor { try await record()?.status == .error })
    #expect(try await record()?.summary == "API Error: 529 overloaded")
    #expect(try await record()?.limitHit == nil)
    _ = try await p.c.call("session.hook", .obj(["id": .string(s.id), "event": "working"]))
    #expect(try await waitFor { try await record()?.status == .working })
}

/// An API error that passes (overloaded, a dropped connection): Kelp goes on after a minute, then five, and then waits for
/// someone; a turn that ends well starts the count again. A login or a bill gone isn't tried again.
@Test func anErrorThatPassesGoesOnTwiceInARow() async throws {
    let p = try await world()
    defer { p.d.stop() }
    let w = try await firstWorkspace(p)
    let s: Session = try await p.c.call(
        "session.create", .obj(["worktreeId": .string(w.id), "command": "sleep 30"]), as: Session.self)
    func record() async throws -> Session? {
        try await p.c.call("session.list", as: [Session].self).first { $0.id == s.id }
    }
    /// After a turn that ended so: in how many seconds it goes on, nil if it doesn't.
    func ended(_ error: String?) async throws -> Int? {
        let said: JSONValue? = error.map {
            .obj(["notification_type": "stop_failure", "message": .string("API Error: \($0)"), "error": .string($0)])
        }
        _ = try await p.c.call("session.hook", .obj(["id": .string(s.id), "event": "working"]))
        #expect(try await waitFor { try await record()?.status == .working })
        _ = try await p.c.call(
            "session.hook", .obj(["id": .string(s.id), "event": "done", "notification": said ?? .null]))
        #expect(try await waitFor { try await record()?.status == (error == nil ? .done : .error) })
        return try await record()?.continueAt.map { Int($0.timeIntervalSinceNow.rounded()) }
    }
    func near(_ seconds: Int) -> ClosedRange<Int> { seconds - 10...seconds }   // read a moment after it was set
    #expect(try await ended("overloaded").map(near(60).contains) == true)
    #expect(try await ended("server_error").map(near(300).contains) == true)
    #expect(try await ended("overloaded") == nil)   // twice in a row: someone looks
    #expect(try await ended(nil) == nil)
    #expect(try await ended("overloaded").map(near(60).contains) == true)   // the count started again
    #expect(try await ended("authentication_failed") == nil)
    _ = try await p.c.call("session.kill", .obj(["id": .string(s.id)]))
}
