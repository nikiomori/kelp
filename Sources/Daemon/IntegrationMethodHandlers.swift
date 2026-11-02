import Foundation
import Core
import GitKit
import Integrations

extension Forges {
    /// The branch checked out in the folder now (a workspace's record can be stale after a switch).
    func checkedOut(_ w: Worktree) -> String {
        (try? Git.currentBranch(w.path, remotes: remotes)) ?? w.branch
    }

    static let bitbucketNeedsCredentials = RPCError.invalidParams("This repo is on Bitbucket — add credentials in Settings › Integrations")
}

/// For a method that brings work in from a forge into a project: a clone added as one, an issue made a workspace with
/// its agent.
struct ForgeWork {
    let forges: Forges, workspaces: Workspaces
}

// MARK: gh / glab / git only

extension GitHubBranchPR: Handled {
    func handle(_ forges: Forges) throws -> GitHub.PullRequest? {
        let w = try forges.store.worktree(named: worktreeId), branch = forges.checkedOut(w), key = w.path + "@" + branch
        if let hit = forges.prCache.withLock({ $0[key] }), Date().timeIntervalSince(hit.at) < 120 { return hit.value }
        // nil: no PR, or gh couldn't tell (try? flattens to one optional)
        let v = GitLab.isGitLab(cwd: w.path) ? try? GitLab.mergeRequest(cwd: w.path, branch: branch) : try? GitHub.pullRequest(cwd: w.path, branch: branch)
        forges.prCache.withLock { $0[key] = (Date(), v) }
        return v
    }
}

extension GitHubForge: Handled {
    func handle(_ forges: Forges) throws -> String {
        let (_, path) = try forges.store.repoPath(worktreeId: worktreeId, repoId: repoId)
        return GitLab.isGitLab(cwd: path) ? "gitlab" : BitbucketClient.slug(cwd: path) != nil ? "bitbucket" : "github"
    }
}

extension CIRunsList: Handled {
    func handle(_ forges: Forges) throws -> Result {
        let w = try forges.store.worktree(named: worktreeId), branch = forges.checkedOut(w)
        return Result(branch: branch, runs: try CIRuns.runs(cwd: w.path, branch: branch),
                      workflows: GitLab.isGitLab(cwd: w.path) ? [] : CIRuns.dispatchable(repo: w.path))
    }
}
extension CIJobs: Handled {
    func handle(_ forges: Forges) throws -> [CIRuns.Job] { try CIRuns.jobs(cwd: forges.store.worktree(named: worktreeId).path, run: run ?? 0) }
}
extension CILog: Handled {
    func handle(_ forges: Forges) throws -> String { try CIRuns.log(cwd: forges.store.worktree(named: worktreeId).path, job: job ?? 0) }
}
extension CIFailures: Handled {
    func handle(_ forges: Forges) throws -> CIRuns.Report {
        let path = try forges.store.worktree(named: worktreeId).path
        if let job { return try CIRuns.report(cwd: path, job: job) }
        return try CIRuns.report(cwd: path, run: run ?? 0, attempt: attempt)
    }
}
extension CIRerun: Handled {
    func handle(_ forges: Forges) throws -> Done { try CIRuns.rerunFailed(cwd: forges.store.worktree(named: worktreeId).path, run: run ?? 0); return Done() }
}
extension CIDispatch: Handled {
    func handle(_ forges: Forges) throws -> Done {
        try CIRuns.dispatch(cwd: forges.store.worktree(named: worktreeId).path, workflow: workflow, branch: clientRef(branch) ?? "", inputs: inputs ?? [:])
        return Done()
    }
}

extension GitHubStatus: Handled {
    func handle(_: NoService) throws -> Result {
        let a = GitHub.account()
        return Result(installed: a.installed, user: a.user)
    }
}
extension GitLabStatus: Handled {
    func handle(_: NoService) throws -> Result {
        let a = GitLab.account()
        return Result(installed: a.installed, user: a.user)
    }
}
extension GitHubIssues: Handled {
    func handle(_ forges: Forges) throws -> [GitHub.Issue] {
        let (_, path) = try forges.store.repoPath(worktreeId: worktreeId, repoId: repoId)
        if GitLab.isGitLab(cwd: path) { return try GitLab.issues(cwd: path, mine: filter == "mine") }
        return try GitHub.issues(cwd: path, mine: filter == "mine")
    }
}
extension GitHubChecks: Handled {
    func handle(_ forges: Forges) throws -> [GitHub.Check] {
        try GitHub.checks(cwd: forges.store.repoPath(worktreeId: worktreeId, repoId: repoId).1, pr: pr ?? 0)
    }
}
extension GitHubFailedLog: Handled {
    func handle(_ forges: Forges) throws -> String {
        try GitHub.failedLog(cwd: forges.store.repoPath(worktreeId: worktreeId, repoId: repoId).1, runId: runId ?? 0)
    }
}
extension GitHubReviewComments: Handled {
    func handle(_ forges: Forges) throws -> [GitHub.ReviewComment] {
        try GitHub.reviewComments(cwd: forges.store.repoPath(worktreeId: worktreeId, repoId: repoId).1, pr: pr ?? 0)
    }
}
extension GitHubProjects: Handled {
    func handle(_ forges: Forges) throws -> [GitHub.Project] { try GitHub.projects(cwd: forges.store.repoPath(worktreeId: worktreeId, repoId: repoId).1) }
}
extension GitHubProjectItems: Handled {
    func handle(_: NoService) throws -> [GitHub.ProjectItem] { try GitHub.projectItems(owner: owner, number: number ?? 0) }
}

// MARK: also a web API

extension GitAuthorAvatar: AsyncHandled {
    func handle(_ forges: Forges) async throws -> Data? {
        let key = email.lowercased()
        if let hit = forges.avatars.withLock({ $0[key] }), hit.value != nil || Date().timeIntervalSince(hit.at) < 600 { return hit.value }
        let path = try forges.store.worktree(named: id).path, email = email
        // The forge the project's origin is on; elsewhere only a GitHub noreply address tells its account.
        let url = try? await forges.offloads.run { () throws -> URL? in
            let origin = (try? Git.run(["remote", "get-url", "origin"], cwd: path, remotes: forges.remotes))?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? ""
            if GitLab.isGitLab(remote: origin) { return try GitLab.avatarURL(email: email, cwd: path) }
            if Git.webRepo(origin)?.0.lowercased().contains("github") == true { return try GitHub.avatarURL(email: email, cwd: path) }
            return GitHub.noreplyAvatar(email)
        }
        var data: Data?
        if let url = url ?? nil {
            let (body, resp) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 15))
            if (resp as? HTTPURLResponse)?.statusCode == 200, !body.isEmpty { data = body }
        }
        let found = data
        forges.avatars.withLock { $0[key] = (Date(), found) }
        return found
    }
}

extension GitHubPRs: AsyncHandled {
    func handle(_ forges: Forges) async throws -> [GitHub.PullRequest] {
        let (_, path) = try forges.store.repoPath(worktreeId: worktreeId, repoId: repoId)
        if let slug = try await forges.offloads.run({ BitbucketClient.slug(cwd: path) }) {
            guard let bb = await forges.bitbucketClient() else { throw Forges.bitbucketNeedsCredentials }
            return try await bb.pullRequests(workspace: slug.workspace, repo: slug.repo)
        }
        let filter = filter
        return try await forges.offloads.run {
            if GitLab.isGitLab(cwd: path) { return try GitLab.mergeRequests(cwd: path, mine: filter == "mine") }
            let f: GitHub.PRFilter = filter == "mine" ? .mine : filter == "review" ? .reviewRequested : .open
            return try GitHub.pullRequests(cwd: path, filter: f)
        }
    }
}

extension GitHubPRCreate: AsyncHandled {
    func handle(_ forges: Forges) async throws -> Result {
        guard let w = try forges.store.worktree(worktreeId), let r = try forges.store.repo(w.repoId) else { throw RPCError.invalidParams("no worktree") }
        let path = w.path, draft = draft == true
        try await forges.offloads.run { try Git.remote(path, .push, remotes: forges.remotes) }   // the branch checked out now
        let branch = try await forges.offloads.run { forges.checkedOut(w) }   // and the PR's source (the record can be stale after a switch)
        var title = title ?? "", body = body ?? ""
        let link = w.issue.isEmpty ? nil : (w.issue.hasPrefix("#") ? "Fixes \(w.issue)" : "Refs \(w.issue)")
        if title.isEmpty || body.isEmpty {
            let cmpBase = w.base.isEmpty ? r.baseBranch : w.base
            let commits = try await forges.offloads.run { try Git.log(path, base: cmpBase, remotes: forges.remotes).map(\.subject) }
            if title.isEmpty { title = commits.last ?? branch }
            if body.isEmpty { body = commits.map { "- \($0)" }.joined(separator: "\n") + (link.map { "\n\n\($0)" } ?? "") }
        } else if let link, !body.contains(w.issue) { body += "\n\n\(link)" }
        // Stacked: a worktree cut from another feature branch opens its PR against that branch.
        let prBase = w.base.isEmpty ? r.baseBranch : w.base
        if prBase != r.baseBranch, !body.contains("Stacked on") { body = "Stacked on `\(prBase)`.\n\n" + body }
        let url: String
        if let slug = try await forges.offloads.run({ BitbucketClient.slug(cwd: path) }) {
            guard let bb = await forges.bitbucketClient() else { throw Forges.bitbucketNeedsCredentials }
            url = try await bb.createPR(workspace: slug.workspace, repo: slug.repo, title: title, body: body, source: branch, destination: prBase)
        } else if try await forges.offloads.run({ GitLab.isGitLab(cwd: path) }) {
            url = try await forges.offloads.run { [title, body] in try GitLab.createMR(cwd: path, title: title, body: body, base: prBase, draft: draft) }
        } else {
            url = try await forges.offloads.run { [title, body] in try GitHub.createPR(cwd: path, title: title, body: body, base: prBase, draft: draft) }
        }
        try forges.store.update(Worktree.self, w.id) { $0.prURL = url; $0.prNumber = Int(url.split(separator: "/").last ?? "") }
        forges.notify(ChangedEvent.worktree)
        await forges.moveLinear(w, to: .inReview)
        await forges.moveJira(w, toName: "review", category: "indeterminate")
        return Result(url: url, title: title)
    }
}

extension GitHubPRMerge: AsyncHandled {
    func handle(_ forges: Forges) async throws -> Done {
        guard let w = try forges.store.worktree(worktreeId), let n = pr ?? w.prNumber else { throw RPCError.invalidParams("no PR linked") }
        let how = method ?? "squash"
        if let slug = try await forges.offloads.run({ BitbucketClient.slug(cwd: w.path) }) {
            // Bitbucket's API or nothing: gh would look for the number on whatever GitHub repository it found.
            guard let bb = await forges.bitbucketClient() else { throw Forges.bitbucketNeedsCredentials }
            try await bb.merge(workspace: slug.workspace, repo: slug.repo, id: n)
        } else if try await forges.offloads.run({ GitLab.isGitLab(cwd: w.path) }) {
            try await forges.offloads.run { try GitLab.mergeMR(cwd: w.path, number: n, squash: how == "squash") }
        } else {
            let m = GitHub.MergeMethod(rawValue: how) ?? .squash
            try await forges.offloads.run { try GitHub.mergePR(cwd: w.path, number: n, method: m) }
        }
        await forges.moveLinear(w, to: .done)
        await forges.moveJira(w, toName: "done", category: "done")
        forges.notify(ChangedEvent.worktree)
        return Done()
    }
}

extension LinearSetKey: AsyncHandled {
    func handle(_ forges: Forges) async throws -> LinearUser? {
        if key.isEmpty { try await forges.keepSecret("", account: Forges.linearKeyAccount); return nil }
        let me = try await LinearClient(apiKey: key).viewer()   // validate before saving
        try await forges.keepSecret(key, account: Forges.linearKeyAccount)
        return me
    }
}
extension LinearStatus: AsyncHandled {
    func handle(_ forges: Forges) async throws -> Result {
        guard let l = await forges.linearClient() else { return Result(connected: false) }
        let me = try? await l.viewer()
        return Result(connected: me != nil, name: me?.name ?? "")
    }
}
extension LinearIssues: AsyncHandled {
    func handle(_ forges: Forges) async throws -> [LinearIssue] {
        guard let l = await forges.linearClient() else { throw RPCError.invalidParams("Linear is not connected (Settings › Integrations)") }
        if let teamId { return try await l.teamIssues(teamId: teamId) }
        return try await l.myIssues()
    }
}
extension LinearTeams: AsyncHandled {
    func handle(_ forges: Forges) async throws -> [LinearTeam] { guard let l = await forges.linearClient() else { return [] }; return try await l.teams() }
}
extension LinearStates: AsyncHandled {
    func handle(_ forges: Forges) async throws -> [LinearState] {
        guard let l = await forges.linearClient() else { return [] }
        return try await l.workflowStates(teamId: teamId)
    }
}
extension LinearSetState: AsyncHandled {
    func handle(_ forges: Forges) async throws -> Done {
        guard let l = await forges.linearClient() else { throw RPCError.invalidParams("Linear is not connected") }
        try await l.setState(issueId: issueId, stateId: stateId)
        return Done()
    }
}

extension JiraSetCredentials: AsyncHandled {
    func handle(_ forges: Forges) async throws -> Account? {
        if token.isEmpty { try await forges.keepSecret("", account: Forges.jiraAccount); return nil }
        let name = try await JiraClient(site: site, email: email, token: token).myself()   // validate before saving
        try await forges.keepSecret(String(decoding: try JSONEncoder().encode(["site": site, "email": email, "token": token]), as: UTF8.self),
                                    account: Forges.jiraAccount)
        return Account(name: name)
    }
}
extension JiraStatus: AsyncHandled {
    func handle(_ forges: Forges) async throws -> Result {
        guard let j = await forges.jiraClient() else { return Result(connected: false) }
        let n = try? await j.myself()
        return Result(connected: n != nil, name: n ?? "", site: j.site)
    }
}
extension JiraIssues: AsyncHandled {
    func handle(_ forges: Forges) async throws -> [JiraIssue] {
        guard let j = await forges.jiraClient() else { throw RPCError.invalidParams("Jira is not connected (Settings › Integrations)") }
        return try await j.search(jql: jql ?? JiraClient.myOpenJQL)
    }
}
extension JiraTransitions: AsyncHandled {
    func handle(_ forges: Forges) async throws -> [JiraTransition] {
        guard let j = await forges.jiraClient() else { return [] }
        return try await j.transitions(key: key)
    }
}
extension JiraTransitionIssue: AsyncHandled {
    func handle(_ forges: Forges) async throws -> Done {
        guard let j = await forges.jiraClient() else { throw RPCError.invalidParams("Jira is not connected") }
        try await j.transition(key: key, id: id)
        return Done()
    }
}

extension BitbucketSetCredentials: AsyncHandled {
    func handle(_ forges: Forges) async throws -> Done {
        try await forges.keepSecret(token.isEmpty ? "" : String(decoding: try JSONEncoder().encode(["user": user, "token": token]), as: UTF8.self),
                               account: Forges.bitbucketAccount)
        return Done()
    }
}
extension BitbucketStatus: AsyncHandled {
    func handle(_ forges: Forges) async throws -> Result { Result(connected: await forges.bitbucketClient() != nil) }
}

extension Methods {
    static let integrationMethods: [any Handled.Type] = [GitHubBranchPR.self, GitHubForge.self, CIRunsList.self, CIJobs.self, CILog.self,
        CIFailures.self, CIRerun.self, CIDispatch.self, GitHubStatus.self, GitLabStatus.self, GitHubIssues.self, GitHubChecks.self, GitHubFailedLog.self,
        GitHubReviewComments.self, GitHubProjects.self, GitHubProjectItems.self]
    static let asyncMethods: [any AsyncHandled.Type] = [GitHubPRs.self, GitHubPRCreate.self, GitHubPRMerge.self, LinearSetKey.self,
        LinearStatus.self, LinearIssues.self, LinearTeams.self, LinearStates.self, LinearSetState.self, JiraSetCredentials.self, JiraStatus.self,
        JiraIssues.self, JiraTransitions.self, JiraTransitionIssue.self, BitbucketSetCredentials.self, BitbucketStatus.self,
        AgentsVersions.self, TaskFromIssue.self, RepoClone.self, RepoCloneCancel.self, GitAuthorAvatar.self]
}
