import Foundation
import Core

/// Pull, push and fetch of a workspace's branch, started from the window bar. `AppModel.syncing` says what runs, so the
/// branch chip shows it after the popover that started it has closed; the git watch reads again when it ends.
@MainActor
enum GitSync {
    /// Runs `ops` (pull | push | fetch) one after another and stops at the first failure: its message, else nil. A push
    /// starts CI: the branch chip looks for its run now.
    static func run(_ app: AppModel, _ wid: String, _ ops: [String]) async -> String? {
        defer { app.syncing[wid] = nil; app.watchAgain(.git, wid) }
        for op in ops {
            app.syncing[wid] = op == "push" ? String(localized: "Pushing…") : op == "pull" ? String(localized: "Pulling…") : String(localized: "Fetching…")
            if let e = await app.tryCall(GitRemoteOp(id: wid, op: op)).error { return e }
            if op == "push" { app.watchAgain(.ci, app.rowBadges.folder(of: wid)?.id ?? wid) }
        }
        return nil
    }

    /// A push git refused because the remote has commits this branch lacks (the fix is a pull first).
    static func isRejected(_ error: String) -> Bool {
        ["[rejected]", "Updates were rejected", "fetch first", "non-fast-forward"].contains { error.contains($0) }
    }
}
