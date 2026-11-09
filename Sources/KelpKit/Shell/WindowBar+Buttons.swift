// The window bar's buttons: Keep Mac Awake, Back and Forward, Side by Side, the pull request's mark.
import AppKit
import Core
import DesignKit

extension WindowBar {
    /// The setting ("always", "agents", "off"), or "working": agents keep the Mac awake right now (as the daemon counts them).
    /// "hidden" once the button's right-click hid it, whatever the mode.
    static func awakeMode(_ app: AppModel) -> String {
        let mode = app.settings[SettingKeys.keepAwake]
        let working = app.sessions.contains { $0.isChat && $0.status == .working }
        return !app.settings[SettingKeys.awakeButton]
            ? "hidden" : mode == "agents" && working ? "working" : mode
    }

    /// The cup right of the search, always there so the switch can be found: empty while the Mac may sleep, steaming while
    /// agents keep it awake, orange while it's on for good. A click is Keep Mac Awake (also in the Tools menu); a right-click
    /// picks the mode or hides it.
    func showAwake(_ mode: String) {
        let app = self.app
        awake.isHidden = mode == "hidden"
        let (symbol, tip) =
            switch mode {
            case "always": ("cup.and.heat.waves.fill", String(localized: "The Mac stays awake until you click here"))
            case "working":
                (
                    "cup.and.heat.waves",
                    String(localized: "The Mac stays awake while agents work. Click to keep it awake always")
                )
            default: ("cup.and.saucer", String(localized: "The Mac can sleep. Click to keep it awake"))
            }
        let cup = NSImage.symbol(symbol, String(localized: "Keep Mac Awake"))   // a recessed button ignores contentTintColor
        awake.image = mode == "always" ? cup.withSymbolConfiguration(.init(paletteColors: [.systemOrange])) : cup
        awake.toolTip = tip
        let menu = NSMenu()
        for (choice, title) in [
            ("agents", String(localized: "While agents work")), ("always", String(localized: "Always")),
            ("off", String(localized: "Never"))
        ] {
            menu.add(title) { app.settings.set(SettingKeys.keepAwake, choice) }.state =
                (mode == "working" ? "agents" : mode) == choice ? .on : .off
        }
        menu.addItem(.separator())
        Self.addHide(to: menu, SettingKeys.awakeButton, app)
        awake.menu = menu
    }

    /// A title-bar button's right-click: off by its setting, which Settings › Window turns back on.
    static func addHide(to menu: NSMenu, _ setting: Setting<Bool>, _ app: AppModel) {
        menu.add(String(localized: "Hide Button")) {
            app.settings.set(setting, false)
            Banner.show(String(localized: "The button is hidden. Settings › Window brings it back."))
        }
    }

    /// Agents that tile side by side in a workspace, as `EditorArea.arrange` picks them: below two the button does nothing.
    static func liveAgents(_ app: AppModel, in wid: String?) -> Int {
        app.sessions.filter {
            $0.worktreeId == wid && !["shell", "custom"].contains($0.agent) && ![.exited, .paused].contains($0.status)
        }.count
    }

    /// The arrows say where they go; with nothing that way they grey out.
    func showNav(back to: String?, forward ahead: String?) {
        for (arrow, name, title, key) in [
            (back, to, String(localized: "Back"), "⌃⌘←"), (forward, ahead, String(localized: "Forward"), "⌃⌘→")
        ] {
            arrow.isEnabled = name != nil
            arrow.toolTip = name.map { "\(title): \($0) (\(key))" } ?? "\(title) (\(key))"
        }
    }
    @objc func goBack() { app.workbench.goBack(-1) }
    @objc func goForward() { app.workbench.goBack(1) }

    @objc func toggleAwake() { app.extensions.command("power.keepAwake")?.run([:]) }

    /// The filled symbol while the workspace puts its agents side by side; a click shows them as tabs in one pane, and
    /// back. Only with two agents or more; a right-click hides it (Settings › Window brings it back).
    /// On: the filled symbol in the accent (the label colour with Graphite), no fill behind it; off: its outline alone.
    func showSideBySide(_ on: Bool) {
        let image = NSImage.symbol(
            on ? "rectangle.split.3x1.fill" : "rectangle.split.3x1", String(localized: "Agents Side by Side"))
        sideBySide.image = on ? image.withSymbolConfiguration(.init(paletteColors: [.emphasis])) : image   // a recessed button ignores contentTintColor
        sideBySide.toolTip =
            on
            ? String(localized: "Agents side by side. Click to show them as tabs (⌃⌘T)")
            : String(localized: "Agents as tabs. Click to put them side by side (⌃⌘T)")
    }
    @objc func toggleSideBySide() { app.extensions.command("agents.sideBySide")?.run([:]) }

    @objc func openPR() {
        guard let url = prMark?.url else { return }
        app.workbench.open(url, workspace: worktree?.id)
    }
}
