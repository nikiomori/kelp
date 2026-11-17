import Core
import Foundation
import KelpKit

/// What runs on each workspace's branch now, by worktree id. The branch chip, the popover and the Source Control panel
/// all show it, and it outlives whichever of them started it. The app has one, as a part (`AppModel.part`).
@MainActor
@Observable
final class SyncState {
    struct Running: Equatable {
        /// "Pushing…", or the caller's word for several steps ("Syncing…").
        var title: String
        /// The step running now.
        var op: GitRemoteOp.Step
    }
    var running: [String: Running] = [:]
}

/// Every pull, push and fetch of a workspace's branch, wherever it's asked for (the window bar's popover, the panel,
/// the commands, Commit & Push). They run one at a time per branch, and `SyncState` says which. The git watch reads
/// again when one ends.
@MainActor
enum GitSync {
    static func state(_ app: AppModel) -> SyncState { app.part { SyncState() } }

    /// Runs `ops` (pull | push | fetch) one after another, stops at the first failure and returns its message, else
    /// nil. A push starts CI, so the branch chip looks for its run now. While one runs on the branch, another is
    /// refused.
    static func run(_ app: AppModel, _ wid: String, _ ops: [GitRemoteOp.Step], title: String? = nil) async -> String? {
        guard state(app).running[wid] == nil else {
            return String(localized: "A pull or push is already running on this branch.")
        }
        defer {
            state(app).running[wid] = nil
            app.watchAgain(.git, app.gitKey(wid))
        }
        for op in ops {
            state(app).running[wid] = .init(title: title ?? Self.title(op), op: op)
            if let error = await app.tryCall(GitRemoteOp(id: wid, op: op)).error { return error }
            if op == .push { app.watchAgain(.ci, app.gitKey(wid)) }
        }
        return nil
    }

    static func title(_ op: GitRemoteOp.Step) -> String {
        switch op {
        case .push: String(localized: "Pushing…")
        case .pull: String(localized: "Pulling…")
        case .fetch: String(localized: "Fetching…")
        }
    }

    /// Whether git refused a push because the remote has commits this branch lacks (the fix is to pull first).
    static func isRejected(_ error: String) -> Bool {
        ["[rejected]", "Updates were rejected", "fetch first", "non-fast-forward"].contains { error.contains($0) }
    }
}
