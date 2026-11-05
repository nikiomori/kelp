import Foundation
import Testing
import Core
import GitKit
import Agents
@testable import Daemon

/// Each turn is kept, named by the prompt that started it, and any one of them reads as its own diff: up to where the
/// next one began.
@Test func everyTurnIsKeptAndReadsAsItsOwnDiff() async throws {
    let w = try await world(agents: [AgentManifest(id: "claude-like", name: "Agent", command: "/bin/cat")]); defer { w.d.stop() }
    let wt = try await desk(w, "history")
    let s: Session = try await w.c.call("session.create", .obj(["worktreeId": .string(wt.id), "agent": "claude-like"]), as: Session.self)
    let live = try #require(w.d.sessions.existing(s.id))
    func turn(_ prompt: String, writes file: String) async throws {
        _ = try await w.c.call(SessionSend(id: s.id, text: prompt, enter: true))   // typed once the program is ready
        #expect(try await waitFor(5) { try await w.c.call("session.read", .obj(["id": .string(s.id)])).string?.contains(prompt) == true })
        live.noteTurn(.working)
        #expect(try await waitFor(5) { try await w.c.call(SessionTurns(id: s.id)).first?.prompt == prompt })
        try "\(prompt)\n".write(toFile: wt.path + "/" + file, atomically: true, encoding: .utf8)
        live.noteTurn(.idle)
    }
    try await turn("write the first file", writes: "one.txt")
    try await turn("now the second one", writes: "two.txt")
    let marks = try await w.c.call(SessionTurns(id: s.id))
    #expect(marks.map(\.prompt) == ["now the second one", "write the first file"])
    var first = GitDiff(id: wt.id, source: "turn", session: s.id); first.turn = marks[1].id
    #expect(try await w.c.call(first).map(\.path) == ["one.txt"])   // not the second turn's file
    var last = GitDiff(id: wt.id, source: "turn", session: s.id); last.turn = marks[0].id
    #expect(try await w.c.call(last).map(\.path) == ["two.txt"])
    #expect(try Git.run(["log", "--all", "--oneline"], cwd: wt.path).split(separator: "\n").count == 1)   // nothing in the project's history
}

/// A turn undone puts its folder back as the turn found it: after a look at what goes, only while nothing changed since
/// the look, with .env files left alone, and never past a commit or beside another agent in the folder.
@Test func aTurnIsUndoneOnlyAsPreviewed() async throws {
    let w = try await world(agents: [AgentManifest(id: "claude-like", name: "Agent", command: "/bin/cat")]); defer { w.d.stop() }
    let wt = try await desk(w, "undo")
    let s: Session = try await w.c.call("session.create", .obj(["worktreeId": .string(wt.id), "agent": "claude-like"]), as: Session.self)
    let live = try #require(w.d.sessions.existing(s.id))
    let file = { (name: String) in try? String(contentsOfFile: wt.path + "/" + name, encoding: .utf8) }
    let before = file("a.txt")
    live.noteTurn(.working)
    let turn = try #require(try await waitFor(5) { !(try await w.c.call(SessionTurns(id: s.id))).isEmpty } ? try await w.c.call(SessionTurns(id: s.id)).first : nil)
    try "agent's\n".write(toFile: wt.path + "/a.txt", atomically: true, encoding: .utf8)
    try "made\n".write(toFile: wt.path + "/new.txt", atomically: true, encoding: .utf8)
    try "KEY=1\n".write(toFile: wt.path + "/.env", atomically: true, encoding: .utf8)
    live.noteTurn(.idle)
    let plan = try await w.c.call(SessionTurnUndo(id: s.id, turn: turn.id))
    #expect(plan.files.sorted() == ["a.txt", "new.txt"])   // .env stays out
    try "later\n".write(toFile: wt.path + "/a.txt", atomically: true, encoding: .utf8)   // changed after the look
    await #expect(throws: (any Error).self) { try await w.c.call(SessionTurnUndo(id: s.id, turn: turn.id, apply: true, state: plan.state)) }
    #expect(file("a.txt") == "later\n" && file("new.txt") == "made\n")
    let fresh = try await w.c.call(SessionTurnUndo(id: s.id, turn: turn.id))
    _ = try await w.c.call(SessionTurnUndo(id: s.id, turn: turn.id, apply: true, state: fresh.state))
    #expect(file("a.txt") == before && file("new.txt") == nil && file(".env") == "KEY=1\n")
    // Another agent in the folder, or a commit since: no.
    let other: Session = try await w.c.call("session.create", .obj(["worktreeId": .string(wt.id), "agent": "claude-like"]), as: Session.self)
    await #expect(throws: (any Error).self) { try await w.c.call(SessionTurnUndo(id: s.id, turn: turn.id)) }
    _ = try await w.c.call("session.kill", .obj(["id": .string(other.id)]))
    #expect(try await waitFor(5) { w.d.sessions.existing(other.id)?.snapshot.status ?? .exited == .exited })
    try Git.run(["commit", "-q", "--allow-empty", "-m", "moved on"], cwd: wt.path)
    await #expect(throws: (any Error).self) { try await w.c.call(SessionTurnUndo(id: s.id, turn: turn.id)) }
}
