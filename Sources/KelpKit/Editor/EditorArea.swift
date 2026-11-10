import AppKit
import Core
import DesignKit
import WorkbenchKit

package enum SplitDirection: String { case right, down }

/// One workspace's editor area: groups of tabs in a split tree. Tabs are made by the providers extensions register.
@MainActor
package final class EditorArea: NSViewController {
    let app: AppModel
    let workspaceId: String
    package var layout: WorkspaceLayout
    var contents: [String: TabContent] = [:]   // by tab id
    var recent: [String] = []   // tab ids by when last shown, newest last (EditorRelease)
    var hiddenAt: [String: Date] = [:]   // since when each built tab is off screen (EditorRelease)
    var groupViews: [String: GroupView] = [:]
    /// The card under an agent's tab, one for all of this workspace's strips: moving along them goes from card to card.
    private lazy var tabCard = HoverCard(app: app, underTabs: true)
    private var renders = 0
    var start: StartView?
    private var responderObservation: NSKeyValueObservation?
    let saveWork = Debounce()
    var reconciledOnce = false
    /// Sessions whose tab was just closed: until their kill lands, a daemon update mustn't bring the tab back.
    var closed: Set<String> = []
    /// Tabs asking before they close: a second ⌘W meanwhile doesn't ask again.
    var closing: Set<String> = []
    /// What's typed in the empty workspace's field.
    var startDraft = ""
    /// The group shown alone (⇧⌘↩), not saved: a relaunch shows every pane.
    var zoomed: String?
    /// The page `kelp browser` last drove here (a tab id): its next command goes to the same one.
    var browsing: String?

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
        track(owner: self) { [app] in
            app.extensions.revision
        } changed: { [weak self] _ in
            self?.extensionsChanged()
        }
        track(owner: self) {
            app.fileIcons.revision
        } changed: { [weak self] _ in
            self?.groupViews.keys.forEach { self?.refreshGroup($0) }
        }
        // A run's tab follows the Run menu: its port once it prints one, its look once its files are read. Any session's
        // follows what it listens on.
        track(owner: self) { [weak self, app] in
            (app.extensions.all.runs?.tabsFollow() ?? [])
                + (app.latest(PortsEvent.self, self?.workspaceId ?? "")?.ports ?? []).map { "\($0.port) \($0.session)" }
        } changed: { [weak self] _ in
            self?.groupViews.keys.forEach { self?.refreshGroup($0) }
        }
        track(owner: self) {
            app.themes.chromeText
        } changed: { [weak self] _ in   // the tabs' titles take the new size
            self?.groupViews.values.forEach { $0.strip.restyle() }
        }
        track(owner: self, now: false) {
            app.settings[SettingKeys.tabWidth]
        } changed: { [weak self] width in
            self?.groupViews.values.forEach { $0.strip.tabWidth = width }
        }
        track(owner: self, now: false) {
            app.settings[SettingKeys.tabHeight] == "compact"
        } changed: { [weak self] low in
            self?.groupViews.values.forEach { $0.strip.low = low }
        }
        // The empty workspace lists the agents that work, with their icons; rebuild it when either changes.
        track(owner: self) {
            app.availability.ids
        } changed: { [weak self] _ in
            self?.rebuildStart()
        }
        track(owner: self) {
            app.agentIcons.images.count
        } changed: { [weak self] _ in
            self?.rebuildStart()
            for gid in self?.layout.root?.sessions ?? [] { self?.refreshGroup(gid) }   // agent tabs get the real icon
        }
        // The default agent's button beside each "+".
        track(owner: self) {
            app.catalog.startable
        } changed: { [weak self] _ in
            for gid in self?.layout.root?.sessions ?? [] { self?.refreshGroup(gid) }
        }
    }

    /// Turning an extension off takes its open tabs' content with it (they say how to turn it back on); turning it on
    /// brings the content back.
    private func extensionsChanged() {
        // A reloaded extension may have changed its view: its tabs are built again from the new definition.
        let stale = contents.filter {
            TabURI.scheme($0.value.uri) == "ext"
                || (app.extensions.tabProvider(for: $0.value.uri) != nil) == ($0.value is UnavailableTab)
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
    package override func viewWillDisappear() {
        super.viewWillDisappear()
        responderObservation = nil
    }

    // MARK: rendering

    /// The panes on show, to tell a change of shape from a tab moving.
    private var shownPanes: Set<String>?
    func render() {
        // A pane opened, closed or zoomed: everything in the area changes place at once, so it fades into its new shape.
        let panes = Set(layout.allTabs.isEmpty ? [] : layout.root?.sessions ?? []).union(zoomed.map { [$0] } ?? [])
        if let shownPanes, shownPanes != panes, view.window != nil { view.crossfade(Motion.base) }
        shownPanes = panes
        view.subviews.forEach { $0.removeFromSuperview() }
        guard var root = layout.root, !layout.allTabs.isEmpty else {
            showStart()
            return
        }
        start = nil
        if let zoomedGroup = zoomed, layout.groups[zoomedGroup] != nil, root.sessions.count > 1 {
            root = .pane(zoomedGroup)
        } else {
            zoomed = nil
        }
        if zoomed == nil, let sizes = layout.sizes { layout.sizes = sizes.filter { root.splitKeys.contains($0.key) } }
        let rootView = build(root)
        view.pin(rootView)
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
                refreshGroup(gid)
                next()
            }
        }
        next()
        for gid in groupViews.keys where layout.groups[gid] == nil { groupViews[gid] = nil }
        let live = Set(layout.allTabs.map(\.id))
        for id in contents.keys where !live.contains(id) { contents[id] = nil }
        scheduleSave()
    }

    private func build(_ node: LayoutNode) -> NSView {
        switch node {
        case .pane(let gid): return groupView(gid)
        case .split(let vertical, let kids):
            let sv = EqualizingSplitView()
            sv.isVertical = vertical
            sv.dividerStyle = .thin
            let key = LayoutNode.splitKey(kids)
            sv.identifier = NSUserInterfaceItemIdentifier(key)
            sv.delegate = self
            let size = view.bounds.width > 0 ? view.bounds.size : NSSize(width: 1000, height: 700)
            let saved = layout.sizes?[key].flatMap { $0.count == kids.count ? $0 : nil }
            let shares = saved ?? Array(repeating: 1 / Double(kids.count), count: kids.count)
            sv.frame = NSRect(origin: .zero, size: size)
            for (kid, share) in zip(kids, shares) {   // starting frames; NSSplitView keeps proportions from there
                let child = build(kid)
                child.translatesAutoresizingMaskIntoConstraints = true
                child.frame.size =
                    vertical
                    ? NSSize(width: size.width * share, height: size.height)
                    : NSSize(width: size.width, height: size.height * share)
                sv.addArrangedSubview(child)
            }
            return sv
        }
    }

    /// Where a tab dropped at the editor area's outer edge will go: half of the whole area along that side.
    private let outerHint = GroupView.dropHint()
    private func showOuterHint(_ edge: NSRectEdge?) {
        guard let edge else {
            outerHint.isHidden = true
            return
        }
        if outerHint.superview !== view { view.addSubview(outerHint, positioned: .above, relativeTo: nil) }
        var frame = view.bounds.insetBy(dx: 6, dy: 6)
        // Its share once added: one more beside the panes already split that way.
        let vertical = edge == .minX || edge == .maxX
        let count: CGFloat = {
            if case .split(let isVertical, let kids)? = layout.root, isVertical == vertical {
                CGFloat(kids.count + 1)
            } else {
                2
            }
        }()
        switch edge {
        case .minX: frame.size.width /= count
        case .maxX:
            frame.origin.x += frame.width * (count - 1) / count
            frame.size.width /= count
        case .minY: frame.size.height /= count
        default:
            frame.origin.y += frame.height * (count - 1) / count
            frame.size.height /= count
        }
        outerHint.frame = frame
        outerHint.isHidden = false
    }

    /// View › Equalize Panes: every split back to equal shares.
    func equalizePanes() {
        guard layout.sizes != nil else { return }
        layout.sizes = nil
        render()
        focusSelected()
    }

    private func groupView(_ gid: String) -> GroupView {
        if let group = groupViews[gid] {
            group.removeFromSuperview()
            return group
        }
        let group = GroupView(groupId: gid, themes: app.themes)
        group.strip.onSelect = { [weak self] id in self?.select(id) }
        group.strip.onClose = { [weak self] id in self?.closeTab(id) }
        group.strip.onMenu = { [weak self] id in self?.tabMenu(id) }
        group.strip.addMenu = { [weak self] in self?.newTabMenu(group: gid) ?? NSMenu() }
        group.strip.onNewAgent = { [weak self] in
            self?.layout.focused = gid
            self?.newAgent()
        }
        group.strip.onUnzoom = { [weak self] in self?.toggleZoom() }
        group.strip.hoverCard = tabCard
        group.strip.tabWidth = app.settings[SettingKeys.tabWidth]
        group.strip.low = app.settings[SettingKeys.tabHeight] == "compact"
        group.strip.onDropTab = { [weak self] id, index in
            guard let self else { return }
            if layout.group(of: id) != gid { arrangedByHand() }   // into another pane's strip, not reordering its own
            layout.move(id, to: gid, index: index)
            render()
        }
        group.editorFrame = { [weak self] in self.map { $0.view.convert($0.view.bounds, to: nil) } }
        group.showOuterHint = { [weak self] edge in self?.showOuterHint(edge) }
        group.onDropOuter = { [weak self] id, edge in
            guard let self else { return }
            arrangedByHand()
            layout.splitRoot(id, vertical: edge == .minX || edge == .maxX, before: edge == .minX || edge == .maxY)
            render()
            focusSelected()
        }
        group.onDropTab = { [weak self] id, edge in
            guard let self else { return }
            if edge != nil || layout.group(of: id) != gid { arrangedByHand() }
            switch edge {
            case nil: layout.move(id, to: gid)
            case .minX?: layout.split(id, from: gid, vertical: true, before: true)
            case .maxX?: layout.split(id, from: gid, vertical: true, before: false)
            case .maxY?: layout.split(id, from: gid, vertical: false, before: true)
            default: layout.split(id, from: gid, vertical: false, before: false)
            }
            render()
            focusSelected()
        }
        group.onDropFiles = { [weak self] urls in
            self?.layout.focused = gid
            self?.app.workbench.open(files: urls) { self?.open($0) }
        }
        groupViews[gid] = group
        return group
    }

    /// Strip and visible content of one group (cheap: called on every title / status change).
    func refreshGroup(_ gid: String) {
        guard let group = groupViews[gid], let model = layout.groups[gid] else { return }
        group.strip.focused = layout.focused == gid || (layout.focused == nil && layout.root?.sessions.first == gid)
        group.strip.zoomed = zoomed == gid
        let agent = app.catalog.startable
        let agentIcon = agent.flatMap { app.catalog.icon($0) }
        group.strip.setNewAgent(
            icon: agentIcon, grey: agentIcon.map(app.agentIcons.grey), name: app.catalog.name(agent))
        // Only the visible tab is built: a background agent tab must not wake a paused agent.
        let visible = model.selectedTab.flatMap { content($0) }
        group.strip.set(
            Self.disambiguated(
                model.tabs.map { tab in
                    guard let content = contents[tab.id] else {
                        // Not built, or let go of (a hidden terminal): what it stands for still says all this.
                        var item = placeholder(tab)
                        item.badge = app.extensions.tabProvider(for: tab.uri)?.badge?(tab.uri)
                        return runLook(item, tab)
                    }
                    return runLook(
                        .init(
                            id: tab.id, title: content.title, icon: content.icon, toolTip: content.toolTip,
                            edited: content.isEdited, badge: content.badge), tab)
                }, model.tabs), selected: model.selectedTab?.id)
        group.show(visible?.view)
        noteShown(model.selectedTab?.id)
        // With panes side by side, those without focus fade, tabs too: the one you're in is the lit one, whatever it shows.
        // Never the one that calls for you: it's the pane to look at.
        group.dimmed =
            !group.strip.focused && zoomed == nil && (layout.root?.sessions.count ?? 0) > 1 && visible != nil
            && visible?.badge?.attention == nil
        group.strip.dimmed = group.dimmed
        group.attention = visible?.badge?.attention
        group.breathing = visible?.badge?.status == .waiting
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

    func content(_ tab: TabRef) -> TabContent? {
        if let content = contents[tab.id] { return content }
        let content = app.extensions.tabProvider(for: tab.uri)?.make(tab.uri) ?? UnavailableTab(uri: tab.uri, app: app)
        contents[tab.id] = content
        track(owner: content, now: false) { [weak content] in
            content.map(TabLook.init)
        } changed: { [weak self] look in
            guard let self, let look, let gid = layout.group(of: tab.id) else { return }
            if var group = layout.groups[gid], let index = group.tabs.firstIndex(where: { $0.id == tab.id }),
                group.tabs[index].uri != look.uri
            {
                group.tabs[index].uri = look.uri
                layout.groups[gid] = group
                scheduleSave()   // e.g. the browser navigated
            }
            refreshGroup(gid)
            app.publishUIState()
        }
        return content
    }

    private func rebuildStart() {
        guard start != nil else { return }
        start?.removeFromSuperview()
        start = nil
        showStart()
    }

    private func showStart() {
        guard start == nil, let worktree else { return }
        let startView = StartView(app: app, worktree: worktree)
        startView.onAgent = { [weak self] agent in self?.newAgent(agent) }
        startView.onPrompt = { [weak self] agent, text in
            self?.startDraft = ""
            self?.newAgent(agent, prompt: text)
        }
        startView.draft = startDraft
        startView.onDraft = { [weak self] in self?.startDraft = $0 }
        startView.onOpen = { [weak self] uri in TabURI.runs(uri) ? self?.runURI(uri) : self?.open(uri) }
        startView.onInstall = { [weak self] m in if let self { app.catalog.install(m, in: self) } }
        start = startView
        view.pin(startView)
        DispatchQueue.main.async { startView.focus() }
    }
}
