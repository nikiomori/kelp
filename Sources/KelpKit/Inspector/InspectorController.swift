import AppKit
import Core
import DesignKit
import SwiftUI

/// The right side of the window: a row of panel icons (from extensions) above the selected panel. The row is a scope
/// bar like Mail's and Finder's: plain icons, with the selected icon on the same grey as a chosen row, in a glass
/// capsule on macOS 26. The row sits in the window's second row (level with the tabs, under the panel's name), or in a
/// bar under the panel. Icons can be dragged into order, and a right-click on the row hides icons and moves the row.
/// Icons that don't fit go into a » menu, as a toolbar's do.
@MainActor
final class InspectorController: NSViewController {
    let app: AppModel
    init(app: AppModel) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    let selector = CapsuleStack()
    /// The view the row's constraints place: the glass around `selector` on macOS 26, or `selector` itself before that.
    private lazy var bar: NSView = Self.glass(around: selector)
    var buttons: [NSButton] = []
    private var counts: [CountBadge] = []   // one per button
    let more = PanelIcon("chevron.right.2", String(localized: "More Panels"))
    private let moreBadge = CountBadge()
    /// The panels whose icons went into the » menu for lack of room (not those hidden through the row's menu).
    var folded: [Int] = []
    /// For each panel, the key of the dot it had when the user saw the panel. The dot stays off until that key changes.
    private var seen: [String: String] = [:]
    private var polls: [Task<Void, Never>] = []
    private let host = NSView()   // clips the panel (see showSelected)
    var panels: [PanelSpec] = []
    private var made: [String: NSViewController] = [:]
    /// One constraint for each choice of Settings › Appearance › Inspector icons (left, centered, right); the active
    /// one holds the row in place.
    private var align: [String: NSLayoutConstraint] = [:]
    /// The constraints for each choice of Settings › Appearance › Inspector icons position: the row level with the
    /// tabs, a bar under the panel, or a column down the inspector's right edge (which has room for every icon).
    private var top: [NSLayoutConstraint] = [], bottom: [NSLayoutConstraint] = [], side: [NSLayoutConstraint] = []
    private let rowSep = NSBox()   // the line over the bar at the bottom
    /// The panel's name in the inspector's top band, level with the traffic lights, because the icons alone don't say
    /// which panel is open.
    private let panelTitle = NSTextField(labelWithString: "")
    private let empty = EmptyStateView()

    override func loadView() {
        let root = InspectorView()
        root.rowMenu = { [weak self] in self?.rowMenu($0) }
        // The row is a segmented capsule like macOS 26's scope bars, with the shown panel's icon on a soft fill.
        let pad = Metrics.iconGap
        selector.spacing = pad
        selector.edgeInsets = NSEdgeInsets(top: pad, left: pad, bottom: pad, right: pad)
        more.target = self
        more.action = #selector(showMore(_:))
        more.rested = { [weak self] in self?.showMore(byHover: true) }
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
        // Like the sidebar, the inspector runs the window's full height. Its top band, as tall as the title bar, holds
        // the panel's name and, in the corner, the window's inspector toggle. The inspector's rows start under the
        // band.
        let under = NSLayoutGuide()
        root.addLayoutGuide(under)
        under.topAnchor.constraint(equalTo: root.topAnchor, constant: WindowBar.height).isActive = true
        align = [
            "left": bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Metrics.insetTrailing),
            "center": bar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            "right": bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Metrics.insetTrailing)
        ]
        align.values.forEach { $0.priority = .defaultHigh }
        // The bar is either level with the tabs and as tall as their strip, or just as tall and under the panel.
        let band = [
            bar.centerYAnchor.constraint(equalTo: under.topAnchor),
            bar.centerYAnchor.constraint(equalTo: root.bottomAnchor),
            rowSep.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sep.bottomAnchor.constraint(equalTo: under.topAnchor)
        ]
        // The band is as tall as the tab strips beside it (Settings › Appearance › Tab height).
        track(owner: self) { [app] in
            TabStrip.height(app.settings)
        } changed: { height in
            zip(band, [height / 2, -height / 2, -height, height]).forEach { $0.constant = $1 }
        }
        let across = [
            bar.heightAnchor.constraint(equalToConstant: Metrics.segmentCapsule),
            host.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        ]
        top =
            across + [
                band[0],
                host.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                host.topAnchor.constraint(equalTo: sep.bottomAnchor)
            ]
        bottom =
            across + [
                band[1], band[2],
                host.bottomAnchor.constraint(equalTo: rowSep.topAnchor),
                host.topAnchor.constraint(equalTo: under.topAnchor)
            ]
        side = [
            bar.widthAnchor.constraint(equalToConstant: Metrics.segment.width + 2 * Metrics.iconGap),
            bar.topAnchor.constraint(equalTo: under.topAnchor, constant: Metrics.insetTrailing),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Metrics.insetTrailing),
            host.trailingAnchor.constraint(equalTo: bar.leadingAnchor),
            host.topAnchor.constraint(equalTo: under.topAnchor),
            host.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ]
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: Metrics.insetTrailing),
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
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 240)
        ])
        empty.place(in: root, under: sep)
        root.onShow = { [weak self] in self?.showSelected() }
        root.onLayout = { [weak self] in self?.fold() }
        view = root
        followModel(sep)
    }

    /// Updates the inspector when what it follows changes: the text size, the registry, the workspace on screen, the
    /// shown panel, the badges and where the icons sit. `sep` is the line over the panel, hidden when the icons are at
    /// the bottom.
    private func followModel(_ sep: NSBox) {
        // Panels are built with the current text size, so they are rebuilt when it changes. The first call comes while
        // none are built yet.
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
            [app.settings[SettingKeys.inspectorIconsPosition], app.settings[SettingKeys.inspectorIcons]]
        } changed: { [weak self] in
            self?.place(at: $0[0], align: $0[1], sep)
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
    }

    /// Places the icons in a row level with the tabs (`top`), in a row under the panel (`bottom`), or in a column at
    /// the right edge (`side`). A column takes no alignment.
    private func place(at position: String, align side: String, _ sep: NSBox) {
        let column = position == "side"
        NSLayoutConstraint.deactivate(top + bottom + self.side + align.values)
        NSLayoutConstraint.activate(column ? self.side : position == "bottom" ? bottom : top)
        let want = align[side] == nil ? "center" : side
        if !column { align[want]?.isActive = true }
        selector.orientation = column ? .vertical : .horizontal
        rowSep.isHidden = position != "bottom"
        sep.isHidden = position == "bottom" || column
    }

    private func rebuild() {
        // Panels go in the order the user dragged the row into. Panels the saved order doesn't name yet follow in the
        // registry's order.
        let order = app.settings[SettingKeys.panelOrder], hidden = Set(app.settings[SettingKeys.hiddenPanels] ?? [])
        func rank(_ entry: (offset: Int, element: PanelSpec)) -> (Int, Int) {
            (order.firstIndex(of: entry.element.id) ?? .max, entry.offset)
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

    /// Whether there is nothing to show: no panels, or no project for them to show (a blank column looked broken).
    /// Activity isn't a project's panel, but it waits for a project too, since without one nothing is running.
    private func showEmpty() {
        let none = !panels.isEmpty && app.workbench.workspaceId == nil
        host.isHidden = none
        if panels.isEmpty {
            empty.show(
                String(localized: "No Panels"), symbol: "sidebar.right",
                text: String(localized: "Turn on an extension in Settings › Extensions."))
        } else {
            empty.show(
                none ? String(localized: "No Project Open") : nil, symbol: "folder",
                text: String(localized: "A project's files, changes and runs show here."))
        }
    }

    private static func size(_ button: NSButton) {
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Metrics.segment.width),
            button.heightAnchor.constraint(equalToConstant: Metrics.segment.height)
        ])
    }

    /// Pins a count badge past the top-right corner of the icon's glyph, clear of its strokes. Placed over the strokes,
    /// the badge hid a node of the branch symbol.
    private func pin(_ countBadge: CountBadge, on button: NSButton) {
        countBadge.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(countBadge)
        let half = Metrics.segmentPoint / 2
        // The badge starts 3 pt past half the glyph's width, because at 1 pt the branch's right node touched the
        // number. A wider badge ("19") moves left rather than onto the next icon, and ends 3 pt before that icon's
        // glyph.
        let start = countBadge.leadingAnchor.constraint(equalTo: button.centerXAnchor, constant: half + 3)
        start.priority = .defaultHigh
        let nextGlyph = Metrics.iconGap + (Metrics.segment.width - Metrics.segmentPoint) / 2
        NSLayoutConstraint.activate([
            start,
            countBadge.trailingAnchor.constraint(lessThanOrEqualTo: button.trailingAnchor, constant: nextGlyph - 3),
            // In a column, the badge hangs past the capsule's edge into the inset, stopping short of the window's edge.
            countBadge.trailingAnchor.constraint(
                lessThanOrEqualTo: button.trailingAnchor, constant: Metrics.iconGap + Metrics.insetTrailing - 2),
            countBadge.centerYAnchor.constraint(equalTo: button.centerYAnchor, constant: Metrics.iconGap - half - 1)
        ])
    }

    /// Drops the built panels of folder extensions so they are made again, because a reload may have changed what they
    /// show (an agent edits one, then runs `kelp ext reload`). Built-in panels stay as they are.
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
        // The » shows a dot when a folded panel has a badge, and the dot is red if any of those badges is an alert.
        moreBadge.badge = folds.isEmpty ? nil : PanelBadge(alert: folds.contains(where: \.alert))
    }

    @objc func selected(_ sender: Any) {
        guard let tag = (sender as? NSButton)?.tag ?? (sender as? NSMenuItem)?.tag, panels.indices.contains(tag) else {
            return
        }
        app.workbench.inspectorPanel = panels[tag].id
        showSelected()   // a click on the shown panel's icon keeps its state on
    }

    /// Moves a dragged icon into the slot under the pointer (`p`, in the row's or column's coordinates); the other
    /// icons slide aside.
    private func move(_ button: NSButton, to p: NSPoint) {
        var views = selector.arrangedSubviews
        views.removeAll { $0 === button || $0 === more }   // the » stays last
        let down = selector.isFlipped ? 1.0 : -1.0   // a column's next slot is further down
        let next = views.first { v in
            !v.isHidden && (selector.orientation == .vertical ? (v.frame.midY - p.y) * down > 0 : v.frame.midX > p.x)
        }
        let index = next.flatMap { slot in views.firstIndex { $0 === slot } } ?? views.count
        guard selector.arrangedSubviews.firstIndex(of: button) != index else { return }
        selector.removeArrangedSubview(button)
        selector.insertArrangedSubview(button, at: index)
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
    /// Returns the panel's view controller if it was already built (panels are built when first shown).
    func built(_ id: String) -> NSViewController? { made[id] }

    func showSelected() {
        guard !panels.isEmpty else {
            host.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        let index = panels.firstIndex { $0.id == app.workbench.inspectorPanel } ?? 0
        for (j, b) in buttons.enumerated() { b.state = j == index ? .on : .off }
        selector.chosen = buttons[index]
        let panel = panels[index]
        if panelTitle.stringValue != loc(panel.title), view.window != nil { panelTitle.crossfade() }   // as the panel
        panelTitle.stringValue = loc(panel.title)
        fold()
        showCounts()   // marks the shown panel's dot seen (fold put its icon in the row)
        // A collapsed inspector builds nothing: a panel is made when it shows, so a hidden Source Control runs no git.
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
        // The panel follows the inspector's width but can't push it. A panel wider than its minimum is clipped instead
        // of shrinking the editor (extension panels with long lines included). The priority is just under required:
        // at 750, the same as a label's own, a bar that didn't fit widened the whole panel instead of cutting its
        // words, and the ends of the rows were cut off.
        let follow = vc.view.widthAnchor.constraint(equalTo: host.widthAnchor)
        follow.priority = .init(999)
        NSLayoutConstraint.activate([
            vc.view.topAnchor.constraint(equalTo: host.topAnchor),
            vc.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            vc.view.leadingAnchor.constraint(equalTo: host.leadingAnchor), follow
        ])
    }
}
