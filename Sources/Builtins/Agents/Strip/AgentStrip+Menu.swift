// The agent strip's right-click menu: the tile's own agent first, then the strip.
import AppKit
import Core
import DesignKit
import KelpKit

extension AgentStrip {
    /// What the tile is about, and what can be done to it from here, over what the strip itself does.
    func menu(for item: StripItem) -> NSMenu {
        let menu = NSMenu()
        tileItems(menu, item)
        menu.addItem(.separator())
        stripItems(menu)
        return menu
    }

    /// Its workspace and what it says, then Open in Kelp, Continue for one back at its prompt, Later (Dismiss for finished
    /// work: off the strip until it does something else) and Mute ▸.
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
        if let ci = item.ci, let open = app.extensions.all.ci?.open {
            menu.add(ci.line) {
                NSApp.activate()
                open(ci.folder)
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

    /// Hide it for a while, what brings it up, where it stands, its settings. Turning it off and full-screen apps are in
    /// those settings.
    private func stripItems(_ menu: NSMenu) {
        let hide = NSMenu()
        for c in Mutes.choices() where c.until != Mutes.forever {
            hide.add(c.title) { [weak self] in self?.hide(until: c.until) }
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
