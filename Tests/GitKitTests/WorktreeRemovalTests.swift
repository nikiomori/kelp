import Foundation
import TestSupport
import Testing

@testable import Core
@testable import GitKit

/// Removing one worktree keeps the record of another whose folder is away for now (an unmounted disk, a rename).
@Test func removingAWorktreeKeepsOneThatIsAway() throws {
    let repo = try tempRepo()
    let a = try Git.addWorktree(
        repo: repo, branch: "a", base: "main", into: URL(fileURLWithPath: repo + "-a"), copyFiles: [])
    let b = try Git.addWorktree(
        repo: repo, branch: "b", base: "main", into: URL(fileURLWithPath: repo + "-b"), copyFiles: [])
    try FileManager.default.moveItem(atPath: a, toPath: a + "-away")
    try Git.removeWorktree(repo: repo, path: b, branch: "b", force: true)
    #expect(try Git.linkedWorktrees(repo).map(\.branch) == ["a"])
    try FileManager.default.moveItem(atPath: a + "-away", toPath: a)
    #expect(try Git.run(["status", "--short"], cwd: a).isEmpty)
    // A folder that isn't a worktree of the repo stays where it is.
    let other = tmp().path
    #expect(throws: GitError.self) { try Git.removeWorktree(repo: repo, path: other, branch: nil, force: true) }
    #expect(FileManager.default.fileExists(atPath: other))
}

/// A locked worktree isn't removed: neither its folder nor its record, rather than the folder in the Trash and git's
/// record left behind.
@Test func aLockedWorktreeStays() throws {
    let repo = try tempRepo()
    let p = try Git.addWorktree(
        repo: repo, branch: "kept", base: "main", into: URL(fileURLWithPath: repo + "-kept"), copyFiles: [])
    try Git.run(["worktree", "lock", p], cwd: repo)
    #expect(throws: GitError.self) { try Git.removeWorktree(repo: repo, path: p, branch: "kept", force: true) }
    #expect(FileManager.default.fileExists(atPath: p))
    #expect(try Git.linkedWorktrees(repo).map(\.branch) == ["kept"])
}

/// A worktree whose path has a newline in it ("…\nlocked") reads as itself: not locked, its path whole.
@Test func aNewlineInAWorktreesPathReadsAsItself() throws {
    let repo = try tempRepo()
    let odd = repo + "-odd\nlocked"
    try Git.run(["worktree", "add", "-q", "-b", "odd", odd, "main"], cwd: repo)
    let listed = try Git.linkedWorktrees(repo)
    #expect(listed.count == 1 && listed.first?.path.hasSuffix("-odd\nlocked") == true && listed.first?.locked == false)
}
