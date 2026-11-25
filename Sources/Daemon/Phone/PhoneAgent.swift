import Agents
import Core
import Foundation

/// Turns a session into the agent record that the phone's page shows (phone/js/api.js `agentFrom`). The record holds
/// the fields the page reads, with null where a value is missing and dates in ISO 8601.
enum PhoneAgent {
    /// Whether the session has an agent row in Kelp's sidebar. It must be an agent that has not exited, and not a
    /// terminal or a command that an agent started.
    static func shown(_ session: Session) -> Bool {
        session.isAgent && session.status != .exited && session.startedBy == nil
    }

    /// Returns the page's record for the session. `name` is the agent's name from its manifest, `project` is the
    /// project's name, and `workspace` is the workspace's `Worktree.displayName`.
    static func from(
        _ session: Session, name: String, project: String, projectId: String? = nil, workspace: String
    ) -> [String: JSONValue] {
        let waiting = session.status == .waiting
        return [
            "id": .string(session.id), "title": .string(session.displayTitle),
            "agent": .string(session.agent ?? ""), "agentName": .string(name),
            "project": .string(project), "projectId": projectId.map(JSONValue.string) ?? .null,
            "workspace": .string(workspace),
            "status": .string(session.status.rawValue), "statusAt": iso(session.statusAt),
            "unread": .bool(session.unread), "summary": .string(session.summary),
            // The page offers Allow / Deny only for a permission question whose text is shown whole, as Kelp's own
            // banner does. The user answers any other question with text.
            "ask": waiting
                ? .object([
                    "kind": .string(session.asksPermission ? "permission" : "question"),
                    "text": .string(session.summary)
                ]) : .null,
            "running": session.running.map(JSONValue.string) ?? .null,
            "progress": session.progress.map(JSONValue.int) ?? .null,
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
