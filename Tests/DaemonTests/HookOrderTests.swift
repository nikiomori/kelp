import Agents
import Core
import Foundation
import Testing

@testable import Daemon

/// Hooks run on threads of their own. An older one past `newest` before a newer one went first changes nothing: a subagent's
/// question landing after the main thread's Stop left Needs You with nothing asked.
@Test func anOlderHookCantLandAfterANewerOne() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await workspace(w, "order")
    let s = try await w.c.call(SessionCreate(worktreeId: wt.id, command: "exec cat"))
    let ls = try #require(w.d.sessions.existing(s.id))
    #expect(ls.newest(10, says: true) && ls.newest(20, says: true))
    #expect(ls.stop([], goal: nil, at: 20) != nil)
    ls.hook(.waiting, asker: "", at: 10)
    #expect(ls.state.withLock { $0.detector.status } != .waiting)
    #expect(ls.state.withLock { $0.kept.asking.isEmpty })
    #expect(ls.stop([], goal: nil, at: 10) == nil)
}

/// `SessionHook.send` sends again when the daemon went away with its reply: the one dialog counts once, or the row stays
/// asking after its answer.
@Test func aHookSentAgainCountsOnce() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await workspace(w, "again")
    let s = try await w.c.call(SessionCreate(worktreeId: wt.id, command: "exec cat"))
    for _ in 0..<2 {
        _ = try await w.c.call(SessionHook(id: s.id, event: "waiting", hookName: "PermissionRequest", at: 50))
    }
    #expect(w.d.sessions.existing(s.id)?.state.withLock { $0.kept.asking.values.reduce(0, +) } == 1)
}

/// A word no hooks file writes (a typo in an agent's own) is no event: it doesn't count as a newer hook.
@Test func aHookThatNamesNoEventChangesNothing() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await workspace(w, "typo")
    let s = try await w.c.call(SessionCreate(worktreeId: wt.id, command: "exec cat"))
    let ls = try #require(w.d.sessions.existing(s.id))
    #expect(ls.newest(10, says: true))
    _ = try await w.c.call(SessionHook(id: s.id, event: "wroking", at: 20))
    #expect(ls.state.withLock { $0.newestHook } == 10)
    #expect(ls.newest(15, says: true))
}
