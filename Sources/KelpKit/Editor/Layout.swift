import Core
import Foundation
import WorkbenchKit

/// Each workspace's layout is kept in the daemon's database (`layout/<id>`, see `UIState`) so a relaunch shows the same arrangement.
extension WorkspaceLayout {
    @MainActor static func load(_ workspace: String, from state: UIState) -> WorkspaceLayout {
        (try? state["layout/\(workspace)"]?.decode(WorkspaceLayout.self)) ?? WorkspaceLayout()
    }
    @MainActor func save(_ workspace: String, to state: UIState) {
        state["layout/\(workspace)"] = try? .from(self)
    }
}
