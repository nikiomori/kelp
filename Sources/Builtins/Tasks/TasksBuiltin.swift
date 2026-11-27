import AppKit
import Core
import KelpKit

extension Builtins {

    /// Tasks: `- [ ]` lines on the projects' pages, gathered in a tab of their own (Window › Tasks), written down with
    /// ⌃⌥⌘T from anywhere, and handed to agents. The Issues panel lists the project's tasks too (its Tasks source).
    package static let tasks = Builtin(
        "kelp.tasks", "Tasks", "Your tasks on the projects’ pages, handed to agents.", icon: "checklist"
    ) { app in
        let entry = app.part {
            let made = QuickEntry(app: app)
            made.hotKey.register()
            return made
        }
        return Contributions(
            editors: [EditorSpec(id: "tasks.open", title: "Tasks", icon: "checklist") { _ in TasksTab.uri }],
            commands: [
                cmd("tasks.show", "Tasks") { app.workbench.open(TasksTab.uri) },
                cmd("tasks.new", "New Task…") { entry.show(repo: nil) },
                CommandSpec(
                    id: "tasks.group", title: "Tasks: Make One Task of the Chosen", key: "opt+cmd+g",
                    enabled: { (app.workbench.focusedContent as? TasksTab)?.canGroup ?? false }
                ) { _ in (app.workbench.focusedContent as? TasksTab)?.group() }
            ],
            tabs: [
                TabProvider(
                    schemes: ["tasks"], make: { TasksTab(uri: $0, app: app) },
                    placeholder: { _ in (TasksTab.title, .symbol("checklist"), nil) })
            ],
            skills: [tasksSkill],
            tasks: ListedTasks(
                cell: { TaskCell(app, $0, place: $1, fill: $2) }, fill: { TaskActions.fill($0, app, $1) },
                open: { TaskActions.open(app, $0) }, run: { TaskActions.run(app, $0) },
                lastAgent: { TaskActions.lastAgent(app) })
        )
    }
}
