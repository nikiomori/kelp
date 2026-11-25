import AppKit
import Core
import KelpKit

/// What Artifacts Overview shows: the pages of every project at once, from the same lists the Artifacts panel watches
/// (one per workspace), and what the user pinned or archived, which lives in the window's state (`UIState`) as two
/// lists of pages. Nothing on disk changes when a page is pinned or archived.
@MainActor
@Observable
final class OverviewModel {
    static let pinnedKey = "artifacts.pinned", archivedKey = "artifacts.archived"

    @ObservationIgnored let app: AppModel
    let pictures: ArtifactPictures
    var source: OverviewSource
    var find = ""
    private(set) var pinned: Set<String>
    private(set) var archived: Set<String>
    /// The workspaces whose lists are watched while the tab shows.
    private(set) var watching: [String] = []
    @ObservationIgnored private var watches: [Watched] = []

    init(app: AppModel) {
        self.app = app
        pictures = ArtifactPictures(app: app)
        pinned = Set(app.uiState.strings(Self.pinnedKey))
        archived = Set(app.uiState.strings(Self.archivedKey))
        // It opens on the project on screen, the place the user is in; All is a click away.
        source = app.worktree(app.workbench.workspaceId).map { .project($0.repoId) } ?? .all
    }

    /// Watches the pages of every workspace, as the panel watches the one on screen. A remote project's list is what
    /// its folder here keeps; the daemon asks its host for new pages only over a connection already open.
    func start() {
        let ids = app.worktrees.filter { !$0.archived }.map(\.id)
        guard ids != watching || watches.isEmpty else { return }
        watching = ids
        watches = ids.map { id in
            let watch = Watched(.artifacts, in: app)
            watch.key = id
            return watch
        }
    }
    func stop() { watches = [] }

    /// Every page of the watched workspaces, with the project each is in.
    var pages: [OverviewPage] {
        watching.flatMap { id -> [OverviewPage] in
            let repo = app.worktree(id)?.repoId ?? id
            return (app.latest(ArtifactsEvent.self, id)?.items ?? []).map {
                OverviewPage(item: $0, worktree: id, repo: repo)
            }
        }
    }

    /// Whether a watched list hasn't come yet.
    var waiting: Bool { watching.contains { app.latest(ArtifactsEvent.self, $0) == nil } }

    /// Why lists couldn't be read, by project name.
    var failures: [String] {
        watching.compactMap { id in
            app.latest(ArtifactsEvent.self, id)?.error.map { "\(projectName(app.worktree(id)?.repoId ?? id)): \($0)" }
        }
    }

    func projectName(_ repo: String) -> String { app.projectName(repo) ?? repo }

    /// A page's title without its project's name in front, as the panel shows it; its project is said under it.
    func title(_ page: OverviewPage) -> String {
        ArtifactsPanel.shortTitle(page.item.title, project: app.projectName(page.repo))
    }

    /// What the search finds a page by: its title, kind, project and the agent that made it.
    func words(_ page: OverviewPage) -> String {
        let kind = Artifacts.Kind(rawValue: page.item.type).map(ArtifactStart.title) ?? page.item.type
        let agent = page.item.session.flatMap(app.session)?.agent.map { app.catalog.name($0) } ?? ""
        return [page.item.title, kind, page.item.type, projectName(page.repo), agent].joined(separator: " ")
    }

    func togglePin(_ ids: [String]) { pinned = toggled(pinned, ids, key: Self.pinnedKey) }
    func toggleArchive(_ ids: [String]) { archived = toggled(archived, ids, key: Self.archivedKey) }

    /// Turns `ids` on in `set`, or off when all of them are on, and saves the list.
    private func toggled(_ set: Set<String>, _ ids: [String], key: String) -> Set<String> {
        let off = ids.allSatisfy(set.contains)
        let next = off ? set.subtracting(ids) : set.union(ids)
        let app = self.app
        Task { _ = await app.uiState.save(key, .array(next.sorted().map { .string($0) })) }
        return next
    }

    func keeping(_ page: OverviewPage) -> ArtifactActions.Keeping {
        ArtifactActions.Keeping(
            pinned: pinned.contains(page.id), archived: archived.contains(page.id),
            pin: { [weak self] in self?.togglePin([page.id]) },
            archive: { [weak self] in self?.toggleArchive([page.id]) })
    }
}
