import Core
import Foundation
import GitKit

// A project made of repositories side by side (`RepoKey`): its branch groups hold a worktree of each of them.
extension Workspaces {
    /// The repositories a project holds side by side when it is a folder of them; none for any other (a remote
    /// project's folder here holds only its marker).
    func repos(in repo: Repo) -> [String] { Git.nestedRepos(repo.path) }

    /// Where a workspace's git is: the project's repository and the workspace's folder, or for a folder of
    /// repositories each of them and its worktree in the workspace's folder.
    func checkouts(_ workspace: Worktree, _ repo: Repo) -> [(repo: String, folder: String)] {
        Git.checkouts(project: repo.path, folder: workspace.path)
    }

    /// The repositories a branch of `repo` is made in, side by side: none for a project that is one repository. A pull
    /// request or a branch that is there opens in one repository, so a folder of several refuses it.
    func branchRepos(_ repo: Repo, pr: Int?, existing: Bool) throws -> [String] {
        let names = repos(in: repo)
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
        let several = repos(in: repo)
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
