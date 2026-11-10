import Agents
import Core
import Foundation
import GitKit

// An agent's turns: the tree when one starts, and what it changed by the time it stops.

extension LiveSession {
    /// One turn of the agent: the tree when it started working, and what it changed by the time it stopped.
    struct Turn: Codable, Sendable {
        struct File: Codable, Sendable {
            var path: String, added: Int, removed: Int
        }
        var files: [File]
        var seconds: Double
    }

    /// Called with every status change: a snapshot when work starts, the changes when it stops (git work off the lock).
    func noteTurn(_ status: AgentStatus, remotes: Remotes = .none) {
        let (shell, starting, ending, start, cwd, prompt, id) = state.withLock { st in
            // A shell or a plain command (a dev server, a script) has no turns: its output comes and goes, and each change
            // would copy the index and hash the tree again.
            let shell = st.record.agent == "shell" || st.record.agent == "custom"
            let (starting, ending) = st.turnMoved(to: status)
            if starting { st.turnPrompt = st.lastSent }
            return (shell, starting, ending, st.turnStart, st.turnFolder ?? st.record.cwd, st.turnPrompt, st.record.id)
        }
        guard !shell, starting || ending else { return }
        // One after another, per session: a short turn's end waits for its own start snapshot instead of diffing against
        // the previous turn's (which credited it with that turn's changes), and snapshots can't land out of order.
        turnWork.async { [weak self] in
            if starting {
                let tree = try? Git.snapshotTree(cwd, remotes: remotes)   // none in a folder without git
                self?.state.withLock { $0.turnTree = tree }
                if let tree, let keep = self?.callbacks.turnStarted {
                    let head = Log.session.attempt("a turn's HEAD") { try Git.head(cwd, remotes: remotes) } ?? nil
                    keep(SessionTurns.Mark(session: id, tree: tree, head: head, folder: cwd, prompt: prompt))
                }
            } else if let start, let base = self?.turnBase {
                let files = ((try? Git.changesSince(tree: base, cwd: cwd, remotes: remotes)) ?? [])
                    .map { Turn.File(path: $0.path, added: $0.added, removed: $0.removed) }
                self?.state.withLock { $0.turnResult = Turn(files: files, seconds: Date().timeIntervalSince(start)) }
            }
            if ending { self?.callbacks.turnEnded?(prompt) }
        }
    }
}
