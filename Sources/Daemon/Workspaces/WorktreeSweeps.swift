import Core
import Foundation
import os

/// The disk each project's other worktrees take, as last swept (`repo.worktreeSizes`: a `du` and two git for each).
/// Every hover card of a project asks, and so does every Disk Usage measure: one sweep of a project at a time, which
/// whoever asks meanwhile waits for and shares, and its answer given again for `fresh` seconds.
final class WorktreeSweeps: Sendable {
    typealias Item = RepoWorktreeSizes.Item
    /// A pointer going back over the sidebar finds the answer it just got; a build since shows on the next look.
    static let fresh: TimeInterval = 30

    private struct Project {
        let sweeping = NSLock()   // held across du and git (blocking runs), so not the unfair lock
        var items: [Item] = [], at = Date.distantPast
        /// Counts `forget`: a sweep it ran during saw worktrees that may be gone, and isn't kept.
        var forgotten = 0
    }
    private let projects = OSAllocatedUnfairLock(initialState: [String: Project]())

    /// `sweep`'s answer for `project`, or the one a sweep left less than `fresh` seconds before the ask: the one under
    /// way too, once it ends. `again`: only `sweep`'s own, after the one under way.
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

    /// Its worktrees changed (some were removed): the next ask sweeps, and the sweep under way isn't kept. Doesn't
    /// wait for that one: a `du` stuck on a dead mount would hold a removal up.
    func forget(_ project: String) {
        projects.withLock {
            $0[project]?.forgotten += 1
            $0[project]?.at = .distantPast
        }
    }
}
