// The sidebar's outline view: its data source and delegate, rows' heights and gaps, nodes found, the selection.
import AppKit
import Core
import DesignKit
import SwiftUI
import WorkbenchKit

extension SidebarController {
    // MARK: data source / delegate

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? roots.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? roots[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Node)?.children.isEmpty ?? true)
    }
    static func isHeader(_ item: Any?) -> Bool {
        if case .project? = (item as? Node)?.kind { true } else { false }
    }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        if case .parked? = (item as? Node)?.kind { return false }
        return !Self.isHeader(item) || (item as? Node)?.workspace != nil
    }
    // A project too: the outline doesn't fold an item without one. Its triangle isn't drawn (SidebarOutline), it has its own chevron.
    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { true }
    // One line per row, as tall as Finder's at the same sidebar size; an agent that asks gets a second line.
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? Node else { return TextSize.of(rowBase) }
        if case .host = node.kind { return TextSize.of(rowBase) + Self.serverGap }
        if underFold(node) { return 0.01 }   // the outline takes no 0
        let pad = pads(node)
        // Its card's edge stays: without that room the cell's height comes out below 0, which the outline throws on.
        if arriving.contains(node.key) { return 0.01 + pad.top + pad.bottom }
        return TextSize.of(rowBase + (hasAsk(node) ? 16 : 0)) + pad.top + pad.bottom
    }
    /// Settings › Appearance › Row height; Match System reads macOS's Sidebar icon size (small, medium, large), as
    /// Finder and Mail do. Limit: only the height follows it, the text stays 13 pt (Text size scales that).
    private var rowBase: CGFloat {
        switch app.settings[SettingKeys.rowHeight] {
        case "compact": 24
        case "regular": 28
        case "large": 32
        default: [1: 24, 3: 32][UserDefaults.standard.integer(forKey: "NSTableViewDefaultSizeMode")] ?? 28
        }
    }
    private func hasAsk(_ node: Node) -> Bool {
        guard case .agent(let id) = node.kind, let session = app.session(id) else { return false }
        return SidebarCell.line(
            session, mode: app.settings[SettingKeys.agentDetail], children: app.children(of: id),
            back: app.arrangement.parkedBack[id], plans: app.extensions.all.plans) != nil
    }
    /// Room in a row for its project's card to open (over the project's name) and close (under its last row).
    func pads(_ node: Node) -> (top: CGFloat, bottom: CGFloat) {
        var pad = group(node).map(SidebarRowView.pads) ?? (top: 0, bottom: 0)
        pad.top += serverGap(node)
        return pad
    }
    /// The gap over a server's header, which starts that server's card, and over No Project's row at the end, which
    /// would read as one more project (or one more of the last server's) without it.
    func serverGap(_ node: Node) -> CGFloat {
        switch node.kind {
        case .host: Self.serverGap
        case .project(let id) where app.repo(id).map(NoProject.holds) == true: Self.serverGap
        default: 0
        }
    }
    /// Where this row is in its project's card: nil for a project with nothing under it, which is a plain row.
    func group(_ node: Node) -> (first: Bool, last: Bool)? {
        var top = node
        while let up = outline.parent(forItem: top) as? Node { top = up }
        guard case .project = top.kind, !top.children.isEmpty else { return nil }
        return (node === top, node === lastRow(top))
    }
    /// The last row of what's under `n` (itself when folded or folding).
    func lastRow(_ node: Node) -> Node {
        var last = node
        while outline.isItemExpanded(last), folding[last.key] == nil, let child = last.children.last { last = child }
        return last
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { SidebarRowView() }
    /// Typing a name jumps to its row (the cells have no textField the outline could read it from).
    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tc: NSTableColumn?, item: Any) -> String? {
        switch (item as? Node)?.kind {
        case .project(let id)?: app.projectName(id)
        case .workspace(let id)?: app.worktree(id)?.displayName
        case .agent(let id)?: app.session(id).map(app.catalog.displayName)
        case .host(let host)?: host
        case .parked?: String(localized: "Parked")
        default: nil
        }
    }
    func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        place(rowView, row)
    }

    func place(_ rowView: NSTableRowView, _ row: Int) {
        let node = outline.item(atRow: row) as? Node
        (rowView as? SidebarRowView)?.group = node.flatMap(group)
        (rowView as? SidebarRowView)?.gap = node.map(serverGap) ?? 0
    }
    /// The cards follow rows that open, close or move; a project's last row changes height with them.
    /// Inside an animation group they move with it; outside one, as the outline moves rows by itself (a quarter second).
    func outlineView(_ outlineView: NSOutlineView, viewFor tc: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        if case .parked = node.kind { return ParkedHeader(count: node.children.count) }
        if case .host(let host) = node.kind {
            let header = app.extensions.all.servers?.header(host, serverRow(host))
            header?.update()
            return header
        }
        let cell = SidebarCell(node: node, owner: self)
        cell.update()
        return cell
    }

    func outlineViewItemDidCollapse(_ notification: Notification) { remember(notification, collapsed: true) }
    func outlineViewItemDidExpand(_ notification: Notification) { remember(notification, collapsed: false) }
    private func remember(_ notification: Notification, collapsed didCollapse: Bool) {
        guard !syncing, let node = notification.userInfo?["NSObject"] as? Node, node.id != nil else { return }
        // A project folding folds its workspaces with it: that isn't the user folding them.
        if let parent = outline.parent(forItem: node) as? Node, !outline.isItemExpanded(parent) { return }
        if didCollapse { collapsed.insert(node.key) } else { collapsed.remove(node.key) }
        if !didCollapse, case .project = node.kind {
            syncing = true
            expand(node)
            syncing = false
        }
        refreshCell(node.key)   // collapsed, the row shows its agents' state itself
        instantly { updateCard() }   // the card ends at another row, where the rows already are (toggle moved them first)
    }
}

/// Finding rows.
extension SidebarController {
    /// The row for a workspace: its own, or its project's when that stands for it.
    func workspaceNode(_ id: String) -> Node? { find { $0.key == "w:" + id || $0.workspace == id } }

    func node(_ key: String) -> Node? { find { $0.key == key } }

    private func find(_ test: (Node) -> Bool) -> Node? {
        func look(_ ns: [Node]) -> Node? {
            for node in ns {
                if test(node) { return node }
                if let found = look(node.children) { return found }
            }
            return nil
        }
        return look(roots)
    }
}

/// A row picked opens what it stands for.
extension SidebarController {
    func outlineViewSelectionDidChange(_ notification: Notification) {
        card.close()
        // Several rows picked: nothing to open, they wait for the menu.
        guard !syncing, outline.selectedRowIndexes.count == 1,
            let node = outline.item(atRow: outline.selectedRow) as? Node
        else { return }
        switch node.kind {
        case .workspace(let id): app.workbench.show(workspace: id)
        case .agent(let id):
            app.workbench.focus(session: id)
            app.arrangement.parkedBack[id] = nil   // opened: its "Back:" line has been read
        case .project:
            guard let id = node.workspace else { break }
            // Already there: the pill stays with the tab.
            if id == app.workbench.workspaceId, app.workbench.page == nil {
                syncSelection()
            } else {
                app.workbench.show(workspace: id)
            }
        case .host(let host): app.workbench.openServer(host)
        case .parked: break
        }
    }
}
