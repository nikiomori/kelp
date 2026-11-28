// The window bar's buttons: Keep Mac Awake, Back and Forward, Side by Side, the pull request's mark.
import AppKit
import Core
import DesignKit

extension WindowBar {
    /// Shows the project's icon for `worktree`. After a switch on screen it returns which way it went: true down the
    /// sidebar, where the names roll up. Another project's icon then comes in.
    func showIcon(switchingTo worktree: Worktree) -> Bool? {
        let up = shown.flatMap {
            $0.id == worktree.id || window?.isVisible != true
                ? nil : app.workbench.goesDown(from: $0.id, to: worktree.id)
        }
        let otherProject = shown?.repoId != worktree.repoId
        shown = worktree
        guard let repo = app.repo(worktree.repoId) else {
            icon.image = nil
            return up
        }
        ProjectIcon.show(repo.path, in: icon, app: app)
        if up != nil, otherProject { icon.popIn() }
        return up
    }

    /// The Keep Mac Awake mode: the setting ("always", "agents", "off"), or "working" when agents keep the Mac awake
    /// right now (as the daemon counts them). It is "hidden" once the button's right-click hid it, whatever the mode.
    static func awakeMode(_ app: AppModel) -> String {
        let mode = app.settings[SettingKeys.keepAwake]
        let working = app.sessions.contains { $0.isChat && $0.status == .working }
        return !app.settings[SettingKeys.awakeButton]
            ? "hidden" : mode == "agents" && working ? "working" : mode
    }

    /// Shows the cup to the right of the search, which is always there so the switch can be found. It is empty while
    /// the Mac may sleep, steaming while agents keep it awake, and filled while it's on for good. It takes no colour,
    /// because nothing waits for you there. A click is Keep Mac Awake (also in the Tools menu), and a right-click picks
    /// the mode or hides the cup.
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
        awake.image = NSImage.symbol(symbol, String(localized: "Keep Mac Awake"))
        awake.toolTip = tip
        let menu = NSMenu()
        for (choice, title) in [
            ("agents", String(localized: "While Agents Work")), ("always", String(localized: "Always")),
            ("off", String(localized: "Never"))
        ] {
            menu.add(title) { app.settings.set(SettingKeys.keepAwake, choice) }.state =
                (mode == "working" ? "agents" : mode) == choice ? .on : .off
        }
        menu.addItem(.separator())
        Self.addHide(to: menu, SettingKeys.awakeButton, app)
        awake.menu = menu
    }

    /// Adds the item to a title-bar button's right-click menu that hides the button by turning its setting off.
    /// Settings › Window turns it back on.
    static func addHide(to menu: NSMenu, _ setting: Setting<Bool>, _ app: AppModel) {
        menu.add(String(localized: "Hide Button")) {
            app.settings.set(setting, false)
            Banner.show(String(localized: "The button is hidden. Settings › Window brings it back."))
        }
    }

    /// The number of agents that tile side by side in a workspace, as `EditorArea.arrange` picks them. Below two, the
    /// button does nothing.
    static func liveAgents(_ app: AppModel, in wid: String?) -> Int {
        app.sessions.filter {
            $0.worktreeId == wid && $0.isAgent && ![.exited, .paused].contains($0.status)
        }.count
    }

    /// Sets the arrows' tooltips to where they go. With nothing in that direction, an arrow greys out.
    func showNav(back to: String?, forward ahead: String?) {
        for (arrow, name, title, id) in [
            (back, to, String(localized: "Back"), "workspace.back"),
            (forward, ahead, String(localized: "Forward"), "workspace.forward")
        ] {
            arrow.isEnabled = name != nil
            arrow.toolTip = app.extensions.hint(name.map { "\(title): \($0)" } ?? title, id)
        }
    }
    @objc func goBack() { app.workbench.goBack(-1) }
    @objc func goForward() { app.workbench.goBack(1) }

    @objc func toggleAwake() { app.extensions.command("power.keepAwake")?.run([:]) }

    /// Shows the side-by-side button. While the workspace shows its agents side by side, the symbol is filled. A click
    /// shows them as tabs in one pane, and back. It appears only with two agents or more, and a right-click hides it
    /// (Settings › Window brings it back).
    /// When on, it is the filled symbol, as the Keep Mac Awake cup shows it, with no colour: nothing waits for you
    /// there. When off, it is only the outline.
    func showSideBySide(_ on: Bool) {
        sideBySide.image = NSImage.symbol(
            on ? "rectangle.split.3x1.fill" : "rectangle.split.3x1", String(localized: "Agents Side by Side"))
        sideBySide.toolTip = app.extensions.hint(
            on
                ? String(localized: "Agents side by side. Click to show them as tabs")
                : String(localized: "Agents as tabs. Click to put them side by side"), "agents.sideBySide")
    }
    @objc func toggleSideBySide() { app.extensions.command("agents.sideBySide")?.run([:]) }

    /// Opens the PR's tab, and with ⌘ held its page in the browser, as the sidebar row's mark does.
    @objc func openPR() {
        guard let mark = prMark else { return }
        if EditorArea.commandClick, let page = mark.page { return PreviewLinks.openOutside(page) }
        app.workbench.open(mark.uri, workspace: worktree?.id)
    }
}
