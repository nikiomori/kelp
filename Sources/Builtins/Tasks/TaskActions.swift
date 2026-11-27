import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// What the person does to a task from any list (the Tasks tab, the Issues panel's Tasks source): tick it, give it up,
/// take an agent's proposal, open its page at its line, or hand it to an agent. Each change goes to the daemon, which
/// writes the line; the lists follow the project's watch (`WatchTopic.tasks`).
@MainActor
enum TaskActions {
    /// The agent the last task went to, offered first next time (the window's state); the one ⌘N starts until then.
    static let lastAgentKey = "tasks.lastAgent"
    static func lastAgent(_ app: AppModel) -> String {
        let last = app.uiState[lastAgentKey]?.string
        return app.catalog.installed.contains { $0.id == last && Session.isAgent($0.id) }
            ? last ?? app.catalog.defaultAgent : app.catalog.defaultAgent
    }

    /// Sets the person's decision. Giving up a task whose agent still works asks whether to stop the agent too: the
    /// task is cancelled either way, and the chats stay.
    static func set(_ app: AppModel, _ row: TaskRow, _ state: TaskState) {
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
    static func toggle(_ app: AppModel, _ row: TaskRow) {
        if row.task.proposed == true { return take(app, row) }
        set(app, row, row.task.state == .open ? .done : .open)
    }
    static func take(_ app: AppModel, _ row: TaskRow) {
        Task { _ = await app.call(TaskChange(path: row.page.path, task: TaskRef(row.task), accept: true)) }
    }
    static func remove(_ app: AppModel, _ row: TaskRow) {
        Task { _ = await app.call(TaskChange(path: row.page.path, task: TaskRef(row.task), remove: true)) }
    }

    /// Makes the task a page of its own, with a Plan heading for its steps, and opens it.
    static func grow(_ app: AppModel, _ row: TaskRow) {
        Task { if let grown = await Self.grown(app, row) { open(app, grown) } }
    }
    /// The row once its task grew into a page with a Plan heading; nil when it didn't.
    private static func grown(_ app: AppModel, _ row: TaskRow) async -> TaskRow? {
        let change = TaskChange(
            path: row.page.path, task: TaskRef(row.task), grow: String(localized: "Plan"),
            goalLabel: String(localized: "Done when"))
        guard let line = await app.call(change) ?? nil else { return nil }
        var grown = row
        grown.task = line
        return grown
    }

    /// Takes the task, with its chats, under `heading` of the page `path`.
    static func move(_ app: AppModel, _ row: TaskRow, to path: String, under heading: String?) {
        Task {
            _ = await app.call(TaskChange(path: row.page.path, task: TaskRef(row.task), move: path, under: heading))
        }
    }

    /// Several lines become one task: the first grows into a page, the others go under its Plan, as Craft groups
    /// blocks into a page (⌥⌘G).
    static func group(_ app: AppModel, _ rows: [TaskRow]) {
        guard let first = rows.first, rows.count > 1 else { return NSSound.beep() }
        Task {
            guard let grown = await Self.grown(app, first), let page = grown.grownPage else { return }
            for row in rows.dropFirst() {
                _ = await app.call(
                    TaskChange(
                        path: row.page.path, task: TaskRef(row.task), move: page, under: String(localized: "Plan")))
            }
            open(app, grown)
        }
    }

    /// The places a task can move to in its project: the list's headings, then the pages tasks grew into.
    static func places(_ app: AppModel, _ row: TaskRow) -> [(title: String, path: String, under: String?)] {
        let pages = app.latest(TasksEvent.self, row.repo)?.pages ?? []
        let list = pages.first { $0.isList == true }
        let headings = (list?.sections ?? []).map { (title: $0, path: list?.path ?? "", under: Optional($0)) }
        let grown = pages.filter { $0.isList != true && $0.path != row.page.path }.map {
            (title: $0.title, path: $0.path, under: String?.none)
        }
        return (headings + grown).filter { !($0.path == row.page.path && $0.under == row.task.section) }
    }

    /// The page the task grew into, or the page it is on, at its line.
    static func open(_ app: AppModel, _ row: TaskRow) {
        if let path = row.grownPage {
            app.workbench.open(TabURI.file(path))
        } else {
            app.workbench.open(TabURI.file(row.page.path, line: row.task.line))
        }
    }

    /// Starts `agent` (the last one used when nil) on the task in its project's own screen, and links the chat to the
    /// line, which gets an id first if it has none. `plan` starts Claude Code in its plan mode: it writes the plan and
    /// asks, and changes no code.
    static func run(_ app: AppModel, _ row: TaskRow, agent: String? = nil, plan: Bool = false) {
        let agent = agent ?? lastAgent(app)
        Task { _ = await app.uiState.save(lastAgentKey, .string(agent)) }
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
            let goal = row.grownPage.flatMap { page in
                app.latest(TasksEvent.self, row.repo)?.pages.first { $0.path == page }?.goal
            }
            // A task from an issue carries someone else's words: the brief waits on the line for the person's Return.
            starter.newAgent(
                agent, prompt: brief(line, row.page, goal: goal, slash: agent == Session.claudeAgent),
                draft: line.issue != nil, env: ["KELP_TASK": id],
                args: plan && agent == Session.claudeAgent ? ["--permission-mode", "plan"] : nil
            ) { session in
                Task { _ = await app.call(TaskChange(path: path, task: TaskRef(id: id), chat: session.id)) }
            }
        }
    }

    /// The project's own screen: its oldest workspace, on the project's folder.
    static func screen(_ app: AppModel, _ repo: String) -> String? {
        let path = app.repo(repo)?.path
        return app.worktrees.first { $0.repoId == repo && $0.path == path && !$0.archived }?.id
    }

    /// What the agent is told (`TaskLines.brief`).
    static func brief(_ task: TaskLine, _ page: TaskPage, goal: String? = nil, slash: Bool = false) -> String {
        TaskLines.brief(task, page: page.path, goal: goal, slash: slash)
    }

    /// Adds a task to the project's list (its inbox unless `under` names a heading), as the person writes it.
    static func add(
        _ app: AppModel, repo: String, text: String, under: String? = nil, issue: String? = nil, chat: String? = nil
    ) async -> TaskAdd.Result? {
        await app.call(TaskAdd(repoId: repo, under: under, text: text, issue: issue, chat: chat, names: .localized))
    }

    /// The task's menu, the same in every list.
    static func fill(_ menu: NSMenu, _ app: AppModel, _ row: TaskRow) {
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
        let places = places(app, row)
        if isOpen, !places.isEmpty {
            let sub = NSMenu()
            for place in places { sub.add(place.title) { move(app, row, to: place.path, under: place.under) } }
            menu.add(String(localized: "Move To"), submenu: sub)
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
