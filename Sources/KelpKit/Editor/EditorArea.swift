import AppKit
import Core
import WorkbenchKit

package enum SplitDirection: String { case right, down }

/// One workspace's editor area: groups of tabs in a split tree. Tabs are made by the providers extensions register.
@MainActor
package final class EditorArea: NSViewController {
    let app: AppModel
    let workspaceId: String
    package var layout: WorkspaceLayout
    var contents: [String: TabContent] = [:]       // by tab id
    var groupViews: [String: GroupView] = [:]
    private var renders = 0
    var start: StartView?
    private var responderObservation: NSKeyValueObservation?
    private let saveWork = Debounce()
    var reconciledOnce = false
    /// Sessions whose tab was just closed: until their kill lands, a daemon update mustn't bring the tab back.
    var closed: Set<String> = []
    /// Tabs asking before they close: a second ⌘W meanwhile doesn't ask again.
    var closing: Set<String> = []
    /// The group shown alone (⇧⌘↩), not saved: a relaunch shows every pane.
    var zoomed: String?

    var worktree: Worktree? { app.worktree(workspaceId) }

    init(app: AppModel, workspaceId: String) {
        self.app = app
        self.workspaceId = workspaceId
        layout = WorkspaceLayout.load(workspaceId, from: app.uiState)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    package override func loadView() {
        let app = self.app
        view = NSView()
        track(owner: self) { [app] in app.extensions.revision } changed: { [weak self] _ in self?.extensionsChanged() }
        track(owner: self) { app.fileIcons.revision } changed: { [weak self] _ in self?.groupViews.keys.forEach { self?.refreshGroup($0) } }
        // A run's tab follows the Run menu: its port once it prints one, its look once its files are read.
        track(owner: self) { [app] in [app.scripts.state.active.count.description] + app.scripts.state.active.values.compactMap(\.url)
            + app.scripts.state.found.keys.sorted() } changed: { [weak self] _ in self?.groupViews.keys.forEach { self?.refreshGroup($0) } }
        track(owner: self) { app.settings.string("workbench.textSize") } changed: { [weak self] _ in   // the tabs' titles take the new size
            self?.groupViews.keys.forEach { self?.refreshGroup($0) }
        }
        // The empty workspace lists the agents that work, with their icons; rebuild it when either changes.
        track(owner: self) { app.availability.ids } changed: { [weak self] _ in self?.rebuildStart() }
        track(owner: self) { app.agentIcons.images.count } changed: { [weak self] _ in
            self?.rebuildStart()
            for gid in self?.layout.root?.sessions ?? [] { self?.refreshGroup(gid) }   // agent tabs get the real icon
        }
        // The default agent's button beside each "+".
        track(owner: self) { app.catalog.startable } changed: { [weak self] _ in
            for gid in self?.layout.root?.sessions ?? [] { self?.refreshGroup(gid) }
        }
    }

    /// Turning an extension off takes its open tabs' content with it (they say how to turn it back on); turning it on
    /// brings the content back.
    private func extensionsChanged() {
        // A reloaded extension may have changed its view: its tabs are built again from the new definition.
        let stale = contents.filter {
            TabURI.scheme($0.value.uri) == "ext" || (app.extensions.tabProvider(for: $0.value.uri) != nil) == ($0.value is UnavailableTab)
        }.map(\.key)
        guard !stale.isEmpty else { return }
        stale.forEach { contents[$0] = nil }
        render()
    }

    package override func viewDidAppear() {
        super.viewDidAppear()
        responderObservation = view.window?.observe(\.firstResponder, options: [.new]) { [weak self] w, _ in
            MainActor.assumeIsolated { self?.responderChanged(w.firstResponder) }   // the first responder changes on main
        }
        publishFocus()
    }
    package override func viewWillDisappear() { super.viewWillDisappear(); responderObservation = nil }

    // MARK: rendering

    func render() {
        view.subviews.forEach { $0.removeFromSuperview() }
        guard var root = layout.root, !layout.allTabs.isEmpty else { showStart(); return }
        start = nil
        if let z = zoomed, layout.groups[z] != nil, root.sessions.count > 1 { root = .pane(z) } else { zoomed = nil }
        if zoomed == nil, let sizes = layout.sizes { layout.sizes = sizes.filter { root.splitKeys.contains($0.key) } }
        let v = build(root)
        view.pin(v)
        // The focused group now, the others one per run-loop turn: restoring a browser, files and terminals together
        // would otherwise hold the main thread for 100–200 ms. A newer render takes over the rest.
        renders += 1
        let gen = renders, first = layout.focusedGroup?.id ?? root.sessions.first
        if let first { refreshGroup(first) }
        var rest = root.sessions.filter { $0 != first }
        func next() {
            guard !rest.isEmpty else { return }
            let gid = rest.removeFirst()
            DispatchQueue.main.async { [weak self] in
                guard let self, renders == gen else { return }
                refreshGroup(gid); next()
            }
        }
        next()
        for gid in groupViews.keys where layout.groups[gid] == nil { groupViews[gid] = nil }
        let live = Set(layout.allTabs.map(\.id))
        for id in contents.keys where !live.contains(id) { contents[id] = nil }
        scheduleSave()
    }

    private func build(_ n: LayoutNode) -> NSView {
        switch n {
        case .pane(let gid): return groupView(gid)
        case .split(let vertical, let kids):
            let sv = EqualizingSplitView()
            sv.isVertical = vertical
            sv.dividerStyle = .thin
            let key = LayoutNode.splitKey(kids)
            sv.identifier = NSUserInterfaceItemIdentifier(key); sv.delegate = self
            let size = view.bounds.width > 0 ? view.bounds.size : NSSize(width: 1000, height: 700)
            let saved = layout.sizes?[key].flatMap { $0.count == kids.count ? $0 : nil }
            let shares = saved ?? Array(repeating: 1 / Double(kids.count), count: kids.count)
            sv.frame = NSRect(origin: .zero, size: size)
            for (k, share) in zip(kids, shares) {   // starting frames; NSSplitView keeps proportions from there
                let v = build(k); v.translatesAutoresizingMaskIntoConstraints = true
                v.frame.size = vertical ? NSSize(width: size.width * share, height: size.height) : NSSize(width: size.width, height: size.height * share)
                sv.addArrangedSubview(v)
            }
            return sv
        }
    }

    /// Where a tab dropped at the editor area's outer edge will go: half of the whole area along that side.
    private let outerHint = GroupView.dropHint()
    private func showOuterHint(_ edge: NSRectEdge?) {
        guard let edge else { outerHint.isHidden = true; return }
        if outerHint.superview !== view { view.addSubview(outerHint, positioned: .above, relativeTo: nil) }
        var r = view.bounds.insetBy(dx: 6, dy: 6)
        // Its share once added: one more beside the panes already split that way.
        let vertical = edge == .minX || edge == .maxX
        let n: CGFloat = { if case .split(let v, let c)? = layout.root, v == vertical { CGFloat(c.count + 1) } else { 2 } }()
        switch edge {
        case .minX: r.size.width /= n
        case .maxX: r.origin.x += r.width * (n - 1) / n; r.size.width /= n
        case .minY: r.size.height /= n
        default: r.origin.y += r.height * (n - 1) / n; r.size.height /= n
        }
        outerHint.frame = r; outerHint.isHidden = false
    }

    /// View › Equalize Panes: every split back to equal shares.
    func equalizePanes() {
        guard layout.sizes != nil else { return }
        layout.sizes = nil
        render()
        focusSelected()
    }

    private func groupView(_ gid: String) -> GroupView {
        if let g = groupViews[gid] { g.removeFromSuperview(); return g }
        let g = GroupView(groupId: gid, themes: app.themes)
        g.strip.onSelect = { [weak self] id in self?.select(id) }
        g.strip.onClose = { [weak self] id in self?.closeTab(id) }
        g.strip.onMenu = { [weak self] id in self?.tabMenu(id) }
        g.strip.addMenu = { [weak self] in self?.newTabMenu(group: gid) ?? NSMenu() }
        g.strip.onNewAgent = { [weak self] in self?.layout.focused = gid; self?.newAgent() }
        g.strip.onUnzoom = { [weak self] in self?.toggleZoom() }
        g.strip.onDropTab = { [weak self] id, index in
            guard let self else { return }
            if layout.group(of: id) != gid { arrangedByHand() }   // into another pane's strip, not reordering its own
            layout.move(id, to: gid, index: index); render()
        }
        g.editorFrame = { [weak self] in self.map { $0.view.convert($0.view.bounds, to: nil) } }
        g.showOuterHint = { [weak self] edge in self?.showOuterHint(edge) }
        g.onDropOuter = { [weak self] id, edge in
            guard let self else { return }
            arrangedByHand()
            layout.splitRoot(id, vertical: edge == .minX || edge == .maxX, before: edge == .minX || edge == .maxY)
            render(); focusSelected()
        }
        g.onDropTab = { [weak self] id, edge in
            guard let self else { return }
            if edge != nil || layout.group(of: id) != gid { arrangedByHand() }
            switch edge {
            case nil: layout.move(id, to: gid)
            case .minX?: layout.split(id, from: gid, vertical: true, before: true)
            case .maxX?: layout.split(id, from: gid, vertical: true, before: false)
            case .maxY?: layout.split(id, from: gid, vertical: false, before: true)
            default: layout.split(id, from: gid, vertical: false, before: false)
            }
            render(); focusSelected()
        }
        g.onDropFiles = { [weak self] urls in
            self?.layout.focused = gid
            self?.app.workbench.open(files: urls) { self?.open($0) }
        }
        groupViews[gid] = g
        return g
    }

    /// Strip and visible content of one group (cheap: called on every title / status change).
    func refreshGroup(_ gid: String) {
        guard let g = groupViews[gid], let model = layout.groups[gid] else { return }
        g.strip.focused = layout.focused == gid || (layout.focused == nil && layout.root?.sessions.first == gid)
        g.strip.zoomed = zoomed == gid
        let agent = app.catalog.startable
        g.strip.setNewAgent(icon: agent.flatMap { app.catalog.icon($0) }, name: app.catalog.name(agent))
        // Only the visible tab is built: a background agent tab must not wake a paused agent.
        let visible = model.selectedTab.flatMap { content($0) }
        g.strip.set(Self.disambiguated(model.tabs.map { t in
            var item = placeholder(t)
            if let c = contents[t.id] {
                let b = c.badge
                item = TabStrip.Item(id: t.id, title: c.title, icon: c.icon, status: b?.status, unread: b?.unread ?? false, toolTip: c.toolTip,
                    edited: c.isEdited, meter: b?.meter, progress: b?.progress, background: b?.background,
                    backgroundTip: b?.backgroundTip, waitsFor: b?.waitsFor ?? false)
            }
            return runLook(item, t)
        }, model.tabs), selected: model.selectedTab?.id)
        g.show(visible?.view)
        // Like Ghostty's unfocused splits: with panes side by side, a terminal without focus fades a little. Never the one
        // that calls for you: it's the pane to look at.
        g.dimmed = !g.strip.focused && zoomed == nil && (layout.root?.sessions.count ?? 0) > 1 && visible?.badge.map { $0.attention == nil } == true
        g.attention = visible?.badge?.attention
        g.breathing = visible?.badge?.status == .waiting
        showEdited()
    }

    /// Unsaved files: the dot in the window's close button (and on their tabs), as in any Mac document app.
    /// In the main window, any loaded workspace's: switching away from one with unsaved files keeps the dot (quitting asks).
    func showEdited() {
        let all = app.workbench.window.flatMap { $0.window === view.window ? $0.editors.editedFiles : nil }
        view.window?.isDocumentEdited = !(all ?? editedFiles).isEmpty
    }

    /// Files with unsaved changes in this workspace (asked about on quit; the workspace isn't dropped from memory).
    var editedFiles: [SavableTab] { contents.values.compactMap { $0 as? SavableTab }.filter(\.isEdited) }

    /// A run's tab (the Run menu's) among the terminals: its purpose's symbol in colour, a glow of that colour, its port.
    private func runLook(_ item: TabStrip.Item, _ t: TabRef) -> TabStrip.Item {
        guard TabURI.scheme(t.uri) == "session", let s = app.session(TabURI.body(t.uri)), s.status != .exited,
              let look = app.scripts.look(s) else { return item }
        var item = item
        item.icon = look.icon
        item.run = look.glow
        if let port = look.port { item.title += " · " + port }
        return item
    }

    /// Strip entry for a tab not built yet, from its URI alone.
    /// Two files with one name (README.md twice): each tab adds its folder, "README.md — docs", as Xcode does.
    static func disambiguated(_ items: [TabStrip.Item], _ tabs: [TabRef]) -> [TabStrip.Item] {
        let paths = tabs.map { TabURI.scheme($0.uri) == "file" ? TabURI.filePath($0.uri).path as NSString : nil }
        let names = paths.map { $0?.lastPathComponent }
        return zip(items, paths).map { item, path in
            guard let path, names.filter({ $0 == path.lastPathComponent }).count > 1 else { return item }
            var item = item
            item.title = path.lastPathComponent + " — " + (path.deletingLastPathComponent as NSString).lastPathComponent
            return item
        }
    }

    func placeholder(_ t: TabRef) -> TabStrip.Item {
        let body = TabURI.body(t.uri)
        switch TabURI.scheme(t.uri) {
        case "session":
            let s = app.session(body)
            let title = s.map(app.catalog.displayName) ?? String(localized: "Session")
            return .init(id: t.id, title: title, icon: app.catalog.icon(s?.agent),
                         status: s.flatMap { $0.agent == "shell" ? nil : $0.endedWithError ? .error : $0.status },
                         unread: s?.unread ?? false, toolTip: title)
        case "file":
            let p = TabURI.filePath(t.uri).path
            return .init(id: t.id, title: (p as NSString).lastPathComponent, icon: app.fileIcons.image((p as NSString).lastPathComponent),
                         status: nil, toolTip: p)
        case "diff": return .init(id: t.id, title: String(localized: "Changes"), icon: .symbol("plus.forwardslash.minus"), status: nil, toolTip: nil)
        case "http", "https", "about":
            return .init(id: t.id, title: URL(string: t.uri)?.host ?? String(localized: "New Page"), icon: .symbol("safari"), status: nil, toolTip: t.uri)
        case "preview": return .init(id: t.id, title: (body as NSString).lastPathComponent, icon: .symbol("eye"), status: nil, toolTip: body)
        case "usage": return .init(id: t.id, title: String(localized: "Usage"), icon: .symbol("chart.bar"), status: nil, toolTip: nil)
        default:
            let v = DeclarativeExtension.viewInfo(t.uri)
            return .init(id: t.id, title: v?.title ?? body, icon: .symbol(v?.icon ?? "puzzlepiece.extension"), status: nil, toolTip: t.uri)
        }
    }

    private func content(_ t: TabRef) -> TabContent? {
        if let c = contents[t.id] { return c }
        let c = app.extensions.tabProvider(for: t.uri)?.make(t.uri) ?? UnavailableTab(uri: t.uri, app: app)
        contents[t.id] = c
        track(owner: c, now: false) { [weak c] in c.map(TabLook.init) } changed: { [weak self] look in
            guard let self, let look, let gid = layout.group(of: t.id) else { return }
            if var g = layout.groups[gid], let i = g.tabs.firstIndex(where: { $0.id == t.id }), g.tabs[i].uri != look.uri {
                g.tabs[i].uri = look.uri
                layout.groups[gid] = g
                scheduleSave()   // e.g. the browser navigated
            }
            refreshGroup(gid)
            app.publishUIState()
        }
        return c
    }

    private func rebuildStart() {
        guard start != nil else { return }
        start?.removeFromSuperview()
        start = nil
        showStart()
    }

    private func showStart() {
        guard start == nil, let w = worktree else { return }
        let s = StartView(app: app, worktree: w)
        s.onAgent = { [weak self] agent in self?.newAgent(agent) }
        s.onPrompt = { [weak self] agent, text in self?.newAgent(agent, prompt: text) }
        s.onOpen = { [weak self] uri in self?.open(uri) }
        s.onInstall = { [weak self] m in if let self { app.catalog.install(m, in: self) } }
        start = s
        view.pin(s)
        DispatchQueue.main.async { s.focus() }
    }

    // MARK: focus

    private func responderChanged(_ r: NSResponder?) {
        var v = r as? NSView
        while let x = v, !(x is GroupView) { v = x.superview }
        guard let g = v as? GroupView, layout.focused != g.groupId else { publishFocus(); return }
        let old = layout.focused
        layout.focused = g.groupId
        if let old { refreshGroup(old) }
        refreshGroup(g.groupId)
        publishFocus()
    }

    /// The focused tab tells the inspector which agent / file the user is looking at. Only the main window's workspace
    /// on screen says so: a background workspace or the Scratch panel opening a tab must not redirect "send to agent".
    func publishFocus() {
        guard app.workbench.window?.editors.current === self else { return }
        let uri = layout.focusedGroup?.selectedTab?.uri ?? ""
        let wb = app.workbench
        if wb.focusedTab != uri { wb.focusedTab = uri }
        if wb.sideBySide != (layout.manual != true) { wb.sideBySide = layout.manual != true }
        switch TabURI.scheme(uri) {
        case "session": wb.focusedSession = TabURI.body(uri)
        case "file": wb.focusedFile = TabURI.filePath(uri).path
        default: break
        }
        if wb.focusedSession.flatMap({ app.session($0)?.worktreeId }) != workspaceId {
            wb.focusedSession = app.sessions.last { $0.worktreeId == workspaceId && $0.status != .exited && $0.agent != "shell" }?.id
        }
        app.publishUIState()
    }

    package func focusSelected() {
        guard let t = layout.focusedGroup?.selectedTab else { start?.focus(); return }
        DispatchQueue.main.async { [weak self] in self?.contents[t.id]?.focus() }
    }

    // MARK: persistence

    func scheduleSave() {
        Self.unsaved.add(self)
        saveWork.after(0.5) { [weak self] in self?.saveLayout() }
    }
    private func saveLayout() { Self.unsaved.remove(self); layout.save(workspaceId, to: app.uiState) }
    /// Areas whose layout is waiting out the pause before it's saved (weak: one that's gone has nothing to save).
    private static let unsaved = NSHashTable<EditorArea>.weakObjects()
    /// Quitting: layouts still waiting are saved now, before the app's last writes go out.
    static func saveLayouts() { for a in unsaved.allObjects { a.saveWork.cancel(); a.saveLayout() } }

    /// Every open tab (URI and title), for the palette.
    var openTabs: [(String, String)] { layout.allTabs.map { ($0.uri, contents[$0.id]?.title ?? placeholder($0).title) } }

    /// Open tabs and focus, for `ui.state`.
    var stateForAgents: JSONValue {
        .obj(["tabs": .array(layout.allTabs.map { t in .obj(["uri": .string(t.uri), "title": .string(contents[t.id]?.title ?? "")]) }),
              "focused": .string(layout.focusedGroup?.selectedTab?.uri ?? "")])
    }
}

extension EditorArea: NSSplitViewDelegate {
    /// A dragged divider stays where it was put: tab changes and relaunches rebuild the splits from these shares.
    package func splitViewDidResizeSubviews(_ n: Notification) {
        guard let sv = n.object as? NSSplitView, sv.window != nil, let key = sv.identifier?.rawValue,
              sv.arrangedSubviews.count == key.split(separator: ",").count else { return }   // being taken apart: not the user
        let lengths = sv.arrangedSubviews.map { Double(sv.isVertical ? $0.frame.width : $0.frame.height) }
        let total = lengths.reduce(0, +)
        guard total > 20 else { return }
        let shares = lengths.map { $0 / total }
        if layout.sizes?[key].map({ zip($0, shares).allSatisfy { abs($0 - $1) < 0.002 } }) == true { return }
        layout.sizes = (layout.sizes ?? [:]).merging([key: shares]) { $1 }
        scheduleSave()
    }
}
