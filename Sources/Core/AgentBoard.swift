import Foundation

/// What `kelp agents` lists: agents that run, the one that needs someone first. Rows keep their order among equals, so a
/// list read on a phone doesn't reshuffle while nothing about it changed.
public enum AgentBoard {
    public struct Row: Sendable, Equatable {
        public var id: String, status: AgentStatus, title: String, detail: String
    }

    private static let order: [AgentStatus] = [.waiting, .error, .working, .done, .idle]

    public static func rows(_ sessions: [Session], worktrees: [Worktree], repos: [Repo]) -> [Row] {
        let byId = Dictionary(sessions.map { ($0.id, $0) }) { a, _ in a }
        func project(_ session: Session) -> String? {
            let repo = worktrees.first { $0.id == session.worktreeId }?.repoId
            return repos.first { $0.id == repo }?.name
        }
        func rank(_ session: Session) -> Int { order.firstIndex(of: session.status) ?? order.count }
        let running = sessions.filter { isAgent($0) && order.contains($0.status) }
        return running.sorted { (rank($0), $0.createdAt, $0.id) < (rank($1), $1.createdAt, $1.id) }.map { session in
            let title =
                (session.parent.flatMap { byId[$0] }.map { $0.displayTitle + " › " } ?? "") + session.displayTitle
            let asks = [.waiting, .error].contains(session.status) && !session.summary.isEmpty   // once it goes on, the question is over
            let detail = [session.status.label, project(session), asks ? session.summary : nil].compactMap(\.self)
                .joined(
                    separator: " · ")
            return Row(id: session.id, status: session.status, title: plain(title), detail: plain(detail))
        }
    }

    /// Agents stopped to save memory: nothing happens in them, so they're counted, not listed.
    public static func paused(_ sessions: [Session]) -> Int {
        sessions.filter { isAgent($0) && $0.status == .paused }.count
    }

    private static func isAgent(_ session: Session) -> Bool {
        session.agent != nil && session.agent != "shell" && session.agent != "custom"
    }

    /// Titles and summaries come from what agents print: on a real terminal an escape in them would be obeyed.
    static func plain(_ text: String) -> String {
        String(
            String.UnicodeScalarView(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 })
        )
    }
}
