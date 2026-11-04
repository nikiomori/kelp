import AppKit
import SwiftUI
import Core
import DesignKit
import WorkbenchKit

/// Projects → workspaces → agents in a source-list outline (like Finder and Xcode).
/// Status changes update the visible cells in place; the outline reloads only when the tree's shape changes.
@MainActor
final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    let app: AppModel
    init(app: AppModel) { self.app = app; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    final class Node: NSObject {
        let kind: SidebarItem.Kind
        var children: [Node] = []
        /// A project's own screen, which its row stands for (SidebarItem.workspace).
        var workspace: String?
        init(_ k: SidebarItem.Kind) { kind = k }
        var key: String {
            switch kind {
            case .project(let id): "p:" + id
            case .workspace(let id): "w:" + id
            case .agent(let id): "a:" + id
            }
        }
        /// What a dragged row reorders: a project's or a workspace's id.
        var id: String? {
            switch kind {
            case .project(let id), .workspace(let id): id
            default: nil
            }
        }
    }

    let outline = SidebarOutline()
    /// Rows on their way to folded (SidebarFolding): the rows under them have no height and the card ends at them, while
    /// the outline still shows them. The number tells this fold from a later one of the same row.
    var folding: [String: Int] = [:]
    var folds = 0
    /// Rows that just came, at no height until they open out (`settle`).
    var arriving: Set<String> = []
    /// Each project's card, under its rows (`placeCards`).
    var cards: [String: ProjectCard] = [:]
    var roots: [Node] = []
    private var shape: [String] = []
    /// Hosts of the remote projects listed, watched for the mark on their icons (`WatchTopic.host`).
    var watchedHosts: Set<String> = []
    /// Project id → the host it's on: a host's projects share one hatched card (`placeCards`).
    var projectHosts: [String: String] = [:]
    /// The first project of each host's run: its card starts there, after a gap, and its row names the host.
    var serverStarts: Set<String> = []
    /// Room between one server's card and what's over it.
    static let serverGap: CGFloat = 8
    private var collapsed: Set<String> {
        get { Set(app.uiState.strings("sidebar.collapsed")) }
        set { app.uiState["sidebar.collapsed"] = try? .from(newValue.sorted()) }
    }
    private var syncing = false
    /// The workspace whose project syncSelection last opened (or found open).
    private var revealed: String?
    /// The workspace or project (`project`) whose name is being edited in its row.
    var renaming: (id: String, project: Bool)?
    lazy var card = HoverCard(app: app)
    var rowHeights: [CGFloat] = []

    override func loadView() {
        let col = NSTableColumn(identifier: .init("main")); col.resizingMask = .autoresizingMask
        outline.addTableColumn(col); outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .custom
        outline.selectionHighlightStyle = .none   // SidebarRowView draws the selection as a pill
        outline.floatsGroupRows = false; outline.indentationPerLevel = 14
        outline.pads = { [weak self] row in (self?.outline.item(atRow: row) as? Node).flatMap { self?.pads($0) } ?? (0, 0) }
        outline.allowsMultipleSelection = true   // ⌘/⇧-click: the menu then acts on all of them
        outline.dataSource = self; outline.delegate = self
        outline.target = self; outline.doubleAction = #selector(doubleClicked)
        outline.registerForDraggedTypes([.fileURL, Self.rowType])   // a folder from Finder becomes a project; rows move
        outline.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                               owner: self, userInfo: nil))
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false   // it starts under the line over the projects, not under the title bar
        // When the list gets shorter (the limits below load), the selected workspace stays in view.
        scroll.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepOpenInView() }   // queue: .main
        }

        let footer = UsageFooter.make(app)   // agent limits, when any agent reports them
        let v = NSView()
        // Over the projects it adds to, where people look for it.
        let add = NSButton.titlebar("folder.badge.plus", String(localized: "Add Project"),
                                    tip: String(localized: "Add a project: a folder, a clone or one over SSH"))
        add.target = self; add.action = #selector(addMenu(_:))
        for x in [add, scroll, footer] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            // Under the traffic lights, in the window's second row: level with the tab strips and the inspector's panel icons.
            add.centerYAnchor.constraint(equalTo: v.topAnchor, constant: WindowBar.height + TabStrip.height / 2),
            add.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -6),
            // In line with the projects' cards (SidebarRowView.band): 8 pt to the window's edge and to the editor area.
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: v.leadingAnchor), footer.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: v.bottomAnchor)
        ])
        view = v
        placeSummary(over: scroll, beside: add)
        track(owner: self) { [app] in app.repos } changed: { [weak self] _ in self?.refresh() }
        track(owner: self) { [app] in app.worktrees } changed: { [weak self] _ in self?.refresh() }
        track(owner: self) { [app] in app.scripts.shown } changed: { [weak self] _ in self?.refresh() }
        track(owner: self) { [app] in app.order } changed: { [weak self] _ in self?.refresh() }
        track(owner: self) { [app] in app.workbench.workspaceId } changed: { [weak self] _ in self?.syncSelection(); self?.updateCard() }
        track(owner: self) { [app] in app.workbench.focusedTab } changed: { [weak self] _ in self?.syncSelection() }
        track(owner: self) { [app] in app.rowBadges.stats } changed: { [weak self] _ in self?.updateVisibleCells() }
        // How each server is (the mark on its projects' icons), not every reading: the server tab's come every 2 s.
        track(owner: self) { [app] in app.hostStats.keys.sorted().map { [$0, app.serverWord($0)?.text ?? ""] } }
            changed: { [weak self] _ in self?.updateVisibleCells() }
        track(owner: self) { [app] in app.rowBadges.prs } changed: { [weak self] _ in self?.updateVisibleCells() }
        track(owner: self) { [app] in app.rowBadges.sidebarMarks } changed: { [weak self] _ in self?.updateVisibleCells() }
        followRowLooks()
        track(owner: self) { [app] in app.themes.chromeText } changed: { [weak self] _ in self?.refresh() }
        track(owner: self) { [app] in ["rowHeight", "agentDetail", "agentIcons"].map { app.settings.string("workbench.sidebar." + $0) } }
            changed: { [weak self] _ in self?.updateVisibleCells() }
        track(owner: self) { [app] in app.settings.bool("workbench.sidebar.gitBadges") } changed: { [weak self] _ in self?.updateVisibleCells() }
        track(owner: self) { [app] in app.settings.string("workbench.sidebar.order") } changed: { [weak self] _ in self?.refresh() }
        // "now" becomes "1m": the times on the right move on their own (a clock: nothing is asked of the daemon).
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in   // main run loop
            MainActor.assumeIsolated { if self?.view.window?.occlusionState.contains(.visible) == true { self?.updateVisibleCells() } }
        }
    }

    func updateVisibleCells() {
        updateCard()
        for row in 0..<outline.numberOfRows { (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell)?.update() }
    }

    // MARK: hover cards

    override func mouseMoved(with e: NSEvent) {
        let row = outline.row(at: outline.convert(e.locationInWindow, from: nil))
        let cell = row >= 0 ? outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell : nil
        guard row >= 0, renaming == nil, let n = outline.item(atRow: row) as? Node, cell?.overAction(e.locationInWindow) != true else {
            card.hover(nil, rect: .zero, in: outline)
            return
        }
        card.hover(n.workspace.map { "w:" + $0 } ?? n.key, rect: outline.rect(ofRow: row), in: outline)
    }
    override func mouseExited(with e: NSEvent) { card.hover(nil, rect: .zero, in: outline) }
    /// A row's card, now: a click asked for it.
    func openCard(_ n: Node) {
        let row = outline.row(forItem: n)
        if row >= 0 { card.open(n.workspace.map { "w:" + $0 } ?? n.key, rect: outline.rect(ofRow: row), in: outline) }
    }

    // MARK: model → tree

    private func build() -> [Node] {
        let m = app
        var tree = SidebarTree(projects: m.projects, workspaces: m.projects.flatMap { m.workspaces(of: $0) }, sessions: m.scripts.shown)
        tree.activeFirst = app.settings.string("workbench.sidebar.order") == "active"
        tree.pinned = m.repos.first(where: NoProject.holds)?.id
        tree.hosts = Dictionary(m.projects.compactMap { r in RemoteHost.of(r.path).map { (r.id, $0.host) } }) { a, _ in a }
        watchHosts(Set(tree.hosts.values))
        projectHosts = tree.hosts
        func node(_ i: SidebarItem) -> Node {
            let n = Node(i.kind)
            n.children = i.children.map(node); n.workspace = i.workspace
            return n
        }
        let items = tree.build()
        // Each host's projects come together: the first of them starts its server's card.
        var last: String?
        serverStarts = []
        for case .project(let id) in items.map(\.kind) {
            let host = tree.hosts[id]
            if let host, host != last { serverStarts.insert(id) }
            last = host
        }
        return items.map(node)
    }

    /// The ways in, as File shows them: a folder (new or existing), a clone, a project over SSH.
    @objc private func addMenu(_ b: NSButton) {
        let m = NSMenu(), app = app
        for id in ["workspace.addProject", "workspace.cloneRepository", "workspace.addRemote"] {
            guard let c = app.extensions.command(id) else { continue }
            let i = m.add(c.title) { app.extensions.run(id) }
            if let k = c.key.flatMap(KeySpec.init) { i.keyEquivalent = k.key; i.keyEquivalentModifierMask = k.mods.flags }
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b)
    }

    /// Same shape → refresh the visible cells; new shape → reload, keeping expansion and selection.
    func refresh() {
        let next = build()
        // A project's row also stands for its one workspace: when that arrives after the project (or changes), the nodes
        // must be new, or the row the workspace on screen is looked up by (workspaceNode) isn't found and nothing is picked.
        func flat(_ ns: [Node]) -> [String] { ns.flatMap { [$0.key + ($0.workspace.map { "=" + $0 } ?? "")] + flat($0.children) } }
        let nextShape = flat(next)
        if nextShape == shape { updateVisibleCells(); return }
        let before = shownRows(), places = rowPlaces(), cardFrames = cards.mapValues(\.frame)
        leaveGhosts(of: before, next: next)
        roots = next; shape = nextShape
        syncing = true
        outline.reloadData()
        for p in roots where !collapsed.contains(p.key) { expand(p) }
        syncing = false
        rowHeights = []   // as with the cells: a row's height was asked before what's under it opened, and it was its card's end
        instantly { updateVisibleCells() }   // cells were made before their rows expanded; the cards go where the rows are now
        syncSelection()
        settle(from: before)
        closeUp(after: before, rows: places, cards: cardFrames)
    }

    /// A project and the workspaces in it that weren't folded (their children wait until the project opens).
    private func expand(_ p: Node) {
        outline.expandItem(p)
        for w in p.children where !collapsed.contains(w.key) { outline.expandItem(w) }
    }

    /// The row of what's on screen: the agent whose tab has focus, else its workspace. Several rows picked stay picked.
    private func syncSelection() {
        guard let id = app.workbench.workspaceId, let w = workspaceNode(id), outline.selectedRowIndexes.count <= 1 else { return }
        // Gone to from elsewhere (⌃1, the line over the list) while its project is folded: open the project. Only on the
        // way in: a project folded while you're in it stays folded.
        if id != revealed, let p = outline.parent(forItem: w) as? Node, isCollapsed(p) { open(p) }
        revealed = id
        let tab = app.workbench.focusedTab ?? ""
        // A child has no row: its parent's stands for it.
        let on = TabURI.body(tab), parent = app.session(on)?.parent ?? ""
        let agent = TabURI.scheme(tab) == "session" ? w.children.first { $0.key == "a:" + on || $0.key == "a:" + parent } : nil
        let row = agent.map { outline.row(forItem: $0) }.flatMap { $0 >= 0 ? $0 : nil } ?? outline.row(forItem: w)
        guard row >= 0 else { return }
        if outline.selectedRow != row {
            syncing = true
            outline.selectRowIndexes([row], byExtendingSelection: false)
            syncing = false
        }
        keepOpenInView()
    }

    /// In the window's second row, beside Add Project: who needs you and who's working. The row is always there, so the
    /// list under it doesn't move when the first agent starts.
    private func placeSummary(over list: NSScrollView, beside add: NSView) {
        let summary = AgentSummary(app: app)
        summary.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(summary)
        NSLayoutConstraint.activate([   // in line with the projects' cards (SidebarRowView.band): 8 pt to the window's edge
            summary.centerYAnchor.constraint(equalTo: add.centerYAnchor),
            summary.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            summary.trailingAnchor.constraint(equalTo: add.leadingAnchor),
            list.topAnchor.constraint(equalTo: add.bottomAnchor)   // the list opens with a little air of its own
        ])
    }

    /// The workspace on screen stays in view with its agents under it (they can show up after it was selected).
    private func keepOpenInView() {
        guard let id = app.workbench.workspaceId, let n = workspaceNode(id) else { return }
        let row = outline.row(forItem: n)
        guard row >= 0 else { return }
        if let last = n.children.last, outline.isItemExpanded(n) { outline.scrollRowToVisible(outline.row(forItem: last)) }
        outline.scrollRowToVisible(row)
    }
    func isCollapsed(_ n: Node) -> Bool { !n.children.isEmpty && (!outline.isItemExpanded(n) || folding[n.key] != nil) }

    // MARK: data source / delegate

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Node)?.children.count ?? roots.count }
    func outlineView(_ o: NSOutlineView, child i: Int, ofItem item: Any?) -> Any { (item as? Node)?.children[i] ?? roots[i] }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? Node)?.children.isEmpty ?? true) }
    static func isHeader(_ item: Any?) -> Bool {
        if case .project? = (item as? Node)?.kind { true } else { false }
    }
    func outlineView(_ o: NSOutlineView, shouldSelectItem item: Any) -> Bool { !Self.isHeader(item) || (item as? Node)?.workspace != nil }
    // A project too: the outline doesn't fold an item without one. Its triangle isn't drawn (SidebarOutline), it has its own chevron.
    func outlineView(_ o: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { true }
    // One line per row, as tall as Finder's at the same sidebar size; an agent that asks gets a second line.
    func outlineView(_ o: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let n = item as? Node else { return TextSize.of(rowBase) }
        if underFold(n) { return 0.01 }   // the outline takes no 0
        let pad = pads(n)
        // Its card's edge stays: without that room the cell's height comes out below 0, which the outline throws on.
        if arriving.contains(n.key) { return 0.01 + pad.top + pad.bottom }
        return TextSize.of(rowBase + (hasAsk(n) ? 16 : 0)) + pad.top + pad.bottom
    }
    /// Settings › Appearance › Row height; Match System reads macOS's Sidebar icon size (small, medium, large), as
    /// Finder and Mail do. Limit: only the height follows it, the text stays 13 pt (Text size scales that).
    private var rowBase: CGFloat {
        switch app.settings.string("workbench.sidebar.rowHeight") {
        case "compact": 24
        case "regular": 28
        case "large": 32
        default: [1: 24, 3: 32][UserDefaults.standard.integer(forKey: "NSTableViewDefaultSizeMode")] ?? 28
        }
    }
    private func hasAsk(_ n: Node) -> Bool {
        guard case .agent(let id) = n.kind, let s = app.session(id) else { return false }
        return SidebarCell.line(s, mode: app.settings.string("workbench.sidebar.agentDetail") ?? "needsYou", among: app.sessions) != nil
    }
    /// Room in a row for its project's card to open (over the project's name) and close (under its last row).
    private func pads(_ n: Node) -> (top: CGFloat, bottom: CGFloat) {
        var p = group(n).map(SidebarRowView.pads) ?? (top: 0, bottom: 0)
        p.top += serverGap(n)
        return p
    }
    /// The gap over a server's first project, which starts that server's card.
    func serverGap(_ n: Node) -> CGFloat {
        if case .project(let id) = n.kind, serverStarts.contains(id) { Self.serverGap } else { 0 }
    }
    /// Where this row is in its project's card: nil for a project with nothing under it, which is a plain row.
    private func group(_ n: Node) -> (first: Bool, last: Bool)? {
        var top = n
        while let up = outline.parent(forItem: top) as? Node { top = up }
        guard case .project = top.kind, !top.children.isEmpty else { return nil }
        return (n === top, n === lastRow(top))
    }
    /// The last row of what's under `n` (itself when folded or folding).
    func lastRow(_ n: Node) -> Node {
        var last = n
        while outline.isItemExpanded(last), folding[last.key] == nil, let c = last.children.last { last = c }
        return last
    }

    func outlineView(_ o: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { SidebarRowView() }
    /// Typing a name jumps to its row (the cells have no textField the outline could read it from).
    func outlineView(_ o: NSOutlineView, typeSelectStringFor tc: NSTableColumn?, item: Any) -> String? {
        switch (item as? Node)?.kind {
        case .project(let id)?: app.projectName(id)
        case .workspace(let id)?: app.worktree(id)?.displayName
        case .agent(let id)?: app.session(id).map(app.catalog.displayName)
        default: nil
        }
    }
    func outlineView(_ o: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) { place(rowView, row) }

    func place(_ v: NSTableRowView, _ row: Int) {
        let n = outline.item(atRow: row) as? Node
        (v as? SidebarRowView)?.group = n.flatMap(group)
        (v as? SidebarRowView)?.gap = n.map(serverGap) ?? 0
    }
    /// The cards follow rows that open, close or move; a project's last row changes height with them.
    /// Inside an animation group they move with it; outside one, as the outline moves rows by itself (a quarter second).
    func outlineView(_ o: NSOutlineView, viewFor tc: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? Node else { return nil }
        let cell = SidebarCell(node: n, owner: self)
        cell.update()
        return cell
    }

    func outlineViewItemDidCollapse(_ n: Notification) { remember(n, collapsed: true) }
    func outlineViewItemDidExpand(_ n: Notification) { remember(n, collapsed: false) }
    private func remember(_ n: Notification, collapsed c: Bool) {
        guard !syncing, let node = n.userInfo?["NSObject"] as? Node, node.id != nil else { return }
        // A project folding folds its workspaces with it: that isn't the user folding them.
        if let p = outline.parent(forItem: node) as? Node, !outline.isItemExpanded(p) { return }
        if c { collapsed.insert(node.key) } else { collapsed.remove(node.key) }
        if !c, case .project = node.kind {
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
        func look(_ ns: [Node]) -> Node? { for n in
            ns { if test(n) { return n }; if let f = look(n.children) { return f } }
            return nil
        }
        return look(roots)
    }
}

/// A row picked opens what it stands for.
extension SidebarController {
    func outlineViewSelectionDidChange(_ n: Notification) {
        card.close()
        // Several rows picked: nothing to open, they wait for the menu.
        guard !syncing, outline.selectedRowIndexes.count == 1, let node = outline.item(atRow: outline.selectedRow) as? Node else { return }
        switch node.kind {
        case .workspace(let id): app.workbench.show(workspace: id)
        case .agent(let id): app.workbench.focus(session: id)
        case .project:
            guard let id = node.workspace else { break }
            // Already there: the pill stays with the tab.
            if id == app.workbench.workspaceId { syncSelection() } else { app.workbench.show(workspace: id) }
        }
    }
}
