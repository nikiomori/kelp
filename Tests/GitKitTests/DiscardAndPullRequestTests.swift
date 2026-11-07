import Foundation
import Testing

@testable import Core
@testable import GitKit

/// A discard that failed partway (a new file it couldn't move to the Trash) left that file as it was: its Undo puts back
/// the rest and lets that one be, instead of failing whole on it.
@Test func anUndoAfterAPartialDiscardPutsBackWhatWent() throws {
    let repo = try tempRepo()
    try "mine\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
    try "new\n".write(toFile: repo + "/n.txt", atomically: true, encoding: .utf8)
    var kept = Data()
    let back = try Git.discard(repo, files: ["f.txt", "n.txt"]) { kept = $0 }
    #expect(back == kept && Git.perFile(back).count == 2)
    try "new\n".write(toFile: repo + "/n.txt", atomically: true, encoding: .utf8)   // as if its move had failed
    try Git.putBack(repo, patch: back, hunk: false)
    #expect(try String(contentsOfFile: repo + "/f.txt", encoding: .utf8) == "mine\n")
    #expect(try String(contentsOfFile: repo + "/n.txt", encoding: .utf8) == "new\n")
}

/// A pull request's code stays its author's on a branch made on top of it, and after its own branch is gone; once it's
/// in origin's branches (merged and pushed) it's the project's.
@Test func aPullRequestsCodeIsToldOnBranchesMadeFromIt() throws {
    let repo = try tempRepo()
    #expect(!Git.holdsPullRequest(repo))
    try Git.run(["checkout", "-qb", "pr-7"], cwd: repo)
    try "theirs\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
    try Git.run(["commit", "-qam", "pr"], cwd: repo)
    let head = try Git.run(["rev-parse", "HEAD"], cwd: repo).trimmingCharacters(in: .whitespacesAndNewlines)
    try Git.run(["update-ref", "refs/kelp/pr/7", head], cwd: repo)
    try Git.run(["checkout", "-q", "main"], cwd: repo)
    #expect(!Git.holdsPullRequest(repo))
    try Git.run(["checkout", "-qb", "on-top", "pr-7"], cwd: repo)
    try Git.run(["branch", "-D", "pr-7"], cwd: repo)
    #expect(Git.holdsPullRequest(repo))
    #expect(Git.holdsPullRequest(repo, at: "on-top") && !Git.holdsPullRequest(repo, at: "main"))
    try Git.run(["update-ref", "refs/remotes/origin/main", head], cwd: repo)
    #expect(!Git.holdsPullRequest(repo))
    #expect(try Git.run(["for-each-ref", "refs/kelp/pr/"], cwd: repo).isEmpty)   // merged and pushed: dropped
}

/// A branch `gh pr checkout` made follows the PR's ref (its `branch.<name>.merge`), with no ref of Kelp's: told too.
@Test func aBranchFollowingAPullRequestsRefIsTold() throws {
    let repo = try tempRepo()
    try Git.run(["checkout", "-qb", "fix-from-fork"], cwd: repo)
    try "theirs\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
    try Git.run(["commit", "-qam", "pr"], cwd: repo)
    try Git.run(["config", "branch.fix-from-fork.merge", "refs/pull/9/head"], cwd: repo)
    #expect(Git.holdsPullRequest(repo))
    try Git.run(["checkout", "-q", "main"], cwd: repo)
    #expect(!Git.holdsPullRequest(repo))
}

/// An Undo that puts back some files and is refused for others says so, not that nothing was put back.
@Test func anUndoPutBackInPartSaysHowMuch() throws {
    let repo = try tempRepo()
    try "mine\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
    try "new\n".write(toFile: repo + "/n.txt", atomically: true, encoding: .utf8)
    let back = try Git.discard(repo, files: ["f.txt", "n.txt"])
    try "later\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)   // changed since: refused
    #expect(throws: Git.PartlyPutBack.self) { try Git.putBack(repo, patch: back, hunk: false) }
    #expect(try String(contentsOfFile: repo + "/n.txt", encoding: .utf8) == "new\n")
}
