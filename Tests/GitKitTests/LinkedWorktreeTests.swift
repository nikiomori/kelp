import Foundation
import Testing

@testable import Core
@testable import GitKit

/// An agent's worktree (Claude Code's `.claude/worktrees/…`) is found from any folder in it, off its files alone; the
/// project's own folder and another repository's worktree are not.
@Test func aLinkedWorktreeIsFoundOffItsFiles() throws {
    let repo = try tempRepo(), other = try tempRepo()
    let fix = repo + "/.claude/worktrees/fix", elsewhere = other + "-wt"
    try Git.run(["worktree", "add", "-q", "-b", "fix", fix], cwd: repo, remotes: .none)
    try Git.run(["worktree", "add", "-q", "-b", "x", elsewhere], cwd: other, remotes: .none)
    let real = { (path: String) in URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
    #expect(Git.linkedWorktree(containing: fix + "/src/deep", besides: repo) == real(fix))
    #expect(Git.linkedWorktree(containing: repo + "/src", besides: repo) == nil)
    #expect(Git.linkedWorktree(containing: elsewhere, besides: repo) == nil)
    #expect(Git.linkedWorktree(containing: fix, besides: fix) == nil)
    #expect(Git.headBranch(fix) == "fix" && Git.headBranch(repo) == "main")
}

/// `git push` goes to the project's origin: its host read from the repository's config, a worktree's followed to it.
@Test func aProjectsRemoteIsItsOriginsHost() throws {
    let repo = try tempRepo(), tree = repo + "-tree"
    try Git.run(["worktree", "add", "-q", "-b", "t", tree], cwd: repo, remotes: .none)
    #expect(Git.originHost(tree) == nil)
    try Git.run(["remote", "add", "origin", "git@github.com:o/r.git"], cwd: repo, remotes: .none)
    #expect(Git.originHost(repo) == "github.com")
    #expect(Git.originHost(tree) == "github.com")
    #expect(Git.commonDir(tree)?.resolvingSymlinksInPath() == Git.commonDir(repo)?.resolvingSymlinksInPath())
}
