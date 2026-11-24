import AppKit
import Core
import DesignKit
import SwiftUI
import TerminalKit

/// The main window, built as Arc and Safari build theirs. One surface wraps around the editor area, which is a card
/// with rounded corners. The surface holds the sidebar with the projects and agents (where the traffic lights sit),
/// the window bar (which shows where you are and holds ⌘P), and the inspector. The first rows of the panels (search,
/// panel icons) line up with the card's tab strips. An auto-hidden panel (and a panel in focus mode) comes in over the
/// card instead, floating clear of the window's edges.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    /// The app this window shows. It is handed to the window's panels and editor areas.
    let app: AppModel
    let editors: EditorHost
    let inspector: InspectorController
    let sidebar: SidebarController
    let split = ShellSplit()
    private let surface: DropRoot
    /// The sidebar's side and the inspector's side of the window.
    let left: Side, right: Side
    var sides: [Side] { [left, right] }
    private var dockWatch: NSKeyValueObservation?
    /// Focus mode (⌃⌘Z) puts both panels away. They slide in while the pointer is at the window's edge.
    private(set) var inFocusMode = false {
        didSet { app.workbench.inFocusMode = inFocusMode }
    }
    lazy var bar = WindowBar(app: app)
    private lazy var updatePill = UpdatePill(app: app)
    /// While the update pill shows, the sidebar's toggle stays clear of it (a hidden view still holds constraints).
    private lazy var clearOfPill = sidebarToggle.leadingAnchor.constraint(
        greaterThanOrEqualTo: updatePill.trailingAnchor, constant: Metrics.gap)
    /// Where the sidebar's toggle may start: after the traffic lights, or at the window's edge where they stood while
    /// the sidebar is put away (`followLights`). The toggle follows the sidebar's column as it opens and closes, and
    /// the workspace's name follows the toggle, so both move once, with the column, and never while the sidebar only
    /// slides in at the edge.
    var toggleFloor: NSLayoutConstraint?
    /// Where the update pill starts: on the same floor as the toggle, so with the sidebar away it stands at the
    /// window's edge too, and the toggle and the name after it.
    var pillFloor: NSLayoutConstraint?
    /// The traffic lights' right end and left start, in the window.
    var lightsEnd: CGFloat = 69, lightsStart: CGFloat = 12
    /// The panel toggles stay fixed in the window bar's corners, whichever panels are open.
    let sidebarToggle = NSButton.titlebar(
        "sidebar.left", String(localized: "Sidebar"), tip: String(localized: "Show or hide the sidebar"))
    private let inspectorToggle = NSButton.titlebar(
        "sidebar.trailing", String(localized: "Inspector"), tip: String(localized: "Show or hide the inspector"))

    init(app: AppModel) {
        let created = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered,
            defer: false)
        self.app = app
        editors = EditorHost(app: app)
        sidebar = SidebarController(app: app)
        inspector = InspectorController(app: app)
        // Both stand as far in from the window's edges, as cards (the sidebar's was flush, under the traffic lights).
        let leftFloater = Floater(width: 260, inset: Card.gap, autosave: "sidebar.floatWidth")
        let rightFloater = Floater(width: 300, inset: Card.gap, autosave: "inspector.floatWidth")
        left = Side(Self.column(sidebar), sidebar, leftFloater, inner: .trailing)
        right = Side(Self.column(inspector), inspector, rightFloater, inner: .leading)
        surface = DropRoot(app: app)
        super.init(window: created)
        app.workbench.window = self   // whatever acts on the window reaches it through the workbench
        // The title stays set, because the Window menu, Mission Control and VoiceOver read it.
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
        wireToggles()
        root.view.pin(split.view)
        // The toggles go under their floaters: the inspector's stood half on its floater's border, and the sidebar's,
        // at the window's edge while the sidebar is away, would stand on the traffic lights of a sidebar sliding in,
        // which covers it as Dia's does. The update pill stands there too, so it goes under as well.
        let parts = [
            bar, sidebarToggle, updatePill, left.floater, inspectorToggle, right.floater, left.edge, right.edge
        ]
        for part in parts {
            part.translatesAutoresizingMaskIntoConstraints = false
            root.view.addSubview(part)
        }
        left.floater.attach(leading: true)
        right.floater.attach(leading: false)
        for side in sides { side.edge.onEnter = { [weak self, unowned side] in self?.peek(side) } }
        let lights = measureLights(created)
        let floor = sidebarToggle.leadingAnchor.constraint(
            greaterThanOrEqualTo: root.view.leadingAnchor, constant: lights + 12)
        toggleFloor = floor
        let pillFloor = updatePill.leadingAnchor.constraint(equalTo: root.view.leadingAnchor, constant: lights + 12)
        self.pillFloor = pillFloor
        // The bar lies over the editor area only, because the sidebar and the inspector both run the window's full
        // height. With the sidebar away, the bar runs under the traffic lights. With the inspector away, it runs under
        // the inspector's toggle.
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.view.topAnchor),
            bar.heightAnchor.constraint(equalToConstant: WindowBar.height),
            bar.leadingAnchor.constraint(equalTo: editors.view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: editors.view.trailingAnchor),
            // The bar is as tall as the title bar, so the traffic lights and the toggles share a centre line. The
            // sidebar's toggle is in the sidebar's top right corner, or after the traffic lights while the sidebar is
            // away.
            floor,
            sidebarToggle.trailingAnchor.constraint(equalTo: editors.view.leadingAnchor, constant: -8).withPriority(
                600),
            sidebarToggle.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            pillFloor,
            updatePill.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            // The workspace's name starts over the editor area, or after the sidebar's toggle while the sidebar is
            // away.
            bar.context.leadingAnchor.constraint(greaterThanOrEqualTo: sidebarToggle.trailingAnchor, constant: 12),
            bar.context.leadingAnchor.constraint(equalTo: editors.view.leadingAnchor, constant: 12).withPriority(700),
            inspectorToggle.trailingAnchor.constraint(equalTo: root.view.trailingAnchor, constant: -10),
            inspectorToggle.centerYAnchor.constraint(equalTo: sidebarToggle.centerYAnchor),
            left.edge.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            left.edge.widthAnchor.constraint(equalToConstant: 4),
            // From the window's top: with the sidebar away, its corner is where the traffic lights were.
            left.edge.topAnchor.constraint(equalTo: root.view.topAnchor),
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
        track(owner: self) {
            app.worktree(app.workbench.mainWorkspaceId)
        } changed: { [weak self] _ in
            self?.updateTitle()
        }
        followPill(app)
        track(owner: self) {
            app.themes.look
        } changed: { [weak self] look in
            self?.surface.show(look)
            self?.sides.forEach { $0.floater.show(look) }
        }
        // Each panel's button itself switches its auto-hide (decision 109): no menu or setting row for the same thing.
        for (side, setting) in [(left, SettingKeys.sidebarAutoHide), (right, SettingKeys.inspectorAutoHide)] {
            track(owner: self) {
                app.settings[setting]
            } changed: { [weak self, unowned side] in
                self?.setAutoHide(side, $0)
            }
        }
    }
    /// Keeps Workbench told whether the inspector is docked, however its column opens or closes (a toggle, focus mode,
    /// a narrow window, or its divider dragged shut).
    /// The two side toggles act on this window, and each one's tooltip names its command's key as it stands.
    private func wireToggles() {
        sidebarToggle.target = self
        sidebarToggle.action = #selector(toggleSidebarPanel)
        inspectorToggle.target = self
        inspectorToggle.action = #selector(toggleInspectorPanel)
        sidebarToggle.toolTip = app.extensions.hint(sidebarToggle.toolTip ?? "", "workbench.toggleSidebar")
        inspectorToggle.toolTip = app.extensions.hint(inspectorToggle.toolTip ?? "", "workbench.toggleInspector")
    }

    private func watchDock() {
        dockWatch = right.item.observe(\.isCollapsed, options: [.initial, .new]) { [weak app] item, _ in
            let docked = !item.isCollapsed
            MainActor.assumeIsolated { app?.workbench.inspectorDocked = docked }   // AppKit sets it on the main thread
        }
    }
    /// Makes a panel's column. It holds the panel while the panel is docked. While the panel hides (auto-hide, focus
    /// mode), the panel is in its floater and the column stays collapsed.
    private static func column(_ panel: NSViewController) -> NSSplitViewItem {
        let slot = NSViewController()
        slot.view = NSView()
        slot.addChild(panel)
        slot.view.pin(panel.view)
        let item = NSSplitViewItem(viewController: slot)
        // Not by dragging its divider shut: a panel is in its column or away at its edge (its button), never just
        // gone. Kelp still closes the column itself (auto-hide, focus mode, a narrow window).
        item.canCollapse = false
        item.holdingPriority = .init(260)   // a resized window widens the editor area, not the panels
        return item
    }
    /// Makes room for the update pill while an update is ready.
    private func followPill(_ app: AppModel) {
        track(owner: self) {
            app.updates.ready != nil
        } changed: { [weak self] in
            self?.makeRoom(forPill: $0)
        }
    }
    /// Moves the sidebar's toggle and the workspace's name over for the update pill, or back once it's gone.
    private func makeRoom(forPill shown: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.duration(shown ? Motion.base : Motion.fast)
            ctx.timingFunction = CAMediaTimingFunction(name: shown ? .easeOut : .easeIn)
            ctx.allowsImplicitAnimation = true
            clearOfPill.isActive = shown
            window?.contentView?.layoutSubtreeIfNeeded()
        }
    }
    /// Notes where the traffic lights start and end in `window`, and returns their end.
    private func measureLights(_ window: NSWindow) -> CGFloat {
        let edge = { (type: NSWindow.ButtonType, side: (NSRect) -> CGFloat) in
            window.standardWindowButton(type).map { side($0.convert($0.bounds, to: nil)) }
        }
        lightsEnd = edge(.zoomButton, \.maxX) ?? 69
        lightsStart = edge(.closeButton, \.minX) ?? 12
        return lightsEnd
    }
    required init?(coder: NSCoder) { fatalError() }

    func showWorkspace(_ id: String?) {
        editors.show(id)
        updateTitle()
        app.publishUIState()
    }

    /// Shows a page over the whole editor area (`Workbench.page`). Returns false when no extension makes it.
    func showPage(_ uri: String) -> Bool {
        guard let page = editors.showPage(uri) else { return false }
        window?.title = page.title
        app.publishUIState()
        return true
    }

    private func updateTitle() {
        let worktree = app.worktree(app.workbench.mainWorkspaceId)
        window?.title = app.groupName(worktree) ?? app.projectName(worktree?.repoId) ?? String(localized: "Kelp")
        editors.current?.showEdited()   // a workspace with unsaved files keeps saying so after a switch
    }

    /// When the window is narrowed until the editor would have less than 640 pt, the inspector steps aside, and it
    /// comes back once the window has room again, as Mail's sidebar does (at 1000 pt the two side columns had half the
    /// window). This isn't saved, but opening or closing the inspector yourself is (`inspector.collapsed`). The split's
    /// own collapse-on-resize only acts on live resizes.
    private var narrowedAt: CGFloat?
    /// The last slide of the side columns (`slide`): only its end lets the widths it held go.
    var slideTurn = 0

    /// In focus mode and with auto-hide, the pointer at an edge brings that side's panel in over the editor area. The
    /// editor area keeps its size, so terminals aren't resized and nothing reflows. Once the pointer leaves the panel
    /// for the rest of the window, the panel goes again. In focus mode ⌘0 / ⌥⌘0 bring the panel in the same way, and
    /// with auto-hide they pin it.
    var peeking: Side?
    var peekMoves: Any?, peekedAt = Date.distantPast
    /// True once the pointer has been over the panel since the panel came in (at once when it came from the edge, and
    /// after ⌘0 once the pointer gets there).
    var peekReached = false
    func windowDidResize(_ notification: Notification) {
        guard !inFocusMode, !right.autoHide, let width = window?.frame.width else { return }
        if let at = narrowedAt {
            if width >= at + 20 {
                narrowedAt = nil
                right.item.isCollapsed = false
            }   // back only 20 pt past where it stepped aside, or it flaps
        } else if !right.item.isCollapsed, editors.view.frame.width < 640 {
            narrowedAt = width
            right.openWidth = right.column.frame.width
            right.item.isCollapsed = true
        }
    }

    /// The inspector's button and ⌥⌘0 do as the sidebar's do (`toggleSidebarPanel`): a panel is either in its column or
    /// away at the window's edge, where it comes in under the pointer. One closed by an older Kelp, or by a narrow
    /// window, opens first.
    @objc func toggleInspectorPanel() {
        narrowedAt = nil
        if inFocusMode { return togglePeek(right) }
        if !right.autoHide, right.item.isCollapsed {
            UserDefaults.standard.set(false, forKey: "inspector.collapsed")   // as an older Kelp left it
            return slide([(right, false)])
        }
        app.settings.set(SettingKeys.inspectorAutoHide, !right.autoHide)
    }
    func showInspector(panel: String, keys: Bool = false) {
        if right.item.isCollapsed, peeking !== right {
            if hides(right) { peek(right) } else { toggleInspectorPanel() }
        }
        inspector.show(panel: panel, keys: keys)
    }
    /// The sidebar button and ⌘0 put the sidebar away so that it still comes in at the window's left edge, as Dia's
    /// does (decision 109): hidden and auto-hide are one state, the setting, not two ways to the same thing. A sidebar
    /// left collapsed by an older Kelp opens first. The inspector does the same at the right edge.
    @objc func toggleSidebarPanel() {
        if inFocusMode { return togglePeek(left) }
        if !left.autoHide, left.item.isCollapsed { return slide([(left, false)]) }
        app.settings.set(SettingKeys.sidebarAutoHide, !left.autoHide)
    }
    /// Whether View's item hides the sidebar, by what choosing it does: a sidebar put away that peeks gets docked by
    /// it, so it says Show (`toggleSidebarPanel`).
    var sidebarShown: Bool { inFocusMode ? peeking === left : !left.autoHide && !left.item.isCollapsed }
    var inspectorShown: Bool { inFocusMode ? peeking === right : !right.autoHide && !right.item.isCollapsed }

    /// Leaves focus mode when quitting, so the panels come back first. Otherwise the split's autosave would start the
    /// next launch wrong.
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
            // The panels go to their floaters once the columns have closed over them. When they moved first, they
            // vanished and two empty columns slid shut.
            floatWidths()
            slide(sides.map { ($0, true) }) { [weak self] in self?.place() }
        }
        fade(inspectorToggle, hidden: inFocusMode)   // the sidebar's stays, at the window's edge (`followLights`)
        followLights()
    }
    func windowDidBecomeKey(_ notification: Notification) { app.workbench.mainWindowBecameKey() }

    /// Closing the window quits the app (the daemon keeps agents running), after the unsaved-files question. Cancel
    /// keeps the window open.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }
}
