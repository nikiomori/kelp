// The sidebar's model → tree: nodes from projects, workspaces and sessions, refreshed, selected, folded.
import AppKit
import Core
import DesignKit
import SwiftUI
import WorkbenchKit

extension SidebarController {
    // MARK: model → tree

    private func build() -> [Node] {
        var tree = SidebarTree(
            projects: app.projects, workspaces: app.projects.flatMap { app.workspaces(of: $0) },
            sessions: app.workbench.shownSessions)
        tree.activeFirst = app.settings[SettingKeys.sidebarOrder] == "active"
        tree.pinnedLast = app.repos.first(where: NoProject.holds)?.id
        tree.parked = app.arrangement.parkedIds
        let servers = app.extensions.all.servers
        tree.hosts = Dictionary(
            app.projects.compactMap { project in
                servers == nil ? nil : RemoteHost.of(project.path).map { (project.id, $0.host) }
            }
        ) { first, _ in
            first
        }
        servers?.listed(Set(tree.hosts.values))
        projectHosts = tree.hosts
        leavePage(unless: Set(tree.hosts.values))
        tree.folded = Set(collapsed.filter { $0.hasPrefix("h:") }.map { String($0.dropFirst(2)) })
        func node(_ item: SidebarItem) -> Node {
            let built = Node(item.kind)
            built.children = item.children.map(node)
            built.workspace = item.workspace
            built.under = item.under
            return built
        }
        return tree.build().map(node)
    }

    /// The ways in, as File shows them: a folder (new or existing), a clone, a project over SSH.
    @objc func addMenu(_ button: NSButton) {
        let menu = NSMenu(), app = app
        for id in ["workspace.addProject", "workspace.cloneRepository", "workspace.addRemote"] {
            guard let command = app.extensions.command(id) else { continue }
            let item = menu.add(command.title) { app.extensions.run(id) }
            if let shortcut = app.extensions.key(id) {
                item.keyEquivalent = shortcut.key
                item.keyEquivalentModifierMask = shortcut.mods.flags
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    /// Same shape → refresh the visible cells; new shape → reload, keeping expansion and selection.
    func refresh() {
        let next = build()
        // A project's row also stands for its one workspace: when that arrives after the project (or changes), the nodes
        // must be new, or the row the workspace on screen is looked up by (workspaceNode) isn't found and nothing is picked.
        func flat(_ ns: [Node]) -> [String] {
            ns.flatMap {
                [$0.key + ($0.workspace.map { "=" + $0 } ?? "") + ($0.under.map { "<" + $0 } ?? "")] + flat($0.children)
            }
        }
        let nextShape = flat(next)
        if nextShape == shape {
            updateVisibleCells()
            return
        }
        let before = shownRows(), places = rowPlaces(), cardFrames = cards.mapValues(\.frame)
        leaveGhosts(of: before, next: next)
        roots = next
        shape = nextShape
        syncing = true
        outline.reloadData()
        for root in roots where !collapsed.contains(root.key) { expand(root) }
        syncing = false
        rowHeights = []   // as with the cells: a row's height was asked before what's under it opened, and it was its card's end
        instantly { updateVisibleCells() }   // cells were made before their rows expanded; the cards go where the rows are now
        syncSelection()
        settle(from: before)
        closeUp(after: before, rows: places, cards: cardFrames)
    }

    /// A project and the workspaces in it that weren't folded (their children wait until the project opens).
    func expand(_ node: Node) {
        outline.expandItem(node)
        for child in node.children where !collapsed.contains(child.key) { outline.expandItem(child) }
    }

    /// The row of what's on screen: the agent whose tab has focus, else its workspace. Several rows picked stay picked.
    func syncSelection() {
        if let page = app.workbench.page { return select(page: page) }
        guard let id = app.workbench.workspaceId, let workspace = workspaceNode(id),
            outline.selectedRowIndexes.count <= 1
        else { return }
        // Gone to from elsewhere (⌃1, the line over the list) while its project is folded: open the project. Only on the
        // way in: a project folded while you're in it stays folded.
        if id != revealed, let project = outline.parent(forItem: workspace) as? Node, isCollapsed(project) {
            open(project)
        }
        revealed = id
        let tab = app.workbench.focusedTab ?? ""
        // A child has no row: its parent's stands for it.
        let on = TabURI.body(tab), parent = app.session(on)?.parent ?? ""
        let agent =
            TabURI.scheme(tab) == "session"
            ? workspace.children.first { $0.kind == .agent(on) || $0.kind == .agent(parent) } : nil
        let row =
            agent.map { outline.row(forItem: $0) }.flatMap { $0 >= 0 ? $0 : nil } ?? outline.row(forItem: workspace)
        guard row >= 0 else { return }
        if outline.selectedRow != row {
            syncing = true
            outline.selectRowIndexes([row], byExtendingSelection: false)
            syncing = false
        }
        keepOpenInView()
    }

    /// A server's page goes with its last project: back to the workspace behind it.
    private func leavePage(unless hosts: Set<String>) {
        guard let page = app.workbench.page, TabURI.scheme(page) == "host", !hosts.contains(TabURI.body(page)),
            let id = app.workbench.workspaceId ?? app.worktrees.first?.id
        else { return }
        app.workbench.show(workspace: id)
    }

    /// A server's page: its header's row.
    private func select(page: String) {
        guard TabURI.scheme(page) == "host", let header = node("h:" + TabURI.body(page)) else { return }
        let row = outline.row(forItem: header)
        guard row >= 0, outline.selectedRow != row else { return }
        syncing = true
        outline.selectRowIndexes([row], byExtendingSelection: false)
        syncing = false
    }

    /// In the window's second row, beside Add Project: who needs you and who's working. The row is always there, so the
    /// list under it doesn't move when the first agent starts.
    func placeSummary(over list: NSScrollView, beside add: NSView) {
        let summary = AgentSummary(app: app)
        summary.light = { [weak self] ids in self?.light(sessions: ids) }
        summary.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(summary)
        NSLayoutConstraint.activate([   // in line with the projects' cards (SidebarRowView.band): 8 pt to the window's edge
            summary.centerYAnchor.constraint(equalTo: add.centerYAnchor),
            summary.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            summary.trailingAnchor.constraint(equalTo: add.leadingAnchor),
            list.topAnchor.constraint(equalTo: add.bottomAnchor)   // the list opens with a little air of its own
        ])
    }

    /// The rows of these chats lit as if the pointer were on them; one in a folded project or group lights that row.
    func light(sessions ids: Set<String>) {
        var rows = IndexSet()
        for id in ids { if let row = shownRow("a:" + id) { rows.insert(row) } }
        outline.enumerateAvailableRowViews { view, row in (view as? SidebarRowView)?.lit = rows.contains(row) }
    }

    /// The row a node shows in: its own, or the nearest folded one over it.
    private func shownRow(_ key: String) -> Int? {
        func path(_ nodes: [Node]) -> [Node]? {
            for node in nodes {
                if node.key == key { return [node] }
                if let below = path(node.children) { return [node] + below }
            }
            return nil
        }
        return path(roots)?.reversed().lazy.map { self.outline.row(forItem: $0) }.first { $0 >= 0 }
    }

    /// The built-ins' sidebar blocks as the registry has them now: each made afresh, in their order, the feet last.
    func makeSections() {
        guard let sections else { return }
        sections.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let all = app.extensions.all.sidebarSections
        for section in all.filter({ !$0.foot }) + all.filter(\.foot) {
            let block = section.make()
            sections.addArrangedSubview(block)
            block.widthAnchor.constraint(equalTo: sections.widthAnchor).isActive = true
        }
    }

    /// The workspace on screen stays in view with its agents under it (they can show up after it was selected).
    func keepOpenInView() {
        guard let id = app.workbench.workspaceId, let workspace = workspaceNode(id) else { return }
        let row = outline.row(forItem: workspace)
        guard row >= 0 else { return }
        if let last = workspace.children.last, outline.isItemExpanded(workspace) {
            outline.scrollRowToVisible(outline.row(forItem: last))
        }
        outline.scrollRowToVisible(row)
    }
    func isCollapsed(_ node: Node) -> Bool {
        !node.children.isEmpty && (!outline.isItemExpanded(node) || folding[node.key] != nil)
    }
}
