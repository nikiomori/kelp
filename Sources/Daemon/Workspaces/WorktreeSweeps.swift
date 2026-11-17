import Core
import Foundation
import os

/// Keeps the disk that each project's other worktrees take, as last swept (`repo.worktreeSizes`, which runs a `du` and
/// two git commands for each worktree). Every hover card of a project asks, and so does every Disk Usage measure. So
/// only one sweep of a project runs at a time, whoever asks meanwhile waits for it and shares its answer, and the
/// answer is given again for `fresh` seconds.
final class WorktreeSweeps: Sendable {
    typealias Item = RepoWorktreeSizes.Item
    /// How long a sweep's answer is reused. A pointer going back over the sidebar finds the answer it just got, and a
    /// build made since then shows on a later look.
    static let fresh: TimeInterval = 30

    private struct Project {
        let sweeping = NSLock()   // held across du and git (blocking runs), so not the unfair lock
        var items: [Item] = [], at = Date.distantPast
        /// Counts calls to `forget`. A sweep that a `forget` ran during saw worktrees that may be gone, so its answer
        /// isn't kept.
        var forgotten = 0
    }
    private let projects = OSAllocatedUnfairLock(initialState: [String: Project]())

    /// Returns `sweep`'s answer for `project`, or the answer a sweep left less than `fresh` seconds before the ask. A
    /// sweep under way counts too, once it ends. With `again`, only this call's own `sweep` answers, run after the one
    /// under way.
    func sizes(of project: String, again: Bool = false, _ sweep: () throws -> [Item]) rethrows -> [Item] {
        let asked = Date()
        let sweeping = projects.withLock { all in
            let found = all[project] ?? Project()
            all[project] = found
            return found.sweeping
        }
        return try sweeping.withLock {
            let kept = projects.withLock { $0[project] }
            if !again, let kept, asked.timeIntervalSince(kept.at) < Self.fresh { return kept.items }
            let items = try sweep()
            projects.withLock {
                guard $0[project]?.forgotten == kept?.forgotten else { return }
                $0[project]?.items = items
                $0[project]?.at = Date()
            }
            return items
        }
    }

    /// Called when the project's worktrees changed (some were removed). The next ask sweeps again, and the sweep under
    /// way isn't kept. This doesn't wait for that sweep, because a `du` stuck on a dead mount would hold up a removal.
    func forget(_ project: String) {
        projects.withLock {
            $0[project]?.forgotten += 1
            $0[project]?.at = .distantPast
        }
    }
}
