import AppKit
import Core
import KelpKit

extension Builtins {

    /// Agents on a schedule: the project's routines as a tab (from "+", the empty workspace and the command palette).
    package static let routines = Builtin("kelp.routines", "Routines", "Agents on a schedule, each in a workspace of its own.",
                                          icon: "clock.arrow.circlepath") { app in
        var c = Contributions()
        c.tabs = [TabProvider(schemes: ["routines"]) { RoutinesTab(uri: $0, app: app) }]
        c.editors = [EditorSpec(id: "routines.open", title: "Routines", icon: "clock.arrow.circlepath") { ctx in
            ctx.workspace.map { "routines:\($0.repoId)" }
        }]
        c.commands = [
            cmd("routines.show", "Routines") { if let r = app.worktree(app.workbench.workspaceId)?.repoId { app.workbench.open("routines:\(r)") } },
            cmd("routines.new", "New Routine…") {
                guard let repo = app.worktree(app.workbench.workspaceId)?.repoId else { NSSound.beep(); return }
                Task {
                    guard let r = await RoutineSheet.run(app, repoId: repo), await app.call(RoutineSet(routine: r)) != nil else { return }
                    app.workbench.open("routines:\(repo)")
                }
            }
        ]
        return c
    }
}
