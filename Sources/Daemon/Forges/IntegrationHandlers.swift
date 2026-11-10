import Core
import Foundation
import GitKit
import Integrations

/// A branch, commit or base from a client, as git will be given it: never one that reads as an option ("--output=…"
/// would make `git show` write a file). No real ref starts with "-".
func clientRef(_ ref: String?) throws -> String? {
    guard let ref else { return nil }
    if ref.hasPrefix("-") { throw RPCError.invalidParams("“\(ref)” isn't a branch or commit.") }
    return ref
}

extension Store {
    /// The project and folder a method names: its workspace's (`worktreeId`), else its project's (`repoId`).
    func repoPath(worktreeId: String?, repoId: String?) throws -> (Repo, String) {
        if let worktreeId, let worktree = try self.worktree(worktreeId), let repo = try self.repo(worktree.repoId) {
            return (repo, worktree.path)
        }
        guard let repoId else { throw RPCError.invalidParams("missing repoId") }
        guard let repo = try self.repo(repoId) else { throw RPCError.invalidParams("no repo") }
        return (repo, repo.path)
    }

    func repoPath(_ params: JSONValue) throws -> (Repo, String) {
        try repoPath(worktreeId: params["worktreeId"]?.string, repoId: params["repoId"]?.string)
    }
}

extension Methods {
    /// The methods that run gh or glab in the project's folder (`Daemon.refuseRemoteForge`): every GitHub, GitLab and CI
    /// method, by its name. (GitHub goes through `gh`, with its auth; the trackers' clients: `Forges`.)
    static var localForge: Set<String> {
        Set(
            integrationMethods.map { $0.name }.filter { name in
                ["github.", "gitlab.", "ci."].contains { name.hasPrefix($0) }
            })
    }
    /// Asked by the sidebar on its own: null for a remote project instead of an error.
    static let quietOnRemote: Set = [GitHubBranchPR.name, GitHubForge.name]
}
