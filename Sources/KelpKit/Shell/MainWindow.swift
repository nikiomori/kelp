import AppKit
import Core
import DesignKit
import SwiftUI
import TerminalKit

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
    /// The sidebar's side and the inspector's.
    private let left: Side, right: Side
    private var sides: [Side] { [left, right] }
    private var dockWatch: NSKeyValueObservation?
    /// Focus mode (⌃⌘Z): both panels away; they slide in while the pointer is at the window's edge.
    private(set) var inFocusMode = false {
        didSet { app.workbench.inFocusMode = inFocusMode }
    }
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
        left = Side(Self.column(sidebar), sidebar, Floater(width: 260, inset: 0), inner: .trailing)
        right = Side(Self.column(inspector), inspector, Floater(width: 300, inset: Card.gap), inner: .leading)
        surface = DropRoot(app: app)
        super.init(window: created)
        app.workbench.window = self   // what acts on the window reaches it there
        // The title stays set: the Window menu, Mission Control and VoiceOver read it.
        created.titlebarAppearsTransparent = true
        created.titleVisibility = .hidden
        created.titlebarSeparatorStyle = .none
        left.item.minimumThickness = 220
        left.item.maximumThickness = 400
        let content = NSSplitViewItem(viewController: editors)
        content.minimumThickness = 420
        right.item.minimumThickness = 250
        right.item.maximumThickness = 520
        right.item.isCollapsed = UserDefaults.standard.bool(forKey: "inspector.collapsed")
        [left.item, content, right.item].forEach(split.addSplitViewItem)
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
        let parts = [
            bar, left.floater, inspectorToggle, right.floater, updatePill, sidebarToggle, left.edge, right.edge
        ]
        for part in parts {
            part.translatesAutoresizingMaskIntoConstraints = false
            root.view.addSubview(part)
        }
        left.floater.attach(leading: true)
        right.floater.attach(leading: false)
        for side in sides { side.edge.onEnter = { [weak self, unowned side] in self?.peek(side) } }
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
            left.edge.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            left.edge.widthAnchor.constraint(equalToConstant: 4),
            left.edge.topAnchor.constraint(equalTo: bar.bottomAnchor),
            left.edge.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
            right.edge.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            right.edge.widthAnchor.constraint(equalToConstant: 4),
            right.edge.topAnchor.constraint(equalTo: bar.bottomAnchor),
            right.edge.bottomAnchor.constraint(equalTo: root.view.bottomAnchor)
        ])
        created.contentViewController = root
        watchDock()
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
            self?.sides.forEach { $0.floater.show(look) }
        }
        let autoHides = [
            (left, sidebarToggle, SettingKeys.sidebarAutoHide, String(localized: "Auto-Hide Sidebar")),
            (right, inspectorToggle, SettingKeys.inspectorAutoHide, String(localized: "Auto-Hide Inspector"))
        ]
        for (side, toggle, setting, title) in autoHides {
            track {
                app.settings[setting]
            } changed: { [weak self, unowned side] in
                self?.setAutoHide(side, $0)
                toggle.menu = self?.autoHideMenu(title, setting, $0)
            }
        }
    }
    /// Workbench says whether the inspector is docked, however its column opens or closes (a toggle, focus mode, a narrow
    /// window, its divider dragged shut).
    private func watchDock() {
        dockWatch = right.item.observe(\.isCollapsed, options: [.initial, .new]) { [weak app] item, _ in
            let docked = !item.isCollapsed
            MainActor.assumeIsolated { app?.workbench.inspectorDocked = docked }   // AppKit sets it on the main thread
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
        guard !inFocusMode, !right.autoHide, let width = window?.frame.width else { return }
        if let at = narrowedAt {
            if width >= at + 20 {
                narrowedAt = nil
                right.item.isCollapsed = false
            }   // a little past it, or it flaps
        } else if !right.item.isCollapsed, editors.view.frame.width < 640 {
            narrowedAt = width
            right.item.isCollapsed = true
        }
    }

    @objc func toggleInspectorPanel() {
        narrowedAt = nil
        if inFocusMode { return togglePeek(right) }
        if right.autoHide { return togglePin(right) }
        let collapsed = !right.item.isCollapsed
        slide([(right, collapsed)])
        UserDefaults.standard.set(collapsed, forKey: "inspector.collapsed")
    }
    func showInspector(panel: String) {
        if right.item.isCollapsed, peeking !== right {
            if hides(right) { peek(right) } else { toggleInspectorPanel() }
        }
        inspector.show(panel: panel)
    }
    @objc func toggleSidebarPanel() {
        if inFocusMode { return togglePeek(left) }
        if left.autoHide { return togglePin(left) }
        slide([(left, !left.item.isCollapsed)])
    }
    var sidebarShown: Bool { !left.item.isCollapsed || peeking === left }
    var inspectorShown: Bool { !right.item.isCollapsed || peeking === right }

    /// Quitting: focus mode's panels come back first, or the split's autosave would start the next launch wrong.
    func leaveFocusMode() {
        stopPeek()
        guard inFocusMode else { return }
        inFocusMode = false
        place()
        sides.forEach { $0.item.isCollapsed = $0.closedBefore }
        for toggle in [sidebarToggle, inspectorToggle] {
            toggle.isHidden = false
            toggle.alphaValue = 1
        }
    }

    @objc func toggleFocusMode() {
        stopPeek()
        if inFocusMode {
            inFocusMode = false
            land(sides.map { ($0, $0.closedBefore) })
        } else {
            sides.forEach { $0.closedBefore = $0.item.isCollapsed || hides($0) }
            inFocusMode = true
            // The panels go to their floaters once the columns have closed over them: moved first, they vanished and
            // two empty columns slid shut.
            floatWidths()
            slide(sides.map { ($0, true) }) { [weak self] in self?.place() }
        }
        for toggle in [sidebarToggle, inspectorToggle] { fade(toggle, hidden: inFocusMode) }
    }
    /// A window bar's button goes or comes with the panels moving beside it, not in a frame.
    private func fade(_ button: NSView, hidden: Bool) {
        if !hidden { button.isHidden = false }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.duration(Motion.base)
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            button.animator().alphaValue = hidden ? 0 : 1
        } completionHandler: {
            MainActor.assumeIsolated { if button.alphaValue == 0 { button.isHidden = true } }   // AppKit: on main
        }
    }

    private func setAutoHide(_ side: Side, _ on: Bool) {
        guard on != side.autoHide else { return }   // the first, unloaded read keeps the saved layout
        side.autoHide = on
        side.pinned = false
        if inFocusMode { side.closedBefore = on }
        if peeking === side { stopPeek() }
        guard !inFocusMode else { return place() }
        if on {
            floatWidths()
            slide([(side, true)]) { [weak self] in self?.place() }   // as focus mode: the column closes over it first
        } else {
            land([(side, false)])
        }
        if side === right { UserDefaults.standard.set(on, forKey: "inspector.collapsed") }
    }
    /// Columns open or close together as a floater slides, and at once under Reduce Motion. The terminals beside them
    /// keep their size until the columns stop: a program in one would redraw for every width on the way.
    /// `then`: once they stand, at once when nothing moves.
    private func slide(_ columns: [(side: Side, collapsed: Bool)], then: (@MainActor () -> Void)? = nil) {
        let moves = columns.filter { $0.side.item.isCollapsed != $0.collapsed }
        guard !moves.isEmpty else {
            then?()
            return
        }
        // Its row is going, and with it the pointer's way out.
        if moves.contains(where: { $0.side === left && $0.collapsed }) { sidebar.card.close() }
        guard !Motion.reduced else {
            moves.forEach { $0.side.item.isCollapsed = $0.collapsed }
            then?()
            return
        }
        GhosttyTerminalView.holdSize(true)
        moves.forEach { $0.side.holdWidth(closing: $0.collapsed) }
        // The side that stays is the one whose panel isn't moving; with both moving, what's shown travels with the left.
        editors.holdWidth(trailing: !moves.contains { $0.side === right })
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.base
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            moves.forEach { $0.side.item.animator().isCollapsed = $0.collapsed }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {   // AppKit runs it on the main thread
                self?.editors.letWidthGo()
                self?.sides.forEach { $0.letWidthGo() }
                // Laid out before the terminals take their size: they take the final one, once.
                self?.window?.contentView?.layoutSubtreeIfNeeded()
                GhosttyTerminalView.holdSize(false)
                then?()
            }
        }
    }

    private func hides(_ side: Side) -> Bool { inFocusMode || side.autoHide && !side.pinned }

    /// Each panel where it belongs now: in its column, or in its floater while it hides. A panel leaving its open column
    /// for the floater keeps its width there.
    /// A floater is as wide as its column was: read while the column is still open.
    private func floatWidths() {
        for side in sides where !side.item.isCollapsed {
            let wide = side.column.frame.width
            if wide >= side.item.minimumThickness { side.floater.width = wide }
        }
    }
    private func place() {
        for side in sides {
            let hide = hides(side), floating = side.floater, column = side.column, panel = side.panel
            side.edge.isHidden = !hide
            if hide, panel.superview !== floating.box {
                if !side.item.isCollapsed, column.frame.width >= side.item.minimumThickness {
                    floating.width = column.frame.width
                }
                floating.box.pin(panel)
            } else if !hide, panel.superview !== column {
                column.pin(panel)
            }
        }
        // The sidebar's cards run to its column's edge, the gap before the editor card being their margin there; in the
        // floater that edge is its border, so a margin goes inside it, as wide as the cards stand from the left (8), and
        // the scroller's knob runs in it.
        sidebar.gutter = hides(left) ? Metrics.gapWide : 0
    }

    /// Focus mode and auto-hide: the pointer at an edge brings that panel in over the editor area (which keeps its size:
    /// terminals aren't resized, nothing reflows); once the pointer leaves the panel for the rest of the window, the
    /// panel goes again. In focus mode ⌘0 / ⌥⌘0 bring it in the same way; with auto-hide they pin it.
    private var peeking: Side?
    private var peekMoves: Any?, peekedAt = Date.distantPast
    /// The pointer has been over the panel since it came in (from the edge at once; after ⌘0, once it gets there).
    private var peekReached = false
    private func peek(_ side: Side) {
        guard hides(side), peeking !== side else { return }
        endPeek()
        peeking = side
        peekedAt = Date()
        peekReached = false
        side.floater.slide(in: true)
        window?.acceptsMouseMovedEvents = true
        peekMoves = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.pointerMoved(event)
            return event
        }
    }
    private func pointerMoved(_ event: NSEvent) {
        guard let side = peeking, event.window === window, let root = window?.contentView else { return }
        let point = root.convert(event.locationInWindow, from: nil)
        if Self.overPeek(point, panel: side.floater.frame, edge: side.edge.frame) {
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
        guard let side = peeking else { return }
        peeking = nil
        side.floater.slide(in: false, animated: animated)
    }
    /// The panels change for good (focus mode, auto-hide switched, pinned): the peeking one goes at once.
    private func stopPeek() { endPeek(animated: false) }
    private func togglePeek(_ side: Side) {
        if peeking === side { endPeek() } else { peek(side) }
    }
    /// Auto-hide: pinned, the panel stays in its column (a peeking one moves there); unpinned, it goes and comes in at
    /// the edge again.
    private func togglePin(_ side: Side) {
        side.pinned.toggle()
        if side.pinned { return land([(side, false)]) }
        if peeking === side { stopPeek() }
        floatWidths()
        slide([(side, true)]) { [weak self] in self?.place() }
    }

    /// Columns open for panels that no longer hide. A panel in its floater comes in there (or stays, peeking) over its
    /// opening column and is put in the column once that stands: moving a panel takes the main thread some 40 ms, and
    /// moved first, that was a wait between the key and anything happening.
    private func land(_ columns: [(side: Side, collapsed: Bool)]) {
        for (side, collapsed) in columns where !collapsed && !hides(side) {
            guard side.panel.superview === side.floater.box else { continue }
            if peeking === side {   // it stays where it stands; nothing watches the pointer for it any more
                if let monitor = peekMoves { NSEvent.removeMonitor(monitor) }
                peekMoves = nil
                peeking = nil
            } else {
                side.floater.slide(in: true)
            }
        }
        slide(columns) { [weak self] in
            guard let self else { return }
            for side in sides where !hides(side) {
                side.floater.slide(in: false, animated: false)
            }
            place()
        }
    }

    /// Closing the window quits (the daemon keeps agents running) — through the unsaved-files question; Cancel keeps it.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }
}

/// A panel beside the editor area (the sidebar, the inspector): its column, the floater it hides in, the edge strip
/// that brings it in, and what keeps it away.
@MainActor
private final class Side {
    let item: NSSplitViewItem, controller: NSViewController, floater: Floater
    let edge = EdgeTrigger()
    /// The panel's side beside the editor area, which lets go while its column slides.
    let inner: NSLayoutConstraint.Attribute
    /// Settings › Appearance › Auto-hide: the panel stays away as in focus mode, for good.
    var autoHide = false
    /// Auto-hidden, the toggle (⌘0 / ⌥⌘0) pinned it: it stays in like a normal panel until it's pressed again.
    var pinned = false
    /// Its column was closed (or it hid) before focus mode: put back on leaving.
    var closedBefore = false
    private var openWidth: CGFloat = 0
    private var held: WidthHold?

    init(
        _ item: NSSplitViewItem, _ controller: NSViewController, _ floater: Floater, inner: NSLayoutConstraint.Attribute
    ) {
        self.item = item
        self.controller = controller
        self.floater = floater
        self.inner = inner
        edge.isHidden = true
    }
    var panel: NSView { controller.view }
    var column: NSView { item.viewController.view }

    /// While its column slides, the panel keeps the width it has open, the column uncovering or covering it. Laid out
    /// for every width on the way, a sidebar's rows dropped and took back their badges and a panel's lines rewrapped.
    func holdWidth(closing: Bool) {
        guard panel.superview === column, held == nil else { return }
        if closing { openWidth = panel.frame.width }
        // The edge beside the editor area lets go; the window's side keeps the panel in place.
        guard openWidth > 0, let hold = WidthHold(panel, in: column, edge: inner, width: openWidth) else { return }
        column.clipsToBounds = true
        held = hold
    }
    func letWidthGo() {
        guard let held else { return }
        held.release()
        column.clipsToBounds = false
        self.held = nil
    }
}
