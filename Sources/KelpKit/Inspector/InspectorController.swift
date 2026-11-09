import AppKit
import Core
import DesignKit
import SwiftUI

/// Right side: a row of panel icons (from extensions) over the selected panel — a scope bar like Mail's and Finder's:
/// plain icons, the selected one on the grey of a chosen row, in a glass capsule on macOS 26. The row is the inspector's
/// part of the window's second row, under the panel's name, or a bar under the panel. Icons are dragged into order; a
/// right-click on the row hides them and moves the row. Icons that don't fit go into a » menu, as a toolbar's do.
@MainActor
final class InspectorController: NSViewController {
    let app: AppModel
    init(app: AppModel) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }
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
    /// The panel's name in the inspector's top band, level with the traffic lights: the icons alone don't say where you are.
    private let panelTitle = NSTextField(labelWithString: "")
    private let empty = EmptyStateView()

    override func loadView() {
        let root = InspectorView()
        root.rowMenu = { [weak self] in self?.rowMenu($0) }
        // A segmented capsule, like the system's scope bars on macOS 26: the shown panel's icon on a soft fill.
        let pad = Metrics.iconGap
        selector.spacing = pad
        selector.edgeInsets = NSEdgeInsets(top: pad, left: pad, bottom: pad, right: pad)
        more.target = self
        more.action = #selector(showMore(_:))
        more.setButtonType(.momentaryChange)
        Self.size(more)
        pin(moreBadge, on: more)
        panelTitle.lineBreakMode = .byTruncatingTail
        panelTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        host.clipsToBounds = true
        let sep = NSBox()
        sep.boxType = .separator
        rowSep.boxType = .separator
        for x in [bar, sep, rowSep, panelTitle, host] as [NSView] {
            x.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(x)
        }
        // Like the sidebar, the inspector runs the window's full height: the top band (as tall as the title bar) holds the
        // panel's name and, in the corner, the window's inspector toggle; its rows start under it.
        let under = NSLayoutGuide()
        root.addLayoutGuide(under)
        under.topAnchor.constraint(equalTo: root.topAnchor, constant: WindowBar.height).isActive = true
        align = [
            "left": bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Metrics.insetTrailing),
            "center": bar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            "right": bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Metrics.insetTrailing)
        ]
        align.values.forEach { $0.priority = .defaultHigh }
        // Level with the tabs, the full height of their strip; or as tall, under the panel.
        let band = [
            bar.centerYAnchor.constraint(equalTo: under.topAnchor),
            bar.centerYAnchor.constraint(equalTo: root.bottomAnchor),
            rowSep.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sep.bottomAnchor.constraint(equalTo: under.topAnchor)
        ]
        // As tall as the tab strips beside it (Settings › Appearance › Tab height).
        track(owner: self) { [app] in
            TabStrip.height(app.settings)
        } changed: { height in
            zip(band, [height / 2, -height / 2, -height, height]).forEach { $0.constant = $1 }
        }
        top = [
            band[0],
            host.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            host.topAnchor.constraint(equalTo: sep.bottomAnchor)
        ]
        bottom = [
            band[1], band[2],
            host.bottomAnchor.constraint(equalTo: rowSep.topAnchor),
            host.topAnchor.constraint(equalTo: under.topAnchor)
        ]
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: Metrics.insetTrailing),
            bar.heightAnchor.constraint(equalToConstant: Metrics.segmentCapsule),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -Metrics.insetTrailing),
            panelTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Metrics.inset),
            panelTitle.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -48),   // clear of the toggle
            panelTitle.centerYAnchor.constraint(equalTo: root.topAnchor, constant: WindowBar.height / 2),
            band[3],
            sep.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            rowSep.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            rowSep.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            host.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 240)
        ])
        empty.place(in: root, under: sep)
        root.onShow = { [weak self] in self?.showSelected() }
        root.onLayout = { [weak self] in self?.fold() }
        view = root
        followModel(sep)
    }

    /// What the panels follow: the text size, the registry, the workspace on screen, where the icons sit (`sep`: the line
    /// over the panel, hidden when the icons are at the bottom).
    private func followModel(_ sep: NSBox) {
        // Panels are built with the text size of the moment: rebuilt when it changes (first, while none are built).
        track(owner: self) { [app] in
            app.themes.chromeText
        } changed: { [weak self] _ in
            guard let self else { return }
            panelTitle.font = .ui(13, weight: .semibold)
            for (_, vc) in made {
                vc.view.removeFromSuperview()
                vc.removeFromParent()
            }
            made = [:]
            showSelected()
        }
        track(owner: self) { [app] in
            app.extensions.revision
        } changed: { [weak self] _ in
            self?.forgetFolderPanels()
            self?.rebuild()
        }
        track(owner: self) { [app] in
            [app.settings[SettingKeys.panelOrder], app.settings[SettingKeys.hiddenPanels] ?? []]
        } changed: { [weak self] _ in
            self?.rebuild()
        }
        track(owner: self) { [app] in
            app.settings[SettingKeys.inspectorIconsPosition] == "bottom"
        } changed: { [weak self] in
            guard let self else { return }
            NSLayoutConstraint.deactivate($0 ? self.top : self.bottom)
            NSLayoutConstraint.activate($0 ? self.bottom : self.top)
            self.rowSep.isHidden = !$0
            sep.isHidden = $0
        }
        track(owner: self) { [app] in
            app.workbench.inspectorPanel
        } changed: { [weak self] _ in
            self?.showSelected()
        }
        track(owner: self) { [app] in
            app.workbench.workspaceId == nil
        } changed: { [weak self] _ in
            self?.showEmpty()
        }
        track(owner: self) { [app] in
            app.extensions.all.panels.map { $0.badge?() }
        } changed: { [weak self] _ in
            self?.showCounts()
        }
        track(owner: self) { [app] in
            app.settings[SettingKeys.inspectorIcons]
        } changed: { [weak self] in
            guard let self else { return }
            let want = self.align[$0] == nil ? "center" : $0
            for (k, c) in self.align { c.isActive = k == want }
        }
    }

    private func rebuild() {
        // In the order the row was dragged into; panels it doesn't name yet follow in the registry's order.
        let order = app.settings[SettingKeys.panelOrder], hidden = Set(app.settings[SettingKeys.hiddenPanels] ?? [])
        func rank(_ e: (offset: Int, element: PanelSpec)) -> (Int, Int) {
            (order.firstIndex(of: e.element.id) ?? .max, e.offset)
        }
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
        buttons = panels.enumerated().map { index, panel in
            let button = PanelIcon(panel.icon, loc(panel.title))
            button.target = self
            button.action = #selector(selected(_:))
            button.tag = index
            button.isHidden = hidden.contains(panel.id)
            button.moved = { [weak self, weak button] position in
                if let self, let button { self.move(button, to: position) }
            }
            button.dropped = { [weak self] in self?.saveOrder() }
            button.contextMenu = { [weak self] in self?.rowMenu($0) }
            Self.size(button)
            let countBadge = CountBadge()
            pin(countBadge, on: button)
            counts.append(countBadge)
            selector.addArrangedSubview(button)
            return button
        }
        selector.addArrangedSubview(more)
        bar.isHidden = panels.isEmpty
        showEmpty()
        folded = []
        fold()
        showCounts()
        showSelected()
    }

    /// Nothing to show: no panels, or no project for them to show (a blank column looked broken). Activity, which
    /// isn't a project's, waits for one too: without a project there's nothing running to show.
    private func showEmpty() {
        let none = !panels.isEmpty && app.workbench.workspaceId == nil
        host.isHidden = none
        if panels.isEmpty {
            empty.show(
                String(localized: "No panels"), symbol: "sidebar.right",
                text: String(localized: "Turn on an extension in Settings › Extensions."))
        } else {
            empty.show(
                none ? String(localized: "No Project Open") : nil, symbol: "folder",
                text: String(localized: "A project's files, changes and runs show here."))
        }
    }

    private static func size(_ b: NSButton) {
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: Metrics.segment.width),
            b.heightAnchor.constraint(equalToConstant: Metrics.segment.height)
        ])
    }

    /// A badge past the glyph's top-right corner, clear of its strokes: over them it hid the branch's node.
    private func pin(_ n: CountBadge, on b: NSButton) {
        n.translatesAutoresizingMaskIntoConstraints = false
        b.addSubview(n)
        let half = Metrics.segmentPoint / 2
        // 3 pt past the glyph's half: 1 pt left the branch's right node touching the number. A wider one ("19") moves
        // left rather than onto the next icon: it ends 3 pt before that glyph.
        let start = n.leadingAnchor.constraint(equalTo: b.centerXAnchor, constant: half + 3)
        start.priority = .defaultHigh
        let nextGlyph = Metrics.iconGap + (Metrics.segment.width - Metrics.segmentPoint) / 2
        NSLayoutConstraint.activate([
            start,
            n.trailingAnchor.constraint(lessThanOrEqualTo: b.trailingAnchor, constant: nextGlyph - 3),
            n.centerYAnchor.constraint(equalTo: b.centerYAnchor, constant: Metrics.iconGap - half - 1)
        ])
    }

    /// As many icons as the inspector's width holds, in the row's order; the rest go into the » menu. The shown
    /// panel's icon stays in the row, in the last slot, so the row always says where you are.
    private func fold() {
        let hidden = Set(app.settings[SettingKeys.hiddenPanels] ?? [])
        let current = panels.firstIndex { $0.id == app.workbench.inspectorPanel } ?? 0   // as showSelected picks it
        let order = selector.arrangedSubviews.compactMap { v in buttons.firstIndex { $0 === v } }
            .filter { !hidden.contains(panels[$0].id) }
        let room = view.bounds.width - 2 * Metrics.insetTrailing - Metrics.iconGap
        let fits = max(1, Int(room / (Metrics.segment.width + Metrics.iconGap)))
        var shown = order
        if order.count > fits {
            shown = Array(order.prefix(fits - 1))   // and the »
            if !shown.contains(current) {
                if shown.isEmpty { shown = [current] } else { shown[shown.count - 1] = current }
            }
        }
        let next = order.filter { !shown.contains($0) }
        if more.isHidden != next.isEmpty { more.isHidden = next.isEmpty }
        for (i, b) in buttons.enumerated() {
            let off = !shown.contains(i)
            if b.isHidden != off { b.isHidden = off }
        }
        if next != folded {
            folded = next
            more.toolTip =
                next.isEmpty
                ? nil : String(localized: "More Panels: \(next.map { loc(panels[$0].title) }.joined(separator: ", "))")
            showCounts()
        }
    }

    @objc private func showMore(_ b: NSButton) {
        let menu = NSMenu()
        for i in folded {
            let panel = panels[i],
                item = NSMenuItem(title: loc(panel.title), action: #selector(selected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.image = .symbol(panel.icon, loc(panel.title))
            if let badge = panel.badge?(), badge.count > 0 { item.badge = NSMenuItemBadge(count: badge.count) }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b)
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
        for (i, p) in panels.enumerated() where counts.indices.contains(i) {
            var badge = p.badge?()
            if let dot = badge, dot.count == 0 {
                if onScreen, p.id == app.workbench.inspectorPanel { seen[p.id] = dot.key }
                if seen[p.id] == dot.key { badge = nil }
            }
            counts[i].badge = badge
            if let badge, folded.contains(i) { folds.append(badge) }
            buttons[i].toolTip =
                badge.map { $0.count > 0 ? "\(loc(p.title)) (\($0.count))" : "\(loc(p.title)) •" } ?? loc(p.title)
        }
        // The » carries a dot for what's behind it: red if any of it is.
        moreBadge.badge = folds.isEmpty ? nil : PanelBadge(alert: folds.contains(where: \.alert))
    }

    @objc private func selected(_ sender: Any) {
        guard let tag = (sender as? NSButton)?.tag ?? (sender as? NSMenuItem)?.tag, panels.indices.contains(tag) else {
            return
        }
        app.workbench.inspectorPanel = panels[tag].id
        showSelected()   // the shown panel's icon again: its state stays on
    }

    /// A dragged icon takes the slot under the pointer (`x` in the row); the others slide aside.
    private func move(_ b: NSButton, to x: CGFloat) {
        var views = selector.arrangedSubviews
        views.removeAll { $0 === b || $0 === more }   // the » stays last
        let next = views.first { !$0.isHidden && $0.frame.midX > x }
        let index = next.flatMap { slot in views.firstIndex { $0 === slot } } ?? views.count
        guard selector.arrangedSubviews.firstIndex(of: b) != index else { return }
        selector.removeArrangedSubview(b)
        selector.insertArrangedSubview(b, at: index)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.duration(Motion.fast)
            ctx.allowsImplicitAnimation = true
            selector.layoutSubtreeIfNeeded()
        }
    }

    private func saveOrder() {
        let order = selector.arrangedSubviews.compactMap { v in buttons.firstIndex { $0 === v }.map { panels[$0].id } }
        app.settings.set(SettingKeys.panelOrder, order)
    }

    /// The row's right-click menu (on an icon or the band around it): which icons show, where the row sits, auto-hide.
    private func rowMenu(_ e: NSEvent) -> NSMenu? {
        let point = view.convert(e.locationInWindow, from: nil)
        let band = view.bounds.height - WindowBar.height
        guard
            (band - TabStrip.height(app.settings)...band).contains(point.y)
                || (selector.frame.minY...selector.frame.maxY).contains(point.y)
        else { return nil }
        let settings = app.settings, hidden = Set(settings[SettingKeys.hiddenPanels] ?? []), menu = NSMenu()
        menu.addItem(.sectionHeader(title: String(localized: "Icons")))
        for panel in panels {
            menu.addItem(item(loc(panel.title), #selector(toggleIcon(_:)), panel.id, on: !hidden.contains(panel.id)))
        }
        let at = settings[SettingKeys.inspectorIconsPosition] == "bottom" ? "bottom" : "top"
        menu.addItem(.sectionHeader(title: String(localized: "Position")))
        for v in ["top", "bottom"] {
            let choice = (SettingKeys.inspectorIconsPosition.key, v)
            menu.addItem(item(loc(v.capitalized), #selector(setChoice(_:)), choice, on: at == v))
        }
        let side =
            ["left", "right"].contains(settings[SettingKeys.inspectorIcons])
            ? settings[SettingKeys.inspectorIcons] : "center"
        menu.addItem(.sectionHeader(title: String(localized: "Alignment")))
        for v in ["left", "center", "right"] {
            menu.addItem(
                item(loc(v.capitalized), #selector(setChoice(_:)), (SettingKeys.inspectorIcons.key, v), on: side == v))
        }
        menu.addItem(.separator())
        menu.addItem(
            item(
                String(localized: "Auto-Hide Inspector"), #selector(toggleAutoHide), nil,
                on: settings[SettingKeys.inspectorAutoHide]))
        menu.addSettingsLink(String(localized: "Inspector Settings…"), section: "appearance", group: "Inspector", app)
        return menu
    }

    private func item(_ title: String, _ action: Selector, _ value: Any?, on: Bool) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        menuItem.representedObject = value
        menuItem.state = on ? .on : .off
        return menuItem
    }

    @objc private func toggleIcon(_ i: NSMenuItem) {
        guard let id = i.representedObject as? String else { return }
        var hidden = app.settings[SettingKeys.hiddenPanels] ?? []
        if let index = hidden.firstIndex(of: id) { hidden.remove(at: index) } else { hidden.append(id) }
        app.settings.set(SettingKeys.hiddenPanels, hidden.isEmpty ? nil : hidden)
        // Hiding the shown panel's icon shows the first panel that still has one.
        let shown = panels.first { $0.id == app.workbench.inspectorPanel } ?? panels.first
        if shown?.id == id, hidden.contains(id), let next = panels.first(where: { !hidden.contains($0.id) }) {
            app.workbench.inspectorPanel = next.id
        }
    }

    @objc private func setChoice(_ i: NSMenuItem) {
        guard let (key, v) = i.representedObject as? (String, String) else { return }
        app.settings.set(key, .string(v))
    }

    @objc private func toggleAutoHide() {
        app.settings.set(SettingKeys.inspectorAutoHide, !app.settings[SettingKeys.inspectorAutoHide])
    }

    /// Shows a panel by id (menus and commands use this too).
    func show(panel id: String) { app.workbench.inspectorPanel = id }
    /// A panel already built (they're built when first shown).
    func built(_ id: String) -> NSViewController? { made[id] }

    private func showSelected() {
        guard !panels.isEmpty else {
            host.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        let index = panels.firstIndex { $0.id == app.workbench.inspectorPanel } ?? 0
        for (j, b) in buttons.enumerated() { b.state = j == index ? .on : .off }
        let panel = panels[index]
        panelTitle.stringValue = loc(panel.title)
        fold()
        showCounts()   // the shown panel's icon into the row, its dot seen
        // A collapsed inspector builds nothing: the panel is made when it shows (a hidden Source Control runs no git).
        guard view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return }
        let vc = made[panel.id] ?? panel.make()
        if made[panel.id] == nil {
            made[panel.id] = vc
            addChild(vc)
        }
        guard vc.view.superview !== host else { return }
        if !host.subviews.isEmpty { host.crossfade() }   // one panel fades into the next
        host.subviews.forEach { $0.removeFromSuperview() }
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(vc.view)
        // The panel follows the inspector's width but can't push it: a panel wider than its minimum is clipped instead
        // of shrinking the editor (extension panels with long lines included).
        let follow = vc.view.widthAnchor.constraint(equalTo: host.widthAnchor)
        follow.priority = .defaultHigh
        NSLayoutConstraint.activate([
            vc.view.topAnchor.constraint(equalTo: host.topAnchor),
            vc.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            vc.view.leadingAnchor.constraint(equalTo: host.leadingAnchor), follow
        ])
    }
}

/// The inspector's view: a right-click on the icon row's band opens the row's menu.
private final class InspectorView: NSView {
    var rowMenu: ((NSEvent) -> NSMenu?)?
    /// On screen: in a window and not collapsed (a collapsed split view item is hidden).
    var onShow: (() -> Void)?
    /// After a resize: how many icons fit.
    var onLayout: (() -> Void)?
    override func layout() {
        super.layout()
        onLayout?()
    }
    override func menu(for e: NSEvent) -> NSMenu? { rowMenu?(e) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onShow?()
    }
    override func viewDidUnhide() {
        super.viewDidUnhide()
        onShow?()
    }
}

extension InspectorController {
    /// macOS 26: the row in a glass capsule (the capsule's own fill off); earlier, the row's soft fill alone.
    static func glass(around row: CapsuleStack) -> NSView {
        guard #available(macOS 26, *) else { return row }
        let capsule = NSGlassEffectView()
        capsule.cornerRadius = Metrics.segmentCapsule / 2
        row.filled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        capsule.contentView = row
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: capsule.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: capsule.trailingAnchor),
            row.topAnchor.constraint(equalTo: capsule.topAnchor),
            row.bottomAnchor.constraint(equalTo: capsule.bottomAnchor)
        ])
        return capsule
    }
}

/// A soft capsule behind a row of icons: the inspector's panels, a pane's new-agent and "+" buttons.
final class CapsuleStack: NSStackView {
    /// Off inside glass, which is the capsule then.
    var filled = true { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = filled ? NSColor.fillRest.cgColor : nil }
    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
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
        symbolConfiguration = .chrome(Metrics.segmentPoint)
        imageScaling = .scaleProportionallyDown
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
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
    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
    /// The frame is the pill: AppKit's alignment insets made Files' 29 pt tall where the others are 24 (as PointerButton).
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    /// The count badge sits over the pill's corner; a button clips to its rounded layer (and sets this back to true on display).
    override var clipsToBounds: Bool {
        get { false }
        set {}
    }
    override func mouseEntered(with e: NSEvent) { hover = true }
    override func mouseExited(with e: NSEvent) { hover = false }

    override func menu(for e: NSEvent) -> NSMenu? { contextMenu?(e) }

    override func mouseDown(with e: NSEvent) {
        if e.modifierFlags.contains(.control), let shown = menu(for: e) {
            return NSMenu.popUpContextMenu(shown, with: e, for: self)
        }
        guard let window, let row = superview else { return super.mouseDown(with: e) }
        isHighlighted = true
        defer { isHighlighted = false }
        var dragging = false, at = e.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            at = next.locationInWindow
            if next.type == .leftMouseUp { break }
            guard dragging || abs(at.x - e.locationInWindow.x) > 3 else { continue }
            dragging = true
            isHighlighted = false
            moved?(row.convert(at, from: nil).x)
        }
        if dragging {
            dropped?()
        } else if bounds.contains(convert(at, from: nil)) {
            pressBounce()
            sendAction(action, to: target)
        }
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
        guard let count = badge?.count, count > 0 else { return nil }
        return NSAttributedString(
            string: count > 99 ? "99+" : "\(count)",
            attributes: [.font: NSFont.uiDigits(10, weight: .semibold), .foregroundColor: NSColor.white])
    }
    init() {
        super.init(frame: .zero)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize {
        guard let label = text else { return NSSize(width: 7, height: 14) }   // a dot, centred where the number's capsule would be
        return NSSize(width: max(14, ceil(label.size().width) + 7), height: 14)
    }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }   // clicks go to the icon
    override func draw(_ r: NSRect) {
        (badge?.alert == true ? NSColor.systemRed : NSColor.systemGray).setFill()
        guard let label = text else { return NSBezierPath(ovalIn: NSRect(x: 0, y: 3, width: 7, height: 7)).fill() }
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let size = label.size()
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

/// SwiftUI panel in an AppKit host.
@MainActor
func hosting<V: View>(_ v: V) -> NSViewController {
    // Filling the panel from the top: content shorter than the panel would otherwise float in its middle.
    let host = NSHostingController(rootView: v.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
    host.sizingOptions = []   // a panel fills the space it's given; it must never resize the window to its ideal size
    return host
}
