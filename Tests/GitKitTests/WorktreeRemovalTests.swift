import Foundation
import TestSupport
import Testing

@testable import Core
@testable import GitKit

/// Removing one worktree keeps the record of another whose folder is away for now (an unmounted disk, a rename).
@Test func removingAWorktreeKeepsOneThatIsAway() throws {
    let repo = try tempRepo()
    let a = try Git.addWorktree(
        repo: repo, branch: "a", base: "main", into: URL(fileURLWithPath: repo + "-a"), copyFiles: [], remotes: .none)
    let b = try Git.addWorktree(
        repo: repo, branch: "b", base: "main", into: URL(fileURLWithPath: repo + "-b"), copyFiles: [], remotes: .none)
    try FileManager.default.moveItem(atPath: a, toPath: a + "-away")
    try Git.removeWorktree(repo: repo, path: b, branch: "b", force: true, remotes: .none)
    #expect(try Git.linkedWorktrees(repo, remotes: .none).map(\.branch) == ["a"])
    try FileManager.default.moveItem(atPath: a + "-away", toPath: a)
    #expect(try Git.run(["status", "--short"], cwd: a, remotes: .none).isEmpty)
    // A folder that isn't a worktree of the repo stays where it is.
    let other = tmp().path
    #expect(throws: GitError.self) {
        try Git.removeWorktree(repo: repo, path: other, branch: nil, force: true, remotes: .none)
    }
    #expect(FileManager.default.fileExists(atPath: other))
}

/// Commits on no branch that git can't count (the folder isn't a repository it can read) refuse the removal rather than
/// read as none; a worktree on a branch has none, even before its first commit.
@Test func uncountableCommitsOnNoBranchRefuseTheRemoval() throws {
    #expect(throws: GitError.self) {
        try Git.checkRemovable(repo: tmp().path, path: tmp().path, branch: nil, force: true, remotes: .none)
    }
    let repo = try tempRepo()
    #expect(try Git.commitsOnNoBranch(repo, remotes: .none) == 0)
    try Git.run(["checkout", "-q", "--orphan", "unborn"], cwd: repo, remotes: .none)
    #expect(try Git.commitsOnNoBranch(repo, remotes: .none) == 0)
}

/// A locked worktree isn't removed: neither its folder nor its record, rather than the folder in the Trash and git's
/// record left behind.
@Test func aLockedWorktreeStays() throws {
    let repo = try tempRepo()
    let p = try Git.addWorktree(
        repo: repo, branch: "kept", base: "main", into: URL(fileURLWithPath: repo + "-kept"), copyFiles: [],
        remotes: .none)
    try Git.run(["worktree", "lock", p], cwd: repo, remotes: .none)
    #expect(throws: GitError.self) {
        try Git.removeWorktree(repo: repo, path: p, branch: "kept", force: true, remotes: .none)
    }
    #expect(FileManager.default.fileExists(atPath: p))
    #expect(try Git.linkedWorktrees(repo, remotes: .none).map(\.branch) == ["kept"])
}

/// A worktree whose path has a newline in it ("…\nlocked") reads as itself: not locked, its path whole.
@Test func aNewlineInAWorktreesPathReadsAsItself() throws {
    let repo = try tempRepo()
    let odd = repo + "-odd\nlocked"
    try Git.run(["worktree", "add", "-q", "-b", "odd", odd, "main"], cwd: repo, remotes: .none)
    let listed = try Git.linkedWorktrees(repo, remotes: .none)
    #expect(listed.count == 1 && listed.first?.path.hasSuffix("-odd\nlocked") == true && listed.first?.locked == false)
}

/// A worktree whose folder is gone is forgotten: git's record of it and its branch go. A branch with commits no other
/// branch or remote has is refused (the record stays too) unless the commits may go.
@Test func aWorktreeWhoseFolderIsGoneIsForgotten() throws {
    let repo = try tempRepo()
    func gone(_ branch: String) throws -> String {
        let p = try Git.addWorktree(
            repo: repo, branch: branch, base: "main", into: URL(fileURLWithPath: repo + "-" + branch), copyFiles: [],
            remotes: .none)
        if branch == "kept" {
            try "x\n".write(toFile: p + "/x.txt", atomically: true, encoding: .utf8)
            try Git.run(["add", "."], cwd: p, remotes: .none)
            try Git.run(["commit", "-qm", "only here"], cwd: p, remotes: .none)
        }
        try FileManager.default.removeItem(atPath: p)
        return p
    }
    let plain = try gone("plain"), kept = try gone("kept")
    try Git.forgetWorktree(repo: repo, path: plain, branch: "plain", remotes: .none)
    #expect(try Git.linkedWorktrees(repo, remotes: .none).map(\.branch) == ["kept"])
    #expect(!Git.branchExists(repo, "plain", remotes: .none))
    #expect(throws: GitError.self) { try Git.forgetWorktree(repo: repo, path: kept, branch: "kept", remotes: .none) }
    #expect(
        try Git.linkedWorktrees(repo, remotes: .none).map(\.branch) == ["kept"]
            && Git.branchExists(repo, "kept", remotes: .none))
    try Git.forgetWorktree(repo: repo, path: kept, branch: "kept", dropCommits: true, remotes: .none)
    #expect(try Git.linkedWorktrees(repo, remotes: .none).isEmpty && !Git.branchExists(repo, "kept", remotes: .none))
}
