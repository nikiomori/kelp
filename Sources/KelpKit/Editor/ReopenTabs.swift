import AppKit
import Core
import WorkbenchKit

/// ⇧⌘T: a tab closed by hand comes back in its place. A file at its line; an agent resuming its conversation; a terminal
/// as a new shell in its folder, since what it ran isn't run again.
extension EditorArea {
    /// Before the tab leaves the layout, while it still has a place.
    func rememberClosing(_ id: String) {
        guard let t = layout.allTabs.first(where: { $0.id == id }), !["untitled", "prompt"].contains(TabURI.scheme(t.uri)) else { return }
        let uri = (contents[id] as? SavableTab).map(\.reopenURI) ?? t.uri
        guard let uri else { return }   // nothing left of it
        let session = TabURI.scheme(t.uri) == "session" ? app.session(TabURI.body(t.uri)) : nil
        let group = layout.group(of: id)
        app.workbench.closedTabs.remember(ClosedTab(
            uri: uri, title: contents[id]?.title ?? session?.displayTitle ?? URL(string: uri)?.lastPathComponent ?? uri, workspace: workspaceId,
            group: group, index: group.flatMap { layout.groups[$0]?.tabs.firstIndex { $0.id == id } }))
    }

    /// Already on screen: the same file or page, opened again since.
    func shows(_ c: ClosedTab) -> Bool { layout.tab(uri: c.uri) != nil || (TabURI.scheme(c.uri) == "file" && layout.fileTab(sameFileAs: c.uri) != nil) }

    func reopen(_ c: ClosedTab) {
        guard TabURI.scheme(c.uri) == "session" else {
            if app.extensions.tabProvider(for: c.uri) == nil || shows(c) { open(c.uri) } else { place(c) }
            return
        }
        // Its tab first: the new session takes it. Otherwise the daemon's update puts the new one in whatever pane is focused.
        let sid = TabURI.body(c.uri)
        guard let s = app.session(sid) else { return }
        closed.remove(sid)
        place(c)
        if s.agent == "shell" { newShell(like: s, inTabOf: c.uri) } else { AgentActions(app).restart(sid) }
    }

    /// Its pane may have closed with its last tab.
    private func place(_ c: ClosedTab) {
        let group = c.group.flatMap { layout.groups[$0] == nil ? nil : $0 }
        let t = layout.add(c.uri, to: group, at: group == nil ? nil : c.index)
        arrange(); render()
        select(t.id)
    }
}

extension Workbench {
    /// What can still come back, latest first: its row is there and, for a session, its record (a restart replaces it).
    var reopenableTabs: [ClosedTab] {
        closedTabs.all.filter { c in
            guard let w = app.worktree(c.workspace), !w.archived else { return false }
            return TabURI.scheme(c.uri) != "session" || app.session(TabURI.body(c.uri)) != nil
        }
    }

    /// What ⇧⌘T brings back: the last one closed on this screen.
    var nextClosedTab: ClosedTab? { reopenableTabs.first { $0.workspace == workspaceId && editor?.shows($0) != true } }

    func reopenClosedTab() {
        guard let c = nextClosedTab else { NSSound.beep(); return }
        reopen(c)
    }

    func reopen(_ c: ClosedTab) {
        closedTabs.forget(c)
        if c.workspace != workspaceId { show(workspace: c.workspace) }
        editor?.reopen(c)
    }

    /// `w` is going with its last tab, and its sessions' records with it: those closed by hand move to `next`, with the same
    /// folder, where ⇧⌘T finds them. A folder of its own goes too, and nothing could resume there.
    func keepClosedTabs(of w: Worktree, on next: Worktree) async {
        if w.path == next.path {
            for c in closedTabs.all where c.workspace == w.id && TabURI.scheme(c.uri) == "session" {
                let sid = TabURI.body(c.uri)
                if workspaceId == next.id { editor?.closed.insert(sid) }   // it may still be ending: no tab for it there
                await app.quiet(SessionMove(id: sid, worktreeId: next.id))
            }
        }
        closedTabs.move(from: w.id, to: next.id)
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
        guard !list.isEmpty else { menu.addItem(withTitle: String(localized: "None"), action: nil, keyEquivalent: "").isEnabled = false; return }
        for c in list {
            let place = [app.worktree(c.workspace)?.displayName, shortAgo(c.at)].compactMap { $0 }.joined(separator: " · ")
            menu.add("\(c.title) — \(place)") { [app] in app.workbench.reopen(c) }.show(.symbol(Self.symbol(c.uri)))
        }
    }

    private static func symbol(_ uri: String) -> String {
        switch TabURI.scheme(uri) {
        case "session": "terminal"
        case "file": "doc"
        case "http", "https": "globe"
        default: "doc.text"
        }
    }
}
