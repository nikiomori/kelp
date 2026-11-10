import Core
import Foundation
import KelpKit

/// What runs on each workspace's branch now, by worktree id: the branch chip, the popover and the Source Control panel
/// all show it, and it outlives whichever of them started it. The app's one, as a part (`AppModel.part`).
@MainActor
@Observable
final class SyncState {
    struct Running: Equatable {
        /// "Pushing…", or the caller's word for several steps ("Syncing…").
        var title: String
        /// The step running now: pull | push | fetch.
        var op: String
    }
    var running: [String: Running] = [:]
}

/// Every pull, push and fetch of a workspace's branch, wherever it's asked for (the window bar's popover, the panel, the
/// commands, Commit & Push): one at a time per branch, and `SyncState` says which; the git watch reads again when it ends.
@MainActor
enum GitSync {
    static func state(_ app: AppModel) -> SyncState { app.part { SyncState() } }

    /// Runs `ops` (pull | push | fetch) one after another and stops at the first failure: its message, else nil. A push
    /// starts CI: the branch chip looks for its run now. While one runs on the branch, another is refused.
    static func run(_ app: AppModel, _ wid: String, _ ops: [String], title: String? = nil) async -> String? {
        guard state(app).running[wid] == nil else {
            return String(localized: "A pull or push is already running on this branch.")
        }
        defer {
            state(app).running[wid] = nil
            app.watchAgain(.git, wid)
        }
        for op in ops {
            state(app).running[wid] = .init(title: title ?? Self.title(op), op: op)
            if let error = await app.tryCall(GitRemoteOp(id: wid, op: op)).error { return error }
            if op == "push" { app.watchAgain(.ci, app.gitFolder(of: wid)?.id ?? wid) }
        }
        return nil
    }

    static func title(_ op: String) -> String {
        switch op {
        case "push": String(localized: "Pushing…")
        case "pull": String(localized: "Pulling…")
        default: String(localized: "Fetching…")
        }
    }

    /// A push git refused because the remote has commits this branch lacks (the fix is a pull first).
    static func isRejected(_ error: String) -> Bool {
        ["[rejected]", "Updates were rejected", "fetch first", "non-fast-forward"].contains { error.contains($0) }
    }
}
