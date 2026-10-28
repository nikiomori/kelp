import AppKit
import SwiftUI
import Core
import DesignKit
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
    private let inspectorItem: NSSplitViewItem
    private let sidebarItem: NSSplitViewItem
    /// Focus mode (⌃⌘Z): both panels away; they slide in while the pointer is at the window's edge.
    /// Holds the panels' state from before, to put back on leaving.
    private var focusMode: (sidebar: Bool, inspector: Bool)?
    /// Settings › Appearance › Auto-hide: that panel stays away the same way, for good.
    private var autoHide = (sidebar: false, inspector: false)
    /// Auto-hide panels the toggle (⌘0 / ⌥⌘0) pinned: they stay in like a normal panel until it's pressed again.
    private var pinned = (sidebar: false, inspector: false)
    private let leftEdge = EdgeTrigger(), rightEdge = EdgeTrigger()
    /// Where a hiding panel is while it's away, and comes in from.
    private let leftFloat = Floater(width: 260), rightFloat = Floater(width: 300)
    private lazy var bar = WindowBar(app: app)
    /// Fixed in the window bar's corners, whichever panels are open.
    private let sidebarToggle = NSButton.titlebar("sidebar.left", String(localized: "Sidebar"), tip: String(localized: "Show or hide the sidebar (⌘0)"))
    private let inspectorToggle = NSButton.titlebar("sidebar.trailing", String(localized: "Inspector"),
                                                    tip: String(localized: "Show or hide the inspector (⌥⌘0)"))

    init(app: AppModel) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        self.app = app
        editors = EditorHost(app: app)
        sidebar = SidebarController(app: app); inspector = InspectorController(app: app)
        sidebarItem = Self.column(sidebar); inspectorItem = Self.column(inspector)
        super.init(window: w)
        app.workbench.window = self   // what acts on the window reaches it there
        // The title stays set: the Window menu, Mission Control and VoiceOver read it.
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.titlebarSeparatorStyle = .none
        sidebarItem.minimumThickness = 220; sidebarItem.maximumThickness = 400
        let content = NSSplitViewItem(viewController: editors)
        content.minimumThickness = 420
        inspectorItem.minimumThickness = 250; inspectorItem.maximumThickness = 520
        inspectorItem.isCollapsed = UserDefaults.standard.bool(forKey: "inspector.collapsed")
        [sidebarItem, content, inspectorItem].forEach(split.addSplitViewItem)
        split.splitView.autosaveName = "main.split"
        let root = NSViewController()
        root.view = DropRoot(app: app)
        root.addChild(split)
        sidebarToggle.target = self; sidebarToggle.action = #selector(toggleSidebarPanel)
        inspectorToggle.target = self; inspectorToggle.action = #selector(toggleInspectorPanel)
        root.view.pin(split.view)
        // The inspector's toggle under its floater: on the floater's corner it stood half on its border. The sidebar's stays
        // over its floater, beside the traffic lights, which are over everything anyway.
        for v in [bar, leftFloat, inspectorToggle, rightFloat, sidebarToggle, leftEdge, rightEdge] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.view.addSubview(v)
        }
        leftFloat.attach(leading: true); rightFloat.attach(leading: false)
        leftEdge.isHidden = true; rightEdge.isHidden = true
        leftEdge.onEnter = { [weak self] in self?.peek(sidebar: true) }
        rightEdge.onEnter = { [weak self] in self?.peek(sidebar: false) }
        let lights = w.standardWindowButton(.zoomButton).map { $0.convert($0.bounds, to: nil).maxX } ?? 69
        // The bar lies over the editor area only: the sidebar and the inspector both run the window's full height. With
        // the sidebar away it runs under the traffic lights; with the inspector away, under its toggle.
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.view.topAnchor), bar.heightAnchor.constraint(equalToConstant: WindowBar.height),
            bar.leadingAnchor.constraint(equalTo: editors.view.leadingAnchor), bar.trailingAnchor.constraint(equalTo: editors.view.trailingAnchor),
            // The bar is as tall as the title bar, so the traffic lights and the toggles share a centre line. The sidebar's
            // toggle is in the sidebar's top right corner, or after the traffic lights while the sidebar is away.
            sidebarToggle.leadingAnchor.constraint(greaterThanOrEqualTo: root.view.leadingAnchor, constant: lights + 12),
            sidebarToggle.trailingAnchor.constraint(equalTo: editors.view.leadingAnchor, constant: -8).withPriority(600),
            sidebarToggle.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            // The workspace starts over the editor area; with the sidebar away, after its toggle.
            bar.context.leadingAnchor.constraint(greaterThanOrEqualTo: sidebarToggle.trailingAnchor, constant: 12),
            bar.context.leadingAnchor.constraint(equalTo: editors.view.leadingAnchor, constant: 12).withPriority(700),
            inspectorToggle.trailingAnchor.constraint(equalTo: root.view.trailingAnchor, constant: -10),
            inspectorToggle.centerYAnchor.constraint(equalTo: sidebarToggle.centerYAnchor),
            leftEdge.leadingAnchor.constraint(equalTo: root.view.leadingAnchor), leftEdge.widthAnchor.constraint(equalToConstant: 4),
            leftEdge.topAnchor.constraint(equalTo: bar.bottomAnchor), leftEdge.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
            rightEdge.trailingAnchor.constraint(equalTo: root.view.trailingAnchor), rightEdge.widthAnchor.constraint(equalToConstant: 4),
            rightEdge.topAnchor.constraint(equalTo: bar.bottomAnchor), rightEdge.bottomAnchor.constraint(equalTo: root.view.bottomAnchor)
        ])
        w.contentViewController = root
        w.title = String(localized: "Kelp")
        w.setFrameAutosaveName("main")
        w.delegate = self
        if w.frame.origin == .zero { w.center() }
        track { app.worktree(app.workbench.workspaceId) } changed: { [weak self] _ in self?.updateTitle() }
        track { app.settings.bool("workbench.sidebar.autoHide") == true } changed: { [weak self] in
            self?.setAutoHide(sidebar: true, $0)
            self?.sidebarToggle.menu = self?.autoHideMenu(String(localized: "Auto-Hide Sidebar"), "workbench.sidebar.autoHide", $0)
        }
        track { app.settings.bool("workbench.inspector.autoHide") == true } changed: { [weak self] in
            self?.setAutoHide(sidebar: false, $0)
            self?.inspectorToggle.menu = self?.autoHideMenu(String(localized: "Auto-Hide Inspector"), "workbench.inspector.autoHide", $0)
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
        item.canCollapse = true; item.holdingPriority = .init(260)   // a resized window widens the editor area, not the panels
        return item
    }
    /// The toggles' right-click menu: the panel's auto-hide, as in Settings › Appearance.
    private func autoHideMenu(_ title: String, _ key: String, _ on: Bool) -> NSMenu {
        let m = NSMenu(), app = app
        m.add(title) { app.settings.set(key, .bool(!on)) }.state = on ? .on : .off
        return m
    }
    required init?(coder: NSCoder) { fatalError() }

    func showWorkspace(_ id: String?) {
        editors.show(id)
        updateTitle()
        app.publishUIState()
    }

    private func updateTitle() {
        window?.title = app.worktree(app.workbench.workspaceId)?.displayName ?? String(localized: "Kelp")
        editors.current?.showEdited()   // a workspace with unsaved files keeps saying so after a switch
    }

    /// Narrowed until the editor would have less than 640 pt, the inspector steps aside and comes back once the window has
    /// room again, as Mail's sidebar does (at 1000 pt the two side columns had half the window). Not saved: the inspector
    /// you open or close yourself is (`inspector.collapsed`). The split's own collapse-on-resize only acts on live resizes.
    private var narrowedAt: CGFloat?
    func windowDidResize(_ n: Notification) {
        guard focusMode == nil, !autoHide.inspector, let width = window?.frame.width else { return }
        if let at = narrowedAt {
            if width >= at + 20 { narrowedAt = nil; inspectorItem.isCollapsed = false }   // a little past it, or it flaps
        } else if !inspectorItem.isCollapsed, editors.view.frame.width < 640 {
            narrowedAt = width; inspectorItem.isCollapsed = true
        }
    }

    @objc func toggleInspectorPanel() {
        narrowedAt = nil
        if focusMode != nil { return togglePeek(inspectorItem) }
        if autoHide.inspector { return togglePin(inspectorItem) }
        inspectorItem.animator().isCollapsed.toggle()
        UserDefaults.standard.set(inspectorItem.isCollapsed, forKey: "inspector.collapsed")
    }
    func showInspector(panel: String) {
        if inspectorItem.isCollapsed, peeking !== inspectorItem { if hides(inspectorItem) { peek(sidebar: false) } else { toggleInspectorPanel() } }
        inspector.show(panel: panel)
    }
    @objc func toggleSidebarPanel() {
        if focusMode != nil { togglePeek(sidebarItem) } else if autoHide.sidebar { togglePin(sidebarItem) } else { sidebarItem.animator().isCollapsed.toggle() }
    }
    var sidebarShown: Bool { !sidebarItem.isCollapsed || peeking === sidebarItem }
    var inspectorShown: Bool { !inspectorItem.isCollapsed || peeking === inspectorItem }

    /// Quitting: focus mode's panels come back first, or the split's autosave would start the next launch wrong.
    func leaveFocusMode() {
        stopPeek()
        guard let was = focusMode else { return }
        focusMode = nil
        place()
        sidebarItem.isCollapsed = was.sidebar; inspectorItem.isCollapsed = was.inspector
        sidebarToggle.isHidden = false; inspectorToggle.isHidden = false
    }

    @objc func toggleFocusMode() {
        stopPeek()
        if let was = focusMode {
            focusMode = nil; place()
            sidebarItem.animator().isCollapsed = was.sidebar; inspectorItem.animator().isCollapsed = was.inspector
        } else {
            focusMode = (sidebarItem.isCollapsed || hides(sidebarItem), inspectorItem.isCollapsed || hides(inspectorItem))
            place()   // before the columns close: the floaters take their widths
            sidebarItem.animator().isCollapsed = true; inspectorItem.animator().isCollapsed = true
        }
        let on = focusMode != nil
        sidebarToggle.isHidden = on; inspectorToggle.isHidden = on
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
            item.animator().isCollapsed = on
            if !sidebar { UserDefaults.standard.set(on, forKey: "inspector.collapsed") }
        }
    }
    private func hides(_ item: NSSplitViewItem) -> Bool {
        focusMode != nil || (item === sidebarItem ? autoHide.sidebar && !pinned.sidebar : autoHide.inspector && !pinned.inspector)
    }
    private func floater(_ item: NSSplitViewItem) -> Floater { item === sidebarItem ? leftFloat : rightFloat }

    /// Each panel where it belongs now: in its column, or in its floater while it hides. A panel leaving its open column
    /// for the floater keeps its width there.
    private func place() {
        for (item, panel, edge) in [(sidebarItem, sidebar.view, leftEdge), (inspectorItem, inspector.view, rightEdge)] {
            let hide = hides(item), f = floater(item), column = item.viewController.view
            edge.isHidden = !hide
            if hide, panel.superview !== f.box {
                if !item.isCollapsed, column.frame.width >= item.minimumThickness { f.width = column.frame.width }
                // The sidebar's cards run to its column's edge, the gap before the editor card being their margin there;
                // in the floater that edge is its border, so a margin goes inside it, as wide as the cards stand from the left (8).
                f.box.pin(panel, inset: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: item === sidebarItem ? Metrics.gapWide : 0))
            } else if !hide, panel.superview !== column {
                column.pin(panel)
            }
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
        peekMoves = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] e in self?.pointerMoved(e); return e }
    }
    private func pointerMoved(_ e: NSEvent) {
        guard let item = peeking, e.window === window, let root = window?.contentView else { return }
        let p = root.convert(e.locationInWindow, from: nil)
        let edge = item === sidebarItem ? leftEdge : rightEdge
        if Self.overPeek(p, panel: floater(item).frame, edge: edge.frame) { peekReached = true; return }
        // Not while it slides in: the panel isn't where the pointer is headed yet.
        if peekReached, Date().timeIntervalSince(peekedAt) > 0.4 { endPeek() }
    }
    /// Over a peeking panel: anywhere from the window's edge through it. The panel stands 6 pt in from the edge, past the
    /// 4 pt strip, and a slow move across that gap closed it under the pointer.
    static func overPeek(_ p: NSPoint, panel: NSRect, edge: NSRect) -> Bool { panel.union(edge).contains(p) }
    private func endPeek(animated: Bool = true) {
        if let m = peekMoves { NSEvent.removeMonitor(m); peekMoves = nil }
        guard let p = peeking else { return }
        peeking = nil
        floater(p).slide(in: false, animated: animated)
    }
    /// The panels change for good (focus mode, auto-hide switched, pinned): the peeking one goes at once.
    private func stopPeek() { endPeek(animated: false) }
    private func togglePeek(_ item: NSSplitViewItem) { if peeking === item { endPeek() } else { peek(sidebar: item === sidebarItem) } }
    /// Auto-hide: pinned, the panel stays in its column (a peeking one moves there); unpinned, it goes and comes in at
    /// the edge again.
    private func togglePin(_ item: NSSplitViewItem) {
        let pin = item === sidebarItem ? !pinned.sidebar : !pinned.inspector
        if item === sidebarItem { pinned.sidebar = pin } else { pinned.inspector = pin }
        if peeking === item { stopPeek() }
        place()
        item.animator().isCollapsed = !pin
    }

    /// Closing the window quits (the daemon keeps agents running) — through the unsaved-files question; Cancel keeps it.
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }
}
