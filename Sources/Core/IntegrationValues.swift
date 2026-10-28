import Foundation

// What GitHub / GitLab / Bitbucket, Linear and Jira answer, as the daemon sends it and the app shows it. Asking them
// (gh, glab, their web APIs) is Integrations' job.

/// Pull requests, issues, checks and projects. GitLab merge requests and Bitbucket pull requests are read into the same
/// shapes.
public enum GitHub {
    /// What gh's error comes back as when the project's git has no remote on GitHub: a state the panels show quietly,
    /// not a failure.
    public static let noRemote = "This project has no GitHub remote."
    public struct PullRequest: Codable, Sendable, Equatable {
        public struct Checks: Codable, Sendable, Equatable {
            public var passed = 0, failed = 0, pending = 0
            public init(passed: Int = 0, failed: Int = 0, pending: Int = 0) { self.passed = passed; self.failed = failed; self.pending = pending }
        }
        public var number: Int, title: String, url: String, author: String, headRefName: String
        public var isDraft: Bool, state: String
        public var reviewDecision: String?
        public var checks: Checks
        public init(number: Int, title: String, url: String, author: String, headRefName: String, isDraft: Bool, state: String,
                    reviewDecision: String? = nil, checks: Checks) {
            self.number = number; self.title = title; self.url = url; self.author = author; self.headRefName = headRefName
            self.isDraft = isDraft; self.state = state; self.reviewDecision = reviewDecision; self.checks = checks
        }
    }
    public struct Issue: Codable, Sendable, Equatable {
        public var number: Int, title: String, body: String, url: String
        public var labels: [String], assignees: [String], state: String
        public init(number: Int, title: String, body: String, url: String, labels: [String], assignees: [String], state: String) {
            self.number = number; self.title = title; self.body = body; self.url = url
            self.labels = labels; self.assignees = assignees; self.state = state
        }
    }
    public struct Check: Codable, Sendable, Equatable {
        /// `bucket` is gh's category of `state`: pass, fail, pending, skipping, cancel.
        public var name: String, state: String, bucket: String, workflow: String, link: String
        public var runId: Int?
        public init(name: String, state: String, bucket: String, workflow: String, link: String, runId: Int? = nil) {
            self.name = name; self.state = state; self.bucket = bucket; self.workflow = workflow; self.link = link; self.runId = runId
        }
    }
    public struct ReviewComment: Codable, Sendable, Equatable {
        /// path/line are nil for top-level review bodies.
        public var path: String?, line: Int?
        public var body: String, author: String
        public var url: String?
        public init(path: String?, line: Int?, body: String, author: String, url: String?) {
            self.path = path; self.line = line; self.body = body; self.author = author; self.url = url
        }
    }
    public struct Project: Codable, Sendable, Equatable {
        public var number: Int, title: String, url: String
        public init(number: Int, title: String, url: String) { self.number = number; self.title = title; self.url = url }
    }
    public struct ProjectItem: Codable, Sendable, Equatable {
        /// `type` is Issue, PullRequest or DraftIssue; drafts have no url.
        public var title: String, type: String
        public var status: String?, url: String?
        public init(title: String, type: String, status: String?, url: String?) { self.title = title; self.type = type; self.status = status; self.url = url }
    }
}

public struct LinearUser: Codable, Sendable, Equatable {
    public var id: String, name: String
    public var email: String?
    public init(id: String, name: String, email: String? = nil) { self.id = id; self.name = name; self.email = email }
}
public struct LinearTeam: Codable, Sendable, Equatable {
    public var id: String, key: String, name: String
    public init(id: String, key: String, name: String) { self.id = id; self.key = key; self.name = name }
}
/// `type` is Linear's state category: triage, backlog, unstarted, started, completed, canceled.
public struct LinearState: Codable, Sendable, Equatable {
    public var id: String, name: String, type: String
    public init(id: String, name: String, type: String) { self.id = id; self.name = name; self.type = type }
}
public struct LinearIssue: Codable, Sendable, Equatable {
    public var id: String, identifier: String, title: String
    public var description: String?
    public var url: String
    public var state: LinearState, team: LinearTeam, branchName: String
    public init(id: String, identifier: String, title: String, description: String?, url: String, state: LinearState, team: LinearTeam, branchName: String) {
        self.id = id; self.identifier = identifier; self.title = title; self.description = description; self.url = url
        self.state = state; self.team = team; self.branchName = branchName
    }
}

public struct JiraIssue: Codable, Sendable, Equatable {
    public var key: String, title: String, description: String, url: String
    public var status: String, statusCategory: String   // statusCategory: new | indeterminate | done
    public var type: String, project: String
    public init(key: String, title: String, description: String, url: String, status: String, statusCategory: String, type: String, project: String) {
        self.key = key; self.title = title; self.description = description; self.url = url
        self.status = status; self.statusCategory = statusCategory; self.type = type; self.project = project
    }
}

public struct JiraTransition: Codable, Sendable, Equatable {
    public var id: String, name: String, toCategory: String
    public init(id: String, name: String, toCategory: String) { self.id = id; self.name = name; self.toCategory = toCategory }
}
