import Foundation

// Value types for what GitHub, GitLab, Bitbucket, Linear and Jira answer, as the daemon sends them and the app shows
// them. Asking those services (with gh, glab or their web APIs) is the job of Integrations.

/// Pull requests, issues, checks and projects. GitLab merge requests and Bitbucket pull requests are read into the same
/// shapes.
public enum GitHub {
    /// The error text gh's failure is turned into when the project's git has no remote on GitHub. The panels show it
    /// quietly as a state, not as a failure.
    public static let noRemote = "This project has no GitHub remote."
    /// Which pull requests `github.prs` lists: open, mine, those asking for my review, or the latest closed or merged.
    public enum PRFilter: String, Codable, CaseIterable, Sendable {
        case open, mine, closed
        case reviewRequested = "review"
    }
    public struct PullRequest: Codable, Sendable, Equatable {
        public struct Checks: Codable, Sendable, Equatable {
            public var passed = 0, failed = 0, pending = 0
            public init(passed: Int = 0, failed: Int = 0, pending: Int = 0) {
                self.passed = passed
                self.failed = failed
                self.pending = pending
            }
        }
        public var number: Int, title: String, url: String, author: String, headRefName: String
        public var isDraft: Bool, state: String
        public var reviewDecision: String?
        public var checks: Checks
        /// GitHub's head commit when the list was read. A merge goes ahead only while this commit is still the head.
        public var headRefOid: String?
        /// GitHub's word for whether the pull request can merge: CLEAN, BLOCKED, BEHIND, DIRTY (conflicts), UNSTABLE,
        /// DRAFT or UNKNOWN.
        public var mergeState: String?
        /// When anything on the pull request last changed (a commit, a check, a comment), in ISO 8601. The list uses it
        /// for its age and for "new since".
        public var updatedAt: String?
        /// The logins of the people asked for a review who haven't given one yet. A request to a team names the team.
        public var reviewRequests: [String]?
        public init(
            number: Int, title: String, url: String, author: String, headRefName: String, isDraft: Bool, state: String,
            reviewDecision: String? = nil, checks: Checks, headRefOid: String? = nil
        ) {
            self.number = number
            self.title = title
            self.url = url
            self.author = author
            self.headRefName = headRefName
            self.isDraft = isDraft
            self.state = state
            self.reviewDecision = reviewDecision
            self.checks = checks
            self.headRefOid = headRefOid
        }
    }
    public struct Issue: Codable, Sendable, Equatable {
        public var number: Int, title: String, body: String, url: String
        public var labels: [String], assignees: [String], state: String
        public var author: String?, updatedAt: String?
        public init(
            number: Int, title: String, body: String, url: String, labels: [String], assignees: [String], state: String
        ) {
            self.number = number
            self.title = title
            self.body = body
            self.url = url
            self.labels = labels
            self.assignees = assignees
            self.state = state
        }
    }
    public struct Check: Codable, Sendable, Equatable {
        /// `bucket` is gh's category of `state`: pass, fail, pending, skipping, cancel.
        public var name: String, state: String, bucket: String, workflow: String, link: String
        public var runId: Int?
        public init(name: String, state: String, bucket: String, workflow: String, link: String, runId: Int? = nil) {
            self.name = name
            self.state = state
            self.bucket = bucket
            self.workflow = workflow
            self.link = link
            self.runId = runId
        }
    }
    public struct ReviewComment: Codable, Sendable, Equatable {
        /// `path` and `line` are nil for top-level review bodies.
        public var path: String?, line: Int?
        public var body: String, author: String
        public var url: String?
        public init(path: String?, line: Int?, body: String, author: String, url: String?) {
            self.path = path
            self.line = line
            self.body = body
            self.author = author
            self.url = url
        }
    }
    public struct Project: Codable, Sendable, Equatable {
        public var number: Int, title: String, url: String
        public init(number: Int, title: String, url: String) {
            self.number = number
            self.title = title
            self.url = url
        }
    }
    /// A comment, or a review that said something, on a pull request or an issue.
    public struct Comment: Codable, Sendable, Equatable {
        /// `review`: APPROVED, CHANGES_REQUESTED or COMMENTED for a review; nil for a plain comment.
        public var author: String, body: String, createdAt: String, review: String?
        public init(author: String, body: String, createdAt: String, review: String? = nil) {
            self.author = author
            self.body = body
            self.createdAt = createdAt
            self.review = review
        }
    }
    /// A file a pull request changes, and by how many lines.
    public struct ChangedFile: Codable, Sendable, Equatable {
        public var path: String, additions: Int, deletions: Int
        public init(path: String, additions: Int, deletions: Int) {
            self.path = path
            self.additions = additions
            self.deletions = deletions
        }
    }
    /// A pull request as its own tab shows it: the list's row, plus the comments and changes on it.
    public struct PRView: Codable, Sendable, Equatable {
        public var pr: PullRequest, body: String, baseRefName: String
        public var files: [ChangedFile], comments: [Comment]
        public init(pr: PullRequest, body: String, baseRefName: String, files: [ChangedFile], comments: [Comment]) {
            self.pr = pr
            self.body = body
            self.baseRefName = baseRefName
            self.files = files
            self.comments = comments
        }
    }
    /// An issue as its own tab reads it.
    public struct IssueView: Codable, Sendable, Equatable {
        public var issue: Issue, comments: [Comment]
        public init(issue: Issue, comments: [Comment]) {
            self.issue = issue
            self.comments = comments
        }
    }
    public struct ProjectItem: Codable, Sendable, Equatable {
        /// `type` is Issue, PullRequest or DraftIssue; drafts have no url.
        public var title: String, type: String
        public var status: String?, url: String?
        public init(title: String, type: String, status: String?, url: String?) {
            self.title = title
            self.type = type
            self.status = status
            self.url = url
        }
    }
}

public struct LinearUser: Codable, Sendable, Equatable {
    public var id: String, name: String
    public var email: String?
    public init(id: String, name: String, email: String? = nil) {
        self.id = id
        self.name = name
        self.email = email
    }
}
public struct LinearTeam: Codable, Sendable, Equatable {
    public var id: String, key: String, name: String
    public init(id: String, key: String, name: String) {
        self.id = id
        self.key = key
        self.name = name
    }
}
/// `type` is Linear's state category: triage, backlog, unstarted, started, completed, canceled.
public struct LinearState: Codable, Sendable, Equatable {
    public var id: String, name: String, type: String
    public init(id: String, name: String, type: String) {
        self.id = id
        self.name = name
        self.type = type
    }
}
public struct LinearIssue: Codable, Sendable, Equatable {
    public var id: String, identifier: String, title: String
    public var description: String?
    public var url: String
    public var state: LinearState, team: LinearTeam, branchName: String
    public init(
        id: String, identifier: String, title: String, description: String?, url: String, state: LinearState,
        team: LinearTeam, branchName: String
    ) {
        self.id = id
        self.identifier = identifier
        self.title = title
        self.description = description
        self.url = url
        self.state = state
        self.team = team
        self.branchName = branchName
    }
}

public struct JiraIssue: Codable, Sendable, Equatable {
    public var key: String, title: String, description: String, url: String
    public var status: String, statusCategory: String   // statusCategory is new, indeterminate or done.
    public var type: String, project: String
    public init(
        key: String, title: String, description: String, url: String, status: String, statusCategory: String,
        type: String, project: String
    ) {
        self.key = key
        self.title = title
        self.description = description
        self.url = url
        self.status = status
        self.statusCategory = statusCategory
        self.type = type
        self.project = project
    }
}

public struct JiraTransition: Codable, Sendable, Equatable {
    public var id: String, name: String, toCategory: String
    public init(id: String, name: String, toCategory: String) {
        self.id = id
        self.name = name
        self.toCategory = toCategory
    }
}
