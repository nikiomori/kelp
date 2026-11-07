import AppKit
import Core
import DesignKit
import SwiftUI
import TerminalKit
import WorkbenchKit

/// The window, as Arc and Safari are: one surface — projects & agents in the sidebar (the traffic lights sit in it), the
/// window bar (where you are, ⌘P), the inspector — wrapped round the editor area, a card with rounded corners. The
/// panels' first rows (search, panel icons) line up with the card's tab strips. An auto-hidden panel (and focus mode's)
/// comes in over the card instead, floating clear of the window's edges.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    /// The app this window shows: handed to its panels and editor areas.
    let app: AppModel
    let editors: EditorHost
    let inspector: InspectorController
    private let sidebar: SidebarController
    private let split = ShellSplit()
    private let surface: DropRoot
    private let inspectorItem: NSSplitViewItem
    private let sidebarItem: NSSplitViewItem
    /// Focus mode (⌃⌘Z): both panels away; they slide in while the pointer is at the window's edge.
    /// Holds the panels' state from before, to put back on leaving.
    private var focusMode: (sidebar: Bool, inspector: Bool)? {
        didSet { app.workbench.inFocusMode = focusMode != nil }
    }
    /// Settings › Appearance › Auto-hide: that panel stays away the same way, for good.
    private var autoHide = (sidebar: false, inspector: false)
    /// Auto-hide panels the toggle (⌘0 / ⌥⌘0) pinned: they stay in like a normal panel until it's pressed again.
    private var pinned = (sidebar: false, inspector: false)
    private let leftEdge = EdgeTrigger(), rightEdge = EdgeTrigger()
    /// Where a hiding panel is while it's away, and comes in from.
    private let leftFloat = Floater(width: 260, inset: 0), rightFloat = Floater(width: 300, inset: Card.gap)
    private lazy var bar = WindowBar(app: app)
    private lazy var updatePill = UpdatePill(app: app)
    /// While the pill shows, the sidebar's toggle stays clear of it (a hidden view still holds constraints).
    private lazy var clearOfPill = sidebarToggle.leadingAnchor.constraint(
        greaterThanOrEqualTo: updatePill.trailingAnchor, constant: Metrics.gap)
    /// Fixed in the window bar's corners, whichever panels are open.
    private let sidebarToggle = NSButton.titlebar(
        "sidebar.left", String(localized: "Sidebar"), tip: String(localized: "Show or hide the sidebar (⌘0)"))
    private let inspectorToggle = NSButton.titlebar(
        "sidebar.trailing", String(localized: "Inspector"),
        tip: String(localized: "Show or hide the inspector (⌥⌘0)"))

    init(app: AppModel) {
        let created = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered,
            defer: false)
        self.app = app
        editors = EditorHost(app: app)
        sidebar = SidebarController(app: app)
        inspector = InspectorController(app: app)
        sidebarItem = Self.column(sidebar)
        inspectorItem = Self.column(inspector)
        surface = DropRoot(app: app)
        super.init(window: created)
        app.workbench.window = self   // what acts on the window reaches it there
        // The title stays set: the Window menu, Mission Control and VoiceOver read it.
        created.titlebarAppearsTransparent = true
        created.titleVisibility = .hidden
        created.titlebarSeparatorStyle = .none
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 400
        let content = NSSplitViewItem(viewController: editors)
        content.minimumThickness = 420
        inspectorItem.minimumThickness = 250
        inspectorItem.maximumThickness = 520
        inspectorItem.isCollapsed = UserDefaults.standard.bool(forKey: "inspector.collapsed")
        [sidebarItem, content, inspectorItem].forEach(split.addSplitViewItem)
        split.splitView.autosaveName = "main.split"
        let root = NSViewController()
        root.view = surface
        root.addChild(split)
        sidebarToggle.target = self
        sidebarToggle.action = #selector(toggleSidebarPanel)
        inspectorToggle.target = self
        inspectorToggle.action = #selector(toggleInspectorPanel)
        root.view.pin(split.view)
        // The inspector's toggle under its floater: on the floater's corner it stood half on its border. The sidebar's stays
        // over its floater, beside the traffic lights, which are over everything anyway.
        for part in [bar, leftFloat, inspectorToggle, rightFloat, updatePill, sidebarToggle, leftEdge, rightEdge] {
            part.translatesAutoresizingMaskIntoConstraints = false
            root.view.addSubview(part)
        }
        leftFloat.attach(leading: true)
        rightFloat.attach(leading: false)
        leftEdge.isHidden = true
        rightEdge.isHidden = true
        leftEdge.onEnter = { [weak self] in self?.peek(sidebar: true) }
        rightEdge.onEnter = { [weak self] in self?.peek(sidebar: false) }
        let lights = created.standardWindowButton(.zoomButton).map { $0.convert($0.bounds, to: nil).maxX } ?? 69
        // The bar lies over the editor area only: the sidebar and the inspector both run the window's full height. With
        // the sidebar away it runs under the traffic lights; with the inspector away, under its toggle.
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.view.topAnchor),
            bar.heightAnchor.constraint(equalToConstant: WindowBar.height),
            bar.leadingAnchor.constraint(equalTo: editors.view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: editors.view.trailingAnchor),
            // The bar is as tall as the title bar, so the traffic lights and the toggles share a centre line. The sidebar's
            // toggle is in the sidebar's top right corner, or after the traffic lights while the sidebar is away.
            sidebarToggle.leadingAnchor.constraint(
                greaterThanOrEqualTo: root.view.leadingAnchor, constant: lights + 12),
            sidebarToggle.trailingAnchor.constraint(equalTo: editors.view.leadingAnchor, constant: -8).withPriority(
                600),
            sidebarToggle.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            updatePill.leadingAnchor.constraint(equalTo: root.view.leadingAnchor, constant: lights + 12),
            updatePill.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            // The workspace starts over the editor area; with the sidebar away, after its toggle.
            bar.context.leadingAnchor.constraint(greaterThanOrEqualTo: sidebarToggle.trailingAnchor, constant: 12),
            bar.context.leadingAnchor.constraint(equalTo: editors.view.leadingAnchor, constant: 12).withPriority(700),
            inspectorToggle.trailingAnchor.constraint(equalTo: root.view.trailingAnchor, constant: -10),
            inspectorToggle.centerYAnchor.constraint(equalTo: sidebarToggle.centerYAnchor),
            leftEdge.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            leftEdge.widthAnchor.constraint(equalToConstant: 4),
            leftEdge.topAnchor.constraint(equalTo: bar.bottomAnchor),
            leftEdge.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
            rightEdge.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            rightEdge.widthAnchor.constraint(equalToConstant: 4),
            rightEdge.topAnchor.constraint(equalTo: bar.bottomAnchor),
            rightEdge.bottomAnchor.constraint(equalTo: root.view.bottomAnchor)
        ])
        created.contentViewController = root
        created.title = String(localized: "Kelp")
        created.setFrameAutosaveName("main")
        created.delegate = self
        if created.frame.origin == .zero { created.center() }
        track {
            app.worktree(app.workbench.workspaceId)
        } changed: { [weak self] _ in
            self?.updateTitle()
        }
        track {
            app.updates.ready != nil
        } changed: { [weak self] in
            self?.clearOfPill.isActive = $0
        }
        track {
            app.themes.look
        } changed: { [weak self] look in
            self?.surface.show(look)
            for panel in [self?.leftFloat, self?.rightFloat] { panel?.show(look) }
        }
        track {
            app.settings[SettingKeys.sidebarAutoHide]
        } changed: { [weak self] in
            self?.setAutoHide(sidebar: true, $0)
            self?.sidebarToggle.menu = self?.autoHideMenu(
                String(localized: "Auto-Hide Sidebar"), SettingKeys.sidebarAutoHide, $0)
        }
        track {
            app.settings[SettingKeys.inspectorAutoHide]
        } changed: { [weak self] in
            self?.setAutoHide(sidebar: false, $0)
            self?.inspectorToggle.menu = self?.autoHideMenu(
                String(localized: "Auto-Hide Inspector"), SettingKeys.inspectorAutoHide, $0)
        }
    }
    /// A panel's column. It holds the panel while it's docked; while the panel hides (auto-hide, focus mode) the panel is
    /// in its floater and the column stays collapsed.
    private static func column(_ panel: NSViewController) -> NSSplitViewItem {
        let slot = NSViewController()
        slot.view = NSView()
        slot.addChild(panel)
        slot.view.pin(panel.view)
        let item = NSSplitViewItem(viewController: slot)
        item.canCollapse = true
        item.holdingPriority = .init(260)   // a resized window widens the editor area, not the panels
        return item
    }
    /// The toggles' right-click menu: the panel's auto-hide, as in Settings › Appearance.
    private func autoHideMenu(_ title: String, _ setting: Setting<Bool>, _ on: Bool) -> NSMenu {
        let menu = NSMenu(), app = app
        menu.add(title) { app.settings.set(setting, !on) }.state = on ? .on : .off
        return menu
    }
    required init?(coder: NSCoder) { fatalError() }

    func showWorkspace(_ id: String?) {
        editors.show(id)
        updateTitle()
        app.publishUIState()
    }

    /// A page over the whole editor area (`Workbench.page`); false when no extension makes it.
    func showPage(_ uri: String) -> Bool {
        guard let page = editors.showPage(uri) else { return false }
        window?.title = page.title
        app.publishUIState()
        return true
    }

    private func updateTitle() {
        let worktree = app.worktree(app.workbench.workspaceId)
        window?.title = app.groupName(worktree) ?? app.projectName(worktree?.repoId) ?? String(localized: "Kelp")
        editors.current?.showEdited()   // a workspace with unsaved files keeps saying so after a switch
    }

    /// Narrowed until the editor would have less than 640 pt, the inspector steps aside and comes back once the window has
    /// room again, as Mail's sidebar does (at 1000 pt the two side columns had half the window). Not saved: the inspector
    /// you open or close yourself is (`inspector.collapsed`). The split's own collapse-on-resize only acts on live resizes.
    private var narrowedAt: CGFloat?
    func windowDidResize(_ notification: Notification) {
        guard focusMode == nil, !autoHide.inspector, let width = window?.frame.width else { return }
        if let at = narrowedAt {
            if width >= at + 20 {
                narrowedAt = nil
                inspectorItem.isCollapsed = false
            }   // a little past it, or it flaps
        } else if !inspectorItem.isCollapsed, editors.view.frame.width < 640 {
            narrowedAt = width
            inspectorItem.isCollapsed = true
        }
    }

    @objc func toggleInspectorPanel() {
        narrowedAt = nil
        if focusMode != nil { return togglePeek(inspectorItem) }
        if autoHide.inspector { return togglePin(inspectorItem) }
        let collapsed = !inspectorItem.isCollapsed
        slide([(inspectorItem, collapsed)])
        UserDefaults.standard.set(collapsed, forKey: "inspector.collapsed")
    }
    func showInspector(panel: String) {
        if inspectorItem.isCollapsed, peeking !== inspectorItem {
            if hides(inspectorItem) { peek(sidebar: false) } else { toggleInspectorPanel() }
        }
        inspector.show(panel: panel)
    }
    @objc func toggleSidebarPanel() {
        if focusMode != nil { return togglePeek(sidebarItem) }
        if autoHide.sidebar { return togglePin(sidebarItem) }
        slide([(sidebarItem, !sidebarItem.isCollapsed)])
    }
    var sidebarShown: Bool { !sidebarItem.isCollapsed || peeking === sidebarItem }
    var inspectorShown: Bool { !inspectorItem.isCollapsed || peeking === inspectorItem }
    /// In its column beside the editors, not only peeking over them.
    var inspectorDocked: Bool { !inspectorItem.isCollapsed }

    /// Quitting: focus mode's panels come back first, or the split's autosave would start the next launch wrong.
    func leaveFocusMode() {
        stopPeek()
        guard let was = focusMode else { return }
        focusMode = nil
        place()
        sidebarItem.isCollapsed = was.sidebar
        inspectorItem.isCollapsed = was.inspector
        sidebarToggle.isHidden = false
        inspectorToggle.isHidden = false
    }

    @objc func toggleFocusMode() {
        stopPeek()
        if let was = focusMode {
            focusMode = nil
            place()
            slide([(sidebarItem, was.sidebar), (inspectorItem, was.inspector)])
        } else {
            focusMode = (
                sidebarItem.isCollapsed || hides(sidebarItem), inspectorItem.isCollapsed || hides(inspectorItem)
            )
            place()   // before the columns close: the floaters take their widths
            slide([(sidebarItem, true), (inspectorItem, true)])
        }
        let on = focusMode != nil
        sidebarToggle.isHidden = on
        inspectorToggle.isHidden = on
    }
    var inFocusMode: Bool { focusMode != nil }

    private func setAutoHide(sidebar: Bool, _ on: Bool) {
        guard on != (sidebar ? autoHide.sidebar : autoHide.inspector) else { return }   // the first, unloaded read keeps the saved layout
        if sidebar {
            autoHide.sidebar = on
            pinned.sidebar = false
            focusMode?.sidebar = on
        } else {
            autoHide.inspector = on
            pinned.inspector = false
            focusMode?.inspector = on
        }
        let item: NSSplitViewItem = sidebar ? sidebarItem : inspectorItem
        if peeking === item { stopPeek() }
        place()
        if focusMode == nil {
            slide([(item, on)])
            if !sidebar { UserDefaults.standard.set(on, forKey: "inspector.collapsed") }
        }
    }
    /// Columns open or close together as a floater slides, and at once under Reduce Motion. The terminals beside them
    /// keep their size until the columns stop: a program in one would redraw for every width on the way.
    private func slide(_ columns: [(item: NSSplitViewItem, collapsed: Bool)]) {
        let moves = columns.filter { $0.item.isCollapsed != $0.collapsed }
        guard !moves.isEmpty else { return }
        if moves.contains(where: { $0.item === sidebarItem && $0.collapsed }) { sidebar.card.close() }   // its row is going, and with it the pointer's way out
        guard !Motion.reduced else { return moves.forEach { $0.item.isCollapsed = $0.collapsed } }
        GhosttyTerminalView.holdSize(true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.base
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            moves.forEach { $0.item.animator().isCollapsed = $0.collapsed }
        } completionHandler: {
            MainActor.assumeIsolated { GhosttyTerminalView.holdSize(false) }   // AppKit runs it on the main thread
        }
    }
    private func hides(_ item: NSSplitViewItem) -> Bool {
        focusMode != nil
            || (item === sidebarItem ? autoHide.sidebar && !pinned.sidebar : autoHide.inspector && !pinned.inspector)
    }
    private func floater(_ item: NSSplitViewItem) -> Floater { item === sidebarItem ? leftFloat : rightFloat }

    /// Each panel where it belongs now: in its column, or in its floater while it hides. A panel leaving its open column
    /// for the floater keeps its width there.
    private func place() {
        for (item, panel, edge) in [(sidebarItem, sidebar.view, leftEdge), (inspectorItem, inspector.view, rightEdge)] {
            let hide = hides(item), floating = floater(item), column = item.viewController.view
            edge.isHidden = !hide
            if hide, panel.superview !== floating.box {
                if !item.isCollapsed, column.frame.width >= item.minimumThickness {
                    floating.width = column.frame.width
                }
                floating.box.pin(panel)
            } else if !hide, panel.superview !== column {
                column.pin(panel)
            }
            // The sidebar's cards run to its column's edge, the gap before the editor card being their margin there; in the
            // floater that edge is its border, so a margin goes inside it, as wide as the cards stand from the left (8),
            // and the scroller's knob runs in it.
            if item === sidebarItem { sidebar.gutter = hide ? Metrics.gapWide : 0 }
        }
    }

    /// Focus mode and auto-hide: the pointer at an edge brings that panel in over the editor area (which keeps its size:
    /// terminals aren't resized, nothing reflows); once the pointer leaves the panel for the rest of the window, the
    /// panel goes again. In focus mode ⌘0 / ⌥⌘0 bring it in the same way; with auto-hide they pin it.
    private var peeking: NSSplitViewItem?
    private var peekMoves: Any?, peekedAt = Date.distantPast
    /// The pointer has been over the panel since it came in (from the edge at once; after ⌘0, once it gets there).
    private var peekReached = false
    private func peek(sidebar: Bool) {
        let item: NSSplitViewItem = sidebar ? sidebarItem : inspectorItem
        guard hides(item), peeking !== item else { return }
        endPeek()
        peeking = item
        peekedAt = Date()
        peekReached = false
        floater(item).slide(in: true)
        window?.acceptsMouseMovedEvents = true
        peekMoves = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.pointerMoved(event)
            return event
        }
    }
    private func pointerMoved(_ event: NSEvent) {
        guard let item = peeking, event.window === window, let root = window?.contentView else { return }
        let point = root.convert(event.locationInWindow, from: nil)
        let edge = item === sidebarItem ? leftEdge : rightEdge
        if Self.overPeek(point, panel: floater(item).frame, edge: edge.frame) {
            peekReached = true
            return
        }
        // Not while it slides in: the panel isn't where the pointer is headed yet.
        if peekReached, Date().timeIntervalSince(peekedAt) > 0.4 { endPeek() }
    }
    /// Over a peeking panel: anywhere from the window's edge through it. The panel stands 6 pt in from the edge, past the
    /// 4 pt strip, and a slow move across that gap closed it under the pointer.
    static func overPeek(_ point: NSPoint, panel: NSRect, edge: NSRect) -> Bool { panel.union(edge).contains(point) }
    private func endPeek(animated: Bool = true) {
        if let monitor = peekMoves {
            NSEvent.removeMonitor(monitor)
            peekMoves = nil
        }
        guard let panel = peeking else { return }
        peeking = nil
        floater(panel).slide(in: false, animated: animated)
    }
    /// The panels change for good (focus mode, auto-hide switched, pinned): the peeking one goes at once.
    private func stopPeek() { endPeek(animated: false) }
    private func togglePeek(_ item: NSSplitViewItem) {
        if peeking === item { endPeek() } else { peek(sidebar: item === sidebarItem) }
    }
    /// Auto-hide: pinned, the panel stays in its column (a peeking one moves there); unpinned, it goes and comes in at
    /// the edge again.
    private func togglePin(_ item: NSSplitViewItem) {
        let pin = item === sidebarItem ? !pinned.sidebar : !pinned.inspector
        if item === sidebarItem { pinned.sidebar = pin } else { pinned.inspector = pin }
        if peeking === item { stopPeek() }
        place()
        slide([(item, !pin)])
    }

    /// Closing the window quits (the daemon keeps agents running) — through the unsaved-files question; Cancel keeps it.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }
}
