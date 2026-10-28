import AppKit
import SwiftUI
import Core
import DesignKit
import WorkbenchKit

/// Projects → workspaces → agents in a source-list outline (like Finder and Xcode).
/// Status changes update the visible cells in place; the outline reloads only when the tree's shape changes.
@MainActor
final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate, NSSearchFieldDelegate {
    let app: AppModel
    init(app: AppModel) { self.app = app; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    final class Node: NSObject {
        let kind: SidebarItem.Kind
        var children: [Node] = []
        /// A project's only workspace, which its row stands for (SidebarItem.workspace).
        var workspace: String?
        init(_ k: SidebarItem.Kind) { kind = k }
        var key: String {
            switch kind {
            case .project(let id): "p:" + id
            case .workspace(let id): "w:" + id
            case .agent(let id): "a:" + id
            case .section(let s): "s:" + s
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
    var roots: [Node] = []
    private var shape: [String] = []
    private var collapsed: Set<String> {
        get { Set(app.uiState.strings("sidebar.collapsed")) }
        set { app.uiState["sidebar.collapsed"] = try? .from(newValue.sorted()) }
    }
    private var syncing = false
    /// The workspace whose project syncSelection last opened (or found open).
    private var revealed: String?
    /// The workspace or project (`project`) whose name is being edited in its row.
    var renaming: (id: String, project: Bool)?
    private let empty = NSStackView()
    private let search = NSSearchField()
    var query = ""
    lazy var card = HoverCard(app: app)
    /// The search field's menu (its magnifier): which workspaces to show. The one on screen always stays.
    var filter = SidebarFilter(rawValue: UserDefaults.standard.string(forKey: "sidebar.filter") ?? "") ?? .all
    var pinned: [String] {
        get { app.uiState.strings("sidebar.pinned") }
        set { app.uiState["sidebar.pinned"] = try? .from(newValue) }
    }
    private let noMatch = NSStackView()
    /// Over the list, who needs you (Appearance › Sidebar › Needs You): a capsule counting them, or a row for each.
    private var needsYou: NSView?
    private var needsYouTabs = false, placing = false
    private weak var list: NSScrollView?

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
            MainActor.assumeIsolated { self?.keepOpenInView(); self?.placeNeedsYou() }   // queue: .main
        }

        let footer = NSHostingView(rootView: UsageView(app: app))   // agent limits, when any agent reports them
        footer.sizingOptions = [.intrinsicContentSize]
        let v = NSView()
        search.placeholderString = String(localized: "Workspace or agent")
        search.delegate = self
        search.controlSize = .regular   // 22 pt, level with the add button beside it (small was 19 pt, off its axis)
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchChanged)
        setFilterMenu()
        // Beside the search, over the projects it adds to, where people look for it.
        let add = NSButton.titlebar("folder.badge.plus", String(localized: "Add Project"),
                                    tip: String(localized: "Add a project: a folder, a clone or one over SSH"))
        add.target = self; add.action = #selector(addMenu(_:))
        for x in [add, search, scroll, footer, empty, noMatch] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            // Under the traffic lights, in the window's second row: level with the tab strips and the inspector's panel icons.
            search.centerYAnchor.constraint(equalTo: v.topAnchor, constant: WindowBar.height + TabStrip.height / 2),
            search.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10), search.trailingAnchor.constraint(equalTo: add.leadingAnchor, constant: -4),
            add.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -6), add.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            // In line with the projects' cards (SidebarRowView.band): 8 pt to the window's edge and to the editor area.
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: v.leadingAnchor), footer.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: v.centerXAnchor), empty.centerYAnchor.constraint(equalTo: v.centerYAnchor, constant: -40),
            empty.widthAnchor.constraint(lessThanOrEqualTo: v.widthAnchor, constant: -32),
            noMatch.centerXAnchor.constraint(equalTo: v.centerXAnchor), noMatch.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 40),
            noMatch.widthAnchor.constraint(lessThanOrEqualTo: v.widthAnchor, constant: -32)
        ])
        buildEmpty()
        view = v
        list = scroll
        track(owner: self) { [app] in app.settings.string("workbench.sidebar.needsYou") } changed: { [weak self] _ in self?.placeNeedsYou() }
        scroll.contentView.postsBoundsChangedNotifications = true   // Automatic: scrolled, someone who needs you may leave the view
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeNeedsYou() }   // queue: .main
        }
        track(owner: self) { [app] in app.repos } changed: { [weak self] _ in self?.refresh() }
        track(owner: self) { [app] in app.worktrees } changed: { [weak self] _ in self?.refresh() }
        track(owner: self) { [app] in app.sessions } changed: { [weak self] _ in self?.refresh() }
        track(owner: self) { [app] in app.order } changed: { [weak self] _ in self?.refresh() }
        track(owner: self) { [app] in app.workbench.workspaceId } changed: { [weak self] _ in self?.syncSelection(); self?.updateCard() }
        track(owner: self) { [app] in app.workbench.focusedTab } changed: { [weak self] _ in self?.syncSelection() }
        track(owner: self) { [app] in app.rowBadges.stats } changed: { [weak self] _ in self?.updateVisibleCells() }
        track(owner: self) { [app] in app.rowBadges.prs } changed: { [weak self] _ in self?.updateVisibleCells() }
        track(owner: self) { [app] in app.settings.string("workbench.textSize") } changed: { [weak self] _ in self?.refresh() }
        track(owner: self) { [app] in ["rowHeight", "agentDetail", "agentIcons"].map { app.settings.string("workbench.sidebar." + $0) } }
            changed: { [weak self] _ in self?.updateVisibleCells() }
        track(owner: self) { [app] in app.settings.bool("workbench.sidebar.gitBadges") } changed: { [weak self] _ in self?.updateVisibleCells() }
        track(owner: self) { [app] in app.settings.string("workbench.sidebar.order") } changed: { [weak self] _ in self?.refresh() }
        // "now" becomes "1m": the times on the right move on their own (a clock: nothing is asked of the daemon).
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in   // main run loop
            MainActor.assumeIsolated { if self?.view.window?.occlusionState.contains(.visible) == true { self?.updateVisibleCells() } }
        }
    }

    private func updateVisibleCells() {
        updateCard()
        for row in 0..<outline.numberOfRows { (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell)?.update() }
    }

    /// Nothing matches the search or the filter: say which, and offer the way back.
    private func showNoMatch(_ on: Bool) {
        noMatch.isHidden = !on
        guard on else { return }
        noMatch.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let what = query.isEmpty ? "“\(loc(filter.rawValue))”" : "“\(query)”" + (filter == .all ? "" : String(localized: " in “\(loc(filter.rawValue))”"))
        let t = NSTextField(wrappingLabelWithString: String(localized: "No workspaces match \(what)."))
        t.alignment = .center
        t.textColor = .secondaryLabelColor
        let b = ClosureButton(title: String(localized: "Show All")) { [weak self] in
            guard let self else { return }
            search.stringValue = ""
            query = ""
            setFilter(.all)
        }
        b.bezelStyle = .push; b.controlSize = .small
        [t, b].forEach { noMatch.addArrangedSubview($0) }
        noMatch.orientation = .vertical; noMatch.spacing = 8
    }

    private func setFilterMenu() {
        let m = NSMenu()
        for f in SidebarFilter.allCases {
            let i = m.add(loc(f.rawValue)) { [weak self] in self?.setFilter(f) }
            i.state = f == filter ? .on : .off
        }
        search.searchMenuTemplate = m
        search.placeholderString = filter == .all ? String(localized: "Workspace or agent") : String(localized: "Search \(loc(filter.rawValue))")
    }
    private func setFilter(_ f: SidebarFilter) {
        filter = f; UserDefaults.standard.set(f.rawValue, forKey: "sidebar.filter")
        setFilterMenu(); refresh()
    }

    // MARK: hover cards

    override func mouseMoved(with e: NSEvent) {
        let row = outline.row(at: outline.convert(e.locationInWindow, from: nil))
        guard row >= 0, renaming == nil, let n = outline.item(atRow: row) as? Node, !n.key.hasPrefix("s:") else {
            card.hover(nil, rect: .zero, in: outline)
            return
        }
        card.hover(n.workspace.map { "w:" + $0 } ?? n.key, rect: outline.rect(ofRow: row), in: outline)
    }
    override func mouseExited(with e: NSEvent) { card.hover(nil, rect: .zero, in: outline) }

    private func buildEmpty() {
        let app = self.app
        let icon = NSImageView(image: .symbol("folder.badge.plus")); icon.symbolConfiguration = .init(pointSize: 28, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        let t = NSTextField(labelWithString: String(localized: "No Projects")); t.font = .ui(13, weight: .semibold)
        let d = NSTextField(wrappingLabelWithString: String(localized: "Add a project folder to start."))
        d.textColor = .secondaryLabelColor
        d.alignment = .center
        let b = ClosureButton(title: String(localized: "Add Project…")) { app.workbench.addProject() }; b.bezelStyle = .push
        [icon, t, d, b].forEach { empty.addArrangedSubview($0) }
        empty.orientation = .vertical; empty.spacing = 8
    }

    // MARK: model → tree

    private func build() -> [Node] {
        let m = app
        var tree = SidebarTree(projects: m.projects, workspaces: m.projects.flatMap { m.workspaces(of: $0) }, sessions: m.sessions)
        tree.pinned = pinned
        tree.query = query
        tree.filter = filter
        tree.current = app.workbench.workspaceId
        tree.activeFirst = app.settings.string("workbench.sidebar.order") == "active"
        tree.statusLabel = { $0.label }
        tree.hasPR = { [app] w in
            (app.rowBadges.folder(workspace: w.id) ?? app.rowBadges.folder(project: w.repoId)).map { [app] in app.rowBadges.prs[$0.id] != nil } ?? false
        }
        func node(_ i: SidebarItem) -> Node {
            let n = Node(i.kind)
            n.children = i.children.map(node); n.workspace = i.workspace
            return n
        }
        return tree.build().map(node)
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

    @objc private func searchChanged() { query = search.stringValue.trimmingCharacters(in: .whitespaces); refresh() }

    /// Same shape → refresh the visible cells; new shape → reload, keeping expansion and selection.
    func refresh() {
        let next = build()
        // A project's row also stands for its one workspace: when that arrives after the project (or changes), the nodes
        // must be new, or the row the workspace on screen is looked up by (workspaceNode) isn't found and nothing is picked.
        func flat(_ ns: [Node]) -> [String] { ns.flatMap { [$0.key + ($0.workspace.map { "=" + $0 } ?? "")] + flat($0.children) } }
        let nextShape = flat(next)
        let projects = app.repos.filter { !ScratchWindow.isScratch($0) }
        empty.isHidden = !projects.isEmpty
        showNoMatch(!projects.isEmpty && !next.contains { if case .project = $0.kind { true } else { false } })
        search.isHidden = projects.isEmpty
        if nextShape == shape { updateVisibleCells(); return }
        roots = next; shape = nextShape
        syncing = true
        outline.reloadData()
        for p in roots where !collapsed.contains(p.key) { expand(p) }
        syncing = false
        updateVisibleCells()   // cells were made before their rows expanded
        syncSelection()
        placeNeedsYou()
    }

    /// A project and the workspaces in it that weren't folded (their children wait until the project opens).
    private func expand(_ p: Node) {
        outline.expandItem(p)
        for w in p.children where !collapsed.contains(w.key) { outline.expandItem(w) }
    }
    func toggle(_ n: Node) { if outline.isItemExpanded(n) { outline.collapseItem(n) } else { outline.expandItem(n) } }

    /// The row for a workspace: its own, or its project's when that stands for it.
    func workspaceNode(_ id: String) -> Node? { node("w:" + id) ?? roots.first { $0.workspace == id } }

    func node(_ key: String) -> Node? {
        func find(_ ns: [Node]) -> Node? { for n in
            ns { if n.key == key { return n }; if let f = find(n.children) { return f } }
            return nil
        }
        return find(roots)
    }

    /// The row of what's on screen: the agent whose tab has focus, else its workspace. Several rows picked stay picked.
    private func syncSelection() {
        guard let id = app.workbench.workspaceId, let w = workspaceNode(id), outline.selectedRowIndexes.count <= 1 else { return }
        // Gone to from elsewhere (⌃1, the line over the list) while its project is folded: open the project. Only on the
        // way in: a project folded while you're in it stays folded.
        if id != revealed, let p = outline.parent(forItem: w) as? Node, !outline.isItemExpanded(p) { outline.expandItem(p) }
        revealed = id
        let tab = app.workbench.focusedTab ?? ""
        let agent = TabURI.scheme(tab) == "session" ? w.children.first { $0.key == "a:" + TabURI.body(tab) } : nil
        let row = agent.map { outline.row(forItem: $0) }.flatMap { $0 >= 0 ? $0 : nil } ?? outline.row(forItem: w)
        guard row >= 0 else { return }
        if outline.selectedRow != row {
            syncing = true
            outline.selectRowIndexes([row], byExtendingSelection: false)
            syncing = false
        }
        keepOpenInView()
    }

    /// The workspace on screen stays in view with its agents under it (they can show up after it was selected).
    /// The capsule or the zone, under the search and over the list (added after it: the zone hangs over its top).
    /// Automatic: the zone while someone who needs you is out of view, the capsule once they are all in it.
    func placeNeedsYou() {
        guard let list else { return }
        let mode = app.settings.string("workbench.sidebar.needsYou")
        let tabs = mode == "tabs" || (mode == "automatic" && !needsYouInView())
        guard needsYou == nil || tabs != needsYouTabs, !placing else { return }
        placing = true
        defer { placing = false }   // the inset going scrolls the list, which asks again
        needsYou?.removeFromSuperview()
        list.contentInsets.top = 0
        let line: NSLayoutGuide, v: NSView
        let later = { [weak self] in DispatchQueue.main.async { self?.placeNeedsYou() } }   // not while the old one is updating
        if tabs {
            let zone = NeedsYouZone(app: app)
            line = zone.line; v = zone
            view.addSubview(zone)
            zone.list = list
            zone.updated = later
        } else {
            let capsule = AgentSummary(app: app)
            line = capsule.line; v = capsule
            view.addSubview(capsule)
            capsule.updated = later
        }
        needsYou = v; needsYouTabs = tabs
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([   // in line with the projects' cards (SidebarRowView.band): 8 pt to the window's edge
            v.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6), v.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            v.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            list.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 4)
        ])
    }

    /// Every agent that needs you has its row on screen: not scrolled away, under the zone, folded or filtered out.
    private func needsYouInView() -> Bool {
        guard let list else { return true }
        // What the clip shows, in the list's terms (flipped: the top is minY), less what the zone covers at its top.
        var seen = outline.convert(list.contentView.bounds, from: list.contentView)
        seen.origin.y += list.contentInsets.top
        seen.size.height -= list.contentInsets.top
        return Inbox.current(app).shown.allSatisfy { s in
            guard let n = node("a:" + s.id), case let row = outline.row(forItem: n), row >= 0 else { return false }
            let r = outline.rect(ofRow: row)
            return r.minY >= seen.minY && r.maxY <= seen.maxY
        }
    }

    private func keepOpenInView() {
        guard let id = app.workbench.workspaceId, let n = workspaceNode(id) else { return }
        let row = outline.row(forItem: n)
        guard row >= 0 else { return }
        if let last = n.children.last, outline.isItemExpanded(n) { outline.scrollRowToVisible(outline.row(forItem: last)) }
        outline.scrollRowToVisible(row)
    }
    func isCollapsed(_ n: Node) -> Bool { !n.children.isEmpty && !outline.isItemExpanded(n) }

    // MARK: data source / delegate

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Node)?.children.count ?? roots.count }
    func outlineView(_ o: NSOutlineView, child i: Int, ofItem item: Any?) -> Any { (item as? Node)?.children[i] ?? roots[i] }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? Node)?.children.isEmpty ?? true) }
    static func isHeader(_ item: Any?) -> Bool {
        switch (item as? Node)?.kind {
        case .project?, .section?: true
        default: false
        }
    }
    // Only the Pinned heading is a group row: the source list puts a section's worth of room over each one, and a
    // project is a card, not a section (that room was a third of a short project's height).
    func outlineView(_ o: NSOutlineView, isGroupItem item: Any) -> Bool {
        if case .section? = (item as? Node)?.kind { true } else { false }
    }
    func outlineView(_ o: NSOutlineView, shouldSelectItem item: Any) -> Bool { !Self.isHeader(item) || (item as? Node)?.workspace != nil }
    // A project too: the outline doesn't fold an item without one. Its triangle isn't drawn (SidebarOutline), it has its own chevron.
    func outlineView(_ o: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        if case .section? = (item as? Node)?.kind { false } else { true }
    }
    // One line per row, as tall as Finder's at the same sidebar size; an agent that asks gets a second line.
    func outlineView(_ o: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let n = item as? Node else { return TextSize.of(rowBase) }
        let pad = pads(n)
        let base = { if case .workspace = n.kind { rowBase - 6 } else { rowBase } }()   // a heading, a little shorter
        return TextSize.of(base + (hasAsk(n) ? 16 : 0)) + pad.top + pad.bottom
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
        return SidebarCell.askLine(s, mode: app.settings.string("workbench.sidebar.agentDetail") ?? "needsYou") != nil
    }
    /// Room in a row for its project's card to open (over the project's name) and close (under its last row).
    private func pads(_ n: Node) -> (top: CGFloat, bottom: CGFloat) {
        guard let p = group(n) else { return (0, 0) }
        return SidebarRowView.pads(p)
    }
    /// Where this row is in its project's card: nil outside a project (the sections over them) and for a project with
    /// nothing under it, which is a plain row.
    private func group(_ n: Node) -> (first: Bool, last: Bool)? {
        var top = n
        while let up = outline.parent(forItem: top) as? Node { top = up }
        guard case .project = top.kind, !top.children.isEmpty else { return nil }
        var last = top
        while outline.isItemExpanded(last), let c = last.children.last { last = c }
        return (n === top, n === last)
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

    private func place(_ v: NSTableRowView, _ row: Int) {
        (v as? SidebarRowView)?.group = (outline.item(atRow: row) as? Node).flatMap(group)
    }
    /// The cards follow rows that open, close or move; a project's last row changes height with them.
    private func updateCard() {
        outline.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<outline.numberOfRows))
        outline.enumerateAvailableRowViews { v, row in self.place(v, row) }
    }

    func outlineView(_ o: NSOutlineView, viewFor tc: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? Node else { return nil }
        let cell = SidebarCell(node: n, owner: self)
        cell.update()
        return cell
    }

    func outlineViewItemDidCollapse(_ n: Notification) { remember(n, collapsed: true); placeNeedsYou() }
    func outlineViewItemDidExpand(_ n: Notification) { remember(n, collapsed: false); placeNeedsYou() }
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
        updateCard()   // the card ends at another row
    }

    func outlineViewSelectionDidChange(_ n: Notification) {
        card.close()
        // Several rows picked: nothing to open, they wait for the menu.
        guard !syncing, outline.selectedRowIndexes.count == 1, let node = outline.item(atRow: outline.selectedRow) as? Node else { return }
        switch node.kind {
        case .workspace(let id): app.workbench.show(workspace: id)
        case .agent(let id): app.workbench.focus(session: id)
        case .project: if let id = node.workspace { app.workbench.show(workspace: id) }
        case .section: break
        }
    }
}

extension SidebarController {
    /// The menu for several selected rows: what applies to all of them.
    func bulkMenu(_ menu: NSMenu, _ nodes: [Node]) {
        let app = self.app
        let m = app
        let ws = nodes.compactMap { n -> Worktree? in
            if case .workspace(let id) = n.kind { m.worktree(id) } else { n.workspace.flatMap(m.worktree) }
        }
        let picked = nodes.compactMap { n -> String? in
            switch n.kind {
            case .agent(let id): id
            default: nil
            }
        }
        let inside = m.sessions.filter { s in ws.contains { $0.id == s.worktreeId } && s.agent != "shell" && s.status != .exited }.map(\.id)
        let agents = Array(Set(picked + inside))
        if agents.contains(where: { m.session($0)?.unread == true }) {
            menu.add(String(localized: "Mark as Read")) {
                for id in agents where m.session(id)?.unread == true { Task { await m.call(SessionMarkRead(id: id)) } }
            }
        }
        if !ws.isEmpty { menu.add(String(localized: "Close \(ws.count) Workspaces…")) { WorkspaceActions(app).close(ws) } }
        if !picked.isEmpty {
            menu.addItem(.separator())
            menu.add(String(localized: "Stop \(Set(picked).count) Agents…")) { AgentActions(app).stop(Array(Set(picked))) }
        }
    }
}
