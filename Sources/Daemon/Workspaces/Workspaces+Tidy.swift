import Core
import Foundation
import GitKit
import os

extension Workspaces {
    /// A branch group done with, closed with nobody asked: one an agent made (`kelp worktree create`) once nobody is left
    /// on it, and anyone's once the work done on it since the group was made landed in the base branch (merged or
    /// fast-forwarded there, or its pull request merged with the branch where the forge last saw it). Never while an agent there works or asks, never with
    /// uncommitted files, never with commits that are only there, unless the merged pull request carries them. A landed
    /// group that still has chats is archived with them (nothing of theirs is lost), one without is removed: folder to the
    /// Trash, branch deleted. Limit: a remote project's groups aren't looked at; a branch merged while its agent worked
    /// goes at the next change of the project's branches, its pull request's next read or Kelp's next start.
    /// `someoneLeft`: a session there just ended; else an agent's empty branch goes only once it's 5 minutes old (its
    /// agent starts a moment after its branch).
    func tidyBranch(_ id: String, merged pr: GitHub.PullRequest? = nil, someoneLeft: Bool = false) {
        dispatchPrecondition(condition: .onQueue(headQueue))
        Log.store.attempt("tidying a branch group") {
            guard let workspace = try store.worktree(id), !workspace.archived,
                let repo = try store.repo(workspace.repoId),
                !isMain(workspace, repo), remotes.of(repo.path) == nil,
                FileManager.default.fileExists(atPath: workspace.path)
            else { return }
            let here = try store.sessions().filter { $0.worktreeId == id }.map {
                sessions.existing($0.id)?.snapshot ?? $0
            }
            .filter { $0.status != .exited }
            guard !here.contains(where: { [.working, .waiting].contains($0.status) }),
                try !Git.isDirty(workspace.path, remotes: remotes)
            else { return }
            let branch = branchNow(of: workspace, in: repo)
            let tip = try Git.line(["rev-parse", "HEAD"], cwd: workspace.path, remotes: remotes)
            // Only a branch that did something since the group was made: one opened to look at, already merged, stays.
            let moved = try Git.moved(repo: repo.path, branch, since: workspace.createdAt, remotes: remotes)
            let squashed =
                moved && pr.map { $0.headRefName == branch && $0.headRefOid != nil && $0.headRefOid == tip } ?? false
            let landed =
                squashed || (moved && Git.isIn(repo: repo.path, branch, base: repo.baseBranch, remotes: remotes))
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
