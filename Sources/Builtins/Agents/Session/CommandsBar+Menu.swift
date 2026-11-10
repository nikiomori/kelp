// What a click or right-click on the commands bar does: a command's output, a run's tab, the menus.
import AppKit
import Core
import DesignKit
import KelpKit
import TerminalKit
import WorkbenchKit

extension CommandsBar {
    @objc func clickedRow() { showItem(table.clickedRow) }
    private func showItem(_ row: Int) {
        guard items.indices.contains(row) else { return }
        switch items[row] {
        case .run(let run):
            open(run)
            layOut(animated: true)
        case .command(let command) where command.command.hasPrefix("kelp db query"):
            Task {
                if await !openDatabaseRun(command) { showOutput(command, row: row) }
            }
        case .command(let command): showOutput(command, row: row)
        }
    }

    private func showOutput(_ command: AgentCommand, row: Int) {
        popover.contentViewController = CommandOutput(command)
        popover.show(relativeTo: table.rect(ofRow: row), of: table, preferredEdge: .minY)
    }

    /// A statement it ran with `kelp db query`: its rows in the database's tab, found among what ran on the workspace's
    /// databases (`db.activity`, newest first) as the first of this agent's since the command started. False when it
    /// isn't there (the daemon restarted since, or it didn't get as far as running).
    private func openDatabaseRun(_ command: AgentCommand) async -> Bool {
        guard let wid = app.session(session)?.worktreeId,
            let activity = await app.quiet(DatabaseActivity(worktreeId: wid))
        else { return false }
        let end = (command.ended ?? Date()).addingTimeInterval(1)
        guard
            let run = activity.runs.last(where: {
                $0.session == session && $0.at >= command.started.addingTimeInterval(-1) && $0.at <= end
            })
        else { return false }
        app.workbench.open(DatabaseTabURI.uri(worktree: wid, name: run.database, run: run.id))
        return true
    }

    /// A command's row.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard items.indices.contains(row) else { return }
        switch items[row] {
        case .run(let run): add(run: run, to: menu)
        case .command(let command):
            menu.add(String(localized: "Show Output")) { [weak self] in self?.showOutput(command, row: row) }
            addCopy(to: menu, command.command)
        }
    }
    private func add(run: Session, to menu: NSMenu) {
        menu.add(String(localized: "Open in Tab")) { [weak self] in self?.moveToTab(run) }
        if run.status != .exited { menu.add(String(localized: "Stop")) { [weak self] in self?.stop(run) } }
        addCopy(to: menu, run.argv.last ?? run.command)
    }
    private func addCopy(to menu: NSMenu, _ command: String) {
        menu.add(String(localized: "Copy Command")) {
            copyText(command)
        }
    }
    /// The bar's own line: its last command, and the way to turn the shell tool's commands off.
    func headerMenu() -> NSMenu {
        let menu = NSMenu(), app = app
        if let run = current {
            add(run: run, to: menu)
        } else if let last = commands.last {
            addCopy(to: menu, last.command)
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        if !commands.isEmpty {
            menu.add(String(localized: "Hide Commands Bar")) {
                app.settings.set(SettingKeys.commandsBar, false)
                Banner.show(String(localized: "The commands bar is hidden. Settings › Agents brings it back."))
            }
        }
        menu.addSettingsLink(String(localized: "Agents Settings…"), section: "agents", app)
        return menu
    }
}
