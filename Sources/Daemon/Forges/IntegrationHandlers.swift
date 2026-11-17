import Core
import Foundation
import GitKit
import Integrations

/// Checks a branch, commit or base from a client before git is given it. It refuses one that reads as an option,
/// because "--output=…" would make `git show` write a file. No real ref starts with "-".
func clientRef(_ ref: String?) throws -> String? {
    guard let ref else { return nil }
    if ref.hasPrefix("-") { throw RPCError.invalidParams("“\(ref)” isn't a branch or commit.") }
    return ref
}

extension Store {
    /// Returns the project and folder that a method names: the workspace's (`worktreeId`), or else the project's
    /// (`repoId`).
    func repoPath(worktreeId: String?, repoId: String?) throws -> (Repo, String) {
        if let worktreeId, let worktree = try self.worktree(worktreeId), let repo = try self.repo(worktree.repoId) {
            return (repo, worktree.path)
        }
        guard let repoId else { throw RPCError.invalidParams("missing repoId") }
        guard let repo = try self.repo(repoId) else { throw RPCError.noProject(repoId) }
        return (repo, repo.path)
    }

    func repoPath(_ params: JSONValue) throws -> (Repo, String) {
        try repoPath(worktreeId: params["worktreeId"]?.string, repoId: params["repoId"]?.string)
    }
}

/// How a method that runs gh in the project's folder answers for a remote project, whose folder on this Mac is only a
/// marker (`Answered.onRemote`, `Daemon.refuseRemoteForge`). GitHub goes through `gh`, with its own auth. The trackers'
/// clients are in `Forges`.
enum RemoteForge {
    /// The call is refused with a message that says so.
    case refused
    /// The call answers null instead of an error, for what the sidebar asks on its own.
    case quiet
}
