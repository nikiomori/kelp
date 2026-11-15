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
                // None in a folder without git, which is no failure. One git couldn't take is: the turn has no diff and
                // no Undo, and the log says why.
                let snapshot =
                    Log.session.attempt("a turn's snapshot in \(cwd)") { try Git.turnSnapshot(cwd, remotes: remotes) }
                    ?? nil
                self?.state.withLock { $0.turnTree = snapshot?.tree }
                if let snapshot, let keep = self?.callbacks.turnStarted {
                    let head = Log.session.attempt("a turn's HEAD") { try Git.head(cwd, remotes: remotes) } ?? nil
                    keep(
                        SessionTurns.Mark(session: id, tree: snapshot.tree, head: head, folder: cwd, prompt: prompt),
                        snapshot.staged)
                }
            } else if let start {
                // No snapshot to compare with, or a diff that failed: no result for this turn. Not one that changed
                // nothing, nor the turn before's left standing as the last.
                let files = self?.turnBase.flatMap { base in
                    Log.session.attempt("what a turn changed in \(cwd)") {
                        try Git.changesSince(tree: base, cwd: cwd, remotes: remotes)
                    }
                }
                let turn = files.map { files in
                    Turn(
                        files: files.map { Turn.File(path: $0.path, added: $0.added, removed: $0.removed) },
                        seconds: Date().timeIntervalSince(start))
                }
                self?.state.withLock { $0.turnResult = turn }
            }
            if ending { self?.callbacks.turnEnded?(prompt) }
        }
    }
}
