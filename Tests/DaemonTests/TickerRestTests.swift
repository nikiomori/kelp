import Core
import Foundation
import IOKit.pwr_mgt
import Testing

@testable import Daemon

/// With no session running the ticker's round does nothing per session (no tick, pause or restart pass), but the Mac's
/// keep-awake is still applied: an assertion the last agent left is let go.
@Test func theTickerRestsWithNoSessions() async throws {
    let w = try await world()
    defer { w.d.stop() }
    var id: IOPMAssertionID = 0
    let kind = kIOPMAssertPreventUserIdleSystemSleep as String
    let made = IOPMAssertionCreateWithName(
        kind as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Kelp's tests" as CFString, &id)
    try #require(made == kIOReturnSuccess)
    let held = id
    w.d.sessions.keepAwake.held.withLock { $0 = (held, kind) }   // what the last working agent left
    #expect(!w.d.tick())
    #expect(w.d.sessions.keepAwake.held.withLock { $0.id == 0 && $0.type == nil })
    let workspace = try #require(try await w.c.call(WorktreeList(repoId: w.repo.id)).first)
    _ = try await w.c.call(SessionCreate(worktreeId: workspace.id, command: "cat"))
    #expect(w.d.tick())
}
