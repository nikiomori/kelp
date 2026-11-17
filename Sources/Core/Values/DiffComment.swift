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
    /// "old" means the lines are removed ones, numbered as in the old file. nil means the new file's lines, or a
    /// comment written before comments had sides.
    public var side: String?
    /// HEAD at the time the comment was written, which the old file's line numbers are counted in.
    public var commit: String?
    /// The agent that wrote the comment (a reviewer's finding). nil when the user wrote it.
    public var author: String?
    /// The full hash of the past commit whose diff the comment is on. nil when it is on the folder's changes.
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

    /// Whether the comment belongs on the diff of `commit` (nil for the folder's changes). A hash matches even when
    /// either side is cut short.
    public func isOn(_ commit: String?) -> Bool {
        guard let on = onCommit, let commit else { return onCommit == nil && commit == nil }
        return on.hasPrefix(commit) || commit.hasPrefix(on)
    }
}
