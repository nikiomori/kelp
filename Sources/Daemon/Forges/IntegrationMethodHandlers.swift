import Core
import Foundation
import GitKit
import Integrations

extension Forges {
    /// The branch checked out in the folder now (a workspace's record can be stale after a switch).
    func checkedOut(_ workspace: Worktree) -> String {
        (try? Git.currentBranch(workspace.path, remotes: remotes)) ?? workspace.branch
    }

    /// The forge the folder's origin is on: what its PRs, issues and CI go through.
    func forge(_ path: String) -> Forge { Forge.of(cwd: path, remotes: remotes) }

    static let bitbucketNeedsCredentials = RPCError.invalidParams(
        "This repo is on Bitbucket — add credentials in Settings › Integrations")

    /// Pushes the workspace's branch and opens its pull (or merge) request against its base, titled and described from
    /// its commits unless given; the workspace keeps the link, and its Linear and Jira issues move to review.
    func createPR(_ workspace: Worktree, in repo: Repo, title: String?, body: String?, draft: Bool) async throws
        -> (url: String, title: String)
    {
        let path = workspace.path
        try await offloads.run { try Git.remote(path, .push, remotes: self.remotes) }   // the branch checked out now
        let branch = try await offloads.run { self.checkedOut(workspace) }   // and the PR's source (the record can be stale after a switch)
        var title = title ?? "", body = body ?? ""
        let link =
            workspace.issue.isEmpty
            ? nil : (workspace.issue.hasPrefix("#") ? "Fixes \(workspace.issue)" : "Refs \(workspace.issue)")
        // Stacked: a worktree cut from another feature branch opens its PR against that branch.
        let base = workspace.base.isEmpty ? repo.baseBranch : workspace.base
        if title.isEmpty || body.isEmpty {
            let commits = try await offloads.run {
                try Git.log(path, base: base, remotes: self.remotes).map(\.subject)
            }
            if title.isEmpty { title = commits.last ?? branch }
            if body.isEmpty {
                body = commits.map { "- \($0)" }.joined(separator: "\n") + (link.map { "\n\n\($0)" } ?? "")
            }
        } else if let link, !body.contains(workspace.issue) {
            body += "\n\n\(link)"
        }
        if base != repo.baseBranch, !body.contains("Stacked on") { body = "Stacked on `\(base)`.\n\n" + body }
        let url: String
        switch try await offloads.run({ self.forge(path) }) {
        case .bitbucket:
            guard let slug = try await offloads.run({ BitbucketClient.slug(cwd: path) }),
                let client = await bitbucketClient()
            else { throw Self.bitbucketNeedsCredentials }
            url = try await client.createPR(
                workspace: slug.workspace, repo: slug.repo, title: title, body: body, source: branch, destination: base)
        case .gitlab:
            url = try await offloads.run { [title, body] in
                try GitLab.createMR(cwd: path, title: title, body: body, base: base, draft: draft)
            }
        case .github:
            url = try await offloads.run { [title, body] in
                try GitHub.createPR(cwd: path, title: title, body: body, base: base, draft: draft)
            }
        }
        try store.update(Worktree.self, workspace.id) {
            $0.prURL = url
            $0.prNumber = Int(url.split(separator: "/").last ?? "")
        }
        notify(ChangedEvent.worktree)
        await moveLinear(workspace, to: .inReview)
        await moveJira(workspace, toName: "review", category: "indeterminate")
        return (url, title)
    }
}

/// For a method that brings work in from a forge into a project: a clone added as one, an issue made a workspace with
/// its agent.
struct ForgeWork {
    let forges: Forges, workspaces: Workspaces
}

// MARK: gh / glab / git only

extension GitHubBranchPR: Handled {
    func handle(_ forges: Forges) throws -> GitHub.PullRequest? {
        let workspace = try forges.store.worktree(named: worktreeId), branch = forges.checkedOut(workspace),
            key = workspace.path + "@" + branch
        if let hit = forges.prCache.withLock({ $0[key] }), Date().timeIntervalSince(hit.at) < 120 { return hit.value }
        // nil: no PR, or gh couldn't tell (try? flattens to one optional)
        let request: GitHub.PullRequest? =
            switch forges.forge(workspace.path) {
            case .gitlab: try? GitLab.mergeRequest(cwd: workspace.path, branch: branch)
            case .github, .bitbucket: try? GitHub.pullRequest(cwd: workspace.path, branch: branch)
            }
        forges.prCache.withLock { cache in
            // what's past its 2 min goes, not kept for the daemon's life
            if cache.count >= 500 { cache = cache.filter { Date().timeIntervalSince($0.value.at) < 120 } }
            cache[key] = (Date(), request)
        }
        return request
    }
}

extension GitHubForge: Handled {
    func handle(_ forges: Forges) throws -> String {
        let (_, path) = try forges.store.repoPath(worktreeId: worktreeId, repoId: repoId)
        return forges.forge(path).rawValue
    }
}

extension CIRunsList: Handled {
    func handle(_ forges: Forges) throws -> Result {
        let workspace = try forges.store.worktree(named: worktreeId), branch = forges.checkedOut(workspace)
        return Result(
            branch: branch, runs: try CIRuns.runs(cwd: workspace.path, branch: branch),
            workflows: forges.forge(workspace.path) == .gitlab ? [] : CIRuns.dispatchable(repo: workspace.path))
    }
}
extension CIJobs: Handled {
    func handle(_ forges: Forges) throws -> [CIRuns.Job] {
        try CIRuns.jobs(cwd: forges.store.worktree(named: worktreeId).path, run: run ?? 0)
    }
}
extension CILog: Handled {
    func handle(_ forges: Forges) throws -> String {
        try CIRuns.log(cwd: forges.store.worktree(named: worktreeId).path, job: job ?? 0)
    }
}
extension CIFullLog: Handled {
    func handle(_ forges: Forges) throws -> String {
        try CIRuns.fullLog(cwd: forges.store.worktree(named: worktreeId).path, job: job ?? 0)
    }
}
extension CIFailures: Handled {
    func handle(_ forges: Forges) throws -> CIRuns.Report {
        let path = try forges.store.worktree(named: worktreeId).path
        if let job { return try CIRuns.report(cwd: path, job: job) }
        return try CIRuns.report(cwd: path, run: run ?? 0, attempt: attempt)
    }
}
extension CIRerun: Handled {
    func handle(_ forges: Forges) throws -> Done {
        try CIRuns.rerunFailed(cwd: forges.store.worktree(named: worktreeId).path, run: run ?? 0)
        return Done()
    }
}
extension CIRerunAll: Handled {
    func handle(_ forges: Forges) throws -> Done {
        try CIRuns.rerunAll(cwd: forges.store.worktree(named: worktreeId).path, run: run ?? 0)
        return Done()
    }
}
extension CIRerunJob: Handled {
    func handle(_ forges: Forges) throws -> Done {
        try CIRuns.rerunJob(cwd: forges.store.worktree(named: worktreeId).path, job: job ?? 0)
        return Done()
    }
}
extension CIRunCancel: Handled {
    func handle(_ forges: Forges) throws -> Done {
        try CIRuns.cancel(cwd: forges.store.worktree(named: worktreeId).path, run: run ?? 0)
        return Done()
    }
}
extension CIDispatch: Handled {
    func handle(_ forges: Forges) throws -> Done {
        try CIRuns.dispatch(
            cwd: forges.store.worktree(named: worktreeId).path, workflow: workflow, branch: clientRef(branch) ?? "",
            inputs: inputs ?? [:])
        return Done()
    }
}

extension GitHubStatus: Handled {
    func handle(_: NoService) throws -> Result {
        let account = GitHub.account()
        return Result(installed: account.installed, user: account.user)
    }
}
extension GitLabStatus: Handled {
    func handle(_: NoService) throws -> Result {
        let account = GitLab.account()
        return Result(installed: account.installed, user: account.user)
    }
}
extension GitHubIssues: Handled {
    func handle(_ forges: Forges) throws -> [GitHub.Issue] {
        let (_, path) = try forges.store.repoPath(worktreeId: worktreeId, repoId: repoId)
        switch forges.forge(path) {
        case .gitlab: return try GitLab.issues(cwd: path, mine: filter == "mine")
        case .github, .bitbucket: return try GitHub.issues(cwd: path, mine: filter == "mine")
        }
    }
}
extension GitHubChecks: Handled {
    func handle(_ forges: Forges) throws -> [GitHub.Check] {
        try GitHub.checks(cwd: forges.store.repoPath(worktreeId: worktreeId, repoId: repoId).1, pr: pr ?? 0)
    }
}
extension GitHubFailedLog: Handled {
    func handle(_ forges: Forges) throws -> String {
        try CIRuns.report(
            cwd: forges.store.repoPath(worktreeId: worktreeId, repoId: repoId).1, run: runId ?? 0, attempt: nil
        ).forAgent
    }
}
extension GitHubReviewComments: Handled {
    func handle(_ forges: Forges) throws -> [GitHub.ReviewComment] {
        try GitHub.reviewComments(cwd: forges.store.repoPath(worktreeId: worktreeId, repoId: repoId).1, pr: pr ?? 0)
    }
}
extension GitHubPRView: Handled {
    func handle(_ work: ForgeWork) throws -> GitHub.PRView {
        try GitHub.pullRequestView(cwd: work.workspaces.store.repoPath(worktreeId: nil, repoId: repoId).1, number: pr)
    }
}
extension GitHubIssueView: Handled {
    func handle(_ work: ForgeWork) throws -> GitHub.IssueView {
        try GitHub.issueView(cwd: work.workspaces.store.repoPath(worktreeId: nil, repoId: repoId).1, number: issue)
    }
}
extension GitHubProjects: Handled {
    func handle(_ forges: Forges) throws -> [GitHub.Project] {
        try GitHub.projects(cwd: forges.store.repoPath(worktreeId: worktreeId, repoId: repoId).1)
    }
}
extension GitHubProjectItems: Handled {
    func handle(_: NoService) throws -> [GitHub.ProjectItem] {
        try GitHub.projectItems(owner: owner, number: number ?? 0)
    }
}

// MARK: also a web API

extension GitAuthorAvatar: AsyncHandled {
    func handle(_ forges: Forges) async throws -> Data? {
        let key = email.lowercased()
        if let hit = forges.avatars.withLock({ $0[key] }), hit.value != nil || Date().timeIntervalSince(hit.at) < 600 {
            return hit.value
        }
        let path = try forges.store.worktree(named: id).path, email = email
        // The forge the project's origin is on; elsewhere only a GitHub noreply address tells its account.
        let url = try? await forges.offloads.run { () throws -> URL? in
            let origin = (try? Git.origin(path, remotes: forges.remotes)) ?? ""
            switch Forge.of(remote: origin) {
            case .gitlab: return try GitLab.avatarURL(email: email, cwd: path)
            case .github where !origin.isEmpty: return try GitHub.avatarURL(email: email, cwd: path)
            case .github, .bitbucket: return GitHub.noreplyAvatar(email)
            }
        }
        var data: Data?
        if let url = url ?? nil {
            let (body, resp) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 15))
            if (resp as? HTTPURLResponse)?.statusCode == 200, !body.isEmpty { data = body }
        }
        let found = data
        forges.avatars.withLock { cache in
            if cache.count >= 2000 { cache.removeAll() }   // a picture each, a few KB: past that many authors, asked again as they're shown
            cache[key] = (Date(), found)
        }
        return found
    }
}

extension GitHubPRs: AsyncHandled {
    func handle(_ forges: Forges) async throws -> [GitHub.PullRequest] {
        let (_, path) = try forges.store.repoPath(worktreeId: worktreeId, repoId: repoId), filter = filter
        switch try await forges.offloads.run({ forges.forge(path) }) {
        case .bitbucket:
            guard let slug = try await forges.offloads.run({ BitbucketClient.slug(cwd: path) }),
                let bb = await forges.bitbucketClient()
            else { throw Forges.bitbucketNeedsCredentials }
            return try await bb.pullRequests(workspace: slug.workspace, repo: slug.repo)
        case .gitlab:
            return try await forges.offloads.run { try GitLab.mergeRequests(cwd: path, mine: filter == "mine") }
        case .github:
            let prFilter: GitHub.PRFilter =
                switch filter {
                case "mine": .mine
                case "review": .reviewRequested
                case "closed": .closed
                default: .open
                }
            return try await forges.offloads.run { try GitHub.pullRequests(cwd: path, filter: prFilter) }
        }
    }
}

extension GitHubPRCreate: AsyncHandled {
    func handle(_ forges: Forges) async throws -> Result {
        guard let workspace = try forges.store.worktree(worktreeId), let repo = try forges.store.repo(workspace.repoId)
        else {
            throw RPCError.invalidParams("no worktree")
        }
        let made = try await forges.createPR(workspace, in: repo, title: title, body: body, draft: draft == true)
        return Result(url: made.url, title: made.title)
    }
}

extension GitHubPRMerge: AsyncHandled {
    func handle(_ forges: Forges) async throws -> Done {
        guard let workspace = try forges.store.worktree(worktreeId), let number = pr ?? workspace.prNumber else {
            throw RPCError.invalidParams("no PR linked")
        }
        let how = method ?? "squash"
        switch try await forges.offloads.run({ forges.forge(workspace.path) }) {
        case .bitbucket:
            // Bitbucket's API or nothing: gh would look for the number on whatever GitHub repository it found.
            guard let slug = try await forges.offloads.run({ BitbucketClient.slug(cwd: workspace.path) }),
                let bb = await forges.bitbucketClient()
            else { throw Forges.bitbucketNeedsCredentials }
            try await bb.merge(workspace: slug.workspace, repo: slug.repo, id: number)
        case .gitlab:
            try await forges.offloads.run {
                try GitLab.mergeMR(cwd: workspace.path, number: number, squash: how == "squash")
            }
        case .github:
            let mergeMethod = GitHub.MergeMethod(rawValue: how) ?? .squash
            try await forges.offloads.run {
                try GitHub.mergePR(cwd: workspace.path, number: number, method: mergeMethod, head: head)
            }
        }
        await forges.moveLinear(workspace, to: .done)
        await forges.moveJira(workspace, toName: "done", category: "done")
        forges.notify(ChangedEvent.worktree)
        return Done()
    }
}

extension BitbucketSetCredentials: AsyncHandled {
    func handle(_ forges: Forges) async throws -> Done {
        try await forges.keepSecret(
            token.isEmpty
                ? "" : String(decoding: try JSONEncoder().encode(["user": user, "token": token]), as: UTF8.self),
            account: Forges.bitbucketAccount)
        return Done()
    }
}
extension BitbucketStatus: AsyncHandled {
    func handle(_ forges: Forges) async throws -> Result { Result(connected: await forges.bitbucketClient() != nil) }
}

extension Methods {
    static let integrationMethods: [any Answered.Type] = [
        GitHubBranchPR.self, GitHubForge.self, CIRunsList.self, CIJobs.self, CILog.self, CIFullLog.self,
        CIFailures.self, CIRerun.self, CIRerunAll.self, CIRerunJob.self, CIRunCancel.self, CIDispatch.self,
        GitHubStatus.self, GitLabStatus.self, GitHubIssues.self, GitHubChecks.self, GitHubFailedLog.self,
        GitHubReviewComments.self, GitHubProjects.self, GitHubProjectItems.self, GitAuthorAvatar.self, GitHubPRs.self,
        GitHubPRView.self, GitHubIssueView.self,
        GitHubPRCreate.self, GitHubPRMerge.self, BitbucketSetCredentials.self, BitbucketStatus.self
    ]
}
