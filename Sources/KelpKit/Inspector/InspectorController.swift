import AppKit
import SwiftUI
import Core
import DesignKit

/// Right side: a row of panel icons (from extensions) over the selected panel — a scope bar like Mail's and Finder's:
/// plain icons, the selected one on the grey of a chosen row, in a glass capsule on macOS 26. The row sits in the
/// inspector's top band beside the window's inspector toggle, as Xcode's do, or in a bar under the panel. Icons are
/// dragged into order; a right-click on the row hides them and moves the row. Icons that don't fit go into a » menu, as
/// a toolbar's do.
@MainActor
final class InspectorController: NSViewController {
    let app: AppModel
    init(app: AppModel) { self.app = app; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    private let selector = CapsuleStack()
    /// What the row's constraints hold: the glass around `selector` on macOS 26, else `selector` itself.
    private lazy var bar: NSView = Self.glass(around: selector)
    private var buttons: [NSButton] = []
    private var counts: [CountBadge] = []   // one per button
    private let more = PanelIcon("chevron.right.2", String(localized: "More Panels"))
    private let moreBadge = CountBadge()
    /// Panels whose icon went into the » menu (not the ones hidden from the row's menu).
    private var folded: [Int] = []
    /// A dot's key once its panel was shown with it: the dot stays off until the key changes.
    private var seen: [String: String] = [:]
    private var polls: [Task<Void, Never>] = []
    private let host = NSView()   // clips: see showSelected
    private var panels: [PanelSpec] = []
    private var made: [String: NSViewController] = [:]
    /// Settings › Appearance › Inspector icons: one of these holds the row (left, centered, right).
    private var align: [String: NSLayoutConstraint] = [:]
    /// Settings › Appearance › Inspector icons position: the row level with the tabs, or a bar under the panel.
    private var top: [NSLayoutConstraint] = [], bottom: [NSLayoutConstraint] = []
    private let rowSep = NSBox()   // over the bar at the bottom
    private let empty = EmptyStateView()
    private static let orderKey = "workbench.inspector.panelOrder", hiddenKey = "workbench.inspector.hiddenPanels"
    /// What the top band keeps clear at its right end: the window's inspector toggle (MainWindow), and a gap before it.
    private static let toggleRoom: CGFloat = 44

    override func loadView() {
        let v = InspectorView()
        v.rowMenu = { [weak self] in self?.rowMenu($0) }
        // A segmented capsule, like the system's scope bars on macOS 26: the shown panel's icon on a soft fill.
        let pad = Metrics.iconGap
        selector.spacing = pad; selector.edgeInsets = NSEdgeInsets(top: pad, left: pad, bottom: pad, right: pad)
        more.target = self
        more.action = #selector(showMore(_:))
        more.setButtonType(.momentaryChange)
        Self.size(more)
        pin(moreBadge, on: more)
        host.clipsToBounds = true
        let sep = NSBox()
        sep.boxType = .separator
        rowSep.boxType = .separator
        for x in [bar, sep, rowSep, host] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        // Like the sidebar, the inspector runs the window's full height: the top band (as tall as the title bar) holds the
        // icons and, in the corner, the window's inspector toggle; the panel starts under it. The shown icon says where
        // you are, so the band carries no title of its own.
        let under = NSLayoutGuide(); v.addLayoutGuide(under)
        under.topAnchor.constraint(equalTo: v.topAnchor, constant: WindowBar.height).isActive = true
        align = ["left": bar.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: Metrics.insetTrailing),
                 "center": bar.centerXAnchor.constraint(equalTo: v.centerXAnchor),
                 "right": bar.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -Metrics.insetTrailing)]
        align.values.forEach { $0.priority = .defaultHigh }
        // In the top band, clear of the toggle in its corner; or in a bar as tall as the tabs' strip, under the panel.
        top = [bar.centerYAnchor.constraint(equalTo: v.topAnchor, constant: WindowBar.height / 2), host.bottomAnchor.constraint(equalTo: v.bottomAnchor),
               bar.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -Self.toggleRoom),
               host.topAnchor.constraint(equalTo: sep.bottomAnchor)]
        bottom = [bar.centerYAnchor.constraint(equalTo: v.bottomAnchor, constant: -TabStrip.height / 2),
                  rowSep.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -TabStrip.height),
                  host.bottomAnchor.constraint(equalTo: rowSep.topAnchor), host.topAnchor.constraint(equalTo: under.topAnchor)]
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: v.leadingAnchor, constant: Metrics.insetTrailing),
            bar.heightAnchor.constraint(equalToConstant: Metrics.segmentCapsule),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -Metrics.insetTrailing),
            sep.bottomAnchor.constraint(equalTo: under.topAnchor),
            sep.leadingAnchor.constraint(equalTo: v.leadingAnchor), sep.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            rowSep.leadingAnchor.constraint(equalTo: v.leadingAnchor), rowSep.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            host.leadingAnchor.constraint(equalTo: v.leadingAnchor), host.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            v.widthAnchor.constraint(greaterThanOrEqualToConstant: 240)
        ])
        empty.place(in: v, under: sep)
        v.onShow = { [weak self] in self?.showSelected() }
        v.onLayout = { [weak self] in self?.fold() }
        view = v
        // Panels are built with the text size of the moment: rebuilt when it changes (first, while none are built).
        track(owner: self) { [app] in app.themes.chromeText } changed: { [weak self] _ in
            guard let self else { return }
            for (_, vc) in made { vc.view.removeFromSuperview(); vc.removeFromParent() }
            made = [:]; showSelected()
        }
        track(owner: self) { [app] in app.extensions.revision } changed: { [weak self] _ in self?.forgetFolderPanels(); self?.rebuild() }
        track(owner: self) { [app] in [app.settings.value(Self.orderKey), app.settings.value(Self.hiddenKey)] } changed: { [weak self] _ in self?.rebuild() }
        track(owner: self) { [app] in app.settings.string("workbench.inspectorIconsPosition") == "bottom" } changed: { [weak self] in
            guard let self else { return }
            NSLayoutConstraint.deactivate($0 ? self.top : self.bottom); NSLayoutConstraint.activate($0 ? self.bottom : self.top)
            self.rowSep.isHidden = !$0; sep.isHidden = $0
            self.fold()   // the toggle's corner is the top band's only
        }
        track(owner: self) { [app] in app.workbench.inspectorPanel } changed: { [weak self] _ in self?.showSelected() }
        track(owner: self) { [app] in app.workbench.workspaceId == nil } changed: { [weak self] _ in self?.showEmpty() }
        track(owner: self) { [app] in app.extensions.all.panels.map { $0.available?() } } changed: { [weak self] _ in self?.fold() }
        track(owner: self) { [app] in app.extensions.all.panels.map { $0.badge?() } } changed: { [weak self] _ in self?.showCounts() }
        track(owner: self) { [app] in app.settings.string("workbench.inspectorIcons") } changed: { [weak self] in
            guard let self else { return }
            let want = self.align[$0 ?? ""] == nil ? "center" : $0 ?? ""
            for (k, c) in self.align { c.isActive = k == want }
        }
    }

    private func rebuild() {
        // In the order the row was dragged into; panels it doesn't name yet follow in the registry's order.
        let order = ids(Self.orderKey), hidden = Set(ids(Self.hiddenKey))
        func rank(_ e: (offset: Int, element: PanelSpec)) -> (Int, Int) { (order.firstIndex(of: e.element.id) ?? .max, e.offset) }
        panels = app.extensions.all.panels.enumerated().sorted { rank($0) < rank($1) }.map(\.element)
        let ids = Set(panels.map(\.id))
        for k in made.keys where !ids.contains(k) {
            made[k]?.view.removeFromSuperview()
            made[k]?.removeFromParent()
            made[k] = nil
        }
        buttons.forEach { $0.removeFromSuperview() }
        more.removeFromSuperview()
        counts = []
        polls.forEach { $0.cancel() }
        polls = panels.compactMap { p in p.poll.map { f in Task { await f() } } }
        buttons = panels.enumerated().map { i, p in
            let b = PanelIcon(p.icon, loc(p.title))
            b.target = self
            b.action = #selector(selected(_:))
            b.tag = i
            b.isHidden = hidden.contains(p.id)
            b.moved = { [weak self, weak b] x in if let self, let b { self.move(b, to: x) } }
            b.dropped = { [weak self] in self?.saveOrder() }
            b.contextMenu = { [weak self] in self?.rowMenu($0) }
            Self.size(b)
            let n = CountBadge(); pin(n, on: b)
            counts.append(n)
            selector.addArrangedSubview(b)
            return b
        }
        selector.addArrangedSubview(more)
        bar.isHidden = panels.isEmpty
        showEmpty()
        folded = []; fold()
        showCounts(); showSelected()
    }

    /// Nothing to show: no panels, or no project for them to show (a blank column looked broken). Activity, which
    /// isn't a project's, waits for one too: without a project there's nothing running to show.
    private func showEmpty() {
        let none = !panels.isEmpty && app.workbench.workspaceId == nil
        host.isHidden = none
        if panels.isEmpty {
            empty.show(String(localized: "No panels"), symbol: "sidebar.right", text: String(localized: "Turn on an extension in Settings › Extensions."))
        } else {
            empty.show(none ? String(localized: "No Project Open") : nil, symbol: "folder",
                       text: String(localized: "A project's files, changes and runs show here."))
        }
    }

    private static func size(_ b: NSButton) {
        NSLayoutConstraint.activate([b.widthAnchor.constraint(equalToConstant: Metrics.segment.width),
                                     b.heightAnchor.constraint(equalToConstant: Metrics.segment.height)])
    }

    /// A badge past the glyph's top-right corner, clear of its strokes: over them it hid the branch's node.
    private func pin(_ n: CountBadge, on b: NSButton) {
        n.translatesAutoresizingMaskIntoConstraints = false; b.addSubview(n)
        let half = Metrics.segmentPoint / 2
        NSLayoutConstraint.activate([n.leadingAnchor.constraint(equalTo: b.centerXAnchor, constant: half + 1),
                                     n.centerYAnchor.constraint(equalTo: b.centerYAnchor, constant: Metrics.iconGap - half)])
    }

    /// As many icons as the inspector's width holds, in the row's order; the rest go into the » menu. The shown
    /// panel's icon stays in the row, in the last slot, so the row always says where you are.
    private func fold() {
        let hidden = Set(ids(Self.hiddenKey))
        let current = panels.firstIndex { $0.id == app.workbench.inspectorPanel } ?? 0   // as showSelected picks it
        // A panel with nothing to show here (CI without a forge remote) leaves the row, unless it's the one on screen.
        let order = selector.arrangedSubviews.compactMap { v in buttons.firstIndex { $0 === v } }
            .filter { !hidden.contains(panels[$0].id) && (panels[$0].available?() != false || $0 == current) }
        let atTop = top.first?.isActive == true
        let room = view.bounds.width - Metrics.insetTrailing - (atTop ? Self.toggleRoom : Metrics.insetTrailing) - Metrics.iconGap
        let fits = max(1, Int(room / (Metrics.segment.width + Metrics.iconGap)))
        var shown = order
        if order.count > fits {
            shown = Array(order.prefix(fits - 1))   // and the »
            if !shown.contains(current) { if shown.isEmpty { shown = [current] } else { shown[shown.count - 1] = current } }
        }
        let next = order.filter { !shown.contains($0) }
        if more.isHidden != next.isEmpty { more.isHidden = next.isEmpty }
        for (i, b) in buttons.enumerated() {
            let off = !shown.contains(i)
            if b.isHidden != off { b.isHidden = off }
        }
        if next != folded {
            folded = next
            more.toolTip = next.isEmpty ? nil : String(localized: "More Panels: \(next.map { loc(panels[$0].title) }.joined(separator: ", "))")
            showCounts()
        }
    }

    @objc private func showMore(_ b: NSButton) {
        let m = NSMenu()
        for i in folded {
            let p = panels[i], item = NSMenuItem(title: loc(p.title), action: #selector(selected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.image = .symbol(p.icon, loc(p.title))
            if let n = p.badge?(), n.count > 0 { item.badge = NSMenuItemBadge(count: n.count) }
            m.addItem(item)
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b)
    }

    /// A reload may have changed what a folder extension's panel shows (an agent edits it, then `kelp ext reload`):
    /// those are made again. Built-in panels stay as they are.
    private func forgetFolderPanels() {
        let builtin = Set(app.extensions.extensions.filter(\.builtin).map(\.id))
        for p in panels where !builtin.contains(p.extensionId) {
            made[p.id]?.view.removeFromSuperview()
            made[p.id]?.removeFromParent()
            made[p.id] = nil
        }
    }

    private func showCounts() {
        let onScreen = view.window != nil && !view.isHiddenOrHasHiddenAncestor
        var folds: [PanelBadge] = []
        let current = panels.firstIndex { $0.id == app.workbench.inspectorPanel } ?? 0
        for (i, p) in panels.enumerated() where counts.indices.contains(i) {
            var n = p.badge?()
            if let d = n, d.count == 0 {
                if onScreen, p.id == app.workbench.inspectorPanel { seen[p.id] = d.key }
                if seen[p.id] == d.key { n = nil }
            }
            counts[i].badge = i == current ? nil : n   // the panel on screen shows its own count, as Xcode's do
            if let n, folded.contains(i) { folds.append(n) }
            buttons[i].toolTip = n.map { $0.count > 0 ? "\(loc(p.title)) (\($0.count))" : "\(loc(p.title)) •" } ?? loc(p.title)
        }
        // The » carries a dot for what's behind it: red if any of it is.
        moreBadge.badge = folds.isEmpty ? nil : PanelBadge(alert: folds.contains(where: \.alert))
    }

    @objc private func selected(_ sender: Any) {
        guard let tag = (sender as? NSButton)?.tag ?? (sender as? NSMenuItem)?.tag, panels.indices.contains(tag) else { return }
        app.workbench.inspectorPanel = panels[tag].id
        showSelected()   // the shown panel's icon again: its state stays on
    }

    private func ids(_ key: String) -> [String] { app.settings.value(key)?.array?.compactMap(\.string) ?? [] }

    /// A dragged icon takes the slot under the pointer (`x` in the row); the others slide aside.
    private func move(_ b: NSButton, to x: CGFloat) {
        var views = selector.arrangedSubviews; views.removeAll { $0 === b || $0 === more }   // the » stays last
        let next = views.first { !$0.isHidden && $0.frame.midX > x }
        let i = next.flatMap { n in views.firstIndex { $0 === n } } ?? views.count
        guard selector.arrangedSubviews.firstIndex(of: b) != i else { return }
        selector.removeArrangedSubview(b); selector.insertArrangedSubview(b, at: i)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.duration(Motion.fast); ctx.allowsImplicitAnimation = true
            selector.layoutSubtreeIfNeeded()
        }
    }

    private func saveOrder() {
        let order = selector.arrangedSubviews.compactMap { v in buttons.firstIndex { $0 === v }.map { panels[$0].id } }
        app.settings.set(Self.orderKey, .array(order.map(JSONValue.string)))
    }

    /// The row's right-click menu (on an icon or the band around it): which icons show, where the row sits, auto-hide.
    private func rowMenu(_ e: NSEvent) -> NSMenu? {
        let p = view.convert(e.locationInWindow, from: nil)
        let band = view.bounds.height - WindowBar.height
        guard (band...view.bounds.height).contains(p.y) || (selector.frame.minY...selector.frame.maxY).contains(p.y) else { return nil }
        let s = app.settings, hidden = Set(ids(Self.hiddenKey)), m = NSMenu()
        m.addItem(.sectionHeader(title: String(localized: "Icons")))
        for panel in panels {
            m.addItem(item(loc(panel.title), #selector(toggleIcon(_:)), panel.id, on: !hidden.contains(panel.id)))
        }
        let at = s.string("workbench.inspectorIconsPosition") == "bottom" ? "bottom" : "top"
        m.addItem(.sectionHeader(title: String(localized: "Position")))
        for v in ["top", "bottom"] { m.addItem(item(loc(v.capitalized), #selector(setChoice(_:)), ("workbench.inspectorIconsPosition", v), on: at == v)) }
        let side = ["left", "right"].contains(s.string("workbench.inspectorIcons")) ? s.string("workbench.inspectorIcons") : "center"
        m.addItem(.sectionHeader(title: String(localized: "Alignment")))
        for v in ["left", "center", "right"] { m.addItem(item(loc(v.capitalized), #selector(setChoice(_:)), ("workbench.inspectorIcons", v), on: side == v)) }
        m.addItem(.separator())
        m.addItem(item(String(localized: "Auto-Hide Inspector"), #selector(toggleAutoHide), nil, on: s.bool("workbench.inspector.autoHide") == true))
        m.addSettingsLink(String(localized: "Inspector Settings…"), section: "appearance", group: "Inspector", app)
        return m
    }

    private func item(_ title: String, _ action: Selector, _ value: Any?, on: Bool) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.representedObject = value
        i.state = on ? .on : .off
        return i
    }

    @objc private func toggleIcon(_ i: NSMenuItem) {
        guard let id = i.representedObject as? String else { return }
        var hidden = ids(Self.hiddenKey)
        if let k = hidden.firstIndex(of: id) { hidden.remove(at: k) } else { hidden.append(id) }
        app.settings.set(Self.hiddenKey, hidden.isEmpty ? nil : .array(hidden.map(JSONValue.string)))
        // Hiding the shown panel's icon shows the first panel that still has one.
        let shown = panels.first { $0.id == app.workbench.inspectorPanel } ?? panels.first
        if shown?.id == id, hidden.contains(id), let next = panels.first(where: { !hidden.contains($0.id) }) { app.workbench.inspectorPanel = next.id }
    }

    @objc private func setChoice(_ i: NSMenuItem) {
        guard let (key, v) = i.representedObject as? (String, String) else { return }
        app.settings.set(key, .string(v))
    }

    @objc private func toggleAutoHide() {
        app.settings.set("workbench.inspector.autoHide", .bool(app.settings.bool("workbench.inspector.autoHide") != true))
    }

    /// Shows a panel by id (menus and commands use this too).
    func show(panel id: String) { app.workbench.inspectorPanel = id }
    /// A panel already built (they're built when first shown).
    func built(_ id: String) -> NSViewController? { made[id] }

    private func showSelected() {
        guard !panels.isEmpty else { host.subviews.forEach { $0.removeFromSuperview() }; return }
        let i = panels.firstIndex { $0.id == app.workbench.inspectorPanel } ?? 0
        for (j, b) in buttons.enumerated() { b.state = j == i ? .on : .off }
        let p = panels[i]
        fold(); showCounts()   // the shown panel's icon into the row, its dot seen
        // A collapsed inspector builds nothing: the panel is made when it shows (a hidden Source Control runs no git).
        guard view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return }
        let vc = made[p.id] ?? p.make()
        if made[p.id] == nil { made[p.id] = vc; addChild(vc) }
        guard vc.view.superview !== host else { return }
        if !host.subviews.isEmpty { host.crossfade() }   // one panel fades into the next
        host.subviews.forEach { $0.removeFromSuperview() }
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(vc.view)
        // The panel follows the inspector's width but can't push it: a panel wider than its minimum is clipped instead
        // of shrinking the editor (extension panels with long lines included).
        let follow = vc.view.widthAnchor.constraint(equalTo: host.widthAnchor); follow.priority = .defaultHigh
        NSLayoutConstraint.activate([vc.view.topAnchor.constraint(equalTo: host.topAnchor), vc.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                                     vc.view.leadingAnchor.constraint(equalTo: host.leadingAnchor), follow])
    }
}

/// The inspector's view: a right-click on the icon row's band opens the row's menu.
private final class InspectorView: NSView {
    var rowMenu: ((NSEvent) -> NSMenu?)?
    /// On screen: in a window and not collapsed (a collapsed split view item is hidden).
    var onShow: (() -> Void)?
    /// After a resize: how many icons fit.
    var onLayout: (() -> Void)?
    override func layout() { super.layout(); onLayout?() }
    override func menu(for e: NSEvent) -> NSMenu? { rowMenu?(e) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onShow?() }
    override func viewDidUnhide() { super.viewDidUnhide(); onShow?() }
}

extension InspectorController {
    /// macOS 26: the row in a glass capsule (the capsule's own fill off); earlier, the row's soft fill alone.
    static func glass(around row: CapsuleStack) -> NSView {
        guard #available(macOS 26, *) else { return row }
        let g = NSGlassEffectView(); g.cornerRadius = Metrics.segmentCapsule / 2
        row.filled = false; row.translatesAutoresizingMaskIntoConstraints = false
        g.contentView = row
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: g.leadingAnchor), row.trailingAnchor.constraint(equalTo: g.trailingAnchor),
                                     row.topAnchor.constraint(equalTo: g.topAnchor), row.bottomAnchor.constraint(equalTo: g.bottomAnchor)])
        return g
    }
}

/// A soft capsule behind a row of icons: the inspector's panels, a pane's new-agent and "+" buttons.
final class CapsuleStack: NSStackView {
    /// Off inside glass, which is the capsule then.
    var filled = true { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = filled ? NSColor.fillRest.cgColor : nil }
    override func layout() { super.layout(); layer?.cornerRadius = bounds.height / 2 }
}

/// A panel's icon, a segment of the capsule: a click shows the panel, a drag moves the icon along the row (`moved`
/// with the pointer's x in the row, `dropped` on release). The shown panel's icon sits on the grey of a chosen row.
final class PanelIcon: NSButton {
    var moved: ((CGFloat) -> Void)?
    var dropped: (() -> Void)?
    var contextMenu: ((NSEvent) -> NSMenu?)?
    private var hover = false { didSet { needsDisplay = true } }

    convenience init(_ symbol: String, _ label: String) {
        self.init(frame: .zero)
        image = .symbol(symbol, label)
        imagePosition = .imageOnly
        title = ""
        toolTip = label
        isBordered = false
        setButtonType(.pushOnPushOff)
        wantsLayer = true
        symbolConfiguration = .chrome(Metrics.segmentPoint); imageScaling = .scaleProportionallyDown
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let on = state == .on
        // Chosen is one grey everywhere (sidebar rows, tabs, Settings), in glass too: a white bubble said it a second way.
        fadeBackground(to: on || isHighlighted ? .fillSelected : hover ? .fillHover : nil, held: isHighlighted)   // held, it darkens
        contentTintColor = on ? .labelColor : .secondaryLabelColor
    }
    override func layout() { super.layout(); layer?.cornerRadius = bounds.height / 2 }
    /// The frame is the pill: AppKit's alignment insets made Files' 29 pt tall where the others are 24 (as PointerButton).
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    /// The count badge sits over the pill's corner; a button clips to its rounded layer (and sets this back to true on display).
    override var clipsToBounds: Bool { get { false } set {} }
    override func mouseEntered(with e: NSEvent) { hover = true }
    override func mouseExited(with e: NSEvent) { hover = false }

    override func menu(for e: NSEvent) -> NSMenu? { contextMenu?(e) }

    override func mouseDown(with e: NSEvent) {
        if e.modifierFlags.contains(.control), let m = menu(for: e) { return NSMenu.popUpContextMenu(m, with: e, for: self) }
        guard let w = window, let row = superview else { return super.mouseDown(with: e) }
        isHighlighted = true; defer { isHighlighted = false }
        var dragging = false, at = e.locationInWindow
        while let next = w.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            at = next.locationInWindow
            if next.type == .leftMouseUp { break }
            guard dragging || abs(at.x - e.locationInWindow.x) > 3 else { continue }
            dragging = true; isHighlighted = false
            moved?(row.convert(at, from: nil).x)
        }
        if dragging { dropped?() } else if bounds.contains(convert(at, from: nil)) { pressBounce(); sendAction(action, to: target) }
    }
}

/// A panel's mark on its icon (`PanelBadge`): a grey capsule with the number, or a dot; red for a failure.
final class CountBadge: NSView {
    var badge: PanelBadge? {
        didSet {
            guard badge != oldValue else { return }
            isHidden = badge == nil
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    private var text: NSAttributedString? {
        guard let n = badge?.count, n > 0 else { return nil }
        return NSAttributedString(string: n > 99 ? "99+" : "\(n)",
                                  attributes: [.font: NSFont.uiDigits(10, weight: .semibold), .foregroundColor: NSColor.white])
    }
    init() { super.init(frame: .zero); isHidden = true }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize {
        guard let t = text else { return NSSize(width: 7, height: 14) }   // a dot, centred where the number's capsule would be
        return NSSize(width: max(14, ceil(t.size().width) + 7), height: 14)
    }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }   // clicks go to the icon
    override func draw(_ r: NSRect) {
        (badge?.alert == true ? NSColor.systemRed : NSColor.systemGray).setFill()
        guard let t = text else { return NSBezierPath(ovalIn: NSRect(x: 0, y: 3, width: 7, height: 7)).fill() }
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let s = t.size()
        t.draw(at: NSPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2))
    }
}

/// SwiftUI panel in an AppKit host.
@MainActor
func hosting<V: View>(_ v: V) -> NSViewController {
    // Filling the panel from the top: content shorter than the panel would otherwise float in its middle.
    let h = NSHostingController(rootView: v.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
    h.sizingOptions = []   // a panel fills the space it's given; it must never resize the window to its ideal size
    return h
}
