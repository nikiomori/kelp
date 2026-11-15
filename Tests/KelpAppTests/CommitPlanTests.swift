import Core
import Testing

@testable import BuiltinGit

/// What an agent proposed is held to the changed files, each in one commit; moving a file keeps every commit's place.
@Test func commitPlanEdits() {
    let proposed = [
        PlannedCommit(files: ["a.swift", "gone.swift", "b.swift"], message: "feat: a"),
        PlannedCommit(files: ["b.swift", "c.sh"], message: "build: c"),
        PlannedCommit(files: ["gone.swift"], message: "nothing left")
    ]
    var plan = CommitPlan(agent: "Claude Code", proposed: proposed, changed: ["a.swift", "b.swift", "c.sh", "d.md"])
    #expect(plan.commits.map(\.files) == [["a.swift", "b.swift"], ["c.sh"]])
    #expect(plan.number(of: "c.sh") == 2 && plan.number(of: "d.md") == nil)

    plan.move("c.sh", to: 0)   // its commit empties and goes
    #expect(plan.commits.map(\.files) == [["a.swift", "b.swift", "c.sh"]])
    plan.move("a.swift", to: 1)   // a new commit, its message to write
    #expect(plan.commits.map(\.files) == [["b.swift", "c.sh"], ["a.swift"]] && plan.commits[1].message.isEmpty)
    plan.move("a.swift", to: 1)   // where it is already
    plan.move("d.md", to: 1)
    #expect(plan.commits[1].files == ["a.swift", "d.md"])
    plan.move("b.swift", to: nil)
    #expect(plan.files == ["c.sh", "a.swift", "d.md"])
    plan.merge()
    #expect(plan.commits.count == 1 && plan.commits[0].message == "feat: a\n\n")
}

extension AppOfItsOwn {
    /// The daemon forgets a plan as it hands it over, so the panel takes it last, once the changed files are read: a
    /// status that failed leaves the plan there and says nothing of the agent. It was taken first, the failed read then
    /// passed for no changes, and the panel said "No commits from …" with the proposal gone.
    @Test func anAgentsPlanIsTakenLastAndOutlivesAStatusThatFailed() async throws {
        let rig = try await AppRig()
        defer { rig.done() }
        let wid = rig.workspace.id, vc = SourceControlController(app: rig.app)
        rig.show(vc, 320, 700)
        try rig.write("f.txt", "b\n")
        func agentStops() async throws {
            _ = try await rig.client.call(CommitPlanAdd(worktreeId: wid, files: ["f.txt"], message: "fix: f"))
            vc.agentCommits[wid] = AgentCommit(agentId: "claude", agent: "Claude Code", hint: "", files: 1)
            await vc.finishAgent(wid)?.value
        }
        try await agentStops()
        #expect(vc.message.string == "fix: f")   // one commit of every file: the message, in the field
        #expect(try await rig.client.call(CommitPlanTake(worktreeId: wid)).isEmpty)

        try rig.write(".git/index", "junk")   // git can't read the folder: its status fails
        try await agentStops()
        #expect(vc.notes[wid] == nil, "\(vc.notes[wid]?.text ?? "")")
        #expect(try await rig.client.call(CommitPlanTake(worktreeId: wid)).map(\.message) == ["fix: f"])
    }
}
