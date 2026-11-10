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
        let runs = app.part { Runs(app: app) }
        let inWorkspace: @MainActor () -> Bool = { app.workbench.workspaceId != nil }
        return Contributions(
            commands: [
                // The Run menu: what ran last in the project, else the list of what its files offer (`{"name": "lint"}`
                // runs a .kelp.yaml command by name).
                CommandSpec(id: "scripts.run", title: "Run", key: "cmd+r", enabled: inWorkspace) { args in
                    runs.run(args["name"]?.string ?? "run")
                },
                cmd("scripts.choose", "Run…", "ctrl+cmd+r") { runs.choose() },
                CommandSpec(id: "scripts.test", title: "Test", key: "cmd+u", enabled: inWorkspace) { _ in
                    runs.run("test")
                },
                CommandSpec(id: "scripts.stop", title: "Stop", key: "cmd+.", enabled: { runs.canStop }) { _ in
                    runs.stop()
                },
                CommandSpec(
                    id: "scripts.openPage", title: "Open Page", key: "shift+cmd+o",
                    enabled: { app.workbench.workspaceId.map { !runs.pages($0).isEmpty } ?? false }
                ) { _ in runs.openPage() },
                CommandSpec(id: "scripts.edit", title: "Edit Commands…", enabled: inWorkspace) { _ in runs.edit() },
                // The language's commands (`contributes.languages`): run the file in front and its test at the cursor.
                cmd("editor.runFile", "Run File") { if let tab = fileTab(app) { runs.runFile(tab, "run") } },
                cmd("editor.testAtCursor", "Test at Cursor") {
                    if let tab = fileTab(app) { runs.runFile(tab, "test") }
                }
            ],
            sessionHidden: [{ runs.hidden }],
            runs: ProjectRuns(
                bar: { [RunChip(app: app, runs: runs), PageChip(app: app, runs: runs)] },
                menu: runs,
                look: { runs.look($0) },
                port: { runs.port(of: $0) },
                tabsFollow: {
                    [runs.state.active.count.description] + runs.state.active.values.compactMap(\.url)
                        + runs.state.found.keys.sorted()
                },
                tabMenu: { runs.tabItems($0, $1) },
                choices: { runs.choices($0) },
                open: { runs.open($0, in: $1) },
                served: { runs.served($0) },
                portBusy: { runs.portBusy($0) },
                setup: { await runs.setup($0, pullRequest: $1) })
        )
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
