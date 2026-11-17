import Core
import DesignKit
import KelpKit

/// The context ring on an agent's tab: watched for the agents of the workspace on screen (the tabs there are) that
/// haven't ended, let go as another workspace is shown or the agent ends. A ring read before stays for the next time its
/// workspace shows, so it's there at once, until its agent ends. The app's one, as a part, from Kelp's start.
@MainActor
final class ContextRings {
    static func start(_ app: AppModel) { _ = app.part { ContextRings(app: app) } }

    private struct Wanted: Equatable { var live: Set<String>, shown: Set<String> }
    private let app: AppModel
    private var watched = Set<String>()

    private init(app: AppModel) {
        self.app = app
        track(owner: self) {
            let here = app.workbench.workspaceId
            let live = app.sessions.filter { !$0.isTerminal && $0.status != .exited }
            return Wanted(
                live: Set(live.map(\.id)), shown: Set(live.filter { $0.worktreeId == here }.map(\.id)))
        } changed: { [weak self] in
            self?.follow($0)
        }
    }

    private func follow(_ now: Wanted) {
        for id in now.shown.subtracting(watched) { app.watch(.context, id) }
        for id in watched.subtracting(now.shown) { app.unwatch(.context, id, forgetting: !now.live.contains(id)) }
        watched = now.shown
    }
}
