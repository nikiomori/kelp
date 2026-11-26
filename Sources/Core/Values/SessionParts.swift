import Foundation

// What a session's record (`Session`) holds beside its own fields: the limit that stopped it, its subagents, the page
// its turn works on.

/// A plan limit that stopped a session's turn.
public struct LimitHit: Codable, Sendable, Equatable {
    /// The limit's name as the agent gives it, such as "5-hour", "weekly" or "usage".
    public var kind: String
    /// When the limit resets, as the agent printed it ("3:40pm", "Oct 20 at 5am"). nil when the agent didn't say.
    public var resets: String?
    /// When the limit stopped the turn. `resets` is read relative to this time, so "3pm" still means that day's 3pm
    /// after it has passed.
    public var at: Date
    public init(kind: String, resets: String?, at: Date = Date()) {
        self.kind = kind
        self.resets = resets
        self.at = at
    }
}

/// A subagent that an agent started during its turn, either still at work or finished. `kind` is empty when Kelp only
/// learned of the subagent from a terminal report.
public struct Subagent: Codable, Sendable, Equatable, Identifiable {
    public var id: String, kind: String, task: String?
    public var started: Date
    public var ended: Date?
    /// True while the subagent's permission dialog is open.
    public var asks: Bool?
    public init(id: String, kind: String, task: String?, started: Date = Date()) {
        self.id = id
        self.kind = kind
        self.task = task
        self.started = started
    }
}

/// An artifact page an agent works with now: what opens it (`ArtifactItem.target`), what the agent does with it, and
/// when it last did.
public struct SessionPage: Codable, Sendable, Equatable {
    public enum Doing: String, Codable, CaseIterable, Sendable {
        case editing, reading, answering
    }
    public var target: String
    public var doing: Doing
    public var at: Date
    public init(target: String, doing: Doing, at: Date) {
        self.target = target
        self.doing = doing
        self.at = at
    }
}
