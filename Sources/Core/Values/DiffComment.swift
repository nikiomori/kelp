import Foundation

/// A comment on lines of a diff, written by the user or by a reviewer agent, kept until it is sent to an agent or
/// resolved.
public struct DiffComment: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable, CaseIterable { case open, sent, resolved }
    public var id: String
    public var worktreeId: String
    public var file: String
    public var startLine: Int
    public var endLine: Int
    public var quote: String
    public var text: String
    public var state: State
    /// "old": the lines are removed ones, numbered in the old file; nil: the new file's (or a comment from before sides).
    public var side: String?
    /// HEAD when it was written: what the old file's line numbers are counted in.
    public var commit: String?
    /// The agent that wrote it (a reviewer's finding); nil: the user.
    public var author: String?
    /// The past commit whose diff it's on (full hash); nil: on the folder's changes.
    public var onCommit: String?
    public init(
        id: String = UUID().uuidString, worktreeId: String, file: String, startLine: Int, endLine: Int, quote: String,
        text: String,
        state: State = .open, side: String? = nil, commit: String? = nil, author: String? = nil, onCommit: String? = nil
    ) {
        self.id = id
        self.worktreeId = worktreeId
        self.file = file
        self.startLine = startLine
        self.endLine = endLine
        self.quote = quote
        self.text = text
        self.state = state
        self.side = side
        self.commit = commit
        self.author = author
        self.onCommit = onCommit
    }

    /// Whether it belongs on the diff of `commit` (nil: the folder's changes); a hash matches either way it's cut short.
    public func isOn(_ commit: String?) -> Bool {
        guard let on = onCommit, let commit else { return onCommit == nil && commit == nil }
        return on.hasPrefix(commit) || commit.hasPrefix(on)
    }
}
