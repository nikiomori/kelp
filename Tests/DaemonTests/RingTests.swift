import Foundation
import Testing
import Core
@testable import Daemon

/// After far more output than the ring holds, what a reader gets is at most the ring's size and ends with the newest
/// bytes. (The ring's storage used to keep all of it: see LiveSession.handleOutput. That part shows in RSS, not here.)
@Test func theRingHoldsTheNewestMegabyte() async throws {
    let p = try await world(); defer { p.d.stop() }
    let c = p.c, w = try await firstWorkspace(p)
    let flood = "head -c 5000000 /dev/zero | tr '\\0' x; echo; echo tail-mark; sleep 30"
    let s: Session = try await c.call("session.create", .obj(["worktreeId": .string(w.id), "command": .string(flood)]), as: Session.self)
    #expect(try await waitFor(30) { try await c.call("session.read", .obj(["id": .string(s.id), "bytes": 200])).string?.contains("tail-mark") == true })
    let all = try await c.call("session.read", .obj(["id": .string(s.id), "bytes": 4_000_000])).string ?? ""
    #expect(all.utf8.count <= LiveSession.ringLimit && all.contains("tail-mark") && all.utf8.count > LiveSession.ringLimit / 2)
}
