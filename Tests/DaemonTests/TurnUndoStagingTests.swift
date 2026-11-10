import Agents
import Core
import Foundation
import GitKit
import Testing

@testable import Daemon

/// Undoing a turn keeps what the user had staged before it (part of a file, a new file added) and drops only what was
/// staged during the turn; Redo gives the turn's index back as well as its files.
@Test func undoingATurnKeepsWhatTheUserHadStaged() async throws {
    let w = try await world(agents: [AgentManifest(id: "claude-like", name: "Agent", command: "/bin/cat")])
    defer { w.d.stop() }
    let wt = try await workspace(w, "staging")
    let lines = (1...10).map { "line \($0)" }
    func text(_ changes: [Int: String]) -> String {
        lines.enumerated().map { changes[$0.offset + 1] ?? $0.element }.joined(separator: "\n") + "\n"
    }
    func write(_ name: String, _ content: String) throws {
        try content.write(toFile: wt.path + "/" + name, atomically: true, encoding: .utf8)
    }
    let file = { (name: String) in try? String(contentsOfFile: wt.path + "/" + name, encoding: .utf8) }
    let staged = { (name: String) in try? Git.run(["show", ":" + name], cwd: wt.path) }
    try write("f.txt", text([:]))
    try Git.run(["add", "f.txt"], cwd: wt.path)
    try Git.run(["commit", "-qm", "ten lines"], cwd: wt.path)
    // The user stages the first line's change but not the last one's (`git add -p`), and adds a new file.
    let userStaged = text([1: "mine"]), userTree = text([1: "mine", 10: "mine too"])
    try write("f.txt", userStaged)
    try Git.run(["add", "f.txt"], cwd: wt.path)
    try write("f.txt", userTree)
    try write("u.txt", "user's\n")
    try Git.run(["add", "u.txt"], cwd: wt.path)
    let s: Session = try await w.c.call(
        "session.create", .obj(["worktreeId": .string(wt.id), "agent": "claude-like"]), as: Session.self)
    let live = try #require(w.d.sessions.existing(s.id))
    live.noteTurn(.working)
    #expect(try await waitFor(10) { !(try await w.c.call(SessionTurns(id: s.id))).isEmpty })
    let turn = try #require(try await w.c.call(SessionTurns(id: s.id)).first)
    // The index is read before the turn is listed and kept just after: waited for, not assumed.
    #expect(
        try await waitFor(10) { Git.succeeds(["rev-parse", "--verify", "-q", Turns.stagedRef(turn.id)], cwd: wt.path) })
    // The agent edits both files and stages everything.
    let agentTree = text([1: "mine", 5: "agent's", 10: "mine too"])
    try write("f.txt", agentTree)
    try write("u.txt", "agent's\n")
    try Git.run(["add", "f.txt", "u.txt"], cwd: wt.path)
    live.noteTurn(.idle)
    let plan = try await w.c.call(SessionTurnUndo(id: s.id, turn: turn.id))
    #expect(plan.files.sorted() == ["f.txt", "u.txt"])
    let after = try await w.c.call(SessionTurnUndo(id: s.id, turn: turn.id, apply: true, state: plan.state))
    #expect(file("f.txt") == userTree && staged("f.txt") == userStaged)   // the user's part still staged
    #expect(file("u.txt") == "user's\n" && staged("u.txt") == "user's\n")   // still added, not untracked
    _ = try await w.c.call(SessionTurnRedo(id: s.id, turn: turn.id, state: after.state))
    #expect(file("f.txt") == agentTree && staged("f.txt") == agentTree)   // the turn's index back too
    #expect(file("u.txt") == "agent's\n" && staged("u.txt") == "agent's\n")
    // Its session gone, the index trees kept for it go with its other refs.
    w.d.sessions.discard(try #require(try w.d.sessions.store.session(s.id)))
    #expect(try Git.run(["for-each-ref", "refs/kelp/"], cwd: wt.path).isEmpty)
}
