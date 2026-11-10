import Core
import Foundation
import TestSupport
import Testing

@testable import GitKit

/// A line that starts with a combining mark: with its "+" it's one Character, and it used to fall out of the hunk.
@Test func aLineStartingWithACombiningMarkStaysInItsHunk() throws {
    let d = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -0,0 +1 @@\n+\u{0301}x\n"
    let lines = try #require(Git.parseDiff(d).first?.hunks.first?.lines)
    #expect(lines.count == 1 && lines[0].kind == .add && lines[0].text == "\u{0301}x")
}

/// Hiding whitespace changes leaves out lines that only moved their spaces, and files with nothing else changed.
@Test func hidingWhitespaceLeavesOutSpaceOnlyChanges() throws {
    let repo = try tempRepo()
    try "a\nb\nc\n".write(toFile: repo + "/g.txt", atomically: true, encoding: .utf8)
    try Git.run(["add", "g.txt"], cwd: repo, remotes: .none)
    try Git.run(["commit", "-qm", "g"], cwd: repo, remotes: .none)
    try "a  \nb\nc\nd\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)   // a space and a real line
    try "  a\nb\nc\n".write(toFile: repo + "/g.txt", atomically: true, encoding: .utf8)   // a space only
    #expect(try Git.diff(repo, source: .allUncommitted, remotes: .none).map(\.path) == ["f.txt", "g.txt", ".env"])
    let hidden = try Git.diff(repo, source: .allUncommitted, ignoreSpace: true, remotes: .none)
    #expect(hidden.map(\.path) == ["f.txt", ".env"])   // .env: untracked, all of it new
    #expect(hidden.first.map { ($0.additions, $0.deletions) } ?? (0, 0) == (1, 0))
}

/// A cloned path is the worktree's own copy: a change there leaves the main checkout's alone; a path outside is never cloned.
@Test func clonedPathsAreTheWorktreesOwn() throws {
    let repo = try tempRepo(), wt = tmp().path
    try FileManager.default.createDirectory(atPath: repo + "/node_modules/pkg", withIntermediateDirectories: true)
    try "v1\n".write(toFile: repo + "/node_modules/pkg/index.js", atomically: true, encoding: .utf8)
    Git.cloneShared(["node_modules", "../escape"], repo: repo, worktree: wt)
    #expect(try String(contentsOfFile: wt + "/node_modules/pkg/index.js", encoding: .utf8) == "v1\n")
    try "v2\n".write(toFile: wt + "/node_modules/pkg/index.js", atomically: true, encoding: .utf8)
    #expect(try String(contentsOfFile: repo + "/node_modules/pkg/index.js", encoding: .utf8) == "v1\n")
    #expect(!FileManager.default.fileExists(atPath: wt + "/../escape"))
    // A path the branch commits as a link to somewhere else (~/.ssh) stays a link: nothing of there is copied in.
    let secrets = tmp().path
    try FileManager.default.createDirectory(atPath: secrets, withIntermediateDirectories: true)
    try "key\n".write(toFile: secrets + "/id", atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(atPath: repo + "/vendor", withDestinationPath: secrets)
    Git.cloneShared(["vendor"], repo: repo, worktree: wt)
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: wt + "/vendor")) == secrets)
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: wt + "/node_modules")) == nil)   // a copy, not a link
}

/// A worktree on a branch that's there: a local one as it is, a remote one as a local branch following it, a pull
/// request's head fetched into a branch of its own.
@Test func worktreesOnBranchesThatExist() throws {
    let origin = tmp().path, repo = try tempRepo(), dir = tmp()
    try Git.run(["init", "-q", "--bare", origin], cwd: repo, remotes: .none)
    try Git.run(["remote", "add", "origin", origin], cwd: repo, remotes: .none)
    try Git.run(["branch", "feat/local"], cwd: repo, remotes: .none)
    try Git.run(["push", "-q", "origin", "main:spike", "main:refs/pull/7/head"], cwd: repo, remotes: .none)
    try Git.run(["fetch", "-q", "origin"], cwd: repo, remotes: .none)
    let a = try Git.addWorktree(
        repo: repo, branch: "feat/local", base: "main", into: dir, copyFiles: [], existing: true, remotes: .none)
    #expect(
        try Git.run(["branch", "--show-current"], cwd: a, remotes: .none).trimmingCharacters(in: .whitespacesAndNewlines)
            == "feat/local")
    let b = try Git.addWorktree(
        repo: repo, branch: "origin/spike", base: "main", into: dir, copyFiles: [], existing: true, remotes: .none)
    #expect(
        try Git.run(["branch", "--show-current"], cwd: b, remotes: .none).trimmingCharacters(in: .whitespacesAndNewlines) == "spike")
    try Git.run(["worktree", "remove", "--force", b], cwd: repo, remotes: .none)
    let again = try Git.addWorktree(
        repo: repo, branch: "origin/spike", base: "main", into: dir, copyFiles: [], existing: true, remotes: .none)
    #expect(
        try Git.run(["branch", "--show-current"], cwd: again, remotes: .none).trimmingCharacters(in: .whitespacesAndNewlines) == "spike"
    )   // the local one
    #expect(try Git.fetchPullRequest(repo: repo, number: 7, remotes: .none) == "pr-7")
    #expect(Git.branchExists(repo, "pr-7", remotes: .none))
}

/// A pull request's worktree gets the PR's code: a local branch that only shares its name (another fork's `fix-typo`, a
/// `main` checked out here) is never taken for it; your own branch is, when it is free and at the PR's head.
@Test func aPullRequestIsItsOwnHead() throws {
    let origin = tmp().path, repo = try tempRepo()
    func head(_ ref: String) throws -> String {
        try Git.run(["rev-parse", ref], cwd: repo, remotes: .none).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    try Git.run(["init", "-q", "--bare", origin], cwd: repo, remotes: .none)
    try Git.run(["remote", "add", "origin", origin], cwd: repo, remotes: .none)
    try Git.run(["branch", "fix-typo"], cwd: repo, remotes: .none)   // mine, unrelated
    try Git.run(["commit", "-q", "--allow-empty", "-m", "theirs"], cwd: repo, remotes: .none)
    try Git.run(["push", "-q", "origin", "HEAD:refs/pull/8/head", "HEAD:refs/pull/9/head"], cwd: repo, remotes: .none)
    try Git.run(["reset", "-q", "--hard", "HEAD~1"], cwd: repo, remotes: .none)
    let theirs = try Git.run(["rev-parse", "refs/pull/8/head"], cwd: origin, remotes: .none).trimmingCharacters(
        in: .whitespacesAndNewlines)
    #expect(try Git.fetchPullRequest(repo: repo, number: 8, wanted: "fix-typo", remotes: .none) == "pr-8")
    #expect(try head("pr-8") == theirs && head("fix-typo") != theirs)
    #expect(try Git.fetchPullRequest(repo: repo, number: 9, wanted: "main", remotes: .none) == "pr-9")   // main: checked out here
    try Git.run(["branch", "mine", theirs], cwd: repo, remotes: .none)
    #expect(try Git.fetchPullRequest(repo: repo, number: 9, wanted: "mine", remotes: .none) == "mine")
    // A pr-8 with commits of its own keeps them: the PR goes to pr-8-2.
    try Git.run(["checkout", "-q", "pr-8"], cwd: repo, remotes: .none)
    try Git.run(["commit", "-q", "--allow-empty", "-m", "my note"], cwd: repo, remotes: .none)
    try Git.run(["checkout", "-q", "main"], cwd: repo, remotes: .none)
    let mineAt = try head("pr-8")
    #expect(try Git.fetchPullRequest(repo: repo, number: 8, remotes: .none) == "pr-8-2")
    #expect(try head("pr-8") == mineAt && head("pr-8-2") == theirs)
    // No such PR: GitHub's way is what it says, not GitLab's fallback.
    #expect { try Git.fetchPullRequest(repo: repo, number: 404, remotes: .none) } throws: { "\($0)".contains("pull/404/head") }
}
