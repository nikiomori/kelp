import Foundation

// Source control, files and review comments of a workspace (`id` is its worktree id). Results are Core's values
// (GitValues), as GitKit returns them in the daemon.

/// The changed files of workspace `id`.
public struct GitStatus: RPCMethod {
    public static let name = "git.status"; public typealias Result = [FileChange]
    public var id: String
    public init(id: String) { self.id = id }
}
/// The project's branches, and which is checked out in workspace `id`.
public struct GitBranches: RPCMethod {
    public static let name = "git.branches"; public typealias Result = BranchInfo
    public var id: String
    public init(id: String) { self.id = id }
}
/// Lines added and removed in the working tree, by kind of file.
public struct GitLineStats: RPCMethod {
    public static let name = "git.lineStats"; public typealias Result = LineStats
    public var id: String
    public init(id: String) { self.id = id }
}
/// Pushes the workspace's branch.
public struct GitPush: RPCMethod {
    public static let name = "git.push"; public typealias Result = Done
    public var id: String
    public init(id: String) { self.id = id }
}

/// `source`: all (default) | unstaged | staged | branch (against `base`, else the project's) | commit | turn (`session`'s last).
public struct GitDiff: RPCMethod {
    public static let name = "git.diff"; public typealias Result = [FileDiff]
    public var id: String, source: String?, file: String?, base: String?, commit: String?, session: String?
    /// Changes of whitespace alone left out (`git diff -w`).
    public var ignoreSpace: Bool?
    public init(id: String, source: String? = nil, file: String? = nil, base: String? = nil, commit: String? = nil, session: String? = nil,
                ignoreSpace: Bool? = nil) {
        self.id = id; self.source = source; self.file = file; self.base = base; self.commit = commit; self.session = session
        self.ignoreSpace = ignoreSpace
    }
}
/// Commits on the branch since its base; `all`: the whole history.
public struct GitLog: RPCMethod {
    public static let name = "git.log"
    public struct Entry: Codable, Sendable, Equatable {
        public var hash: String, subject: String
        public init(hash: String, subject: String) { self.hash = hash; self.subject = subject }
    }
    public typealias Result = [Entry]
    public var id: String, all: Bool?
    public init(id: String, all: Bool? = nil) { self.id = id; self.all = all }
}
/// The commits a push would send and a pull would bring, `limit` (default 5) of each, newest first. The counts are `git.branches`'.
public struct GitUnsynced: RPCMethod {
    public static let name = "git.unsynced"; public typealias Result = Unsynced
    public var id: String, limit: Int?
    public init(id: String, limit: Int? = nil) { self.id = id; self.limit = limit }
}
/// Stages `files`.
public struct GitStage: RPCMethod {
    public static let name = "git.stage"; public typealias Result = Done
    public var id: String, files: [String]?
    public init(id: String, files: [String]? = nil) { self.id = id; self.files = files }
}
/// Unstages `files`.
public struct GitUnstage: RPCMethod {
    public static let name = "git.unstage"; public typealias Result = Done
    public var id: String, files: [String]?
    public init(id: String, files: [String]? = nil) { self.id = id; self.files = files }
}
/// One hunk of `file` staged (or unstaged with `reverse`): the one with `fingerprint`, else `header`, else number `hunk`.
public struct GitHunk: RPCMethod {
    public static let name = "git.hunk"; public typealias Result = Done
    public var id: String, file: String, hunk: Int?, reverse: Bool?, header: String?, fingerprint: String?
    public init(id: String, file: String, hunk: Int? = nil, reverse: Bool? = nil, header: String? = nil, fingerprint: String? = nil) {
        self.id = id; self.file = file; self.hunk = hunk; self.reverse = reverse; self.header = header; self.fingerprint = fingerprint
    }
}
/// → the new commit's hash.
public struct GitCommit: RPCMethod {
    public static let name = "git.commit"; public typealias Result = String
    public var id: String, message: String, all: Bool?, amend: Bool?
    public init(id: String, message: String, all: Bool? = nil, amend: Bool? = nil) { self.id = id; self.message = message; self.all = all; self.amend = amend }
}
/// The workspace's branch into the project's base branch, in the main checkout.
public struct GitMerge: RPCMethod {
    public static let name = "git.merge"
    public struct Result: Codable, Sendable, Equatable {
        public var merged: Bool, conflicts: [String]
        public init(merged: Bool, conflicts: [String]) { self.merged = merged; self.conflicts = conflicts }
    }
    public var id: String, keepConflicts: Bool?
    public init(id: String, keepConflicts: Bool? = nil) { self.id = id; self.keepConflicts = keepConflicts }
}
/// Checks out `branch` in workspace `id`; `create` makes it, `remote` takes it from origin.
public struct GitSwitch: RPCMethod {
    public static let name = "git.switch"; public typealias Result = Done
    public var id: String, branch: String, create: Bool?, remote: Bool?
    public init(id: String, branch: String, create: Bool? = nil, remote: Bool? = nil) {
        self.id = id; self.branch = branch; self.create = create; self.remote = remote
    }
}
/// The history as graph rows, at most `limit`; `more`: there's more.
public struct GitGraph: RPCMethod {
    public static let name = "git.graph"
    public struct Result: Codable, Sendable, Equatable {
        public var commits: [GraphCommit], more: Bool
        public init(commits: [GraphCommit], more: Bool) { self.commits = commits; self.more = more }
    }
    public var id: String, limit: Int?
    public init(id: String, limit: Int? = nil) { self.id = id; self.limit = limit }
}
/// The files `commit` changed.
public struct GitCommitFiles: RPCMethod {
    public static let name = "git.commitFiles"; public typealias Result = [FileChange]
    public var id: String, commit: String
    public init(id: String, commit: String) { self.id = id; self.commit = commit }
}
/// The picture of a commit author's account on the project's GitHub or GitLab (through gh / glab), as image data.
/// nil: no account has the email, or the project isn't on either.
public struct GitAuthorAvatar: InternalMethod {
    public static let name = "git.authorAvatar"; public typealias Result = Data?
    public var id: String, email: String
    public init(id: String, email: String) { self.id = id; self.email = email }
}
/// What a commit's card shows beyond its graph row: the message's body, the author's email, how big the change is.
public struct GitCommitDetails: RPCMethod {
    public static let name = "git.commitDetails"; public typealias Result = CommitDetails
    public var id: String, commit: String
    public init(id: String, commit: String) { self.id = id; self.commit = commit }
}
/// Throws away the changes to `files` in workspace `id`.
public struct GitDiscard: RPCMethod {
    public static let name = "git.discard"; public typealias Result = Done
    public var id: String, files: [String]?
    public init(id: String, files: [String]? = nil) { self.id = id; self.files = files }
}
/// Puts back what the last discard in workspace `id`'s folder threw away (a hunk or files), within a minute of it and
/// only while the files are as the discard left them.
public struct GitUndoDiscard: InternalMethod {
    public static let name = "git.undoDiscard"; public typealias Result = Done
    public var id: String
    public init(id: String) { self.id = id }
}
/// `op`: pull | push | fetch.
public struct GitRemoteOp: RPCMethod {
    public static let name = "git.remote"; public typealias Result = Done
    public var id: String, op: String
    public init(id: String, op: String) { self.id = id; self.op = op }
}
/// Stashes the changes of workspace `id`, or brings the last stash back with `pop`.
public struct GitStash: RPCMethod {
    public static let name = "git.stash"; public typealias Result = Done
    public var id: String, pop: Bool?
    public init(id: String, pop: Bool? = nil) { self.id = id; self.pop = pop }
}
/// The file at `path` on its forge at HEAD, lines `start`…`end`.
public struct GitWebURL: RPCMethod {
    public static let name = "git.webURL"; public typealias Result = String
    public var path: String, start: Int?, end: Int?
    public init(path: String, start: Int? = nil, end: Int? = nil) { self.path = path; self.start = start; self.end = end }
}
/// The project's pages on its website (from origin), or null when origin isn't on GitHub, GitLab or Bitbucket.
public struct GitWebPages: RPCMethod {
    public static let name = "git.webPages"; public typealias Result = Pages?
    /// `forge`: "github" | "gitlab" | "bitbucket"; `ci`: Actions / Pipelines; `pulls`: pull or merge requests.
    public struct Pages: Codable, Sendable, Equatable {
        public var forge: String, repo: String, ci: String, pulls: String, issues: String
        public init(forge: String, repo: String, ci: String, pulls: String, issues: String) {
            self.forge = forge; self.repo = repo; self.ci = ci; self.pulls = pulls; self.issues = issues
        }
        /// A commit's page, each site's way.
        public func commitURL(_ hash: String) -> String { repo + (forge == "gitlab" ? "/-/commit/" : forge == "bitbucket" ? "/commits/" : "/commit/") + hash }
    }
    public var worktreeId: String?, repoId: String?
    public init(worktreeId: String? = nil, repoId: String? = nil) { self.worktreeId = worktreeId; self.repoId = repoId }
}

/// The project's files, relative paths.
public struct FilesList: RPCMethod {
    public static let name = "files.list"; public typealias Result = [String]
    public var id: String
    public init(id: String) { self.id = id }
}
/// What git ignores in the project (.build/, .env…), relative paths; a folder ignored whole ends with "/" and isn't
/// opened. `folder` (one of those): what's in it, one level, its folders ending with "/".
public struct FilesIgnored: RPCMethod {
    public static let name = "files.ignored"; public typealias Result = [String]
    public var id: String, folder: String?
    public init(id: String, folder: String? = nil) { self.id = id; self.folder = folder }
}
/// Searches the workspace's files for `query`, as a `regex` if set, matching `case` if set, whole words only if `word` is.
public struct FilesSearch: RPCMethod {
    public static let name = "files.search"; public typealias Result = [SearchMatch]
    public var id: String, query: String, regex: Bool?, `case`: Bool?, word: Bool?
    public init(id: String, query: String, regex: Bool? = nil, case: Bool? = nil, word: Bool? = nil) {
        self.id = id; self.query = query; self.regex = regex; self.case = `case`; self.word = word
    }
}

/// A review comment on lines `start`…`end` of `file` in workspace `id`.
public struct CommentAdd: RPCMethod {
    public static let name = "comment.add"; public typealias Result = DiffComment
    public var id: String, file: String, start: Int?, end: Int?, quote: String?, text: String
    /// "old": on removed lines, numbered in the old file.
    public var side: String?
    public init(id: String, file: String, start: Int? = nil, end: Int? = nil, quote: String? = nil, text: String, side: String? = nil) {
        self.id = id; self.file = file; self.start = start; self.end = end; self.quote = quote; self.text = text; self.side = side
    }
}
/// The workspace's review comments.
public struct CommentList: RPCMethod {
    public static let name = "comment.list"; public typealias Result = [DiffComment]
    public var id: String
    public init(id: String) { self.id = id }
}
/// `id`: the comment's. `state`: open | sent | resolved.
public struct CommentSetState: RPCMethod {
    public static let name = "comment.setState"; public typealias Result = Done
    public var id: String, state: String
    public init(id: String, state: String) { self.id = id; self.state = state }
}
/// The workspace's open comments as one message into `session` → how many went.
public struct CommentSend: RPCMethod {
    public static let name = "comment.send"; public typealias Result = Int
    public var id: String, session: String
    public init(id: String, session: String) { self.id = id; self.session = session }
}
