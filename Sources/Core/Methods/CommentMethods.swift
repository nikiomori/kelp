import Foundation

// Review comments on a workspace's diff (`id` is its worktree id), from the user and from reviewer agents. They are
// kept until they are sent to an agent or resolved.

/// Adds a review comment on lines `start`…`end` of `file` in workspace `id`.
public struct CommentAdd: RPCMethod {
    public static let name = "comment.add"
    public typealias Result = DiffComment
    public var id: String, file: String, start: Int?, end: Int?, quote: String?, text: String
    /// "old" puts the comment on removed lines, numbered as in the old file.
    public var side: String?
    /// The session the comment comes from (`kelp comment add` in an agent's terminal). That session's agent is named as
    /// the comment's author.
    public var session: String?
    /// The commit whose diff the comment is on, when that isn't the folder's HEAD (a past commit on screen).
    public var commit: String?
    public init(
        id: String, file: String, start: Int? = nil, end: Int? = nil, quote: String? = nil, text: String,
        side: String? = nil,
        session: String? = nil, commit: String? = nil
    ) {
        self.id = id
        self.file = file
        self.start = start
        self.end = end
        self.quote = quote
        self.text = text
        self.side = side
        self.session = session
        self.commit = commit
    }
}
/// Lists the workspace's review comments.
public struct CommentList: RPCMethod {
    public static let name = "comment.list"
    public typealias Result = [DiffComment]
    public var id: String
    public init(id: String) { self.id = id }
}
/// Sets the state of comment `id` to open, sent or resolved.
public struct CommentSetState: RPCMethod {
    public static let name = "comment.setState"
    public typealias Result = Done
    public var id: String, state: String
    public init(id: String, state: String) {
        self.id = id
        self.state = state
    }
}
/// Sends the workspace's open comments (only those in `only`, when given) as one message into `session`. Returns how
/// many were sent.
public struct CommentSend: RPCMethod {
    public static let name = "comment.send"
    public typealias Result = Int
    public var id: String, session: String, only: [String]?
    public init(id: String, session: String, only: [String]? = nil) {
        self.id = id
        self.session = session
        self.only = only
    }
}
