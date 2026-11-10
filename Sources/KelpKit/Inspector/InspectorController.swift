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
    let selector = CapsuleStack()
    /// What the row's constraints hold: the glass around `selector` on macOS 26, else `selector` itself.
    private lazy var bar: NSView = Self.glass(around: selector)
    var buttons: [NSButton] = []
    private var counts: [CountBadge] = []   // one per button
    let more = PanelIcon("chevron.right.2", String(localized: "More Panels"))
    private let moreBadge = CountBadge()
    /// Panels whose icon went into the » menu (not the ones hidden from the row's menu).
    var folded: [Int] = []
    /// A dot's key once its panel was shown with it: the dot stays off until the key changes.
    private var seen: [String: String] = [:]
    private var polls: [Task<Void, Never>] = []
    private let host = NSView()   // clips: see showSelected
    var panels: [PanelSpec] = []
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
            panelTitle.font = .ui(TextSize.body, weight: .semibold)
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

    func showCounts() {
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

    @objc func selected(_ sender: Any) {
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

    /// Shows a panel by id (menus and commands use this too).
    func show(panel id: String) { app.workbench.inspectorPanel = id }
    /// A panel already built (they're built when first shown).
    func built(_ id: String) -> NSViewController? { made[id] }

    func showSelected() {
        guard !panels.isEmpty else {
            host.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        let index = panels.firstIndex { $0.id == app.workbench.inspectorPanel } ?? 0
        for (j, b) in buttons.enumerated() { b.state = j == index ? .on : .off }
        let panel = panels[index]
        if panelTitle.stringValue != loc(panel.title), view.window != nil { panelTitle.crossfade() }   // as the panel
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
        // of shrinking the editor (extension panels with long lines included). Just under required: at 750, a label's
        // own, a bar that didn't fit widened the whole panel instead of cutting its words, and the rows' ends went.
        let follow = vc.view.widthAnchor.constraint(equalTo: host.widthAnchor)
        follow.priority = .init(999)
        NSLayoutConstraint.activate([
            vc.view.topAnchor.constraint(equalTo: host.topAnchor),
            vc.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            vc.view.leadingAnchor.constraint(equalTo: host.leadingAnchor), follow
        ])
    }
}
