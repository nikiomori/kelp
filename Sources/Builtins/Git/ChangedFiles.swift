import Core
import DesignKit
import Foundation
import KelpKit

/// Watches the git status of the workspace on screen for as long as it's on screen; the daemon pushes it when the
/// workspace's files change. The number on the Source Control icon, the branch chip in the window bar and Source
/// Control itself read its `GitEvent` (`AppModel.latest`).
@MainActor
final class ChangedFiles {
    private let app: AppModel
    private let watched: Watched

    /// How many files changed in the workspace on screen.
    var count: Int { app.latest(GitEvent.self, app.gitKey(app.workbench.workspaceId))?.changes?.count ?? 0 }

    init(app: AppModel) {
        self.app = app
        watched = Watched(.git, in: app)
        track(owner: self) { [app] in
            app.workbench.workspaceId.map(app.gitKey)
        } changed: { [weak self] in
            self?.watched.key = $0
        }
    }
}
