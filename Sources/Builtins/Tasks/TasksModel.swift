import Core
import Foundation
import KelpKit

/// What the Tasks tab shows: every project's task lines, from one watch per project (`WatchTopic.tasks`), with the
/// work of each line's chats from the sessions the app already has. The chosen list is the window's state (`UIState`),
/// so it is where it was the next time the tab opens.
@MainActor
@Observable
final class TasksModel {
    static let sourceKey = "tasks.source", boardKey = "tasks.board"

    @ObservationIgnored let app: AppModel
    var source: TaskSource {
        didSet {
            guard source != oldValue, !restoring else { return }
            chosen = true
            keepSource()
        }
    }
    /// True once the person picked a list here; until then the tab follows the one kept in the window's state, which
    /// may come after the tab (a tab restored at launch opens before the state is read).
    @ObservationIgnored private var chosen = false
    @ObservationIgnored private var restoring = false
    func restore(_ name: String?) {
        guard !chosen, let kept = Self.source(name), kept != source else { return }
        restoring = true
        source = kept
        restoring = false
    }
    var find = ""
    /// True when the rows show as the board. Kept as the list is, in the window's state.
    var board: Bool {
        didSet {
            guard board != oldValue else { return }
            let app = self.app, board = self.board
            Task { _ = await app.uiState.save(Self.boardKey, .bool(board)) }
        }
    }
    /// The projects whose tasks are watched while the tab shows.
    private(set) var watching: [String] = []
    @ObservationIgnored private var watches: [Watched] = []

    init(app: AppModel) {
        self.app = app
        source = Self.source(app.uiState[Self.sourceKey]?.string) ?? .now
        board = app.uiState[Self.boardKey]?.bool ?? false
    }

    func start() {
        let ids = app.repos.map(\.id)
        guard ids != watching || watches.isEmpty else { return }
        watching = ids
        watches = ids.map { id in
            let watch = Watched(.tasks, in: app)
            watch.key = id
            return watch
        }
    }
    func stop() { watches = [] }

    /// Every task line of the watched projects, with its chats' work.
    var rows: [TaskRow] {
        TaskViews.rows(watching.map { ($0, app.latest(TasksEvent.self, $0)?.pages ?? []) }, session: app.session)
    }

    /// Whether a project's lines haven't come yet.
    var waiting: Bool { watching.contains { app.latest(TasksEvent.self, $0) == nil } }

    /// Why a project's lines couldn't be read, by its name.
    var failures: [String] {
        watching.compactMap { id in app.latest(TasksEvent.self, id)?.error.map { "\(projectName(id)): \($0)" } }
    }

    func projectName(_ id: String) -> String { app.projectName(id) ?? id }

    /// Whether a chat of the task has its branch's pull request open, as the project's pull requests were last read.
    func inPR(_ row: TaskRow) -> Bool {
        let heads = Set((app.latest(PRsEvent.self, row.repo)?.prs ?? []).map(\.headRefName))
        return (row.task.chats ?? []).contains { chat in
            app.worktree(app.session(chat)?.worktreeId).map { heads.contains($0.branch) } ?? false
        }
    }

    /// The project new lines go to: the one on screen, or the first one.
    var currentProject: String? {
        if case .project(let id) = source { return id }
        return app.worktree(app.workbench.workspaceId)?.repoId ?? app.repos.first?.id
    }

    // A list that names a project or a tag isn't kept: it may be gone next time.
    private func keepSource() {
        let fixed: [TaskSource: String] = [
            .inbox: "inbox", .now: "now", .waiting: "waiting", .all: "all", .journal: "journal"
        ]
        guard let name = fixed[source] else { return }
        let app = self.app
        Task { _ = await app.uiState.save(Self.sourceKey, .string(name)) }
    }
    static func source(_ name: String?) -> TaskSource? {
        ["inbox": .inbox, "now": .now, "waiting": .waiting, "all": .all, "journal": .journal][name ?? ""]
    }
}
