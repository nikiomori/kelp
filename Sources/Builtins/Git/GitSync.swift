import Core
import Foundation
import KelpKit

/// What runs on each workspace's branch now ("Pushing…"), by worktree id: the branch chip shows it after the popover that
/// started it has closed. The app's one, as a part (`AppModel.part`).
@MainActor
@Observable
final class SyncState {
    var running: [String: String] = [:]
}

/// Pull, push and fetch of a workspace's branch, started from the window bar (`BranchActions`): `SyncState` says what
/// runs, and the git watch reads again when it ends.
@MainActor
enum GitSync {
    static func state(_ app: AppModel) -> SyncState { app.part { SyncState() } }

    /// Runs `ops` (pull | push | fetch) one after another and stops at the first failure: its message, else nil. A push
    /// starts CI: the branch chip looks for its run now.
    static func run(_ app: AppModel, _ wid: String, _ ops: [String]) async -> String? {
        defer {
            state(app).running[wid] = nil
            app.watchAgain(.git, wid)
        }
        for op in ops {
            state(app).running[wid] =
                op == "push"
                ? String(localized: "Pushing…")
                : op == "pull" ? String(localized: "Pulling…") : String(localized: "Fetching…")
            if let error = await app.tryCall(GitRemoteOp(id: wid, op: op)).error { return error }
            if op == "push" { app.watchAgain(.ci, app.gitFolder(of: wid)?.id ?? wid) }
        }
        return nil
    }

    /// A push git refused because the remote has commits this branch lacks (the fix is a pull first).
    static func isRejected(_ error: String) -> Bool {
        ["[rejected]", "Updates were rejected", "fetch first", "non-fast-forward"].contains { error.contains($0) }
    }
}
