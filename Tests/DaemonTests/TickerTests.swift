import Core
import Foundation
import Testing

@testable import Daemon

/// The 0.5 s ticker passes over a session at rest (started up, idle, nothing waiting to be typed or timed): only one
/// with something to do is ticked.
@Test func theTickerPassesOverASessionAtRest() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let workspace = try #require(try await w.c.call(WorktreeList(repoId: w.repo.id)).first)
    let s = try await w.c.call(SessionCreate(worktreeId: workspace.id, command: "cat"))   // prints nothing: idle
    let ls = try #require(w.d.sessions.existing(s.id))
    #expect(ls.tick())   // starting up: the wait for it to draw and go quiet runs on the tick
    #expect(try await waitFor(10) { w.d.sessions.tick() == 0 })   // started up and idle: nothing to do
    ls.state.withLock { $0.pendingPrompts.append(("hello", true, false)) }   // text to type once it's ready
    #expect(w.d.sessions.tick() == 1)
}
