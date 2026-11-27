import AppKit
import Core
import DesignKit
import WorkbenchKit

extension TasksEvent: Pushed {
    package var key: String { repo }
    package static var forgottenWith: WatchTopic? { .tasks }
}

/// What the person does to a task from any list (the Tasks tab, the Issues panel's Tasks source): tick it, give it up,
/// take an agent's proposal, open its page at its line, or hand it to an agent. Each change goes to the daemon, which
/// writes the line; the lists follow the project's watch (`WatchTopic.tasks`).
@MainActor
package enum TaskActions {
    /// The list's title and first heading when a first task makes it, in the window's language.
    package static var listNames: TaskListNames {
        TaskListNames(title: String(localized: "Tasks"), inbox: String(localized: "Inbox"))
    }

    /// The agent a task goes to with ▶: the one ⌘N starts.
    package static func lastAgent(_ app: AppModel) -> String { app.catalog.defaultAgent }

    /// Sets the person's decision. Giving up a task whose agent still works asks whether to stop the agent too: the
    /// task is cancelled either way, and the chats stay.
    package static func set(_ app: AppModel, _ row: TaskRow, _ state: TaskState) {
        let live = (row.task.chats ?? []).compactMap(app.session).filter {
            $0.status == .working || $0.status == .waiting
        }
        Task {
            if state == .cancelled, !live.isEmpty,
                await confirm(
                    String(localized: "Stop the task’s agent too?"),
                    detail: String(
                        localized:
                            "The task is cancelled either way. Conversations can be resumed from Session History."),
                    action: String(localized: "Stop Agent"), cancel: String(localized: "Keep It Working"),
                    destructive: true)
            {
                for chat in live { await app.call(SessionKill(id: chat.id)) }
            }
            _ = await app.call(TaskChange(path: row.page.path, task: TaskRef(row.task), state: state))
        }
    }
    /// The box's click: done, or open again.
    package static func toggle(_ app: AppModel, _ row: TaskRow) {
        if row.task.proposed == true { return take(app, row) }
        set(app, row, row.task.state == .open ? .done : .open)
    }
    static func take(_ app: AppModel, _ row: TaskRow) {
        Task { _ = await app.call(TaskChange(path: row.page.path, task: TaskRef(row.task), accept: true)) }
    }
    package static func remove(_ app: AppModel, _ row: TaskRow) {
        Task { _ = await app.call(TaskChange(path: row.page.path, task: TaskRef(row.task), remove: true)) }
    }

    /// Makes the task a page of its own, with a Plan heading for its steps, and opens it.
    package static func grow(_ app: AppModel, _ row: TaskRow) {
        Task {
            guard
                let line = await app.call(
                    TaskChange(
                        path: row.page.path, task: TaskRef(row.task), grow: String(localized: "Plan"),
                        goalLabel: String(localized: "Done when"))) ?? nil
            else { return }
            var grown = row
            grown.task = line
            open(app, grown)
        }
    }

    /// The page the task grew into, or the page it is on, at its line.
    package static func open(_ app: AppModel, _ row: TaskRow) {
        if let path = grownPage(row) {
            app.workbench.open(TabURI.file(path))
        } else {
            app.workbench.open(TabURI.file(row.page.path, line: row.task.line))
        }
    }

    /// The file of the page the task grew into, if it did.
    static func grownPage(_ row: TaskRow) -> String? {
        row.task.page.map {
            URL(fileURLWithPath: row.page.path).deletingLastPathComponent().appendingPathComponent($0)
                .standardizedFileURL.path
        }
    }

    /// Starts `agent` (the last one used when nil) on the task in its project's own screen, and links the chat to the
    /// line, which gets an id first if it has none. `plan` starts Claude Code in its plan mode: it writes the plan and
    /// asks, and changes no code.
    package static func run(_ app: AppModel, _ row: TaskRow, agent: String? = nil, plan: Bool = false) {
        let agent = agent ?? lastAgent(app)
        Task {
            guard let line = await app.call(TaskChange(path: row.page.path, task: TaskRef(row.task))) ?? nil,
                let id = line.id
            else { return }
            if app.worktree(app.workbench.workspaceId)?.repoId != row.repo, let screen = screen(app, row.repo) {
                app.workbench.show(workspace: screen)
            }
            guard let starter = app.workbench.starter else { return NSSound.beep() }
            let path = row.page.path
            // A grown page's "Done when" is the chat's goal: Claude Code's /goal, which Kelp follows; others read it.
            let goal = grownPage(row).flatMap { page in
                app.latest(TasksEvent.self, row.repo)?.pages.first { $0.path == page }?.goal
            }
            starter.newAgent(
                agent, prompt: brief(line, row.page, goal: goal, slash: agent == Session.claudeAgent),
                env: ["KELP_TASK": id],
                args: plan && agent == Session.claudeAgent ? ["--permission-mode", "plan"] : nil
            ) { session in
                Task { _ = await app.call(TaskChange(path: path, task: TaskRef(id: id), chat: session.id)) }
            }
        }
    }

    /// The task a chat was started for, as its project's tasks were last read (while something watches them).
    package static func task(of session: Session, in app: AppModel) -> TaskLine? {
        guard let repo = app.worktree(session.worktreeId)?.repoId else { return nil }
        return app.latest(TasksEvent.self, repo)?.pages.lazy.flatMap(\.tasks).first {
            $0.chats?.contains(session.id) == true
        }
    }

    /// The project's own screen: its oldest workspace, on the project's folder.
    static func screen(_ app: AppModel, _ repo: String) -> String? {
        let path = app.repo(repo)?.path
        return app.worktrees.first { $0.repoId == repo && $0.path == path && !$0.archived }?.id
    }

    /// What the agent is told: the task's words, where it is, and how to tick its steps. In English, as Kelp's other
    /// prompts to agents are.
    static func brief(_ task: TaskLine, _ page: TaskPage, goal: String? = nil, slash: Bool = false) -> String {
        var lines = [task.title, ""]
        if let issue = task.issue { lines.append("It comes from \(issue).") }
        lines.append(
            "This is a task from the project's task list (\(page.path), line \(task.line)). "
                + "`kelp task show \(task.id ?? "")` reads it with the steps under it; tick a step with "
                + "`kelp task done <id>` when it's done. The person closes the task itself.")
        guard let goal else { return lines.joined(separator: "\n") }
        // /goal takes one line: the condition, then the task it is for.
        if slash { return "/goal \(goal) — " + lines.filter { !$0.isEmpty }.joined(separator: " ") }
        return (lines + ["", "Done when: \(goal)"]).joined(separator: "\n")
    }

    /// Adds a task to the project's list (its inbox unless `under` names a heading), as the person writes it.
    package static func add(
        _ app: AppModel, repo: String, text: String, under: String? = nil, issue: String? = nil, chat: String? = nil
    ) async -> TaskAdd.Result? {
        await app.call(TaskAdd(repoId: repo, under: under, text: text, issue: issue, chat: chat, names: listNames))
    }

    /// The task's menu, the same in every list.
    package static func fill(_ menu: NSMenu, _ app: AppModel, _ row: TaskRow) {
        let isOpen = row.task.state == .open
        if row.task.proposed == true {
            menu.add(String(localized: "Take Task")) { take(app, row) }
            menu.add(String(localized: "Remove")) { remove(app, row) }
            menu.addItem(.separator())
        }
        if isOpen {
            let last = lastAgent(app)
            menu.add(String(localized: "Do with \(app.catalog.name(last))")) { run(app, row, agent: last) }
            let others = app.catalog.installed.filter { Session.isAgent($0.id) && $0.id != last }
            if !others.isEmpty {
                let sub = NSMenu()
                for agent in others {
                    sub.add(String(localized: "Do with \(agent.name)")) { run(app, row, agent: agent.id) }
                }
                menu.add(String(localized: "Do With"), submenu: sub)
            }
            if app.catalog.installed.contains(where: { $0.id == Session.claudeAgent }) {
                menu.add(String(localized: "Plan with Claude")) {
                    run(app, row, agent: Session.claudeAgent, plan: true)
                }
            }
            menu.addItem(.separator())
        }
        if isOpen, row.task.page == nil, row.task.proposed != true {
            menu.add(String(localized: "Open as Page")) { grow(app, row) }
        }
        menu.add(row.task.page == nil ? String(localized: "Show on Its Page") : String(localized: "Open Page")) {
            open(app, row)
        }
        let chats = (row.task.chats ?? []).compactMap(app.session)
        for chat in chats {
            menu.add(String(localized: "Open Chat “\(chat.displayTitle)”")) {
                app.workbench.open(TabURI.session(chat.id))
            }
        }
        menu.addItem(.separator())
        menu.add(isOpen ? String(localized: "Mark as Done") : String(localized: "Open Again")) {
            set(app, row, isOpen ? .done : .open)
        }
        if isOpen { menu.add(String(localized: "Cancel Task")) { set(app, row, .cancelled) } }
        if row.task.proposed != true, (row.task.chats ?? []).isEmpty {
            menu.add(String(localized: "Remove")) { remove(app, row) }
        }
    }
}
