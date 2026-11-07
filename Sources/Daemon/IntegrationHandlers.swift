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
    func repoPath(_ params: JSONValue) throws -> (Repo, String) {
        if let wid = params["worktreeId"]?.string, let worktree = try self.worktree(wid),
            let repo = try self.repo(worktree.repoId)
        {
            return (repo, worktree.path)
        }
        guard let repo = try self.repo(params.req("repoId")) else { throw RPCError.invalidParams("no repo") }
        return (repo, repo.path)
    }

    func repoPath(worktreeId: String?, repoId: String?) throws -> (Repo, String) {
        try repoPath(
            .obj(["worktreeId": worktreeId.map { .string($0) } ?? .null, "repoId": repoId.map { .string($0) } ?? .null])
        )
    }
}

/// Runs gh or glab in the project's folder (`Daemon.refuseRemoteForge`): every GitHub, GitLab and CI method. (GitHub goes
/// through `gh`, with its auth; the trackers' clients: `Forges`.)
protocol LocalForge {
    /// Asked by the sidebar on its own: null for a remote project instead of an error.
    static var quietOnRemote: Bool { get }
}
extension LocalForge { static var quietOnRemote: Bool { false } }

extension GitHubBranchPR: LocalForge { static var quietOnRemote: Bool { true } }
extension GitHubForge: LocalForge { static var quietOnRemote: Bool { true } }
extension GitHubStatus: LocalForge {}
extension GitLabStatus: LocalForge {}
extension GitHubIssues: LocalForge {}
extension GitHubChecks: LocalForge {}
extension GitHubFailedLog: LocalForge {}
extension GitHubReviewComments: LocalForge {}
extension GitHubProjects: LocalForge {}
extension GitHubProjectItems: LocalForge {}
extension GitHubPRs: LocalForge {}
extension GitHubPRCreate: LocalForge {}
extension GitHubPRMerge: LocalForge {}
extension CIRunsList: LocalForge {}
extension CIJobs: LocalForge {}
extension CILog: LocalForge {}
extension CIFailures: LocalForge {}
extension CIFullLog: LocalForge {}
extension CIRerun: LocalForge {}
extension CIRerunAll: LocalForge {}
extension CIRerunJob: LocalForge {}
extension CIRunCancel: LocalForge {}
extension CIDispatch: LocalForge {}
