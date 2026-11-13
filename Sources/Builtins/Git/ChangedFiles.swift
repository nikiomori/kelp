import Core
import DesignKit
import Foundation
import KelpKit

/// The workspace on screen's git, watched for as long as it's on screen (the daemon pushes it when its files change):
/// the number on the Source Control icon, the window bar's branch chip and Source Control itself read `AppModel.git`.
@MainActor
final class ChangedFiles {
    private let app: AppModel
    private let watched: Watched

    /// Files changed in the workspace on screen.
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
