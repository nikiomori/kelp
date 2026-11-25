// Builds the sidebar's tree from the model: nodes made from projects, workspaces and sessions, and how the tree is
// refreshed, selected and folded.
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
        tree.foldedProjects = Set(collapsed.filter { $0.hasPrefix("p:") }.map { String($0.dropFirst(2)) })
        tree.withTabs = Self.madeWithTabs(app)
        func node(_ item: SidebarItem) -> Node {
            let built = Node(item.kind)
            built.children = item.children.map(node)
            built.workspace = item.workspace
            built.under = item.under
            built.branch = item.branch
            built.hidden = item.hidden
            return built
        }
        return tree.build().map(node)
    }

    /// The ways to add a project, as the File menu shows them: a folder (new or existing), a clone, a project over SSH.
    @objc func addMenu(_ button: NSButton) {
        let menu = NSMenu(), app = app
        for id in ["workspace.addProject", "workspace.cloneRepository", "workspace.addRemote"] {
            guard let command = app.extensions.command(id) else { continue }
            app.extensions.showKey(id, on: menu.add(command.title) { app.extensions.run(id) })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    /// Same shape → refresh the visible cells; new shape → reload, keeping expansion and selection.
    func refresh() {
        let next = build()
        // A project's row also stands for its one workspace. When that workspace arrives after the project (or
        // changes), the nodes must be new. Otherwise `workspaceNode` doesn't find the row for the workspace on screen,
        // and nothing is selected.
        func flat(_ ns: [Node]) -> [String] {
            ns.flatMap { node -> [String] in
                let marks = [
                    node.workspace.map { "=" + $0 }, node.under.map { "<" + $0 }, node.branch.map { "^" + $0 }
                ]
                let shape = node.key + marks.compactMap { $0 }.joined() + node.hidden.map { "~" + $0 }.joined()
                return [shape] + flat(node.children)
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
        // A project is never folded in the outline: its fold is in the tree, which then lists only its screens.
        for root in roots where Self.isHeader(root) || !collapsed.contains(root.key) { expand(root) }
        syncing = false
        // As with the cells, a row's height was taken before the rows under it opened, as the end of its card.
        rowHeights = []
        // The cells were made before their rows expanded. The cards go where the rows are now.
        instantly { updateVisibleCells() }
        syncSelection()
        settle(from: before)
        closeUp(after: before, rows: places, cards: cardFrames)
    }

    /// Expands a project and the workspaces in it that weren't folded (their children wait until the project opens).
    func expand(_ node: Node) {
        outline.expandItem(node)
        for child in node.children where !collapsed.contains(child.key) { outline.expandItem(child) }
    }

    /// Selects the row of what's on screen: the agent whose tab has focus, or else its workspace. When several rows are
    /// selected, they stay selected.
    func syncSelection() {
        if let page = app.workbench.page { return select(page: page) }
        guard let id = app.workbench.workspaceId, let workspace = workspaceNode(id),
            outline.selectedRowIndexes.count <= 1
        else { return }
        // When you reach a chat from elsewhere (⌃1, the line above the list) while its project folds it away, the
        // project opens. A folded project's screens keep their rows, so reaching a screen leaves it folded. This
        // happens only on the way in, so a project you fold while you're in it stays folded.
        let tab = app.workbench.focusedTab ?? ""
        let chat = TabURI.scheme(tab) == "session" ? TabURI.body(tab) : nil
        if id != revealed, let chat,
            let project = Self.isHeader(workspace) ? workspace : outline.parent(forItem: workspace) as? Node,
            isCollapsed(project), find({ $0.hidden.contains(chat) }) != nil
        {
            revealed = id
            unfold(project)
            return syncSelection()   // the rows were made again
        }
        revealed = id
        // A child agent has no row, so its parent's row stands for it.
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

    /// Closes a server's page when its last project goes, and goes back to the workspace behind it.
    private func leavePage(unless hosts: Set<String>) {
        guard let page = app.workbench.page, TabURI.scheme(page) == "host", !hosts.contains(TabURI.body(page)),
            let id = app.workbench.workspaceId ?? app.worktrees.first?.id
        else { return }
        app.workbench.show(workspace: id)
    }

    /// Selects the header row of a server whose page is open.
    private func select(page: String) {
        guard TabURI.scheme(page) == "host", let header = node("h:" + TabURI.body(page)) else { return }
        let row = outline.row(forItem: header)
        guard row >= 0, outline.selectedRow != row else { return }
        syncing = true
        outline.selectRowIndexes([row], byExtendingSelection: false)
        syncing = false
    }

    /// Places the summary of who needs you and who's working in the window's second row, beside Add Project. The row is
    /// always there, so the list under it doesn't move when the first agent starts.
    func placeSummary(over list: NSScrollView, beside add: NSView) {
        let summary = AgentSummary(app: app)
        summary.light = { [weak self] ids in self?.light(sessions: ids) }
        summary.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(summary)
        NSLayoutConstraint.activate([   // in line with the project cards (SidebarRowView.band), 8 pt from the edge
            summary.centerYAnchor.constraint(equalTo: add.centerYAnchor),
            summary.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            summary.trailingAnchor.constraint(equalTo: add.leadingAnchor),
            list.topAnchor.constraint(equalTo: add.bottomAnchor)   // the list opens with a little air of its own
        ])
    }

    /// Lights the rows of these chats as if the pointer were on them. A chat in a folded project or group lights that
    /// project's or group's row.
    func light(sessions ids: Set<String>) {
        var rows = IndexSet()
        for id in ids { if let row = shownRow("a:" + id) { rows.insert(row) } }
        outline.enumerateAvailableRowViews { view, row in (view as? SidebarRowView)?.lit = rows.contains(row) }
    }

    /// The row a node shows in: its own row, the nearest folded row above it, or the row of a folded project that
    /// holds it as a logo.
    private func shownRow(_ key: String) -> Int? {
        if key.hasPrefix("a:"), case let id = String(key.dropFirst(2)), let holder = find({ $0.hidden.contains(id) }) {
            let row = outline.row(forItem: holder)
            if row >= 0 { return row }
        }
        func path(_ nodes: [Node]) -> [Node]? {
            for node in nodes {
                if node.key == key { return [node] }
                if let below = path(node.children) { return [node] + below }
            }
            return nil
        }
        return path(roots)?.reversed().lazy.map { self.outline.row(forItem: $0) }.first { $0 >= 0 }
    }

    /// Makes the built-ins' sidebar blocks as the registry has them now. Each block is made afresh, in the registry's
    /// order, with the foot blocks last.
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

    /// Keeps the workspace on screen in view, with its agents under it (they can show up after it was selected).
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
        if Self.isHeader(node) { return collapsed.contains(node.key) }
        return !node.children.isEmpty && (!outline.isItemExpanded(node) || folding[node.key] != nil)
    }
}
