import Foundation

// Source control of a workspace (`id` is its worktree id). Results are Core's values
// (GitValues), as GitKit returns them in the daemon.

/// The changed files of workspace `id`.
public struct GitStatus: RPCMethod {
    public static let name = "git.status"
    public typealias Result = [FileChange]
    public var id: String
    public init(id: String) { self.id = id }
}
/// The project's branches, and which is checked out in workspace `id`.
public struct GitBranches: RPCMethod {
    public static let name = "git.branches"
    public typealias Result = BranchInfo
    public var id: String
    public init(id: String) { self.id = id }
}
/// Lines added and removed in the working tree, by kind of file.
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

/// `source`: all (default) | unstaged | staged | branch (against `base`, else the project's) | commit | turn (`session`'s last).
public struct GitDiff: RPCMethod {
    public static let name = "git.diff"
    public typealias Result = [FileDiff]
    /// What the diff is taken against; a name the daemon doesn't know is refused, not read as `all`.
    public enum Source: String, Codable, Sendable, CaseIterable {
        case all, unstaged, staged, branch, commit, turn
        case tidy   // Tidy Up's copies of the instruction files against the files now
    }
    public var id: String, source: Source?, file: String?, base: String?, commit: String?, session: String?
    /// Changes of whitespace alone left out (`git diff -w`).
    public var ignoreSpace: Bool?
    /// Unchanged lines around each change, 3 when nil (git's -U).
    public var context: Int?
    /// With source "turn": that turn (`SessionTurns.Mark.id`), up to where the next one began; nil: the last turn.
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
/// Commits on the branch since its base; `all`: the whole history.
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
/// The commits a push would send and a pull would bring, `limit` (default 5) of each, newest first. The counts are `git.branches`'.
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
/// One hunk of `file` staged (or unstaged with `reverse`): the one with `fingerprint`, else `header`, else number `hunk`.
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
/// → the new commit's hash.
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
/// Checks out `branch` in workspace `id`; `create` makes it, `remote` takes it from origin.
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
/// The history as graph rows, at most `limit`; `more`: there's more.
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
/// The files `commit` changed.
public struct GitCommitFiles: RPCMethod {
    public static let name = "git.commitFiles"
    public typealias Result = [FileChange]
    public var id: String, commit: String
    public init(id: String, commit: String) {
        self.id = id
        self.commit = commit
    }
}
/// The picture of a commit author's account on the project's GitHub or GitLab (through gh / glab), as image data. nil
/// when no account has the email, or when the project is on neither.
public struct GitAuthorAvatar: InternalMethod {
    public static let name = "git.authorAvatar"
    public typealias Result = Data?
    public var id: String, email: String
    public init(id: String, email: String) {
        self.id = id
        self.email = email
    }
}
/// Who last changed a line of a file in workspace `worktreeId`, as the file is on disk: the agent's turn whose changes
/// brought it (its changes shown as a commit made for them), else the commit, else nobody yet (`commit` nil).
public struct GitLineOrigin: InternalMethod {
    public static let name = "git.lineOrigin"
    public var worktreeId: String, file: String
    /// 1-based.
    public var line: Int
    public init(worktreeId: String, file: String, line: Int) {
        self.worktreeId = worktreeId
        self.file = file
        self.line = line
    }
    public struct Origin: Codable, Sendable, Equatable {
        /// What brought the line in: one of the project's commits, or the commit made for the turn's changes; nil when
        /// nothing did.
        public var commit: String?
        public var author: String, date: Date, summary: String
        /// The agent's turn whose changes brought it.
        public var turn: SessionTurns.Mark?
        public init(commit: String?, author: String, date: Date, summary: String, turn: SessionTurns.Mark? = nil) {
            self.commit = commit
            self.author = author
            self.date = date
            self.summary = summary
            self.turn = turn
        }
    }
    /// Nil: the line or the file isn't in git's view.
    public typealias Result = Origin?
}
/// What a commit's card shows beyond its row in the graph: the message's body, the author's email, and how big the
/// change is.
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
    /// A name the caller picks, for `git.undoDiscard` to put back this discard and no other.
    public var undo: String?
    public init(id: String, files: [String]? = nil, undo: String? = nil) {
        self.id = id
        self.files = files
        self.undo = undo
    }
}
/// Puts back what the last discard in workspace `id`'s folder threw away (a hunk or files), within a minute of it and
/// only while the files are as the discard left them.
public struct GitUndoDiscard: InternalMethod {
    public static let name = "git.undoDiscard"
    public typealias Result = Done
    public var id: String
    /// The discard's own `undo` name: that one. nil: the last one without a name.
    public var undo: String?
    public init(id: String, undo: String? = nil) {
        self.id = id
        self.undo = undo
    }
}
/// `op`: pull | push | fetch.
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
/// The file at `path` on its forge at HEAD, lines `start`…`end`.
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
/// The project's pages on its website (from origin), or null when origin isn't on GitHub, GitLab or Bitbucket.
public struct GitWebPages: RPCMethod {
    public static let name = "git.webPages"
    public typealias Result = Pages?
    /// `forge` is "github", "gitlab" or "bitbucket"; `ci` is what the forge calls CI (Actions, Pipelines); `pulls` is
    /// what it calls pull requests (pull or merge requests).
    public struct Pages: Codable, Sendable, Equatable {
        public var forge: String, repo: String, ci: String, pulls: String, issues: String
        public init(forge: String, repo: String, ci: String, pulls: String, issues: String) {
            self.forge = forge
            self.repo = repo
            self.ci = ci
            self.pulls = pulls
            self.issues = issues
        }
        /// The address of a commit's page, built the way each site builds it.
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

/// Throws away one hunk of a file's unstaged changes in workspace `id`: the one with `fingerprint`, else the one whose
/// "@@ … @@" line is `header`, as the caller saw it (as `git.hunk` finds it; `hunk`, its number, isn't read). If
/// the file changed since and that hunk isn't there, nothing is thrown away.
public struct GitDiscardHunk: RPCMethod {
    public static let name = "git.discardHunk"
    public typealias Result = Done
    public var id: String, file: String, hunk: Int, header: String
    /// The hunk's full text as shown (GitKit's `Hunk.fingerprint`): with it, a hunk whose lines changed since is refused
    /// even when its header didn't. Optional, so older callers keep working.
    public var fingerprint: String?
    /// A name the caller picks, for `git.undoDiscard` to put back this hunk and no other.
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
