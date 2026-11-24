// The inspector's icon row: which icons fold into the » menu, and the row's right-click menu.
import AppKit
import Core
import DesignKit
import SwiftUI

extension InspectorController {
    /// The registry's panels in the icon row's order: as the user dragged them, and the ones the saved order doesn't
    /// name yet after those, in the registry's order.
    static func ordered(_ app: AppModel) -> [PanelSpec] {
        let order = app.settings[SettingKeys.panelOrder]
        func rank(_ entry: (offset: Int, element: PanelSpec)) -> (Int, Int) {
            (order.firstIndex(of: entry.element.id) ?? .max, entry.offset)
        }
        return app.extensions.all.panels.enumerated().sorted { rank($0) < rank($1) }.map(\.element)
    }

    /// The panels that have an icon in the row, in its order. The View menu lists and numbers these, so ⌥⌘1 is the
    /// row's first icon whatever the user dragged or hid.
    static func shown(_ app: AppModel) -> [PanelSpec] {
        let hidden = Set(app.settings[SettingKeys.hiddenPanels] ?? [])
        return ordered(app).filter { !hidden.contains($0.id) }
    }

    /// Pins a count badge past the top-right corner of the icon's glyph, clear of its strokes. Placed over the strokes,
    /// the badge hid a node of the branch symbol.
    func pin(_ countBadge: CountBadge, on button: NSButton) {
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

    /// The first list of a panel that can take the keys.
    static func list(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table.isHiddenOrHasHiddenAncestor ? nil : table }
        for sub in view.subviews { if let found = list(in: sub) { return found } }
        return nil
    }

    /// Answers a key that a panel's list passed on. Return does what a click on the selected row does (or a
    /// double-click, in a list where only that acts), and Esc gives the keys back to the tab.
    func answer(_ event: NSEvent) -> Bool {
        guard let list = view.window?.firstResponder as? NSTableView, list.isDescendant(of: view) else { return false }
        switch event.keyCode {
        case 53: app.workbench.focusTab()
        case 36, 76:
            guard list.selectedRow >= 0, let action = list.action ?? list.doubleAction else { return false }
            NSApp.sendAction(action, to: list.target, from: list)
        default: return false
        }
        return true
    }

    /// Keeps as many icons in the row as the inspector's width holds, in the row's order, and puts the rest into the »
    /// menu. The shown panel's icon stays in the row (taking the last slot if it would have folded), so the row always
    /// shows which panel is open.
    func fold() {
        let hidden = Set(app.settings[SettingKeys.hiddenPanels] ?? [])
        let current = panels.firstIndex { $0.id == app.workbench.inspectorPanel } ?? 0   // as showSelected picks it
        let order = selector.arrangedSubviews.compactMap { v in buttons.firstIndex { $0 === v } }
            .filter { !hidden.contains(panels[$0].id) }
        let column = selector.orientation == .vertical
        let length = column ? view.bounds.height - WindowBar.height : view.bounds.width
        let room = length - 2 * Metrics.insetTrailing - Metrics.iconGap
        let fits = max(1, Int(room / ((column ? Metrics.segment.height : Metrics.segment.width) + Metrics.iconGap)))
        var shown = order
        if order.count > fits {
            shown = Array(order.prefix(fits - 1))   // the last slot goes to the »
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

    @objc func showMore(_ button: NSButton) { showMore(byHover: false) }

    /// Shows the » menu of folded panels. Opened by a click, the menu stays until the next click; opened by the pointer
    /// resting on the », it closes when the pointer leaves.
    func showMore(byHover: Bool) {
        let menu = NSMenu()
        for i in folded {
            let panel = panels[i],
                item = NSMenuItem(title: loc(panel.title), action: #selector(selected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.show(.symbol(panel.icon, loc(panel.title)))   // macOS 27 hides an item's image unless asked
            if let badge = panel.badge?(), badge.count > 0 { item.badge = NSMenuItemBadge(count: badge.count) }
            menu.addItem(item)
        }
        more.popUp(menu, closingWhenLeft: byHover)
    }

    /// Builds the row's right-click menu (on an icon or the band around it). It sets which icons show, where the row
    /// sits, and auto-hide.
    func rowMenu(_ event: NSEvent) -> NSMenu? {
        let point = view.convert(event.locationInWindow, from: nil)
        let band = view.bounds.height - WindowBar.height
        let settings = app.settings, column = settings[SettingKeys.inspectorIconsPosition] == "side"
        let onRow =
            column
            ? selector.superview.map { $0.convert(selector.frame, to: view).contains(point) } ?? false
            : (band - TabStrip.height(settings)...band).contains(point.y)
                || (selector.frame.minY...selector.frame.maxY).contains(point.y)
        guard onRow else { return nil }
        let hidden = Set(settings[SettingKeys.hiddenPanels] ?? []), menu = NSMenu()
        menu.addItem(.sectionHeader(title: String(localized: "Icons")))
        for panel in panels {
            menu.addItem(item(loc(panel.title), #selector(toggleIcon(_:)), panel.id, on: !hidden.contains(panel.id)))
        }
        let at = settings[SettingKeys.inspectorIconsPosition]
        menu.addItem(.sectionHeader(title: String(localized: "Position")))
        // The choices named as Settings names them (Beside the Tabs…), so the two places read the same.
        let names = Builtins.inspectorRows.first { $0.key == SettingKeys.inspectorIconsPosition.key }?.labels ?? [:]
        for v in ["top", "bottom", "side"] {
            let choice = (SettingKeys.inspectorIconsPosition.key, v)
            menu.addItem(item(names[v] ?? loc(v.capitalized), #selector(setChoice(_:)), choice, on: at == v))
        }
        let side =
            ["left", "right"].contains(settings[SettingKeys.inspectorIcons])
            ? settings[SettingKeys.inspectorIcons] : "center"
        if !column {   // a column has no alignment
            menu.addItem(.sectionHeader(title: String(localized: "Alignment")))
            for v in ["left", "center", "right"] {
                let choice = (SettingKeys.inspectorIcons.key, v)
                menu.addItem(item(loc(v.capitalized), #selector(setChoice(_:)), choice, on: side == v))
            }
        }
        menu.addItem(.separator())
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

    @objc private func toggleIcon(_ menuItem: NSMenuItem) {
        guard let id = menuItem.representedObject as? String else { return }
        var hidden = app.settings[SettingKeys.hiddenPanels] ?? []
        if let index = hidden.firstIndex(of: id) { hidden.remove(at: index) } else { hidden.append(id) }
        app.settings.set(SettingKeys.hiddenPanels, hidden.isEmpty ? nil : hidden)
        // Hiding the shown panel's icon shows the first panel that still has one.
        let shown = panels.first { $0.id == app.workbench.inspectorPanel } ?? panels.first
        if shown?.id == id, hidden.contains(id), let next = panels.first(where: { !hidden.contains($0.id) }) {
            app.workbench.inspectorPanel = next.id
        }
    }

    @objc private func setChoice(_ menuItem: NSMenuItem) {
        guard let (key, v) = menuItem.representedObject as? (String, String) else { return }
        app.settings.set(key, .string(v))
    }

}
