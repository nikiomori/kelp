// The inspector's icon row: what folds into the » menu, and the row's right-click menu.
import AppKit
import Core
import DesignKit
import SwiftUI

extension InspectorController {
    /// As many icons as the inspector's width holds, in the row's order; the rest go into the » menu. The shown
    /// panel's icon stays in the row, in the last slot, so the row always says where you are.
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

    @objc func showMore(_ b: NSButton) {
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
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b)
    }

    /// The row's right-click menu (on an icon or the band around it): which icons show, where the row sits, auto-hide.
    func rowMenu(_ e: NSEvent) -> NSMenu? {
        let point = view.convert(e.locationInWindow, from: nil)
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
        for v in ["top", "bottom", "side"] {
            let choice = (SettingKeys.inspectorIconsPosition.key, v)
            menu.addItem(item(loc(v.capitalized), #selector(setChoice(_:)), choice, on: at == v))
        }
        let side =
            ["left", "right"].contains(settings[SettingKeys.inspectorIcons])
            ? settings[SettingKeys.inspectorIcons] : "center"
        if !column {   // a column has none
            menu.addItem(.sectionHeader(title: String(localized: "Alignment")))
            for v in ["left", "center", "right"] {
                let choice = (SettingKeys.inspectorIcons.key, v)
                menu.addItem(item(loc(v.capitalized), #selector(setChoice(_:)), choice, on: side == v))
            }
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
}
