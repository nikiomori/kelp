import Core
import Foundation
import GitKit
import Testing

@testable import Daemon

/// What an agent proposes waits for the window, which takes it once; Kelp then commits each part with only its files,
/// and an undo puts them back while nothing came since.
@Test func aProposedPlanIsTakenOnceThenCommittedFileByFile() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await workspace(w, "feat/plan")
    for (name, text) in [("a.txt", "changed\n"), ("n.txt", "new\n")] {
        try text.write(toFile: wt.path + "/" + name, atomically: true, encoding: .utf8)
    }
    #expect(try await w.c.call(CommitPlanAdd(worktreeId: wt.id, files: ["n.txt"], message: "feat: n\n")) == 1)
    #expect(try await w.c.call(CommitPlanAdd(worktreeId: wt.id, files: ["a.txt"], message: "fix: a")) == 2)
    await #expect(throws: (any Error).self) {
        _ = try await w.c.call(CommitPlanAdd(worktreeId: wt.id, files: [], message: "nothing"))
    }
    let plan = try await w.c.call(CommitPlanTake(worktreeId: wt.id))
    #expect(
        plan == [
            PlannedCommit(files: ["n.txt"], message: "feat: n"), PlannedCommit(files: ["a.txt"], message: "fix: a")
        ])
    #expect(try await w.c.call(CommitPlanTake(worktreeId: wt.id)).isEmpty)

    for commit in plan {
        _ = try await w.c.call(GitCommitPaths(worktreeId: wt.id, files: commit.files, message: commit.message))
    }
    #expect(try Git.run(["log", "-2", "--format=%s"], cwd: wt.path, remotes: .none) == "fix: a\nfeat: n\n")
    let head = try Git.line(["rev-parse", "HEAD"], cwd: wt.path, remotes: .none)
    _ = try await w.c.call(GitUndoCommits(worktreeId: wt.id, head: head, count: 2))
    #expect(Set(try await w.c.call(GitStatus(id: wt.id)).filter(\.staged).map(\.path)) == ["a.txt", "n.txt"])
}
