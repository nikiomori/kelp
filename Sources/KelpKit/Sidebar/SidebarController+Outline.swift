// The sidebar's outline view: its data source and delegate, row heights and gaps, finding nodes, and the selection.
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
    // Every item has an outline cell, projects too, because the outline doesn't fold an item without one. The triangle
    // isn't drawn (SidebarOutline), since the rows have their own chevron.
    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { true }
    // One line per row, as tall as Finder's rows at the same sidebar size. An agent that asks gets a second line.
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? Node else { return TextSize.of(rowBase) }
        if case .host = node.kind { return TextSize.of(rowBase) + Self.serverGap }
        if underFold(node) { return 0.01 }   // the outline doesn't accept 0
        let pad = pads(node)
        // The edge of the row's card keeps its room, because without it the cell's height comes out below 0, and the
        // outline throws on that.
        if arriving.contains(node.key) { return 0.01 + pad.top + pad.bottom }
        return TextSize.of(rowBase + (hasAsk(node) ? 16 : 0)) + pad.top + pad.bottom
    }
    /// The row height from Settings › Appearance › Row height. Match System reads macOS's Sidebar icon size (small,
    /// medium, large), as Finder and Mail do. Limit: only the height follows it, and the text stays 13 pt (Text size
    /// scales that).
    var rowBase: CGFloat {
        if let passRowBase { return passRowBase }
        return switch app.settings[SettingKeys.rowHeight] {
        case "compact": 24
        case "regular": 28
        case "large": 32
        default: [1: 24, 3: 32][UserDefaults.standard.integer(forKey: "NSTableViewDefaultSizeMode")] ?? 28
        }
    }
    private func hasAsk(_ node: Node) -> Bool {
        guard case .agent(let id) = node.kind, let session = app.session(id) else { return false }
        return session.rowLine(
            mode: app.settings[SettingKeys.agentDetail], children: app.children(of: id),
            back: app.arrangement.parkedBack[id], plans: app.extensions.all.plans) != nil
    }
    /// The room in a row where the project's card opens (above the project's name) and closes (below its last row).
    func pads(_ node: Node) -> (top: CGFloat, bottom: CGFloat) {
        var pad = group(node).map(SidebarRowView.pads) ?? (top: 0, bottom: 0)
        pad.top += serverGap(node)
        return pad
    }
    /// The gap above a server's header, which starts that server's card, and above the No Project row at the end.
    /// Without the gap, No Project would read as one more project (or one more of the last server's projects).
    func serverGap(_ node: Node) -> CGFloat {
        switch node.kind {
        case .host: Self.serverGap
        case .project(let id) where app.repo(id).map(NoProject.holds) == true: Self.serverGap
        default: 0
        }
    }
    /// Whether this row is first or last in its project's card. It is nil for a project with nothing under it, which
    /// is a plain row.
    func group(_ node: Node) -> (first: Bool, last: Bool)? {
        var top = node
        while let up = outline.parent(forItem: top) as? Node { top = up }
        guard case .project = top.kind, !top.children.isEmpty else { return nil }
        return (node === top, node === lastRow(top))
    }
    /// The last row under `node`, or `node` itself when it is folded or folding.
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
    /// The cards follow rows that open, close or move, and a project's last row changes height with them. Inside an
    /// animation group, the cards move with the group. Outside one, they move the way the outline moves rows by itself
    /// (in a quarter second).
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
        // When a project folds, its workspaces fold with it. That isn't the user folding them, so it isn't saved.
        if let parent = outline.parent(forItem: node) as? Node, !outline.isItemExpanded(parent) { return }
        if didCollapse { collapsed.insert(node.key) } else { collapsed.remove(node.key) }
        if !didCollapse, case .project = node.kind {
            syncing = true
            expand(node)
            syncing = false
        }
        refreshCell(node.key)   // a collapsed row shows its agents' state itself
        instantly { updateCard() }   // the card ends at another row; rows are in place (toggle moved them first)
    }
}

/// Finding rows.
extension SidebarController {
    /// Returns the row for a workspace: its own row, or the project's row when the project stands for it.
    func workspaceNode(_ id: String) -> Node? { find { $0.kind == .workspace(id) || $0.workspace == id } }

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

/// Selecting a row opens what it stands for.
extension SidebarController {
    func outlineViewSelectionDidChange(_ notification: Notification) {
        card.close()
        // With several rows selected nothing opens, because they wait for the menu.
        guard !syncing, outline.selectedRowIndexes.count == 1,
            let node = outline.item(atRow: outline.selectedRow) as? Node
        else { return }
        switch node.kind {
        case .workspace(let id): app.workbench.show(workspace: id)
        case .agent(let id):
            app.workbench.focus(session: id)
            app.arrangement.parkedBack[id] = nil   // once opened, its "Back:" line has been read
        case .project:
            guard let id = node.workspace else { break }
            // When the project's screen is already showing, the pill stays with the tab.
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
