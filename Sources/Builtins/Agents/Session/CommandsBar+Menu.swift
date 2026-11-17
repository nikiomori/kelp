// What a click or a right-click on the commands bar does. It shows a command's output, opens a run's tab, or builds
// the menus.
import AppKit
import Core
import DesignKit
import KelpKit

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

    /// Opens the rows of a statement the agent ran with `kelp db query` in the database's tab. The statement is the
    /// earliest one this agent ran since the command started, among what ran on the workspace's databases
    /// (`db.activity`, newest first). Returns false when it isn't there, because the daemon restarted since or the
    /// command never got as far as running it.
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

    /// Fills the right-click menu of a command's row.
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
    /// Returns the menu of the bar's header line. It holds the actions for the current run or the last command, and a
    /// way to turn off the shell tool's commands.
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
