import Core
import Foundation
import GitKit

// A project made of repositories side by side (`RepoKey`): its branch groups hold a worktree of each of them.
extension Workspaces {
    /// The repositories a branch of `repo` is made in, side by side: none for a project that is one repository. A pull
    /// request or a branch that is there opens in one repository, so a folder of several refuses it.
    func branchRepos(_ repo: Repo, pr: Int?, existing: Bool) throws -> [String] {
        let names = Git.nestedRepos(repo.path)
        guard names.isEmpty || (pr == nil && !existing) else {
            throw RPCError.invalidParams(
                "A pull request or a branch that's there opens in its own repository: “\(repo.name)” holds several.")
        }
        return names
    }

    /// Removes a branch group of a folder of repositories as `removeWorkspace` removes one: each repository's worktree
    /// and branch, then the folder, refused before anything stops. Returns false for any other workspace.
    func removeSeveral(_ workspace: Worktree, _ repo: Repo, branch: String?, force: Bool, dropCommits drop: Bool)
        throws -> Bool
    {
        let several = Git.nestedRepos(repo.path)
        guard !several.isEmpty else { return false }
        try Git.checkRemovable(
            project: repo.path, path: workspace.path, branch: branch, force: force,
            dropCommits: drop, remotes: remotes)
        try sessions.pauseSessions(of: workspace.id)
        try Git.removeWorktrees(
            project: repo.path, path: workspace.path, branch: branch, force: force,
            dropCommits: drop, remotes: remotes)
        for session in try store.sessions() where session.worktreeId == workspace.id {
            for name in several { sessions.turns.dropRefs(of: session.id, in: repo.path + "/" + name) }
        }
        sessions.discard(try store.sessions().filter { $0.worktreeId == workspace.id })
        try store.delete(workspace)
        sweeps.forget(repo.id)
        notify(ChangedEvent.worktree)
        return true
    }
}
