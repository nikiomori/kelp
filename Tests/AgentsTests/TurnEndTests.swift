import Core
import Foundation
import Testing

@testable import Agents

private func task(_ id: String, _ type: String = "shell", _ command: String = "npm test") -> JSONValue {
    .obj(["id": .string(id), "type": .string(type), "status": "running", "command": .string(command)])
}

@Test func stopWithSubagentsOrAWorkflowIsNotDone() {
    var t = TurnEnd()
    #expect(t.stop([task("a", "subagent")], goal: nil).0 == .working)
    #expect(t.stop([task("b", "workflow")], goal: nil).0 == .working)
    #expect(t.stop([], goal: nil).0 == .done)
}

/// Claude Code wakes the agent when a command it started in the background ends: until then the turn isn't over.
@Test func stopWaitsForACommandItStartedButNotForAServer() {
    var t = TurnEnd()
    let (v, running) = t.stop([task("t1", "shell", "npm test")], goal: nil)
    #expect(v == .command("npm test") && running == ["npm test"])
    #expect(t.stop([task("d1", "shell", "npm run dev")], goal: nil).0 == .done)   // a dev server never ends
    #expect(t.stop([task("m1", "monitor", "tail log")], goal: nil).0 == .done)
}

@Test func aCommandStillRunningAfterAWholeTurnIsAServer() {
    var t = TurnEnd()
    #expect(t.stop([task("x", "shell", "python -m http.server")], goal: nil).0 == .done)   // server-like words
    #expect(t.stop([task("y", "shell", "./run-forever.sh")], goal: nil).0 == .command("./run-forever.sh"))
    let (v, running) = t.stop([task("y", "shell", "./run-forever.sh")], goal: nil)   // the next turn: still there
    #expect(v == .done && running == ["./run-forever.sh"])
}

@Test func stopWithAnOpenGoalGoesOn() {
    var t = TurnEnd()
    let open = GoalStatus(met: false, condition: "tests pass", id: "1")
    #expect(t.stop([], goal: open).0 == .goal("tests pass"))
    #expect(t.stop([], goal: GoalStatus(met: true, condition: "tests pass", id: "2")).0 == .done)
}

@Test func lastGoalStatusIsReadFromTheTranscriptsTail() {
    // Lines as Claude Code 2.1 writes them; the first is cut, as a tail's first line is.
    let tail = """
        ment","attachment":{"type":"goal_status","met":false}}
        {"type":"attachment","uuid":"u1","attachment":{"type":"goal_status","met":false,"sentinel":true,"condition":"a.txt exists"}}
        {"type":"assistant","message":{"content":"goal_status is a word here"}}
        {"type":"attachment","uuid":"u2","attachment":{"type":"goal_status","met":true,"condition":"a.txt exists","reason":"it does"}}
        {"type":"system","subtype":"stop_hook_summary"}
        """
    #expect(GoalStatus.last(in: tail) == GoalStatus(met: true, condition: "a.txt exists", id: "u2"))
    #expect(GoalStatus.last(in: "{\"type\":\"user\"}") == nil)
}
