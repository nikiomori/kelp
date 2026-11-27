import AppKit
import Core
import WorkbenchKit

/// The tabs of a loaded workspace (one shown lately, whose tabs live on while another workspace is on screen), for
/// whatever acts in them without showing the workspace, such as an agent's `kelp browser` in its page tab.
@MainActor
extension Workbench {
    /// The workspace's tabs, or nil while it isn't loaded.
    package func loadedTabs(_ workspace: String) -> [TabRef]? { editors?.area(workspace)?.layout.allTabs }

    /// What a tab of the workspace shows, made if it wasn't made yet.
    package func content(_ tab: TabRef, in workspace: String) -> TabContent? { editors?.area(workspace)?.content(tab) }

    /// Opens `uri` in a new pane to the right and leaves the keys where they are (`kelp open` without `--focus`),
    /// whether or not the workspace is on screen. A new shared browser page can opt out of reusing an open tab.
    package func openBeside(_ uri: String, in workspace: String, reuse: Bool = true) -> TabRef? {
        guard let area = editors?.area(workspace) else { return nil }
        if editors?.current === area {
            return area.showAside(uri, split: .right, reuse: reuse)
        }
        return area.open(uri, split: .right, focus: false, reuse: reuse)
    }

    package func selectTab(_ id: String, in workspace: String) {
        guard let area = editors?.area(workspace), area.layout.group(of: id) != nil else { return }
        area.select(id, focus: false)
    }
}
