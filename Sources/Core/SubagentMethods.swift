import Foundation

/// One thing a subagent did: the tool, and the path or command it was given.
public struct SubagentStep: Codable, Sendable, Equatable {
    public var tool: String, detail: String, at: Date
    public init(tool: String, detail: String, at: Date) { self.tool = tool; self.detail = detail; self.at = at }
}

/// What an agent's subagents at work did last, by id. Empty for an agent that keeps no transcript of them: only Claude Code does.
public struct SessionSubagentSteps: InternalMethod {
    public static let name = "session.subagentSteps"
    public struct Last: Codable, Sendable, Equatable {
        public var step: SubagentStep
        /// When its transcript last changed: a long quiet is a long command, or a subagent that hangs.
        public var touched: Date
        public init(step: SubagentStep, touched: Date) { self.step = step; self.touched = touched }
    }
    public typealias Result = [String: Last]
    public var id: String
    public init(id: String) { self.id = id }
}

/// All a subagent did and what it reported, read from its transcript; nil when there is none.
public struct SessionSubagentJournal: InternalMethod {
    public static let name = "session.subagentJournal"
    public struct Journal: Codable, Sendable, Equatable {
        public var kind: String, task: String?, model: String?
        /// Tokens in its last request.
        public var context: Int?
        public var steps: [SubagentStep] = []
        public var report: String?
        public init(kind: String, task: String?) { self.kind = kind; self.task = task }
    }
    public typealias Result = Journal?
    public var id: String, subagent: String
    public init(id: String, subagent: String) { self.id = id; self.subagent = subagent }
}
