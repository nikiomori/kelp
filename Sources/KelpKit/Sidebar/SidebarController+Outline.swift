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
        if underFold(node) { return 0.01 }   // the outline doesn't accept 0
        let pad = pads(node)
        // The edge of the row's card keeps its room, because without it the cell's height comes out below 0, and the
        // outline throws on that.
        return rest(node) + pad.top + pad.bottom
    }
    /// A row's own height, without the room its card's ends take: one line, two for an agent that asks, and next to
    /// nothing for a row that is arriving or under a fold. Its pill and its name stand in this, hung from the card's
    /// top. It is asked of the row itself: a list of heights by row number names another row once a project above
    /// folds, and the name then stood 6 pt off its pill.
    func rest(_ node: Node) -> CGFloat {
        if underFold(node) || arriving.contains(node.key) { return 0.01 }
        if case .host = node.kind { return TextSize.of(rowBase) }
        return TextSize.of(rowBase + (hasAsk(node) ? 16 : 0))
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
    /// The room in a row where its card opens (above a project's or a server's first row) and closes (below the last
    /// one), half the step to the next card outside it. Every root keeps that room, on a card or not, so the cards and
    /// the plain rows between them all stand one step apart. A server's header and its projects share one card, which
    /// reaches the rim past its projects' cards.
    func pads(_ node: Node) -> (top: CGFloat, bottom: CGFloat) {
        let root = root(of: node), pad = SidebarRowView.pad
        let top = node === root ? pad : 0
        guard node === lastRow(root) else { return (top, 0) }
        let onServer = host(of: root) != nil, more = onServer && servedNext(root)
        if case .host = root.kind { return (top, more ? 0 : pad) }   // its projects go on under it
        return (top, onServer && !more ? pad + SidebarRowView.rim : pad)
    }
    /// How far in from the sides the card under the row is (SidebarRowView.band), or nil when the row has none. A
    /// project has a card when it holds rows, or always in the Filled Card look. A server's card reaches the rim past
    /// the cards of its projects, when they show.
    func cardInset(_ node: Node) -> CGFloat? {
        let root = root(of: node), band = SidebarRowView.cardBand
        switch root.kind {
        case .host: return servedNext(root) ? band - SidebarRowView.rim : band
        case .project: return root.holds || app.arrangement.projectLook.style == .card ? band : nil
        default: return nil
        }
    }
    func root(of node: Node) -> Node {
        var top = node
        while let up = outline.parent(forItem: top) as? Node { top = up }
        return top
    }
    /// The server a root is on: its header's, or the host of a project over SSH.
    func host(of root: Node) -> String? {
        switch root.kind {
        case .host(let host): host
        case .project(let id): projectHosts[id]
        default: nil
        }
    }
    /// Whether the root after `root` is a project on the same server, on the same card.
    private func servedNext(_ root: Node) -> Bool {
        guard let index = roots.firstIndex(where: { $0 === root }), index + 1 < roots.count,
            case .project = roots[index + 1].kind
        else { return false }
        return host(of: roots[index + 1]) == host(of: root)
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
        guard let rowView = rowView as? SidebarRowView else { return }
        let node = outline.item(atRow: row) as? Node
        rowView.pads = node.map(pads) ?? (0, 0)
        rowView.cardInset = node.flatMap(cardInset)
        rowView.content = node.map(rest) ?? 0
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
    /// A project folds in the tree, not in the outline (`foldProject`), so ← on its row folds it that way.
    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        guard !syncing, Self.isHeader(item), let node = item as? Node else { return true }
        if !collapsed.contains(node.key) { foldProject(node.key) }
        return false
    }
    private func remember(_ notification: Notification, collapsed didCollapse: Bool) {
        guard !syncing, let node = notification.userInfo?["NSObject"] as? Node, node.id != nil, !Self.isHeader(node)
        else { return }
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
    /// Returns the row for a workspace: its own row, or the project's row when the project stands for it (a project
    /// with one screen, or a folded one).
    func workspaceNode(_ id: String) -> Node? { index.byKey["w:" + id] ?? index.standingFor[id] }

    func node(_ key: String) -> Node? { index.byKey[key] }

    /// Each row by its key, the first row (top to bottom) that stands for a project's own screen, and the folded row
    /// that holds a chat as a logo. The first one seen wins, as a walk from the top would find it.
    struct NodeIndex {
        var byKey: [String: Node] = [:], standingFor: [String: Node] = [:], holding: [String: Node] = [:]
        init(_ roots: [Node]) {
            func add(_ nodes: [Node]) {
                for node in nodes {
                    if byKey[node.key] == nil { byKey[node.key] = node }
                    if let own = node.workspace, standingFor[own] == nil { standingFor[own] = node }
                    for chat in node.hidden where holding[chat] == nil { holding[chat] = node }
                    add(node.children)
                }
            }
            add(roots)
        }
    }
}

/// Selecting a row opens what it stands for.
extension SidebarController {
    func outlineViewSelectionDidChange(_ notification: Notification) {
        card.close()
        glidePill()
        // With several rows selected nothing opens, because they wait for the menu.
        guard !syncing, outline.selectedRowIndexes.count == 1,
            let node = outline.item(atRow: outline.selectedRow) as? Node
        else { return }
        switch node.kind {
        case .workspace(let id):
            revealed = id   // a screen picked from a folded project leaves the project folded
            app.workbench.show(workspace: id)
        case .agent(let id):
            // ⌥-click: another action of the same row, so the chat's group goes into a window of its own (as its row's
            // Open in Own Window). ⌘ and ⇧ stay for picking several rows.
            if NSApp.currentEvent?.isClick(with: .option) == true, let group = app.session(id)?.worktreeId,
                !app.workbench.inOwnWindow(group)
            {
                app.workbench.moveToOwnWindow(group)
            }
            app.workbench.focus(session: id)
            app.arrangement.parkedBack[id] = nil   // once opened, its "Back:" line has been read
        case .project:
            guard let id = node.workspace else { break }
            // When the project's screen is already showing, the pill stays with the tab.
            revealed = id
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
