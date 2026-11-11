import AppKit
import Core
import DesignKit
import KelpKit

/// The panel's "+" (a server, a skill from somewhere, a new skill) and its ⋯ (the order, what's off, the skills'
/// folders, the chat's restart, reading the list again). The order and what's off are this Mac's view: UserDefaults.
extension AddonsPanel {
    private static let byNameKey = "addons.byName", hideOffKey = "addons.hideOff"

    static func savedView() -> AddonView {
        AddonView(
            byName: UserDefaults.standard.bool(forKey: byNameKey),
            showOff: !UserDefaults.standard.bool(forKey: hideOffKey))
    }

    private func keep(byName: Bool? = nil, showOff: Bool? = nil) {
        if let byName {
            display.byName = byName
            UserDefaults.standard.set(byName, forKey: Self.byNameKey)
        }
        if let showOff {
            display.showOff = showOff
            UserDefaults.standard.set(!showOff, forKey: Self.hideOffKey)
        }
    }

    func showAdd() {
        let menu = NSMenu()
        menu.add(String(localized: "Add an MCP Server…")) { [weak self] in self?.addServer() }
        menu.add(String(localized: "Add a Skill…")) { [weak self] in self?.addSkill(new: false) }
        menu.add(String(localized: "New Skill…")) { [weak self] in self?.addSkill(new: true) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: add.bounds.height + Metrics.lineGap * 2), in: add)
    }

    func showMore() {
        let menu = NSMenu()
        menu.add(String(localized: "Sort by Weight")) { [weak self] in self?.keep(byName: false) }.state =
            display.byName ? .off : .on
        menu.add(String(localized: "Sort by Name")) { [weak self] in self?.keep(byName: true) }.state =
            display.byName ? .on : .off
        let showOff = display.showOff
        menu.add(String(localized: "Show What’s Off")) { [weak self] in self?.keep(showOff: !showOff) }.state =
            showOff ? .on : .off
        menu.addItem(.separator())
        let folders = NSMenu()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let project = app.worktree(app.workbench.workspaceId)?.path
        for folder in AddonGroups.skillFolders(home: home, project: project, items: addons?.items ?? []) {
            folders.add((folder as NSString).abbreviatingWithTildeInPath) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
            }
        }
        menu.setSubmenu(
            folders,
            for: menu.addItem(withTitle: String(localized: "Open Skills Folder"), action: nil, keyEquivalent: ""))
        if shownChat != nil { menu.add(String(localized: "Restart This Chat")) { [weak self] in self?.restart() } }
        menu.add(String(localized: "Refresh")) { [weak self] in self?.reload() }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + Metrics.lineGap * 2), in: more)
    }

    private var projectName: String {
        app.projectName(app.worktree(app.workbench.workspaceId)?.repoId) ?? String(localized: "This Project")
    }

    private func addServer() {
        guard let workspace = app.workbench.workspaceId else { return }
        let project = projectName
        Task { [weak self, app] in
            guard let server = await AddonAddForm(project: project).ask() else { return }
            await app.call(
                AddonsAdd(worktreeId: workspace, name: server.name, entry: server.entry, project: server.project))
            self?.reload()
        }
    }

    /// Add a Skill or New Skill; then the list again, and the (first) new SKILL.md in a tab.
    private func addSkill(new: Bool) {
        guard let workspace = app.workbench.workspaceId else { return }
        let project = projectName
        Task { [weak self, app] in
            guard let typed = await AddonSkillForm(new: new, project: project).ask() else { return }
            let install =
                new
                ? AddonsInstall(worktreeId: workspace, name: typed.text, project: typed.project)
                : AddonsInstall(worktreeId: workspace, source: typed.text, project: typed.project)
            let made = await app.call(install)
            self?.reload()
            if let first = made?.first { self?.open(first) }
        }
    }
}
