import AppKit
import Core
import DesignKit
import WorkbenchKit

/// ⇧⌘T: a tab closed by hand comes back in its place. A file at its line; an agent resuming its conversation; a terminal
/// as a new shell in its folder, since what it ran isn't run again.
extension EditorArea {
    /// Before the tab leaves the layout, while it still has a place.
    func rememberClosing(_ id: String) {
        guard let tab = layout.allTabs.first(where: { $0.id == id }),
            !["untitled", "prompt"].contains(TabURI.scheme(tab.uri))
        else { return }
        let uri = (contents[id] as? SavableTab).map(\.reopenURI) ?? tab.uri
        guard let uri else { return }   // nothing left of it
        let session = TabURI.scheme(tab.uri) == "session" ? app.session(TabURI.body(tab.uri)) : nil
        let group = layout.group(of: id)
        app.workbench.closedTabs.remember(
            ClosedTab(
                uri: uri,
                title: contents[id]?.title ?? session?.displayTitle ?? URL(string: uri)?.lastPathComponent ?? uri,
                workspace: workspaceId,
                group: group, index: group.flatMap { layout.groups[$0]?.tabs.firstIndex { $0.id == id } }))
    }

    /// Already on screen: the same file or page, opened again since.
    func shows(_ closedTab: ClosedTab) -> Bool {
        layout.tab(uri: closedTab.uri) != nil
            || (TabURI.scheme(closedTab.uri) == "file" && layout.fileTab(sameFileAs: closedTab.uri) != nil)
    }

    func reopen(_ closedTab: ClosedTab) {
        guard TabURI.scheme(closedTab.uri) == "session" else {
            if app.extensions.tabProvider(for: closedTab.uri) == nil || shows(closedTab) {
                open(closedTab.uri)
            } else {
                place(closedTab)
            }
            return
        }
        // Its tab first: the new session takes it. Otherwise the daemon's update puts the new one in whatever pane is focused.
        let sid = TabURI.body(closedTab.uri)
        guard let session = app.session(sid) else { return }
        closed.remove(sid)
        place(closedTab)
        if session.agent == "shell" {
            starter.newShell(like: session, inTabOf: closedTab.uri)
        } else {
            AgentActions(app).restart(sid)
        }
    }

    /// Its pane may have closed with its last tab.
    private func place(_ closedTab: ClosedTab) {
        let group = closedTab.group.flatMap { layout.groups[$0] == nil ? nil : $0 }
        let tab = layout.add(closedTab.uri, to: group, at: group == nil ? nil : closedTab.index)
        arrange()
        render()
        select(tab.id)
    }
}

extension Workbench {
    /// What can still come back, latest first: its row is there and, for a session, its record (a restart replaces it).
    var reopenableTabs: [ClosedTab] {
        closedTabs.all.filter { closedTab in
            guard let worktree = app.worktree(closedTab.workspace), !worktree.archived else { return false }
            return TabURI.scheme(closedTab.uri) != "session" || app.session(TabURI.body(closedTab.uri)) != nil
        }
    }

    /// What ⇧⌘T brings back: the last one closed on this screen.
    var nextClosedTab: ClosedTab? { reopenableTabs.first { $0.workspace == workspaceId && editor?.shows($0) != true } }

    func reopenClosedTab() {
        guard let closedTab = nextClosedTab else {
            NSSound.beep()
            return
        }
        reopen(closedTab)
    }

    func reopen(_ closedTab: ClosedTab) {
        closedTabs.forget(closedTab)
        if closedTab.workspace != workspaceId { show(workspace: closedTab.workspace) }
        editor?.reopen(closedTab)
    }

    /// `worktree` is going with its last tab, and its sessions' records with it: those closed by hand move to `next`, with the same
    /// folder, where ⇧⌘T finds them. A folder of its own goes too, and nothing could resume there.
    func keepClosedTabs(of worktree: Worktree, on next: Worktree) async {
        if worktree.path == next.path {
            for closedTab in closedTabs.all
            where closedTab.workspace == worktree.id && TabURI.scheme(closedTab.uri) == "session" {
                let sid = TabURI.body(closedTab.uri)
                if workspaceId == next.id { editor?.closed.insert(sid) }   // it may still be ending: no tab for it there
                await app.quiet(SessionMove(id: sid, worktreeId: next.id))
            }
        }
        closedTabs.move(from: worktree.id, to: next.id)
    }
}

/// File › Recently Closed, made as it opens.
@MainActor
final class RecentlyClosedMenu: NSObject, NSMenuDelegate {
    private static let shown = 10
    private let app: AppModel
    init(app: AppModel) { self.app = app }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let list = app.workbench.reopenableTabs.prefix(Self.shown)
        guard !list.isEmpty else {
            menu.addItem(withTitle: String(localized: "None"), action: nil, keyEquivalent: "").isEnabled = false
            return
        }
        for closedTab in list {
            let place = [app.worktree(closedTab.workspace)?.displayName, shortAgo(closedTab.at)].compactMap { $0 }
                .joined(
                    separator: " · ")
            menu.add("\(closedTab.title) — \(place)") { [app] in app.workbench.reopen(closedTab) }.show(
                .symbol(Self.symbol(closedTab.uri)))
        }
    }

    private static func symbol(_ uri: String) -> String {
        switch TabURI.scheme(uri) {
        case "session": "terminal"
        case "file": "doc"
        case "http", "https": "safari"
        default: "doc.text"
        }
    }
}
