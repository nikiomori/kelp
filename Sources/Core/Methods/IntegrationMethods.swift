import Foundation

// GitHub and GitLab (through gh and glab), CI runs, Linear, Jira and Bitbucket. Where a method takes a project, it is
// the workspace's project (`worktreeId`) or the project itself (`repoId`).

/// Returns the PR of the branch checked out in the workspace, or null. The answer is cached for two minutes.
public struct GitHubBranchPR: RPCMethod {
    public static let name = "github.branchPR"
    public typealias Result = GitHub.PullRequest?
    public var worktreeId: String
    public init(worktreeId: String) { self.worktreeId = worktreeId }
}
/// Returns "github", "gitlab" or "bitbucket", which sets what the panels call things.
public struct GitHubForge: RPCMethod {
    public static let name = "github.forge"
    public typealias Result = String
    public var worktreeId: String?, repoId: String?
    public init(worktreeId: String? = nil, repoId: String? = nil) {
        self.worktreeId = worktreeId
        self.repoId = repoId
    }
}
/// Returns whether gh is installed and who is signed in. No user means not signed in, or no network to ask.
public struct GitHubStatus: RPCMethod {
    public static let name = "github.status"
    public struct Result: Codable, Sendable, Equatable {
        public var installed: Bool, user: String?
        public init(installed: Bool, user: String?) {
            self.installed = installed
            self.user = user
        }
    }
    public init() {}
}
/// The same for glab. `user` names each host glab is signed in to ("ada on gitlab.com").
public struct GitLabStatus: RPCMethod {
    public static let name = "gitlab.status"
    public typealias Result = GitHubStatus.Result
    public init() {}
}
/// Lists issues: mine with `filter`, or else the open ones.
public struct GitHubIssues: RPCMethod {
    public static let name = "github.issues"
    public typealias Result = [GitHub.Issue]
    public var worktreeId: String?, repoId: String?, filter: String?
    public init(worktreeId: String? = nil, repoId: String? = nil, filter: String? = nil) {
        self.worktreeId = worktreeId
        self.repoId = repoId
        self.filter = filter
    }
}
/// Returns the checks of `pr`, or else of the workspace's own PR.
public struct GitHubChecks: RPCMethod {
    public static let name = "github.checks"
    public typealias Result = [GitHub.Check]
    public var worktreeId: String?, repoId: String?, pr: Int?
    public init(worktreeId: String? = nil, repoId: String? = nil, pr: Int?) {
        self.worktreeId = worktreeId
        self.repoId = repoId
        self.pr = pr
    }
}
/// Returns the log of a run's failed jobs.
public struct GitHubFailedLog: RPCMethod {
    public static let name = "github.failedLog"
    public typealias Result = String
    public var worktreeId: String?, repoId: String?, runId: Int?
    public init(worktreeId: String? = nil, repoId: String? = nil, runId: Int?) {
        self.worktreeId = worktreeId
        self.repoId = repoId
        self.runId = runId
    }
}
/// Returns the review comments of `pr`, or else of the workspace's own PR.
public struct GitHubReviewComments: RPCMethod {
    public static let name = "github.reviewComments"
    public typealias Result = [GitHub.ReviewComment]
    public var worktreeId: String?, repoId: String?, pr: Int?
    public init(worktreeId: String? = nil, repoId: String? = nil, pr: Int?) {
        self.worktreeId = worktreeId
        self.repoId = repoId
        self.pr = pr
    }
}
/// Lists the GitHub projects of the repository.
public struct GitHubProjects: RPCMethod {
    public static let name = "github.projects"
    public typealias Result = [GitHub.Project]
    public var worktreeId: String?, repoId: String?
    public init(worktreeId: String? = nil, repoId: String? = nil) {
        self.worktreeId = worktreeId
        self.repoId = repoId
    }
}
/// Lists the items of project `number` of `owner`.
public struct GitHubProjectItems: RPCMethod {
    public static let name = "github.projectItems"
    public typealias Result = [GitHub.ProjectItem]
    public var owner: String, number: Int?
    public init(owner: String, number: Int?) {
        self.owner = owner
        self.number = number
    }
}
/// Lists pull requests. `filter` is mine, review or closed (the latest closed or merged), and open by default.
public struct GitHubPRs: RPCMethod {
    public static let name = "github.prs"
    public typealias Result = [GitHub.PullRequest]
    public var worktreeId: String?, repoId: String?, filter: GitHub.PRFilter?
    public init(worktreeId: String? = nil, repoId: String? = nil, filter: GitHub.PRFilter? = nil) {
        self.worktreeId = worktreeId
        self.repoId = repoId
        self.filter = filter
    }
}
/// Returns pull request `pr` with its description, changed files and conversation (GitHub).
public struct GitHubPRView: RPCMethod {
    public static let name = "github.prView"
    public typealias Result = GitHub.PRView
    public var repoId: String, pr: Int
    public init(repoId: String, pr: Int) {
        self.repoId = repoId
        self.pr = pr
    }
}
/// Returns issue `issue` with its conversation (GitHub).
public struct GitHubIssueView: RPCMethod {
    public static let name = "github.issueView"
    public typealias Result = GitHub.IssueView
    public var repoId: String, issue: Int
    public init(repoId: String, issue: Int) {
        self.repoId = repoId
        self.issue = issue
    }
}
/// Pushes, takes the title and body from the commits if they aren't given, opens the PR (a draft with `draft`), and
/// links it. Returns {url, title}.
public struct GitHubPRCreate: RPCMethod {
    public static let name = "github.pr-create"
    public struct Result: Codable, Sendable, Equatable {
        public var url: String, title: String
        public init(url: String, title: String) {
            self.url = url
            self.title = title
        }
    }
    public var worktreeId: String, title: String?, body: String?, draft: Bool?
    public init(worktreeId: String, title: String? = nil, body: String? = nil, draft: Bool? = nil) {
        self.worktreeId = worktreeId
        self.title = title
        self.body = body
        self.draft = draft
    }
}
/// Merges a PR. `method` is squash (the default), merge or rebase. `pr` defaults to the workspace's linked PR. `head`
/// is the commit that was on screen, and GitHub merges only while it is still the PR's head.
public struct GitHubPRMerge: RPCMethod {
    public static let name = "github.pr-merge"
    public typealias Result = Done
    public var worktreeId: String, pr: Int?, method: String?, head: String?
    public init(worktreeId: String, pr: Int? = nil, method: String? = nil, head: String? = nil) {
        self.worktreeId = worktreeId
        self.pr = pr
        self.method = method
        self.head = head
    }
}

/// Returns the CI runs of the branch checked out in the workspace, as {branch, runs, workflows}.
public struct CIRunsList: RPCMethod {
    public static let name = "ci.runs"
    public struct Result: Codable, Sendable, Equatable {
        public var branch: String, runs: [CIRuns.Run], workflows: [CIRuns.Workflow]
        public init(branch: String, runs: [CIRuns.Run], workflows: [CIRuns.Workflow]) {
            self.branch = branch
            self.runs = runs
            self.workflows = workflows
        }
    }
    public var worktreeId: String
    public init(worktreeId: String) { self.worktreeId = worktreeId }
}
/// Lists the jobs of `run`.
public struct CIJobs: RPCMethod {
    public static let name = "ci.jobs"
    public typealias Result = [CIRuns.Job]
    public var worktreeId: String, run: Int?
    public init(worktreeId: String, run: Int?) {
        self.worktreeId = worktreeId
        self.run = run
    }
}
/// Returns the log of `job`, as text.
public struct CILog: RPCMethod {
    public static let name = "ci.log"
    public typealias Result = String
    public var worktreeId: String, job: Int?
    public init(worktreeId: String, job: Int?) {
        self.worktreeId = worktreeId
        self.job = job
    }
}
/// Returns the whole log of `job`, every step of it, as text.
public struct CIFullLog: RPCMethod {
    public static let name = "ci.fullLog"
    public typealias Result = String
    public var worktreeId: String, job: Int?
    public init(worktreeId: String, job: Int?) {
        self.worktreeId = worktreeId
        self.job = job
    }
}
/// Returns what broke in `job`, or in `run` (at `attempt`, if not the latest), read from the failed log. That is the
/// tests or compiler errors with their files and lines, plus the log's tail.
public struct CIFailures: RPCMethod {
    public static let name = "ci.failures"
    public typealias Result = CIRuns.Report
    public var worktreeId: String, job: Int?, run: Int?, attempt: Int?
    public init(worktreeId: String, job: Int? = nil, run: Int? = nil, attempt: Int? = nil) {
        self.worktreeId = worktreeId
        self.job = job
        self.run = run
        self.attempt = attempt
    }
}
/// Runs `run` again.
public struct CIRerun: RPCMethod {
    public static let name = "ci.rerun"
    public typealias Result = Done
    public var worktreeId: String, run: Int?
    public init(worktreeId: String, run: Int?) {
        self.worktreeId = worktreeId
        self.run = run
    }
}
/// Runs every job of `run` again, not only those that failed.
public struct CIRerunAll: RPCMethod {
    public static let name = "ci.rerunAll"
    public typealias Result = Done
    public var worktreeId: String, run: Int?
    public init(worktreeId: String, run: Int?) {
        self.worktreeId = worktreeId
        self.run = run
    }
}
/// Runs `job` again, with what it depends on.
public struct CIRerunJob: RPCMethod {
    public static let name = "ci.rerunJob"
    public typealias Result = Done
    public var worktreeId: String, job: Int?
    public init(worktreeId: String, job: Int?) {
        self.worktreeId = worktreeId
        self.job = job
    }
}
/// Stops `run`.
public struct CIRunCancel: RPCMethod {
    public static let name = "ci.cancel"
    public typealias Result = Done
    public var worktreeId: String, run: Int?
    public init(worktreeId: String, run: Int?) {
        self.worktreeId = worktreeId
        self.run = run
    }
}
/// Starts `workflow` on `branch`, with `inputs` if it takes any.
public struct CIDispatch: RPCMethod {
    public static let name = "ci.dispatch"
    public typealias Result = Done
    public var worktreeId: String, workflow: String, branch: String, inputs: [String: String]?
    public init(worktreeId: String, workflow: String, branch: String, inputs: [String: String]? = nil) {
        self.worktreeId = worktreeId
        self.workflow = workflow
        self.branch = branch
        self.inputs = inputs
    }
}

/// Saves a Linear key. An empty `key` disconnects and returns null. Otherwise the key is checked before it is saved,
/// and the key's user is returned.
public struct LinearSetKey: RPCMethod {
    public static let name = "linear.setKey"
    public typealias Result = LinearUser?
    public var key: String
    public init(key: String) { self.key = key }
}
/// Returns Linear's status. `name` is set only when a key is saved.
public struct LinearStatus: RPCMethod {
    public static let name = "linear.status"
    public struct Result: Codable, Sendable, Equatable {
        public var connected: Bool, name: String?
        public init(connected: Bool, name: String? = nil) {
            self.connected = connected
            self.name = name
        }
    }
    public init() {}
}
/// Lists a team's issues, or else mine.
public struct LinearIssues: RPCMethod {
    public static let name = "linear.issues"
    public typealias Result = [LinearIssue]
    public var teamId: String?
    public init(teamId: String? = nil) { self.teamId = teamId }
}
/// The teams of the connected Linear account.
public struct LinearTeams: RPCMethod {
    public static let name = "linear.teams"
    public typealias Result = [LinearTeam]
    public init() {}
}
/// Lists the workflow states of team `teamId`.
public struct LinearStates: RPCMethod {
    public static let name = "linear.states"
    public typealias Result = [LinearState]
    public var teamId: String
    public init(teamId: String) { self.teamId = teamId }
}
/// Moves issue `issueId` to state `stateId`.
public struct LinearSetState: RPCMethod {
    public static let name = "linear.setState"
    public typealias Result = Done
    public var issueId: String, stateId: String
    public init(issueId: String, stateId: String) {
        self.issueId = issueId
        self.stateId = stateId
    }
}

/// Saves Jira credentials. An empty `token` disconnects and returns null. Otherwise the credentials are checked before
/// they are saved, and the account's name is returned.
public struct JiraSetCredentials: RPCMethod {
    public static let name = "jira.setCredentials"
    public struct Account: Codable, Sendable, Equatable {
        public var name: String
        public init(name: String) { self.name = name }
    }
    public typealias Result = Account?
    public var site: String, email: String, token: String
    public init(site: String, email: String, token: String) {
        self.site = site
        self.email = email
        self.token = token
    }
}
/// Returns Jira's status. `name` and `site` are set only when credentials are saved.
public struct JiraStatus: RPCMethod {
    public static let name = "jira.status"
    public struct Result: Codable, Sendable, Equatable {
        public var connected: Bool, name: String?, site: String?
        public init(connected: Bool, name: String? = nil, site: String? = nil) {
            self.connected = connected
            self.name = name
            self.site = site
        }
    }
    public init() {}
}
/// Lists the issues `jql` finds, or else my open issues.
public struct JiraIssues: RPCMethod {
    public static let name = "jira.issues"
    public typealias Result = [JiraIssue]
    public var jql: String?
    public init(jql: String? = nil) { self.jql = jql }
}
/// Lists the transitions issue `key` can take now.
public struct JiraTransitions: RPCMethod {
    public static let name = "jira.transitions"
    public typealias Result = [JiraTransition]
    public var key: String
    public init(key: String) { self.key = key }
}
/// Moves issue `key` along transition `id`.
public struct JiraTransitionIssue: RPCMethod {
    public static let name = "jira.transition"
    public typealias Result = Done
    public var key: String, id: String
    public init(key: String, id: String) {
        self.key = key
        self.id = id
    }
}

/// Saves Bitbucket credentials. An empty `token` disconnects.
public struct BitbucketSetCredentials: RPCMethod {
    public static let name = "bitbucket.setCredentials"
    public typealias Result = Done
    public var user: String, token: String
    public init(user: String, token: String) {
        self.user = user
        self.token = token
    }
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
