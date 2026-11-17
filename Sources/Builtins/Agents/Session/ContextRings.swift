import Core
import DesignKit
import KelpKit

/// Watches the context rings on agents' tabs. It watches each agent that hasn't ended in the workspace on screen,
/// since only those agents have tabs there, and stops when another workspace is shown or the agent ends. A ring that
/// was read before is kept for the next time its workspace shows, so it appears at once, until its agent ends. The app
/// has one of these, made as a part when Kelp starts.
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
