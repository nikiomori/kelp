import Foundation

// Commits an agent proposes for a workspace's changes (`kelp commit add`), which the user edits and Kelp makes: the
// agent never stages or commits itself.

/// One commit of a plan: the files it takes, whole, and its message (subject, a blank line, the body).
public struct PlannedCommit: Codable, Sendable, Equatable {
    public var files: [String]
    public var message: String
    public init(files: [String], message: String) {
        self.files = files
        self.message = message
    }
}

/// An agent proposes one more commit for `worktreeId`'s changes → how many it has proposed so far.
public struct CommitPlanAdd: RPCMethod {
    public static let name = "commit.plan.add"
    public typealias Result = Int
    public var worktreeId: String, files: [String], message: String
    /// The session it comes from (`KELP_SESSION`), whose agent the panel names.
    public var session: String?
    public init(worktreeId: String, files: [String], message: String, session: String? = nil) {
        self.worktreeId = worktreeId
        self.files = files
        self.message = message
        self.session = session
    }
}

/// The commits proposed for `worktreeId` since the last take, oldest first; the daemon forgets them.
public struct CommitPlanTake: InternalMethod {
    public static let name = "commit.plan.take"
    public typealias Result = [PlannedCommit]
    public var worktreeId: String
    public init(worktreeId: String) { self.worktreeId = worktreeId }
}

/// A commit of exactly `files` as they are on disk (new and deleted ones too), whatever else is staged, which stays
/// staged → the new commit's short hash.
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

/// The last `count` commits undone, their changes kept staged (`git reset --soft`): only while HEAD is still `head`.
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
