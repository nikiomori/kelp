import Foundation

// Source control of a workspace (`id` is its worktree id). The results are Core's value types (GitValues), as GitKit
// returns them in the daemon.

/// Returns the changed files of workspace `id`.
public struct GitStatus: RPCMethod {
    public static let name = "git.status"
    public typealias Result = [FileChange]
    public var id: String
    public init(id: String) { self.id = id }
}
/// Returns the project's branches, and which one is checked out in workspace `id`.
public struct GitBranches: RPCMethod {
    public static let name = "git.branches"
    public typealias Result = BranchInfo
    public var id: String
    public init(id: String) { self.id = id }
}
/// Returns the lines added and removed in the working tree, by kind of file.
public struct GitLineStats: RPCMethod {
    public static let name = "git.lineStats"
    public typealias Result = LineStats
    public var id: String
    public init(id: String) { self.id = id }
}
/// Pushes the workspace's branch.
public struct GitPush: RPCMethod {
    public static let name = "git.push"
    public typealias Result = Done
    public var id: String
    public init(id: String) { self.id = id }
}

/// Returns a diff. `source` is all (the default), unstaged, staged, branch (against `base`, or else the project's
/// base), commit, or turn (the last turn of `session`).
public struct GitDiff: RPCMethod {
    public static let name = "git.diff"
    public typealias Result = [FileDiff]
    /// What the diff is taken against. A name the daemon doesn't know is refused rather than read as `all`.
    public enum Source: String, Codable, Sendable, CaseIterable {
        case all, unstaged, staged, branch, commit, turn
        case tidy   // Tidy Up's copies of the instruction files against the files as they are now
    }
    public var id: String, source: Source?, file: String?, base: String?, commit: String?, session: String?
    /// Leaves out changes of whitespace alone (`git diff -w`).
    public var ignoreSpace: Bool?
    /// The number of unchanged lines around each change, 3 when nil (git's -U).
    public var context: Int?
    /// With source "turn", the turn to show (`SessionTurns.Mark.id`), up to where the next turn began. nil means the
    /// last turn.
    public var turn: String?
    public init(
        id: String, source: Source? = nil, file: String? = nil, base: String? = nil, commit: String? = nil,
        session: String? = nil,
        ignoreSpace: Bool? = nil
    ) {
        self.id = id
        self.source = source
        self.file = file
        self.base = base
        self.commit = commit
        self.session = session
        self.ignoreSpace = ignoreSpace
    }
}
/// Returns the commits on the branch since its base, or with `all`, the whole history.
public struct GitLog: RPCMethod {
    public static let name = "git.log"
    public struct Entry: Codable, Sendable, Equatable {
        public var hash: String, subject: String
        public init(hash: String, subject: String) {
            self.hash = hash
            self.subject = subject
        }
    }
    public typealias Result = [Entry]
    public var id: String, all: Bool?
    public init(id: String, all: Bool? = nil) {
        self.id = id
        self.all = all
    }
}
/// Returns the commits a push would send and a pull would bring, `limit` (default 5) of each, newest first. The counts
/// come from `git.branches`.
public struct GitUnsynced: RPCMethod {
    public static let name = "git.unsynced"
    public typealias Result = Unsynced
    public var id: String, limit: Int?
    public init(id: String, limit: Int? = nil) {
        self.id = id
        self.limit = limit
    }
}
/// Stages `files`.
public struct GitStage: RPCMethod {
    public static let name = "git.stage"
    public typealias Result = Done
    public var id: String, files: [String]?
    public init(id: String, files: [String]? = nil) {
        self.id = id
        self.files = files
    }
}
/// Unstages `files`.
public struct GitUnstage: RPCMethod {
    public static let name = "git.unstage"
    public typealias Result = Done
    public var id: String, files: [String]?
    public init(id: String, files: [String]? = nil) {
        self.id = id
        self.files = files
    }
}
/// Stages one hunk of `file`, or unstages it with `reverse`. The hunk is the one with `fingerprint`, or else the one
/// with `header`, or else number `hunk`.
public struct GitHunk: RPCMethod {
    public static let name = "git.hunk"
    public typealias Result = Done
    public var id: String, file: String, hunk: Int?, reverse: Bool?, header: String?, fingerprint: String?
    public init(
        id: String, file: String, hunk: Int? = nil, reverse: Bool? = nil, header: String? = nil,
        fingerprint: String? = nil
    ) {
        self.id = id
        self.file = file
        self.hunk = hunk
        self.reverse = reverse
        self.header = header
        self.fingerprint = fingerprint
    }
}
/// Makes a commit and returns the new commit's hash.
public struct GitCommit: RPCMethod {
    public static let name = "git.commit"
    public typealias Result = String
    public var id: String, message: String, all: Bool?, amend: Bool?
    public init(id: String, message: String, all: Bool? = nil, amend: Bool? = nil) {
        self.id = id
        self.message = message
        self.all = all
        self.amend = amend
    }
}
/// Merges the workspace's branch into the project's base branch, in the main checkout.
public struct GitMerge: RPCMethod {
    public static let name = "git.merge"
    public struct Result: Codable, Sendable, Equatable {
        public var merged: Bool, conflicts: [String]
        public init(merged: Bool, conflicts: [String]) {
            self.merged = merged
            self.conflicts = conflicts
        }
    }
    public var id: String, keepConflicts: Bool?
    public init(id: String, keepConflicts: Bool? = nil) {
        self.id = id
        self.keepConflicts = keepConflicts
    }
}
/// Checks out `branch` in workspace `id`. `create` makes the branch, and `remote` takes it from origin.
public struct GitSwitch: RPCMethod {
    public static let name = "git.switch"
    public typealias Result = Done
    public var id: String, branch: String, create: Bool?, remote: Bool?
    public init(id: String, branch: String, create: Bool? = nil, remote: Bool? = nil) {
        self.id = id
        self.branch = branch
        self.create = create
        self.remote = remote
    }
}
/// Returns the history as graph rows, at most `limit`. `more` says there are more rows.
public struct GitGraph: RPCMethod {
    public static let name = "git.graph"
    public struct Result: Codable, Sendable, Equatable {
        public var commits: [GraphCommit], more: Bool
        public init(commits: [GraphCommit], more: Bool) {
            self.commits = commits
            self.more = more
        }
    }
    public var id: String, limit: Int?
    public init(id: String, limit: Int? = nil) {
        self.id = id
        self.limit = limit
    }
}
/// Returns the files `commit` changed.
public struct GitCommitFiles: RPCMethod {
    public static let name = "git.commitFiles"
    public typealias Result = [FileChange]
    public var id: String, commit: String
    public init(id: String, commit: String) {
        self.id = id
        self.commit = commit
    }
}
/// Returns the picture of a commit author's account on the project's GitHub or GitLab (through gh or glab), as image
/// data. nil when no account has the email, or when the project is on neither.
public struct GitAuthorAvatar: InternalMethod {
    public static let name = "git.authorAvatar"
    public typealias Result = Data?
    public var id: String, email: String
    public init(id: String, email: String) {
        self.id = id
        self.email = email
    }
}
/// Returns who last changed a line of a file in workspace `worktreeId`, as the file is on disk. That is the agent turn
/// whose changes brought the line (shown as a commit made for those changes), or else the commit, or else nobody yet
/// (`commit` is nil).
public struct GitLineOrigin: InternalMethod {
    public static let name = "git.lineOrigin"
    public var worktreeId: String, file: String
    /// The line number, 1-based.
    public var line: Int
    public init(worktreeId: String, file: String, line: Int) {
        self.worktreeId = worktreeId
        self.file = file
        self.line = line
    }
    public struct Origin: Codable, Sendable, Equatable {
        /// The commit that brought the line in: one of the project's commits, or the commit made for the turn's
        /// changes. nil when nothing did.
        public var commit: String?
        public var author: String, date: Date, summary: String
        /// The agent's turn whose changes brought the line.
        public var turn: SessionTurns.Mark?
        public init(commit: String?, author: String, date: Date, summary: String, turn: SessionTurns.Mark? = nil) {
            self.commit = commit
            self.author = author
            self.date = date
            self.summary = summary
            self.turn = turn
        }
    }
    /// Nil when the line or the file isn't in git's view.
    public typealias Result = Origin?
}
/// Returns what a commit's card shows beyond its row in the graph: the message's body, the author's email, and how big
/// the change is.
public struct GitCommitDetails: RPCMethod {
    public static let name = "git.commitDetails"
    public typealias Result = CommitDetails
    public var id: String, commit: String
    public init(id: String, commit: String) {
        self.id = id
        self.commit = commit
    }
}
/// Throws away the changes to `files` in workspace `id`.
public struct GitDiscard: RPCMethod {
    public static let name = "git.discard"
    public typealias Result = Done
    public var id: String, files: [String]?
    /// A name the caller picks, so `git.undoDiscard` puts back this discard and no other.
    public var undo: String?
    public init(id: String, files: [String]? = nil, undo: String? = nil) {
        self.id = id
        self.files = files
        self.undo = undo
    }
}
/// Puts back what the last discard in the folder of workspace `id` threw away (a hunk or files). It works within a
/// minute of the discard, and only while the files are as the discard left them.
public struct GitUndoDiscard: InternalMethod {
    public static let name = "git.undoDiscard"
    public typealias Result = Done
    public var id: String
    /// The `undo` name the discard was given, to put back that discard. nil puts back the last discard without a
    /// name.
    public var undo: String?
    public init(id: String, undo: String? = nil) {
        self.id = id
        self.undo = undo
    }
}
/// Runs a remote operation. `op` is pull, push or fetch.
public struct GitRemoteOp: RPCMethod {
    public static let name = "git.remote"
    public typealias Result = Done
    public enum Step: String, Codable, Sendable, CaseIterable { case pull, push, fetch }
    public var id: String, op: Step
    public init(id: String, op: Step) {
        self.id = id
        self.op = op
    }
}
/// Fetches workspace `worktreeId`'s remotes for Kelp's background fetch (Settings › Source Control): as Fetch does,
/// but without a password or passphrase prompt nobody would see, and giving up sooner. A failure is the answer, not an
/// error. A remote project is fetched only over a connection already open: Kelp doesn't dial a host by itself.
public struct GitFetchQuietly: InternalMethod {
    public static let name = "git.fetchQuietly"
    public typealias Result = QuietFetch
    public var worktreeId: String
    public init(worktreeId: String) { self.worktreeId = worktreeId }
}
/// Acts on one commit of workspace `worktreeId`'s history: `checkout` puts HEAD on it with no branch, `branch` makes
/// the branch `branch` there and switches to it, `cherryPick` applies it to the current branch, and `revert` adds a
/// commit that undoes it. A conflict leaves the cherry-pick or revert under way, for Source Control's Merge section.
public struct GitCommitAct: RPCMethod {
    public static let name = "git.commitAct"
    public typealias Result = Done
    public enum Kind: String, Codable, Sendable, CaseIterable { case checkout, branch, cherryPick, revert }
    public var worktreeId: String, commit: String, op: Kind, branch: String?
    public init(worktreeId: String, commit: String, op: Kind, branch: String? = nil) {
        self.worktreeId = worktreeId
        self.commit = commit
        self.op = op
        self.branch = branch
    }
}
/// Stashes the changes of workspace `id`, or brings the last stash back with `pop`.
public struct GitStash: RPCMethod {
    public static let name = "git.stash"
    public typealias Result = Done
    public var id: String, pop: Bool?
    public init(id: String, pop: Bool? = nil) {
        self.id = id
        self.pop = pop
    }
}
/// Returns the web address of the file at `path` on its forge at HEAD, lines `start`…`end`.
public struct GitWebURL: RPCMethod {
    public static let name = "git.webURL"
    public typealias Result = String
    public var path: String, start: Int?, end: Int?
    public init(path: String, start: Int? = nil, end: Int? = nil) {
        self.path = path
        self.start = start
        self.end = end
    }
}
/// Returns the project's pages on its forge's website (from origin), or null when origin isn't on GitHub, GitLab or
/// Bitbucket.
public struct GitWebPages: RPCMethod {
    public static let name = "git.webPages"
    public typealias Result = Pages?
    /// `forge` is "github", "gitlab" or "bitbucket". `ci` is what the forge calls CI (Actions, Pipelines), and `pulls`
    /// is what it calls pull requests (pull or merge requests).
    public struct Pages: Codable, Sendable, Equatable {
        public var forge: String, repo: String, ci: String, pulls: String, issues: String
        public init(forge: String, repo: String, ci: String, pulls: String, issues: String) {
            self.forge = forge
            self.repo = repo
            self.ci = ci
            self.pulls = pulls
            self.issues = issues
        }
        /// Returns the address of a commit's page, built the way each site builds it.
        public func commitURL(_ hash: String) -> String {
            repo + (forge == "gitlab" ? "/-/commit/" : forge == "bitbucket" ? "/commits/" : "/commit/") + hash
        }
    }
    public var worktreeId: String?, repoId: String?
    public init(worktreeId: String? = nil, repoId: String? = nil) {
        self.worktreeId = worktreeId
        self.repoId = repoId
    }
}

/// Throws away one hunk of a file's unstaged changes in workspace `id`. The hunk is the one with `fingerprint`, or else
/// the one whose "@@ … @@" line is `header` as the caller saw it, found the way `git.hunk` finds it. `hunk`, its
/// number, isn't read. If the file changed since and that hunk isn't there, nothing is thrown away.
public struct GitDiscardHunk: RPCMethod {
    public static let name = "git.discardHunk"
    public typealias Result = Done
    public var id: String, file: String, hunk: Int, header: String
    /// The hunk's full text as shown (GitKit's `Hunk.fingerprint`). With it, a hunk whose lines changed since is
    /// refused even when its header didn't change. It is optional, so older callers keep working.
    public var fingerprint: String?
    /// A name the caller picks, so `git.undoDiscard` puts back this hunk and no other.
    public var undo: String?
    public init(id: String, file: String, hunk: Int, header: String, fingerprint: String? = nil, undo: String? = nil) {
        self.id = id
        self.file = file
        self.hunk = hunk
        self.header = header
        self.fingerprint = fingerprint
        self.undo = undo
    }
}
