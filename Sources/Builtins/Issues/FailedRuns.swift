import Foundation
import Core
import KelpKit

/// The CI of the workspace on screen, watched for as long as it's on screen (gh asks the forge once, then again only
/// while a run goes on): the red dot on the CI Runs icon when the branch's latest run of a workflow failed, and whether
/// the icon is in the row at all.
@MainActor
final class FailedRuns {
    private let app: AppModel
    private let watched: Watched

    /// A dot keyed by the failed runs: a new failure shows it again after the panel was looked at.
    var badge: PanelBadge? {
        let runs = CIRuns.latest(app.ci[app.workbench.workspaceId ?? ""]?.result?.runs ?? []).filter(\.failed)
        return runs.isEmpty ? nil : PanelBadge(alert: true, key: runs.map { String($0.id) }.joined(separator: ","))
    }

    /// The CI Runs icon stays out of the row while the daemon says the workspace has no forge remote (Issues stays:
    /// Linear and Jira don't need one). Before it has said, the icon shows: most projects with CI have one.
    var hasRemote: Bool { app.ci[app.workbench.workspaceId ?? ""]?.error != GitHub.noRemote }

    init(app: AppModel) {
        self.app = app; watched = Watched(.ci, in: app)
        track(owner: self) { [app] in app.workbench.workspaceId } changed: { [weak self] in self?.watched.key = $0 }
    }
}
