import AppKit
import SwiftUI
import Core
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
        init(_ k: SidebarItem.Kind) { kind = k }
        var key: String {
            switch kind {
            case .project(let id): "p:" + id
            case .workspace(let id): "w:" + id
            case .agent(let id): "a:" + id
            case .section(let s): "s:" + s
            case .needs(let id): "n:" + id
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
    var renaming: String?
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
    private lazy var summary = AgentSummary(app: app)

    override func loadView() {
        let col = NSTableColumn(identifier: .init("main")); col.resizingMask = .autoresizingMask
        outline.addTableColumn(col); outline.outlineTableColumn = col
        outline.headerView = nil; outline.style = .sourceList; outline.rowSizeStyle = .custom
        outline.selectionHighlightStyle = .none   // SidebarRowView draws the selection as a pill
        outline.floatsGroupRows = false; outline.indentationPerLevel = 14
        outline.pads = { [weak self] row in (self?.outline.item(atRow: row) as? Node).flatMap { self?.pads($0) } ?? (0, 0) }
        outline.allowsMultipleSelection = true   // ⌘/⇧-click: the menu then acts on all of them
        outline.dataSource = self; outline.delegate = self
        outline.target = self; outline.doubleAction = #selector(doubleClicked)
        outline.registerForDraggedTypes([.fileURL, Self.rowType])   // a folder from Finder becomes a project; rows move
        outline.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                               owner: self, userInfo: nil))
        let menu = NSMenu(); menu.delegate = self; outline.menu = menu
        let scroll = NSScrollView(); scroll.documentView = outline; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        // When the list gets shorter (the limits below load), the selected workspace stays in view.
        scroll.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepOpenInView() }   // queue: .main
        }

        let footer = NSHostingView(rootView: UsageView(app: app))   // agent limits, when any agent reports them
        footer.sizingOptions = [.intrinsicContentSize]
        let v = NSView()
        search.placeholderString = String(localized: "Workspace or agent"); search.delegate = self; search.controlSize = .small
        search.sendsSearchStringImmediately = true; search.target = self; search.action = #selector(searchChanged)
        setFilterMenu()
        // Beside the search, over the projects it adds to, where people look for it.
        let add = NSButton.titlebar("folder.badge.plus", String(localized: "Add Project"), tip: String(localized: "Add a project: a folder, a clone or one over SSH"))
        add.target = self; add.action = #selector(addMenu(_:))
        for x in [add, search, summary, scroll, footer, empty, noMatch] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            // Under the traffic lights, in the window's second row: level with the tab strips and the inspector's panel icons.
            search.centerYAnchor.constraint(equalTo: v.topAnchor, constant: WindowBar.height + TabStrip.height / 2),
            search.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10), search.trailingAnchor.constraint(equalTo: add.leadingAnchor, constant: -4),
            add.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -6), add.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            summary.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8), summary.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
            summary.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 4), scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
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
        track(owner: self) { [app] in app.repos } changed: { [weak self] _ in self?.refresh() }
        track(owner: self) { [app] in app.worktrees } changed: { [weak self] _ in self?.refresh() }
        track(owner: self) { [app] in app.sessions } changed: { [weak self] in self?.refresh(); self?.summary.update($0) }
        track(owner: self) { [app] in app.order } changed: { [weak self] _ in self?.refresh() }
        track(owner: self) { [app] in app.workbench.workspaceId } changed: { [weak self] _ in self?.syncSelection(); self?.updateCard() }
        track(owner: self) { [app] in app.workbench.focusedTab } changed: { [weak self] _ in self?.syncSelection() }
        track(owner: self) { [app] in app.rowBadges.stats } changed: { [weak self] _ in self?.updateVisibleCells() }
        track(owner: self) { [app] in app.rowBadges.prs } changed: { [weak self] _ in self?.updateVisibleCells() }
        track(owner: self) { [app] in app.settings.string("workbench.textSize") } changed: { [weak self] _ in self?.refresh() }
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
        let t = NSTextField(wrappingLabelWithString: String(localized: "No workspaces match \(what).")); t.alignment = .center; t.textColor = .secondaryLabelColor
        let b = ClosureButton(title: String(localized: "Show All")) { [weak self] in
            guard let self else { return }
            search.stringValue = ""; query = ""; setFilter(.all)
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
        guard row >= 0, renaming == nil, let n = outline.item(atRow: row) as? Node, !n.key.hasPrefix("s:") else { card.hover(nil, rect: .zero, in: outline); return }
        card.hover(n.key.replacingOccurrences(of: "n:", with: "a:"), rect: outline.rect(ofRow: row), in: outline)
    }
    override func mouseExited(with e: NSEvent) { card.hover(nil, rect: .zero, in: outline) }

    private func buildEmpty() {
        let app = self.app
        let icon = NSImageView(image: .symbol("folder.badge.plus")); icon.symbolConfiguration = .init(pointSize: 28, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        let t = NSTextField(labelWithString: String(localized: "No Projects")); t.font = .ui(13, weight: .semibold)
        let d = NSTextField(wrappingLabelWithString: String(localized: "Add a project folder to start.")); d.textColor = .secondaryLabelColor; d.alignment = .center
        let b = ClosureButton(title: String(localized: "Add Project…")) { app.workbench.addProject() }; b.bezelStyle = .push
        [icon, t, d, b].forEach { empty.addArrangedSubview($0) }
        empty.orientation = .vertical; empty.spacing = 8
    }

    // MARK: model → tree

    private var needsOrder = StableOrder()
    /// Builds the list again when an agent held back from "Needs You" (SidebarTree.settle) is due.
    private var settleTimer: Timer?

    private func build() -> [Node] {
        let m = app
        var tree = SidebarTree(projects: m.projects, workspaces: m.projects.flatMap { m.workspaces(of: $0) }, sessions: m.sessions, attention: AttentionQueue(app).sessions)
        tree.pinned = pinned
        tree.query = query
        tree.filter = filter
        tree.current = app.workbench.workspaceId
        tree.statusLabel = { $0.label }
        tree.hasPR = { [app] w in (app.rowBadges.folder(workspace: w.id) ?? app.rowBadges.folder(project: w.repoId)).map { [app] in app.rowBadges.prs[$0.id] != nil } ?? false }
        tree.stableOrder = { [unowned self] in needsOrder($0) }
        tree.settle = 5
        settleTimer?.invalidate(); settleTimer = nil
        if let due = tree.settlesAt {
            settleTimer = Timer.scheduledTimer(withTimeInterval: due.timeIntervalSinceNow, repeats: false) { [weak self] _ in   // main run loop
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        func node(_ i: SidebarItem) -> Node {
            let n = Node(i.kind)
            n.children = i.children.map(node)
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
        func flat(_ ns: [Node]) -> [String] { ns.flatMap { [$0.key] + flat($0.children) } }
        let nextShape = flat(next)
        let projects = app.repos.filter { !ScratchWindow.isScratch($0) }
        empty.isHidden = !projects.isEmpty
        showNoMatch(!projects.isEmpty && !next.contains { if case .project = $0.kind { true } else { false } })
        search.isHidden = projects.isEmpty
        if nextShape == shape { updateVisibleCells(); return }
        roots = next; shape = nextShape
        syncing = true
        outline.reloadData()
        for p in roots { outline.expandItem(p); for w in p.children where !collapsed.contains(w.key) { outline.expandItem(w) } }
        syncing = false
        updateVisibleCells()   // cells were made before their rows expanded
        syncSelection()
    }

    func node(_ key: String) -> Node? {
        func find(_ ns: [Node]) -> Node? { for n in ns { if n.key == key { return n }; if let f = find(n.children) { return f } }; return nil }
        return find(roots)
    }

    /// The row of what's on screen: the agent whose tab has focus, else its workspace. Several rows picked stay picked.
    private func syncSelection() {
        guard let id = app.workbench.workspaceId, let w = node("w:" + id), outline.selectedRowIndexes.count <= 1 else { return }
        let tab = app.workbench.focusedTab ?? ""
        let agent = TabURI.scheme(tab) == "session" ? w.children.first { $0.key == "a:" + TabURI.body(tab) } : nil
        let row = agent.map { outline.row(forItem: $0) }.flatMap { $0 >= 0 ? $0 : nil } ?? outline.row(forItem: w)
        guard row >= 0 else { return }
        if outline.selectedRow != row { syncing = true; outline.selectRowIndexes([row], byExtendingSelection: false); syncing = false }
        keepOpenInView()
    }

    /// The workspace on screen stays in view with its agents under it (they can show up after it was selected).
    private func keepOpenInView() {
        guard let id = app.workbench.workspaceId, let n = node("w:" + id) else { return }
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
    func outlineView(_ o: NSOutlineView, isGroupItem item: Any) -> Bool { Self.isHeader(item) }
    func outlineView(_ o: NSOutlineView, shouldSelectItem item: Any) -> Bool { !Self.isHeader(item) }
    func outlineView(_ o: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { !Self.isHeader(item) }
    // One line per row, like Mail's mailbox list; section headers a little taller for air above them, and an agent
    // with news two lines (what it asks or did under its name).
    func outlineView(_ o: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let n = item as? Node else { return TextSize.of(28) }
        let pad = pads(n)
        return TextSize.of(Self.isHeader(item) ? 32 : 28) + pad.top + pad.bottom
    }
    /// Room in a row for its project's card to open (over the project's name) and close (under its last row).
    private func pads(_ n: Node) -> (top: CGFloat, bottom: CGFloat) {
        guard let p = group(n) else { return (0, 0) }
        return (p.first ? 4 : 0, p.last ? 8 : 0)
    }
    /// Where this row is in its project's card: nil outside a project (the sections over them).
    private func group(_ n: Node) -> (first: Bool, last: Bool)? {
        var top = n
        while let up = outline.parent(forItem: top) as? Node { top = up }
        guard case .project = top.kind else { return nil }
        var last = top
        while outline.isItemExpanded(last), let c = last.children.last { last = c }
        return (n === top, n === last)
    }

    func outlineView(_ o: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { SidebarRowView() }
    func outlineView(_ o: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) { place(rowView, row) }

    /// The workspace on screen and its agents are drawn as one card, like a tab group in Safari.
    private func cardPlace(_ row: Int) -> (first: Bool, last: Bool)? {
        // A workspace without agents showing is just its pill.
        guard let id = app.workbench.workspaceId, let w = node("w:" + id), outline.isItemExpanded(w) else { return nil }
        func inCard(_ r: Int) -> Bool {
            guard let n = outline.item(atRow: r) as? Node else { return false }
            return n === w || outline.parent(forItem: n) as? Node === w
        }
        guard inCard(row) else { return nil }
        return (outline.item(atRow: row) as? Node === w, !inCard(row + 1))
    }
    private func place(_ v: NSTableRowView, _ row: Int) {
        guard let v = v as? SidebarRowView else { return }
        v.card = cardPlace(row)
        v.group = (outline.item(atRow: row) as? Node).flatMap(group)
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

    func outlineViewItemDidCollapse(_ n: Notification) { remember(n, collapsed: true) }
    func outlineViewItemDidExpand(_ n: Notification) { remember(n, collapsed: false) }
    private func remember(_ n: Notification, collapsed c: Bool) {
        guard !syncing, let node = n.userInfo?["NSObject"] as? Node, case .workspace = node.kind else { return }
        if c { collapsed.insert(node.key) } else { collapsed.remove(node.key) }
        refreshCell(node.key)   // collapsed, the workspace shows its agents' state itself
        updateCard()   // the card ends at another row
    }

    func outlineViewSelectionDidChange(_ n: Notification) {
        card.close()
        // Several rows picked: nothing to open, they wait for the menu.
        guard !syncing, outline.selectedRowIndexes.count == 1, let node = outline.item(atRow: outline.selectedRow) as? Node else { return }
        switch node.kind {
        case .workspace(let id): app.workbench.show(workspace: id)
        case .agent(let id), .needs(let id): app.workbench.focus(session: id)
        case .project, .section: break
        }
    }
}

extension SidebarController {
    /// The menu for several selected rows: what applies to all of them.
    func bulkMenu(_ menu: NSMenu, _ nodes: [Node]) {
        let app = self.app
        let m = app
        let ws = nodes.compactMap { n -> Worktree? in if case .workspace(let id) = n.kind { m.worktree(id) } else { nil } }
        let picked = nodes.compactMap { n -> String? in
            switch n.kind {
            case .agent(let id), .needs(let id): id
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
