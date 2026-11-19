// The agent strip's right-click menu. Items for the tile's agent come first, then items for the strip itself.
import AppKit
import Core
import DesignKit
import KelpKit

extension AgentStrip {
    /// Returns a tile's menu: what the tile is about and what can be done to its agent from here, above the items for
    /// the strip itself.
    func menu(for item: StripItem) -> NSMenu {
        let menu = NSMenu()
        tileItems(menu, item)
        menu.addItem(.separator())
        stripItems(menu)
        return menu
    }

    /// Adds the tile's items. They are the workspace and what the agent says, then Open in Kelp, the CI mark's action,
    /// Continue for an agent back at its prompt, Later, and Mute ▸. Later reads Dismiss for finished work, and either
    /// one keeps the agent off the strip until it does something else.
    private func tileItems(_ menu: NSMenu, _ item: StripItem) {
        let about = menu.addItem(
            withTitle: [item.name, item.words.map(StripModel.brief)].compactMap { $0 }.joined(separator: " — "),
            action: nil, keyEquivalent: "")
        about.isEnabled = false
        let app = app, id = item.session
        menu.add(String(localized: "Open in Kelp")) {
            NSApp.activate()
            app.workbench.focus(session: id)
        }
        if let ci = item.ci, let open = ci.open {
            menu.add(ci.tip) {
                NSApp.activate()
                open()
            }
        }
        if let session = app.session(id), QuickReply.fits(session) {
            menu.add(QuickReply.goOn.title) {
                Task { _ = await app.call(SessionSend(id: id, text: QuickReply.goOn.text)) }
            }
        }
        if item.cell != .working {
            let title = item.cell == .done ? String(localized: "Dismiss") : String(localized: "Later")
            menu.add(title) { [weak self] in self?.later(id) }
        }
        let times = NSMenu()
        for (title, until) in Mutes.choices() { times.add(title) { Mutes.mute([id], until: until, in: app) } }
        menu.add(String(localized: "Mute Notifications"), submenu: times)
    }

    /// Adds the strip's own items: hide it for a while, what brings it up, where it stands, and its settings. Turning
    /// the strip off and showing it over full-screen apps are in those settings.
    private func stripItems(_ menu: NSMenu) {
        let hide = NSMenu()
        for choice in Mutes.choices() where choice.until != Mutes.forever {
            hide.add(choice.title) { [weak self] in self?.hide(until: choice.until) }
        }
        menu.add(String(localized: "Hide Strip"), submenu: hide)
        menu.addChoiceMenu(SettingKeys.dockStripComesFor, app, title: String(localized: "Comes Up For"), tryOn: false)
        if place?.edge == nil { menu.add(String(localized: "Hide Behind the Edge")) { [weak self] in self?.tuck() } }
        if place != nil {
            menu.add(String(localized: "Move Back Above the Dock")) { [weak self] in self?.moved(to: nil) }
        }
        menu.addSettingsLink(String(localized: "Strip Settings…"), section: "notifications", group: "Dock", app)
    }
}
