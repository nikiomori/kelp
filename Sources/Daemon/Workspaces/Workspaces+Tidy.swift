import Core
import Foundation
import GitKit
import os

extension Workspaces {
    /// Closes a branch group that is done with, without asking anyone. A group an agent made (`kelp worktree create`)
    /// goes once nobody is left on it. Any group goes once the work done on it since it was made has landed in the base
    /// branch, either merged or fast-forwarded there, or through its pull request merged with the branch where the
    /// forge last saw it.
    /// A group is never closed while an agent there works or asks, never with uncommitted files, and never with commits
    /// that exist only there, unless the merged pull request carries them. A landed group that still has chats is
    /// archived with them, so nothing of theirs is lost. A landed group without chats is removed, which moves its
    /// folder to the Trash and deletes its branch.
    /// Limit: a remote project's groups aren't looked at, and a branch merged while its agent worked goes only at the
    /// next change of the project's branches, the next read of its pull request, or Kelp's next start.
    /// `someoneLeft` says a session there just ended. Otherwise an agent's empty branch goes only once it is 5 minutes
    /// old, because its agent starts a moment after its branch. The agent that made it counts as on it while its chat
    /// is open, wherever that chat is: it works in its branch from its own screen, the branch a mark on its row.
    func tidyBranch(_ id: String, merged pr: GitHub.PullRequest? = nil, someoneLeft: Bool = false) {
        dispatchPrecondition(condition: .onQueue(headQueue))
        Log.store.attempt("tidying a branch group") {
            guard let workspace = try store.worktree(id), !workspace.archived,
                let repo = try store.repo(workspace.repoId),
                !isMain(workspace, repo), remotes.of(repo.path) == nil,
                FileManager.default.fileExists(atPath: workspace.path)
            else { return }
            // Returns the sessions still in the group, or nil when one of them works or asks. It is called again once
            // git has answered, because a prompt sent or a chat started meanwhile means someone is at work.
            let maker = workspace.madeBy.map { $0.hasPrefix("typed:") ? String($0.dropFirst(6)) : $0 }
            func look() throws -> [Session]? {
                let here = try store.sessions().filter { $0.worktreeId == id || $0.id == maker }.map {
                    sessions.existing($0.id)?.snapshot ?? $0
                }
                .filter { $0.status != .exited }
                return here.contains { [.working, .waiting].contains($0.status) } ? nil : here
            }
            // A folder of repositories (`RepoKey`) is each of them: a branch group of one holds a worktree of each.
            let several = repos(in: repo), checkouts = self.checkouts(workspace, repo)
            guard try look() != nil, try !checkouts.contains(where: { try Git.isDirty($0.1, remotes: remotes) }) else {
                return
            }
            let branch = branchNow(of: workspace, in: repo)
            let tip = try Git.line(["rev-parse", "HEAD"], cwd: checkouts[0].1, remotes: remotes)
            // Only a branch that did something since the group was made counts as landed, so a branch opened just to
            // look at, already merged, stays. In a folder of repositories, every one whose branch did something has
            // to be in its own base. Limit: there a pull request merged with a squash isn't seen as landed.
            let moved = try checkouts.filter {
                try Git.moved(repo: $0.0, branch, since: workspace.createdAt, remotes: remotes)
            }
            let squashed =
                several.isEmpty && !moved.isEmpty
                && pr.map { $0.headRefName == branch && $0.headRefOid != nil && $0.headRefOid == tip } ?? false
            let landed =
                squashed
                || (!moved.isEmpty
                    && moved.allSatisfy {
                        let base = several.isEmpty ? repo.baseBranch : Git.defaultBranch(repo: $0.0, remotes: remotes)
                        return Git.isIn(repo: $0.0, branch, base: base, remotes: remotes)
                    })
            guard let here = try look() else { return }
            if landed, !here.isEmpty {
                try archive(workspace, repo)
            } else if landed
                || (workspace.madeBy != nil && here.isEmpty
                    && (someoneLeft || workspace.createdAt.timeIntervalSinceNow < -300))
            {
                // A branch that was there before (the user's, checked out with `--existing`) stays, and only its
                // folder goes.
                let theirs =
                    try !landed && !Git.made(repo: checkouts[0].0, branch, at: workspace.createdAt, remotes: remotes)
                do {
                    try removeWorkspace(workspace, repo, force: false, dropCommits: squashed, keepBranch: theirs)
                } catch GitError.refused {
                    return   // some work exists only there, so the group stays and its row says why
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

    /// Tidies every branch group of `repo`, or of all projects at start. That closes the groups that were done with
    /// while no daemon ran, or since the project's branches moved.
    func tidyBranches(in repo: String? = nil) {
        dispatchPrecondition(condition: .onQueue(headQueue))
        for workspace in store.look("the workspaces", { try $0.worktrees(repo: repo) }) ?? [] {
            tidyBranch(workspace.id)
        }
    }
}
