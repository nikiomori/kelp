import Foundation

/// Returns the status changes of every session that changed since `since`, oldest first, read from the trail the daemon
/// keeps beside each session's history (`session.trail`). The Agents Overview draws each chat's day from them and sums
/// the week. A session lists the status it had at `since` as its first change, at `since`; one with no change since
/// then isn't listed.
public struct SessionHistory: InternalMethod {
    public static let name = "session.history"
    public struct Change: Codable, Sendable, Equatable {
        public var at: Date
        public var status: AgentStatus
        public init(at: Date, status: AgentStatus) {
            self.at = at
            self.status = status
        }
    }
    public struct Entry: Codable, Sendable, Equatable {
        public var session: String
        public var changes: [Change]
        public init(session: String, changes: [Change]) {
            self.session = session
            self.changes = changes
        }
    }
    public typealias Result = [Entry]
    public var since: Date
    public init(since: Date) { self.since = since }
}
