import Core
import Foundation
import Testing

@testable import Daemon

/// Where a session is in its life (`SessionTable.Phase`), step by step: running, let go by an idle pause (input waits for
/// it), paused by its record or by a save that failed, ended, deleted. Input wakes only what's running, letting go or
/// paused (`Sessions.mustWake`).
@Test func aSessionsPhaseFollowsItsLife() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await workspace(w, "phase")
    let s: Session = try await w.c.call(
        "session.create", .obj(["worktreeId": .string(wt.id), "command": "cat"]), as: Session.self)
    let table = w.d.sessions.live, ls = try #require(w.d.sessions.existing(s.id))
    var record = try #require(try w.d.store.session(s.id))
    func phase() -> SessionTable.Phase { table.phase(s.id) { record } }
    #expect(phase() == .running)
    #expect(table.letGo(ls) { _ in true })
    defer { _ = ls.pty.terminate() }
    #expect(phase() == .lettingGo)
    #expect(throws: Never.self) { try w.d.sessions.mustWake(s.id) }
    table.saved(s.id, paused: false, written: true)   // a status queued before the pause
    #expect(phase() == .lettingGo)
    table.saved(s.id, paused: true, written: false)   // the pause itself, on a full disk
    #expect(phase() == .paused(saved: false))
    table.letGone(s.id)
    #expect(phase() == .paused(saved: false))
    #expect(w.d.sessions.isPaused(record))
    table.saved(s.id, paused: false, written: true)   // woken, and saved
    #expect(phase() == .ended)
    record.status = .paused
    #expect(phase() == .paused(saved: true))
    record.status = .exited
    #expect(phase() == .ended)
    #expect(table.phase(s.id) { nil } == .deleted)
    table.saved(s.id, paused: true, written: false)
    table.forget(s.id)
    #expect(phase() == .ended)
}

/// Neither an ended session nor one that's gone takes input: it isn't woken.
@Test func onlyARunningOrPausedSessionWakesForInput() async throws {
    let w = try await world()
    defer { w.d.stop() }
    var s = Session(worktreeId: nil, cwd: "/tmp", command: "cat", argv: ["cat"])
    s.status = .exited
    try w.d.store.save(s)
    #expect(throws: RPCError.self) { try w.d.sessions.mustWake(s.id) }
    #expect(throws: RPCError.self) { try w.d.sessions.mustWake(UUID().uuidString) }
    s.status = .paused
    try w.d.store.save(s)
    #expect(throws: Never.self) { try w.d.sessions.mustWake(s.id) }
}
