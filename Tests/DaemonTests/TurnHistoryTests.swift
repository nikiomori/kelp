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
