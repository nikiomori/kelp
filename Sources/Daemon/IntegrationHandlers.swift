import Foundation
import Core
import GitKit
import Integrations

/// A branch, commit or base from a client, as git will be given it: never one that reads as an option ("--output=…"
/// would make `git show` write a file). No real ref starts with "-".
func clientRef(_ v: String?) throws -> String? {
    guard let v else { return nil }
    if v.hasPrefix("-") { throw RPCError.invalidParams("“\(v)” isn't a branch or commit.") }
    return v
}

extension Store {
    /// The project and folder a method names: its workspace's (`worktreeId`), else its project's (`repoId`).
    func repoPath(_ p: JSONValue) throws -> (Repo, String) {
        if let wid = p["worktreeId"]?.string, let w = try worktree(wid), let r = try repo(w.repoId) { return (r, w.path) }
        guard let r = try repo(p.req("repoId")) else { throw RPCError.invalidParams("no repo") }
        return (r, r.path)
    }

    func repoPath(worktreeId: String?, repoId: String?) throws -> (Repo, String) {
        try repoPath(.obj(["worktreeId": worktreeId.map { .string($0) } ?? .null, "repoId": repoId.map { .string($0) } ?? .null]))
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
