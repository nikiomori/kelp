import AppKit
import Core
import WorkbenchKit

/// The tabs of a workspace that is loaded (shown lately: its tabs live on while another one is on screen), for what
/// acts in them without showing it: an agent's `kelp browser` in its page tab.
@MainActor
extension Workbench {
    /// Its tabs; nil while it isn't loaded.
    package func loadedTabs(_ workspace: String) -> [TabRef]? { editors?.area(workspace)?.layout.allTabs }

    /// What a tab of it shows, made if it wasn't yet.
    package func content(_ tab: TabRef, in workspace: String) -> TabContent? { editors?.area(workspace)?.content(tab) }

    /// Opens `uri` in a new pane to the right, the keys left where they are (`kelp open` without `--focus`), whether or
    /// not the workspace is on screen: the tab it shows in (a page already open stays where it is).
    package func openBeside(_ uri: String, in workspace: String) -> TabRef? {
        guard let area = editors?.area(workspace) else { return nil }
        if editors?.current === area {
            area.showAside(uri, split: .right)
        } else {
            area.open(uri, split: .right, focus: false)
        }
        return area.layout.tab(uri: uri) ?? area.layout.pageTab(for: uri)
    }
}
