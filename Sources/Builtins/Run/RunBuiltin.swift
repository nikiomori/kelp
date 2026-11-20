import AppKit
import Core
import KelpKit
import WorkbenchKit

extension Builtins {

    /// A project's commands, each run in a tab of its own: the window bar's run chip and the page a run serves, the
    /// Run menu (⌘R, ⌘U, ⌘.), the Run rows in the "+" menu and the empty workspace, and running the file in front.
    package static let run = Builtin(
        "kelp.run", "Run", "The project’s commands: the run chip, the Run menu and the pages they serve.",
        icon: "play.fill"
    ) { app in
        let runs = app.part { Runs(app: app) }
        let inWorkspace: @MainActor () -> Bool = { app.workbench.workspaceId != nil }
        return Contributions(
            commands: [
                // The Run menu runs what ran last in the project, else lists what the project's files offer.
                // `{"name": "lint"}` runs a .kelp.yaml command by name.
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
                // The page capsule's right-click items, for the page it shows.
                pageCommand(runs, "scripts.pageInBrowser", "Open Page in Browser", when: { $0.isWeb }) {
                    runs.openOutside($0, in: $1)
                },
                pageCommand(runs, "scripts.copyPageAddress", "Copy Page Address") { runs.copyAddress($0, in: $1) },
                pageCommand(runs, "scripts.unforwardPage", "Stop Forwarding Page", when: { runs.forwarded($0) }) {
                    runs.stopForwarding($0, in: $1)
                },
                pageCommand(runs, "scripts.stopPage", "Stop Page’s Server", when: { $0.pid != nil }) {
                    runs.stopServer($0, in: $1)
                },
                // The run tab's right-click item, for the run whose tab is in front.
                CommandSpec(id: "scripts.hide", title: "Hide in Run Menu", enabled: { runs.focusedRun != nil }) { _ in
                    if let run = runs.focusedRun { runs.hide(run.id) } else { NSSound.beep() }
                },
                // The language's commands (`contributes.languages`): run the file in front, and its test at the
                // cursor.
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
                run: { await runs.runForTemplate($0, $1) }),
            // A page a session printed (a run's page waits on the chip for a click), and a run whose port another
            // program holds.
            events: [
                {
                    switch $0 {
                    case let page as DevServerEvent: runs.served(page)
                    case let busy as PortBusyEvent: runs.portBusy(busy)
                    default: return false
                    }
                    return true
                }
            ]
        )
    }

    /// A command for the page the title bar's capsule shows (`Runs.frontPage`), enabled when there is one and `when`
    /// holds for it.
    private static func pageCommand(
        _ runs: Runs, _ id: String, _ title: String, when: @escaping @MainActor (ServedPage) -> Bool = { _ in true },
        _ act: @escaping @MainActor (ServedPage, String) -> Void
    ) -> CommandSpec {
        CommandSpec(id: id, title: title, enabled: { runs.frontPage.map { when($0.page) } ?? false }) { _ in
            if let front = runs.frontPage { act(front.page, front.workspace) } else { NSSound.beep() }
        }
    }

    /// The file tab in front (only a file's tab has a file), or a beep when there is none.
    private static func fileTab(_ app: AppModel) -> TabContent? {
        guard let tab = app.workbench.focusedContent, tab.fileURL != nil else {
            NSSound.beep()
            return nil
        }
        return tab
    }
}
