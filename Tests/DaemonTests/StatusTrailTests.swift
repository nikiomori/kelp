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

/// The trail says what a session's status went through and what it heard, a hook that changed nothing too. It outlives the
/// program, hears the hook that comes too late, and goes with the session.
@Test func theTrailSaysWhatASessionWentThrough() async throws {
    let w = try await world(); defer { w.d.stop() }
    let wt = try await desk(w, "trail")
    let s = try await w.c.call(SessionCreate(worktreeId: wt.id, command: "exec cat"))
    func hook(_ event: String, _ type: String? = nil) async throws {
        _ = try await w.c.call(SessionHook(id: s.id, event: event, notification: type.map { .obj(["notification_type": .string($0)]) }))
    }
    try await hook("working")
    try await hook("waiting", "idle_prompt")
    try await hook("waiting", "permission_request")
    try await hook("done")
    _ = try await w.c.call(SessionKill(id: s.id))
    #expect(try await waitFor(10) { w.d.sessions.existing(s.id) == nil })
    try await hook("working")
    #expect(try await waitFor(5) { try await w.c.call(SessionTrail(id: s.id)).contains("nothing runs here") })
    let trail = try await w.c.call(SessionTrail(id: s.id))
    var rest = Substring(trail)
    for line in ["hook working", "idle → working  hook: working", "hook waiting idle_prompt: asks nothing", "hook waiting permission_request",
                 "working → waiting  hook: waiting", "hook done", "stop: done", "waiting → done  hook: done", "hook working: nothing runs here"] {
        let found = try #require(rest.range(of: line), "no \(line) in\n\(trail)")
        rest = rest[found.upperBound...]
    }
    #expect(trail.split(separator: "\n").allSatisfy { $0.contains("  up ") })

    let file = try #require(try w.d.sessions.trail(s.id)).url
    #expect(FileManager.default.fileExists(atPath: file.path))
    w.d.sessions.discard(try #require(try w.d.sessions.store.session(s.id)))
    #expect(!FileManager.default.fileExists(atPath: file.path))
    await #expect(throws: RPCError.self) { try await w.c.call(SessionTrail(id: s.id)) }
}

/// The id comes from outside and names a file: only a session Kelp has gets one, read or written.
@Test func aTrailIsOnlyASessionsOwn() async throws {
    let (d, c, root) = try daemon(); defer { d.stop() }
    let outside = root.appendingPathComponent("outside.trail")
    try Data("not a trail".utf8).write(to: outside)
    await #expect(throws: RPCError.self) { try await c.call(SessionTrail(id: "../outside")) }
    _ = try await c.call(SessionHook(id: "../outside", event: "done"))
    #expect(try String(contentsOf: outside, encoding: .utf8) == "not a trail")
}

/// Past its limit a trail keeps its newer half, in whole lines.
@Test func aTrailKeepsItsNewerHalf() throws {
    let dir = tmp(); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let t = StatusTrail(history: dir, session: "s"), filler = String(repeating: "x", count: 100)
    let lines = 2 * StatusTrail.limit / 100
    for i in 0..<lines { t.add("\(i) \(filler)") }
    let kept = t.read()
    #expect(kept.utf8.count <= StatusTrail.limit)
    #expect(kept.utf8.count > StatusTrail.limit / 4)
    #expect(kept.hasSuffix("\(lines - 1) \(filler)\n"))
    #expect(kept.split(separator: "\n").allSatisfy { $0.contains("  up ") && $0.hasSuffix(filler) })
}
