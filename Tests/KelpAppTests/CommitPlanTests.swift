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
