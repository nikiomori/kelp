import Agents
import Core
import Foundation

/// A session as the phone's page shows an agent (phone/js/api.js `agentFrom`): the fields the page reads, null where
/// there's nothing, dates as ISO 8601.
enum PhoneAgent {
    /// The rows Kelp's sidebar has for agents: still there, and not a terminal or a command that runs under one.
    static func shown(_ session: Session) -> Bool {
        session.isAgent && session.status != .exited && session.startedBy == nil
    }

    /// `name`: the agent's, as its manifest says. `place`: its project and workspace (`Worktree.displayName`).
    static func from(_ session: Session, name: String, project: String, workspace: String) -> [String: JSONValue] {
        let waiting = session.status == .waiting
        return [
            "id": .string(session.id), "title": .string(session.displayTitle),
            "agent": .string(session.agent ?? ""), "agentName": .string(name),
            "project": .string(project), "workspace": .string(workspace),
            "status": .string(session.status.rawValue), "statusAt": iso(session.statusAt),
            "unread": .bool(session.unread), "summary": .string(session.summary),
            // Allow / Deny only for a question shown whole, as Kelp's own banner tells; anything else is answered by text.
            "ask": waiting
                ? .object([
                    "kind": .string(session.asksPermission ? "permission" : "question"),
                    "text": .string(session.summary)
                ]) : .null,
            "running": session.running.map(JSONValue.string) ?? .null,
            "limit": session.limitHit.map {
                .object(["kind": .string($0.kind), "resets": $0.resets.map(JSONValue.string) ?? .null])
            } ?? .null,
            "continueAt": iso(session.continueAt)
        ]
    }

    private static func iso(_ date: Date?) -> JSONValue {
        date.map { .string($0.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))) } ?? .null
    }
}
