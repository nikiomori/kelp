import AppKit
import Core
import DesignKit
import KelpKit

/// The panel's Tasks source and the thread between an issue, its task and its pull request: the project's own tasks
/// beside the chat (Open, Waiting for You, Inbox, Logbook, as the Tasks tab's lists), an issue that knows it is a task,
/// and a pull request that knows the task its branch's chat worked on.
extension TasksViewController {
    /// The project's tasks, and what their chats do: the Tasks source follows them, and the issues and pull requests
    /// that are tasks say so.
    func followTasks() {
        track(owner: self, now: false) { [weak self] in
            self.map { vc in
                Values(vc.projectTasks.map(\.id), vc.projectTasks.map(\.work), vc.projectTasks.map(\.task))
            }
        } changed: { [weak self] _ in
            guard let self else { return }
            if shown == .tasks { load(quietly: true) } else { table.reloadData() }
        }
    }

    /// A double-click on a task shows its line on its page. False for any other row. (`tasksWatch` keeps the project's
    /// tasks read while the panel is built.)
    func openTask(at index: Int) -> Bool {
        guard case .task(let task)? = row(at: index) else { return false }
        TaskActions.open(app, task)
        return true
    }

    /// The project's task lines, with their chats' work, as its watch last read them.
    var projectTasks: [TaskRow] {
        guard let repoId else { return [] }
        let pages = app.latest(TasksEvent.self, repoId)?.pages ?? []
        return TaskViews.rows([(repoId, pages)], session: app.session)
    }

    /// The Tasks source's rows for the filter picked: the project's open tasks, those waiting for the person, the
    /// inbox, or the logbook (newest first).
    func taskRows(filter: Int) -> [Row] {
        let source: TaskSource =
            switch filter {
            case 1: .waiting
            case 2: .inbox
            case 3: .journal
            default: repoId.map(TaskSource.project) ?? .all
            }
        var rows = projectTasks.filter(source.holds)
        if source == .journal {
            rows.sort { ($0.task.at ?? $0.page.modified ?? 0) > ($1.task.at ?? $1.page.modified ?? 0) }
        }
        return rows.map(Row.task)
    }

    /// The task line of an issue, by its link.
    func task(issue url: String) -> TaskRow? { projectTasks.first { $0.task.issue == url } }

    /// The task whose chat worked on `branch` (a pull request's head).
    func task(branch: String) -> TaskRow? {
        projectTasks.first { row in
            (row.task.chats ?? []).contains { app.worktree(app.session($0)?.worktreeId)?.branch == branch }
        }
    }

    /// The task's row in the panel: the Tasks tab's row, with where the line is and its issue under the words.
    func taskCell(_ row: TaskRow) -> NSView {
        let place = [row.place, row.task.issueRef].compactMap { $0 }.joined(separator: " · ")
        return TaskCell(app, row, place: place) { [weak self] in self?.fillTaskMenu($0, row) }
    }

    func fillTaskMenu(_ menu: NSMenu, _ row: TaskRow) {
        TaskActions.fill(menu, app, row)
        menu.addItem(.separator())
        menu.add(String(localized: "Show in Tasks Tab")) { [app] in app.extensions.run("tasks.show", [:]) }
    }

    func addTaskItem(_ menu: NSMenu, title: String, url: String) {
        let item = Self.taskAction(app, known: task(issue: url), repo: repoId, title: title, url: url)
        menu.add(item.title, item.action)
    }

    /// An issue's "Add to Tasks", or "Show in Tasks" when `known` is its task already: a line in the inbox with the
    /// issue's link, its words the issue's title.
    static func taskAction(
        _ app: AppModel, known: TaskRow?, repo: String?, title: String, url: String
    ) -> (title: String, action: @MainActor () -> Void) {
        if let known { return (String(localized: "Show in Tasks"), { TaskActions.open(app, known) }) }
        return (
            String(localized: "Add to Tasks"),
            {
                guard let repo else { return }
                Task { _ = await TaskActions.add(app, repo: repo, text: title, issue: url) }
            }
        )
    }

    /// Writes down a chat started from an issue as the issue's task (the line it has, or a new one in the inbox), so
    /// work begun from the panel shows in Tasks at once.
    static func noteStarted(_ app: AppModel, repo: String, title: String, url: String, chat: String) {
        Task { _ = await TaskActions.add(app, repo: repo, text: title, issue: url, chat: chat) }
    }
}
