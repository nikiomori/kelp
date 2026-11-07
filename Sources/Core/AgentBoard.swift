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
        func project(_ s: Session) -> String? {
            let repo = worktrees.first { $0.id == s.worktreeId }?.repoId
            return repos.first { $0.id == repo }?.name
        }
        func rank(_ s: Session) -> Int { order.firstIndex(of: s.status) ?? order.count }
        let running = sessions.filter { isAgent($0) && order.contains($0.status) }
        return running.sorted { (rank($0), $0.createdAt, $0.id) < (rank($1), $1.createdAt, $1.id) }.map { s in
            let title = (s.parent.flatMap { byId[$0] }.map { $0.displayTitle + " › " } ?? "") + s.displayTitle
            let asks = [.waiting, .error].contains(s.status) && !s.summary.isEmpty   // once it goes on, the question is over
            let detail = [s.status.label, project(s), asks ? s.summary : nil].compactMap(\.self).joined(
                separator: " · ")
            return Row(id: s.id, status: s.status, title: plain(title), detail: plain(detail))
        }
    }

    /// Agents stopped to save memory: nothing happens in them, so they're counted, not listed.
    public static func paused(_ sessions: [Session]) -> Int {
        sessions.filter { isAgent($0) && $0.status == .paused }.count
    }

    private static func isAgent(_ s: Session) -> Bool { s.agent != nil && s.agent != "shell" && s.agent != "custom" }

    /// Titles and summaries come from what agents print: on a real terminal an escape in them would be obeyed.
    static func plain(_ s: String) -> String {
        String(
            String.UnicodeScalarView(s.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }))
    }
}
