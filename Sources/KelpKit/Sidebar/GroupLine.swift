import AppKit
import Core
import DesignKit
import WorkbenchKit

/// A group's grey line beside its name. It shows the branch when the name isn't the branch, what only that branch
/// holds, and, when no agent is on the group, what's open there (a row with nothing under it read as an empty one).
extension SidebarCell {
    func showGroupLine(_ worktree: Worktree, onBranch: Bool) {
        var parts: [String] = []
        if onBranch, worktree.branch != worktree.displayName { parts.append(worktree.branch) }
        let work = onBranch ? app.gitState.ownWork(worktree.id) : nil, held = (work?.commits ?? 0) + (work?.files ?? 0)
        if let work, work.commits > 0 { parts.append(String(localized: "\(work.commits) commits")) }
        if let work, work.files > 0 { parts.append(String(localized: "\(work.files) files")) }
        if node.children.isEmpty, node.hidden.isEmpty { parts += openWords(worktree.id) }
        detail.stringValue = parts.joined(separator: " · ")
        detail.isHidden = parts.isEmpty
        detail.toolTip =
            held > 0
            ? String(
                localized:
                    "Only on \(worktree.branch): commits no other branch or remote has, and files not committed. Closing it asks first."
            ) : nil
        // Remove doesn't show on the group on screen, because an empty group goes by itself when the screen moves on.
        remove.isHidden =
            !(work != nil && held == 0 && node.children.isEmpty && node.hidden.isEmpty
            && app.workbench.workspaceId != worktree.id)
    }

    /// The tabs of a group that has no agent's row to show, as in "Terminal · 2 files · 1 more".
    private func openWords(_ id: String) -> [String] {
        var terminals = 0, files = 0, other = 0
        for tab in app.workbench.layouts[id].allTabs {
            switch TabURI.scheme(tab.uri) {
            case "session": terminals += 1
            case "file": files += 1
            default: other += 1
            }
        }
        return [
            terminals == 1 ? String(localized: "Terminal") : nil,
            terminals > 1 ? String(localized: "\(terminals) terminals") : nil,
            files > 0 ? String(localized: "\(files) files") : nil, other > 0 ? String(localized: "\(other) more") : nil
        ].compactMap { $0 }
    }
}

extension SidebarController {
    /// Makes the rows follow what a group's line says: what only its branch holds, and, when no agent is on it, what's
    /// open there.
    func followGroupLines() {
        track(owner: self) { [app] in
            app.worktrees.map {
                [app.gitState.ownWork($0.id)?.commits ?? -1, app.workbench.layouts[$0.id].allTabs.count]
            }
        } changed: { [weak self] _ in
            self?.updateVisibleCells()
        }
    }
}
