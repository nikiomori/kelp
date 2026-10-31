import Foundation
import Testing
import Core
import Agents
@testable import Daemon

/// A running session is listed with the revision its last change went out with. With an older one the app keeps the copy it
/// has, and a list read after a reconnect never brought back a change it had missed.
@Test func aRunningSessionIsListedWithItsRevision() async throws {
    let w = try await world(); defer { w.d.stop() }
    let wt = try await desk(w, "listed")
    let s = try await w.c.call(SessionCreate(worktreeId: wt.id, command: "exec cat"))
    _ = try await w.c.call(SessionHook(id: s.id, event: "waiting"))
    #expect(try await waitFor(10) {
        let saved = try w.d.sessions.store.session(s.id)
        let listed = try await w.c.call(SessionList()).first { $0.id == s.id }
        return saved?.status == .waiting && listed?.revision == saved?.revision
    })
}
