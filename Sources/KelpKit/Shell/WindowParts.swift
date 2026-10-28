import AppKit
import SwiftUI
import Core
import DesignKit
import WorkbenchKit

/// The window's split: its dividers aren't drawn (the panels and the gap round the card are one surface), and each can
/// be dragged across that gap too, not only at the panel's edge.
@MainActor
final class ShellSplit: NSSplitViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
        let v = Seamless()
        v.isVertical = true
        v.dividerStyle = .thin
        splitView = v
    }
    required init?(coder: NSCoder) { fatalError() }
    override func splitView(_ v: NSSplitView, effectiveRect proposed: NSRect, forDrawnRect drawn: NSRect, ofDividerAt i: Int) -> NSRect {
        var r = super.splitView(v, effectiveRect: proposed, forDrawnRect: drawn, ofDividerAt: i)
        r.size.width += Card.gap; if i > 0 { r.origin.x -= Card.gap }   // into the gap, which is on the editor area's side
        return r
    }
    private final class Seamless: NSSplitView { override var dividerColor: NSColor { .clear } }
}

/// A hiding panel's place (auto-hide, focus mode): it holds the panel while it's away and, at the window's edge, brings
/// it in over the editor area, clear of the window's edges, with rounded corners and a shadow, as Arc's sidebar does.
@MainActor
final class Floater: NSView {
    private static let inset: CGFloat = 6, radius: CGFloat = 12
    /// The panel's background, the same material the window's surface is.
    let box = NSVisualEffectView()
    private var edge: NSLayoutConstraint?, widthC: NSLayoutConstraint?
    private var shown = false
    var width: CGFloat { didSet { widthC?.constant = width } }

    init(width: CGFloat) {
        self.width = width
        super.init(frame: .zero)
        isHidden = true; wantsLayer = true
        box.material = .sidebar
        box.blendingMode = .behindWindow
        box.state = .followsWindowActiveState
        box.wantsLayer = true
        box.layer?.cornerRadius = Self.radius
        box.layer?.cornerCurve = .continuous
        box.layer?.masksToBounds = true
        box.layer?.borderWidth = 1
        pin(box)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Against the window's leading or trailing edge, its full height; out of sight until it slides in.
    func attach(leading: Bool) {
        guard let s = superview else { return }
        let e = leading ? leadingAnchor.constraint(equalTo: s.leadingAnchor) : s.trailingAnchor.constraint(equalTo: trailingAnchor)
        let w = widthAnchor.constraint(equalToConstant: width)
        NSLayoutConstraint.activate([e, w, topAnchor.constraint(equalTo: s.topAnchor, constant: Self.inset),
                                     bottomAnchor.constraint(equalTo: s.bottomAnchor, constant: -Self.inset)])
        edge = e; widthC = w
    }

    func slide(in on: Bool, animated: Bool = true) {
        guard let edge, on != shown else { return }
        shown = on
        let away = -width - 2 * Self.inset - 20   // the shadow out of sight too
        if on, isHidden {
            edge.constant = away
            isHidden = false
            superview?.layoutSubtreeIfNeeded()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated ? Motion.duration(Motion.base) : 0
            ctx.timingFunction = CAMediaTimingFunction(name: on ? .easeOut : .easeIn)
            edge.animator().constant = on ? Self.inset : away
        } completionHandler: { [weak self] in   // on main
            MainActor.assumeIsolated { if let self, !self.shown { self.isHidden = true } }
        }
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.shadowColor = NSColor.shadowColor.cgColor
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = 14
        layer?.shadowOffset = .zero
    }
    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
    }
}

/// The editor area's card: rounded, a hairline round it, in from the panels and the window's edges, so the panels and
/// the window bar read as one surface round it.
@MainActor
final class Card: NSView {
    static let gap: CGFloat = 6
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor; layer?.borderColor = NSColor.separatorColor.cgColor }
}

extension NSButton {
    /// An icon button for the title bar: 14 pt, greyed in under the pointer like every Kelp control.
    static func titlebar(_ symbol: String, _ label: String, tip: String) -> NSButton {
        let b = PointerButton(frame: .zero)   // greys in under the pointer, springs when clicked, as every Kelp control
        b.image = .symbol(symbol, label)
        b.imagePosition = .imageOnly
        b.toolTip = tip
        b.symbolConfiguration = .init(pointSize: 14, weight: Metrics.iconWeight)
        return b
    }
}

/// A strip at the window's edge that reports the pointer arriving (focus mode's way back to the panels).
@MainActor
final class EdgeTrigger: NSView {
    var onEnter: (() -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { onEnter?() }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }   // clicks go to whatever is under it
}

/// The window's surface, in the sidebar's material: the panels and the gap round the editor area are this.
/// Files and folders dropped where nothing else takes them (the empty workspace, the window bar, the inspector): as if
/// dropped on the Dock icon.
@MainActor
final class DropRoot: NSVisualEffectView {
    private let app: AppModel
    init(app: AppModel) {
        self.app = app
        super.init(frame: .zero)
        material = .sidebar
        blendingMode = .behindWindow
        state = .followsWindowActiveState
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { Workbench.files(s).isEmpty ? [] : .copy }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        let files = Workbench.files(s)
        app.workbench.open(files: files); return !files.isEmpty
    }
}

/// Holds one editor area per recently used workspace, so switching back is instant (terminals stay attached).
@MainActor
final class EditorHost: NSViewController {
    let app: AppModel
    init(app: AppModel) { self.app = app; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    /// The editor area (or the welcome) is in this card, under the window bar, which lies over this view's top.
    private let card = Card()
    private var areas: [String: EditorArea] = [:]
    private var recent: [String] = []
    private(set) var current: EditorArea?
    var editedFiles: [SavableTab] { areas.values.flatMap(\.editedFiles) }
    func editedFiles(in ids: [String]) -> [SavableTab] { ids.compactMap { areas[$0] }.flatMap(\.editedFiles) }
    private var welcome: NSView?
    private static let keep = 4

    override func loadView() {
        let app = self.app
        view = NSView()
        view.pin(card, inset: NSEdgeInsets(top: WindowBar.height, left: Card.gap, bottom: Card.gap, right: Card.gap))
        showWelcome()
        // Daemon state: workspaces that are gone leave; sessions' tabs come and show their status and context ring.
        track { app.repos } changed: { [weak self] _ in self?.refresh() }
        track { app.worktrees } changed: { [weak self] _ in self?.refresh() }
        track { app.sessions } changed: { [weak self] _ in self?.refresh() }
        track { app.contextUsage } changed: { [weak self] _ in self?.refresh() }
    }

    func show(_ id: String?) {
        if let c = current, c.workspaceId == id { return }
        current?.view.removeFromSuperview()
        guard let id, app.worktree(id) != nil else {
            current = nil
            showWelcome()
            return
        }
        welcome?.removeFromSuperview(); welcome = nil
        let area = areas[id] ?? EditorArea(app: app, workspaceId: id)
        if areas[id] == nil { areas[id] = area; addChild(area) }
        recent.removeAll { $0 == id }; recent.insert(id, at: 0)
        // Their terminals detach.
        let gone: [String]
        (recent, gone) = Self.evicting(recent, keep: Self.keep) { self.areas[$0]?.editedFiles.isEmpty == false }
        for old in gone { areas[old]?.removeFromParent(); areas[old] = nil }
        current = area
        card.pin(area.view)
        area.reconcile()
        area.focusSelected()
    }

    /// The areas past the newest `keep` go, except those with unsaved files: they stay listed, and go on a later switch
    /// once saved (dropped from the list, one would stay loaded, and its terminal attached, until shown again).
    static func evicting(_ recent: [String], keep: Int, edited: (String) -> Bool) -> (recent: [String], gone: [String]) {
        let gone = recent.dropFirst(keep).filter { !edited($0) }
        return (recent.filter { !gone.contains($0) }, gone)
    }

    /// A tab for a workspace that isn't on screen: into its editor area if it's loaded, else into its saved layout.
    func openInBackground(_ uri: String, workspace id: String) {
        if let a = areas[id] { a.open(uri, focus: false); return }
        var l = WorkspaceLayout.load(id, from: app.uiState)
        if l.tab(uri: uri) == nil { _ = l.add(uri, to: l.focusedGroup?.id); l.save(id, to: app.uiState) }
    }

    /// A restarted session into its old tab in a workspace that isn't on screen, the same two ways.
    func replaceInBackground(_ old: String, with new: String, workspace id: String) {
        if let a = areas[id] { a.replace(old, with: new, focus: false); return }
        var l = WorkspaceLayout.load(id, from: app.uiState)
        if l.replace(old, with: new) == nil, l.tab(uri: new) == nil { l.add(new, to: l.focusedGroup?.id) }
        l.save(id, to: app.uiState)
    }

    private func refresh() {
        for (id, a) in areas where app.worktree(id) == nil {
            a.view.removeFromSuperview()
            areas[id] = nil
            recent.removeAll { $0 == id }
            // Closed from elsewhere (the CLI, an agent): unsaved files still get their question, only without Cancel.
            let edited = a.editedFiles
            guard !edited.isEmpty else { a.removeFromParent(); continue }
            Task {
                let answer = await runSheet(UnsavedChanges.alert(edited, quitting: false, canCancel: false))
                if await UnsavedChanges.settle(edited, answer, canCancel: false) { _ = await UnsavedChanges.written(edited) }
                a.removeFromParent()
            }
        }
        if let c = current, areas[c.workspaceId] == nil { current = nil; showWelcome() }
        current?.reconcile()   // the others reconcile when shown
        if current == nil { showWelcome() }
    }

    private func showWelcome() {
        let hasRepos = app.repos.contains { !ScratchWindow.isScratch($0) }
        if let w = welcome as? WelcomeView, w.hasRepos == hasRepos { return }
        welcome?.removeFromSuperview()
        let w = WelcomeView(hasRepos: hasRepos, app: app)
        card.pin(w)
        welcome = w
    }
}

/// No workspace selected: first-run guidance.
@MainActor
final class WelcomeView: NSView {
    let hasRepos: Bool
    init(hasRepos: Bool, app: AppModel) {
        self.hasRepos = hasRepos
        super.init(frame: .zero)
        let icon = NSImageView(image: .symbol(hasRepos ? "sidebar.left" : "folder.badge.plus"))
        icon.symbolConfiguration = .init(pointSize: 40, weight: .light); icon.contentTintColor = .tertiaryLabelColor
        let title = NSTextField(labelWithString: hasRepos ? String(localized: "Select a workspace") : String(localized: "Welcome to Kelp"))
        title.font = .ui(20, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: hasRepos
            ? String(localized: "Pick a workspace in the sidebar, or press ⌘N for a new one — a clean desk in the project for one task and its agents.")
            : String(localized: "Add a project folder. Each task gets its own workspace: agents, terminals and files side by side."))
        body.alignment = .center; body.textColor = .secondaryLabelColor
        let button = ClosureButton(title: hasRepos ? String(localized: "New Workspace") : String(localized: "Add Project…")) { [app] in
            hasRepos ? app.workbench.newWorkspace() : app.workbench.addProject()
        }
        button.bezelStyle = .push
        button.keyEquivalent = "\r"
        button.controlSize = .large
        let stack = NSStackView(views: [icon, title, body, button])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.setCustomSpacing(18, after: body)
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor),
                                     stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -30),
                                     body.widthAnchor.constraint(equalToConstant: 420)])
    }
    required init?(coder: NSCoder) { fatalError() }
}
