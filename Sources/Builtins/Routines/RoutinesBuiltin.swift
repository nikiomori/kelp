import AppKit
import Core
import KelpKit

extension Builtins {

    /// Agents on a schedule: the project's routines as a tab, opened from "+", the empty workspace and the command
    /// palette.
    package static let routines = Builtin(
        "kelp.routines", "Routines", "Agents on a schedule, each in a group of its own.",
        icon: "clock.arrow.circlepath"
    ) { app in
        let pick = app.part { RoutinePick() }, actions = RoutineActions(app: app)
        return Contributions(
            editors: [
                EditorSpec(id: "routines.open", title: "Routines", icon: "clock.arrow.circlepath") { ctx in
                    ctx.workspace.map { "routines:\($0.repoId)" }
                }
            ],
            commands: [
                cmd("routines.show", "Routines") {
                    if let repoId = app.worktree(app.workbench.workspaceId)?.repoId {
                        app.workbench.open("routines:\(repoId)")
                    }
                },
                cmd("routines.new", "New Routine…") {
                    guard let repo = app.worktree(app.workbench.workspaceId)?.repoId else {
                        NSSound.beep()
                        return
                    }
                    Task {
                        guard let routine = await RoutineSheet.run(app, repoId: repo),
                            await app.call(RoutineSet(routine: routine)) != nil
                        else { return }
                        app.workbench.open("routines:\(repo)")
                    }
                }
            ] + chosenCommands(app, pick, actions),
            tabs: [
                TabProvider(
                    schemes: ["routines"], make: { routinesTab(uri: $0, app: app) },
                    placeholder: { _ in (String(localized: "Routines"), .symbol("clock.arrow.circlepath"), nil) })
            ],
            skills: [routinesSkill]
        )
    }

    /// What the chosen row's right-click does, as commands on the routine chosen on the Routines tab in front.
    private static func chosenCommands(_ app: AppModel, _ pick: RoutinePick, _ actions: RoutineActions)
        -> [CommandSpec]
    {
        let chosen: @MainActor () -> Routine? = { pick.front(app) }
        let runOrStop: @MainActor ([String: JSONValue]) -> Void = { _ in
            guard let routine = chosen() else { return NSSound.beep() }
            Task { _ = await actions.runOrStop(routine, runs: pick.runs(app)) }
        }
        return [
            CommandSpec(
                id: "routines.runNow", title: "Run Routine Now",
                enabled: { chosen().map { !pick.isOpen($0, app) } ?? false }, run: runOrStop),
            CommandSpec(
                id: "routines.stop", title: "Stop Routine", enabled: { chosen().map { pick.isOpen($0, app) } ?? false },
                run: runOrStop),
            CommandSpec(id: "routines.edit", title: "Edit Routine…", enabled: { chosen() != nil }) { _ in
                if let routine = chosen() { actions.edit(routine) }
            },
            CommandSpec(id: "routines.turnOff", title: "Turn Routine Off", enabled: { chosen()?.enabled == true }) {
                _ in
                if let routine = chosen() { actions.turn(routine, on: false) }
            },
            CommandSpec(id: "routines.turnOn", title: "Turn Routine On", enabled: { chosen()?.enabled == false }) { _ in
                if let routine = chosen() { actions.turn(routine, on: true) }
            },
            CommandSpec(id: "routines.delete", title: "Delete Routine…", enabled: { chosen() != nil }) { _ in
                if let routine = chosen() { actions.delete(routine) }
            }
        ]
    }
}
