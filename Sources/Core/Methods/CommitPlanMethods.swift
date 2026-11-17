import Foundation

// Commits that an agent proposes for a workspace's changes (`kelp commit add`). The user edits them and Kelp makes
// them, so the agent never stages or commits by itself.

/// One commit of a plan: the files it takes, whole, and its message (the subject, a blank line, then the body).
public struct PlannedCommit: Codable, Sendable, Equatable {
    public var files: [String]
    public var message: String
    public init(files: [String], message: String) {
        self.files = files
        self.message = message
    }
}

/// Proposes one more commit for the changes in `worktreeId`. Returns how many commits the agent has proposed so far.
public struct CommitPlanAdd: RPCMethod {
    public static let name = "commit.plan.add"
    public typealias Result = Int
    public var worktreeId: String, files: [String], message: String
    /// The session the proposal comes from (`KELP_SESSION`). The panel names that session's agent.
    public var session: String?
    public init(worktreeId: String, files: [String], message: String, session: String? = nil) {
        self.worktreeId = worktreeId
        self.files = files
        self.message = message
        self.session = session
    }
}

/// Returns the commits proposed for `worktreeId` since the last take, oldest first, and the daemon forgets them.
public struct CommitPlanTake: InternalMethod {
    public static let name = "commit.plan.take"
    public typealias Result = [PlannedCommit]
    public var worktreeId: String
    public init(worktreeId: String) { self.worktreeId = worktreeId }
}

/// Commits exactly `files` as they are on disk (new and deleted files too), whatever else is staged, and leaves the
/// rest staged. Returns the new commit's short hash.
public struct GitCommitPaths: RPCMethod {
    public static let name = "git.commitPaths"
    public typealias Result = String
    public var worktreeId: String, files: [String], message: String
    public init(worktreeId: String, files: [String], message: String) {
        self.worktreeId = worktreeId
        self.files = files
        self.message = message
    }
}

/// Undoes the last `count` commits and keeps their changes staged (`git reset --soft`). It does so only while HEAD is
/// still `head`.
public struct GitUndoCommits: RPCMethod {
    public static let name = "git.undoCommits"
    public typealias Result = Done
    public var worktreeId: String, head: String, count: Int
    public init(worktreeId: String, head: String, count: Int) {
        self.worktreeId = worktreeId
        self.head = head
        self.count = count
    }
}
