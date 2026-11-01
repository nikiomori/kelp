import Foundation

// GitHub / GitLab (through gh / glab), CI runs, Linear, Jira and Bitbucket. Where a method takes a project, it is the
// workspace's (`worktreeId`) or the project's (`repoId`).

/// The PR of the branch checked out in the workspace, or null (cached for two minutes).
public struct GitHubBranchPR: RPCMethod {
    public static let name = "github.branchPR"; public typealias Result = GitHub.PullRequest?
    public var worktreeId: String
    public init(worktreeId: String) { self.worktreeId = worktreeId }
}
/// "github" | "gitlab" | "bitbucket": what the panels call things.
public struct GitHubForge: RPCMethod {
    public static let name = "github.forge"; public typealias Result = String
    public var worktreeId: String?, repoId: String?
    public init(worktreeId: String? = nil, repoId: String? = nil) { self.worktreeId = worktreeId; self.repoId = repoId }
}
/// Whether gh is installed and who is signed in (no user: not signed in, or no network to ask).
public struct GitHubStatus: RPCMethod {
    public static let name = "github.status"
    public struct Result: Codable, Sendable, Equatable {
        public var installed: Bool, user: String?
        public init(installed: Bool, user: String?) { self.installed = installed; self.user = user }
    }
    public init() {}
}
/// The same for glab; `user` names each host it's signed in to ("ada on gitlab.com").
public struct GitLabStatus: RPCMethod {
    public static let name = "gitlab.status"; public typealias Result = GitHubStatus.Result
    public init() {}
}
/// `filter`: mine, else open.
public struct GitHubIssues: RPCMethod {
    public static let name = "github.issues"; public typealias Result = [GitHub.Issue]
    public var worktreeId: String?, repoId: String?, filter: String?
    public init(worktreeId: String? = nil, repoId: String? = nil, filter: String? = nil) {
        self.worktreeId = worktreeId; self.repoId = repoId; self.filter = filter
    }
}
/// The checks of `pr`, else of the workspace's own PR.
public struct GitHubChecks: RPCMethod {
    public static let name = "github.checks"; public typealias Result = [GitHub.Check]
    public var worktreeId: String?, repoId: String?, pr: Int?
    public init(worktreeId: String? = nil, repoId: String? = nil, pr: Int?) { self.worktreeId = worktreeId; self.repoId = repoId; self.pr = pr }
}
/// The failed jobs' log of a run.
public struct GitHubFailedLog: RPCMethod {
    public static let name = "github.failedLog"; public typealias Result = String
    public var worktreeId: String?, repoId: String?, runId: Int?
    public init(worktreeId: String? = nil, repoId: String? = nil, runId: Int?) { self.worktreeId = worktreeId; self.repoId = repoId; self.runId = runId }
}
/// The review comments of `pr`, else of the workspace's own PR.
public struct GitHubReviewComments: RPCMethod {
    public static let name = "github.reviewComments"; public typealias Result = [GitHub.ReviewComment]
    public var worktreeId: String?, repoId: String?, pr: Int?
    public init(worktreeId: String? = nil, repoId: String? = nil, pr: Int?) { self.worktreeId = worktreeId; self.repoId = repoId; self.pr = pr }
}
/// The GitHub projects of the repository.
public struct GitHubProjects: RPCMethod {
    public static let name = "github.projects"; public typealias Result = [GitHub.Project]
    public var worktreeId: String?, repoId: String?
    public init(worktreeId: String? = nil, repoId: String? = nil) { self.worktreeId = worktreeId; self.repoId = repoId }
}
/// Project `number` of `owner`: its items.
public struct GitHubProjectItems: RPCMethod {
    public static let name = "github.projectItems"; public typealias Result = [GitHub.ProjectItem]
    public var owner: String, number: Int?
    public init(owner: String, number: Int?) { self.owner = owner; self.number = number }
}
/// `filter`: mine | review, else open.
public struct GitHubPRs: RPCMethod {
    public static let name = "github.prs"; public typealias Result = [GitHub.PullRequest]
    public var worktreeId: String?, repoId: String?, filter: String?
    public init(worktreeId: String? = nil, repoId: String? = nil, filter: String? = nil) {
        self.worktreeId = worktreeId; self.repoId = repoId; self.filter = filter
    }
}
/// Push, title and body from the commits if not given, open the PR (a draft with `draft`), link it → {url, title}.
public struct GitHubPRCreate: RPCMethod {
    public static let name = "github.pr-create"
    public struct Result: Codable, Sendable, Equatable {
        public var url: String, title: String
        public init(url: String, title: String) { self.url = url; self.title = title }
    }
    public var worktreeId: String, title: String?, body: String?, draft: Bool?
    public init(worktreeId: String, title: String? = nil, body: String? = nil, draft: Bool? = nil) {
        self.worktreeId = worktreeId; self.title = title; self.body = body; self.draft = draft
    }
}
/// `method`: squash (default) | merge | rebase; `pr`: else the workspace's linked one.
public struct GitHubPRMerge: RPCMethod {
    public static let name = "github.pr-merge"; public typealias Result = Done
    public var worktreeId: String, pr: Int?, method: String?
    public init(worktreeId: String, pr: Int? = nil, method: String? = nil) { self.worktreeId = worktreeId; self.pr = pr; self.method = method }
}

/// CI runs of the branch checked out in the workspace → {branch, runs, workflows}.
public struct CIRunsList: RPCMethod {
    public static let name = "ci.runs"
    public struct Result: Codable, Sendable, Equatable {
        public var branch: String, runs: [CIRuns.Run], workflows: [CIRuns.Workflow]
        public init(branch: String, runs: [CIRuns.Run], workflows: [CIRuns.Workflow]) { self.branch = branch; self.runs = runs; self.workflows = workflows }
    }
    public var worktreeId: String
    public init(worktreeId: String) { self.worktreeId = worktreeId }
}
/// The jobs of `run`.
public struct CIJobs: RPCMethod {
    public static let name = "ci.jobs"; public typealias Result = [CIRuns.Job]
    public var worktreeId: String, run: Int?
    public init(worktreeId: String, run: Int?) { self.worktreeId = worktreeId; self.run = run }
}
/// The log of `job`, as text.
public struct CILog: RPCMethod {
    public static let name = "ci.log"; public typealias Result = String
    public var worktreeId: String, job: Int?
    public init(worktreeId: String, job: Int?) { self.worktreeId = worktreeId; self.job = job }
}
/// Runs `run` again.
public struct CIRerun: RPCMethod {
    public static let name = "ci.rerun"; public typealias Result = Done
    public var worktreeId: String, run: Int?
    public init(worktreeId: String, run: Int?) { self.worktreeId = worktreeId; self.run = run }
}
/// Starts `workflow` on `branch`, with `inputs` if it takes any.
public struct CIDispatch: RPCMethod {
    public static let name = "ci.dispatch"; public typealias Result = Done
    public var worktreeId: String, workflow: String, branch: String, inputs: [String: String]?
    public init(worktreeId: String, workflow: String, branch: String, inputs: [String: String]? = nil) {
        self.worktreeId = worktreeId; self.workflow = workflow; self.branch = branch; self.inputs = inputs
    }
}

/// An empty `key` disconnects (null); else the key's user, checked before it's saved.
public struct LinearSetKey: RPCMethod {
    public static let name = "linear.setKey"; public typealias Result = LinearUser?
    public var key: String
    public init(key: String) { self.key = key }
}
/// `name` only when a key is saved.
public struct LinearStatus: RPCMethod {
    public static let name = "linear.status"
    public struct Result: Codable, Sendable, Equatable {
        public var connected: Bool, name: String?
        public init(connected: Bool, name: String? = nil) { self.connected = connected; self.name = name }
    }
    public init() {}
}
/// A team's issues, else mine.
public struct LinearIssues: RPCMethod {
    public static let name = "linear.issues"; public typealias Result = [LinearIssue]
    public var teamId: String?
    public init(teamId: String? = nil) { self.teamId = teamId }
}
/// The teams of the connected Linear account.
public struct LinearTeams: RPCMethod {
    public static let name = "linear.teams"; public typealias Result = [LinearTeam]
    public init() {}
}
/// Team `teamId`'s workflow states.
public struct LinearStates: RPCMethod {
    public static let name = "linear.states"; public typealias Result = [LinearState]
    public var teamId: String
    public init(teamId: String) { self.teamId = teamId }
}
/// Moves issue `issueId` to state `stateId`.
public struct LinearSetState: RPCMethod {
    public static let name = "linear.setState"; public typealias Result = Done
    public var issueId: String, stateId: String
    public init(issueId: String, stateId: String) { self.issueId = issueId; self.stateId = stateId }
}

/// An empty `token` disconnects (null); else the account's name, checked before it's saved.
public struct JiraSetCredentials: RPCMethod {
    public static let name = "jira.setCredentials"
    public struct Account: Codable, Sendable, Equatable {
        public var name: String
        public init(name: String) { self.name = name }
    }
    public typealias Result = Account?
    public var site: String, email: String, token: String
    public init(site: String, email: String, token: String) { self.site = site; self.email = email; self.token = token }
}
/// `name` and `site` only when credentials are saved.
public struct JiraStatus: RPCMethod {
    public static let name = "jira.status"
    public struct Result: Codable, Sendable, Equatable {
        public var connected: Bool, name: String?, site: String?
        public init(connected: Bool, name: String? = nil, site: String? = nil) { self.connected = connected; self.name = name; self.site = site }
    }
    public init() {}
}
/// `jql`, else my open issues.
public struct JiraIssues: RPCMethod {
    public static let name = "jira.issues"; public typealias Result = [JiraIssue]
    public var jql: String?
    public init(jql: String? = nil) { self.jql = jql }
}
/// The transitions issue `key` can take now.
public struct JiraTransitions: RPCMethod {
    public static let name = "jira.transitions"; public typealias Result = [JiraTransition]
    public var key: String
    public init(key: String) { self.key = key }
}
/// Moves issue `key` along transition `id`.
public struct JiraTransitionIssue: RPCMethod {
    public static let name = "jira.transition"; public typealias Result = Done
    public var key: String, id: String
    public init(key: String, id: String) { self.key = key; self.id = id }
}

/// An empty `token` disconnects.
public struct BitbucketSetCredentials: RPCMethod {
    public static let name = "bitbucket.setCredentials"; public typealias Result = Done
    public var user: String, token: String
    public init(user: String, token: String) { self.user = user; self.token = token }
}
/// Whether a Bitbucket account is connected.
public struct BitbucketStatus: RPCMethod {
    public static let name = "bitbucket.status"
    public struct Result: Codable, Sendable, Equatable {
        public var connected: Bool
        public init(connected: Bool) { self.connected = connected }
    }
    public init() {}
}
