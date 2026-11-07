import AppKit
import Core
import KelpKit

extension Builtins {

    /// A project's commands, each in a tab of its own: the window bar's run chip and the page a run serves, the Run
    /// menu (⌘R, ⌘U, ⌘.), the "+" menu's and the empty workspace's Run rows, and running the file in front.
    package static let run = Builtin(
        "kelp.run", "Run", "The project's commands: the run chip, the Run menu and the pages they serve.",
        icon: "play"
    ) { app in
        let scripts = app.part { ScriptsMenu(app: app) }
        let inWorkspace: @MainActor () -> Bool = { app.workbench.workspaceId != nil }
        var contributions = Contributions()
        contributions.runs = ProjectRuns(
            bar: { [RunChip(app: app, scripts: scripts), PageChip(app: app, scripts: scripts)] },
            menu: scripts,
            hidden: { scripts.hidden },
            look: { scripts.look($0) },
            port: { scripts.port(of: $0) },
            tabsFollow: {
                [scripts.state.active.count.description] + scripts.state.active.values.compactMap(\.url)
                    + scripts.state.found.keys.sorted()
            },
            tabMenu: { scripts.tabItems($0, $1) },
            choices: { scripts.choices($0) },
            open: { scripts.open($0, in: $1) },
            served: { scripts.served($0) },
            portBusy: { scripts.portBusy($0) },
            setup: { await scripts.setup($0, pullRequest: $1) })
        contributions.commands = [
            // The Run menu: what ran last in the project, else the list of what its files offer (`{"name": "lint"}`
            // runs a .kelp.yaml command by name).
            CommandSpec(id: "scripts.run", title: "Run", key: "cmd+r", enabled: inWorkspace) { args in
                scripts.run(args["name"]?.string ?? "run")
            },
            cmd("scripts.choose", "Run…", "ctrl+cmd+r") { scripts.choose() },
            CommandSpec(id: "scripts.test", title: "Test", key: "cmd+u", enabled: inWorkspace) { _ in
                scripts.run("test")
            },
            CommandSpec(id: "scripts.stop", title: "Stop", key: "cmd+.", enabled: { scripts.canStop }) { _ in
                scripts.stop()
            },
            CommandSpec(
                id: "scripts.openPage", title: "Open Page", key: "shift+cmd+o",
                enabled: { app.workbench.workspaceId.map { !scripts.pages($0).isEmpty } ?? false }
            ) { _ in scripts.openPage() },
            CommandSpec(id: "scripts.edit", title: "Edit Commands…", enabled: inWorkspace) { _ in scripts.edit() },
            // The language's commands (`contributes.languages`): run the file in front and its test at the cursor.
            cmd("editor.runFile", "Run File") { if let tab = fileTab(app) { scripts.runFile(tab, "run") } },
            cmd("editor.testAtCursor", "Test at Cursor") {
                if let tab = fileTab(app) { scripts.runFile(tab, "test") }
            }
        ]
        return contributions
    }

    /// The file tab in front (only a file's tab has a file); a beep when there is none.
    private static func fileTab(_ app: AppModel) -> TabContent? {
        guard let tab = app.workbench.editor?.focusedContent, tab.fileURL != nil else {
            NSSound.beep()
            return nil
        }
        return tab
    }
}
