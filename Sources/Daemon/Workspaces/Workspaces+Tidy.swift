import Core
import Foundation
import GitKit
import os

extension Workspaces {
    /// Closes a branch group that is done with, without asking anyone. A group an agent made (`kelp worktree create`)
    /// goes once nobody is left on it; anyone's group goes once the work done on it since the group was made has landed
    /// in the base branch (merged or fast-forwarded there, or its pull request merged with the branch where the forge
    /// last saw it).
    /// Never while an agent there works or asks, never with uncommitted files, and never with commits that exist only
    /// there, unless the merged pull request carries them. A landed group that still has chats is archived with them
    /// (nothing of theirs is lost); one without chats is removed: its folder goes to the Trash and its branch is
    /// deleted.
    /// Limit: a remote project's groups aren't looked at, and a branch merged while its agent worked goes only at the
    /// next change of the project's branches, the next read of its pull request, or Kelp's next start.
    /// `someoneLeft` says a session there just ended; otherwise an agent's empty branch goes only once it is 5 minutes
    /// old (its agent starts a moment after its branch).
    func tidyBranch(_ id: String, merged pr: GitHub.PullRequest? = nil, someoneLeft: Bool = false) {
        dispatchPrecondition(condition: .onQueue(headQueue))
        Log.store.attempt("tidying a branch group") {
            guard let workspace = try store.worktree(id), !workspace.archived,
                let repo = try store.repo(workspace.repoId),
                !isMain(workspace, repo), remotes.of(repo.path) == nil,
                FileManager.default.fileExists(atPath: workspace.path)
            else { return }
            // Who's there, and whether one of them works or asks: looked at again once git has answered, since a
            // prompt sent or a chat started meanwhile is someone at work.
            func look() throws -> [Session]? {
                let here = try store.sessions().filter { $0.worktreeId == id }.map {
                    sessions.existing($0.id)?.snapshot ?? $0
                }
                .filter { $0.status != .exited }
                return here.contains { [.working, .waiting].contains($0.status) } ? nil : here
            }
            guard try look() != nil, try !Git.isDirty(workspace.path, remotes: remotes) else { return }
            let branch = branchNow(of: workspace, in: repo)
            let tip = try Git.line(["rev-parse", "HEAD"], cwd: workspace.path, remotes: remotes)
            // Only a branch that did something since the group was made: one opened to look at, already merged, stays.
            let moved = try Git.moved(repo: repo.path, branch, since: workspace.createdAt, remotes: remotes)
            let squashed =
                moved && pr.map { $0.headRefName == branch && $0.headRefOid != nil && $0.headRefOid == tip } ?? false
            let landed =
                squashed || (moved && Git.isIn(repo: repo.path, branch, base: repo.baseBranch, remotes: remotes))
            guard let here = try look() else { return }
            if landed, !here.isEmpty {
                try archive(workspace, repo)
            } else if landed
                || (workspace.madeBy != nil && here.isEmpty
                    && (someoneLeft || workspace.createdAt.timeIntervalSinceNow < -300))
            {
                // A branch that was there before (the user's, checked out with `--existing`) stays: only its folder goes.
                let theirs =
                    try !landed && !Git.made(repo: repo.path, branch, at: workspace.createdAt, remotes: remotes)
                do {
                    try removeWorkspace(workspace, repo, force: false, dropCommits: squashed, keepBranch: theirs)
                } catch GitError.refused {
                    return   // work that's only there: kept, and its row says what
                }
            } else {
                return
            }
            if landed {
                notify(
                    LandedEvent(
                        worktree: id, name: workspace.displayName, base: repo.baseBranch, archived: !here.isEmpty))
            }
        }
    }

    /// Every branch group of `repo` (all at start): those done with while no daemon ran, or since its branches moved.
    func tidyBranches(in repo: String? = nil) {
        dispatchPrecondition(condition: .onQueue(headQueue))
        for workspace in store.look("the workspaces", { try $0.worktrees(repo: repo) }) ?? [] {
            tidyBranch(workspace.id)
        }
    }
}
