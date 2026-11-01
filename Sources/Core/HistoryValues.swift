import Foundation

/// One resumable conversation of a CLI coding agent, read from its on-disk transcript (AgentData reads them).
public struct AgentSessionInfo: Codable, Sendable, Equatable, Identifiable {
    public enum Agent: String, Codable, Sendable, CaseIterable { case claude, codex }
    public var agent: Agent
    public var id: String
    public var cwd: String
    public var title: String
    public var started: Date
    public var updated: Date
    /// Exact for small files; extrapolated from the head and tail for large ones.
    public var messageCount: Int
    public var path: URL
    public init(agent: Agent, id: String, cwd: String, title: String, started: Date, updated: Date, messageCount: Int, path: URL) {
        self.agent = agent; self.id = id; self.cwd = cwd; self.title = title
        self.started = started; self.updated = updated; self.messageCount = messageCount; self.path = path
    }
}
