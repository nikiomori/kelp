import AppKit
import Core
import DesignKit
import KelpKit

/// What Artifacts Overview shows: the pages of every project at once, from the same lists the Artifacts panel watches
/// (one per workspace). A page's tags and archive are in its record (`ArtifactChange`), where agents change them too;
/// what the user pinned, how they dressed their tags and when they closed an agent's change are the window's state
/// (`UIState`).
@MainActor
@Observable
final class OverviewModel {
    static let pinnedKey = "artifacts.pinned", changesSeenKey = "artifacts.agentChangesSeen"

    @ObservationIgnored let app: AppModel
    let pictures: ArtifactPictures
    var source: OverviewSource
    var find = ""
    private(set) var pinned: Set<String>
    private(set) var styles: [String: TagStyle]
    /// When the user closed the bar of an agent's change: changes up to then aren't offered again.
    private(set) var changesSeen: Double
    /// The workspaces whose lists are watched while the tab shows.
    private(set) var watching: [String] = []
    @ObservationIgnored private var watches: [Watched] = []

    init(app: AppModel) {
        self.app = app
        pictures = ArtifactPictures(app: app)
        pinned = Set(app.uiState.strings(Self.pinnedKey))
        styles = TagStyle.read(app.uiState[TagStyle.key])
        changesSeen = app.uiState[Self.changesSeenKey]?.number ?? 0
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

    /// What the search finds a page by: its title, kind, project, tags and the agent that made it.
    func words(_ page: OverviewPage) -> String {
        let kind = Artifacts.Kind(rawValue: page.item.type).map(ArtifactStart.title) ?? page.item.type
        let agent = page.item.session.flatMap(app.session)?.agent.map { app.catalog.name($0) } ?? ""
        return ([page.item.title, kind, page.item.type, projectName(page.repo), agent] + (page.item.tags ?? []))
            .joined(separator: " ")
    }

    /// Pins `ids`, or unpins them when all of them are pinned, and saves the list.
    func togglePin(_ ids: [String]) {
        let next = ids.allSatisfy(pinned.contains) ? pinned.subtracting(ids) : pinned.union(ids)
        pinned = next
        let app = self.app
        Task { _ = await app.uiState.save(Self.pinnedKey, .array(next.sorted().map { .string($0) })) }
    }

    /// The folder that holds a page and its record.
    func folder(_ page: OverviewPage) -> String? {
        app.worktree(page.worktree).map { Artifacts.dir(root: $0.path).appendingPathComponent(page.item.slug).path }
    }

    /// Asks the daemon for a change to `pages`' records; the list that comes back shows it.
    private func change(_ pages: [OverviewPage], _ make: (String) -> ArtifactChange) {
        let calls = pages.compactMap(folder).map(make), app = self.app
        Task { for call in calls { await app.call(call) } }
    }

    /// Moves `pages` to the archive, or out of it when all of them are there.
    func toggleArchive(_ pages: [OverviewPage]) {
        let out = pages.allSatisfy { $0.item.archived == true }
        change(pages) { ArtifactChange(folder: $0, archived: !out) }
    }

    /// Puts `tag` on `pages`, or takes it off when all of them have it.
    func toggleTag(_ tag: String, on pages: [OverviewPage]) {
        let off = pages.allSatisfy { $0.item.tags?.contains(tag) == true }
        change(pages) { ArtifactChange(folder: $0, add: off ? nil : [tag], remove: off ? [tag] : nil) }
    }

    /// Asks for a new tag's name and puts it on `pages`.
    func newTag(on pages: [OverviewPage]) {
        Task {
            let typed = await prompt(
                String(localized: "New Tag"), String(localized: "What the page is about, in a word or two."),
                action: String(localized: "Add Tag"))
            guard let tag = typed.flatMap(Artifacts.tag) else { return }
            change(pages) { ArtifactChange(folder: $0, add: [tag]) }
        }
    }

    /// Dresses `tag`: nil takes its style away, and it is grey again.
    func setStyle(_ style: TagStyle?, for tag: String) {
        styles[tag] = style
        let value = TagStyle.value(styles), app = self.app
        Task { _ = await app.uiState.save(TagStyle.key, value) }
    }

    /// The last agent's change still to undo, unless the user closed its bar.
    var agentChange: OverviewAgentChange? { OverviewPages.agentChange(pages, seen: changesSeen) }

    /// The pages the agent's change touched.
    private func touched(by change: OverviewAgentChange) -> [OverviewPage] {
        pages.filter { $0.item.agentChange?.session == change.session }
    }

    /// Puts back every page the agent's change touched.
    func undo(_ change: OverviewAgentChange) {
        self.change(touched(by: change)) { ArtifactChange(folder: $0, undo: true) }
        seen(change)
    }

    /// Closes the bar: the user keeps what the agent did, and the pages forget what they had before, so a later
    /// change by the same chat offers to undo only itself.
    func dismiss(_ change: OverviewAgentChange) {
        self.change(touched(by: change)) { ArtifactChange(folder: $0, keep: true) }
        seen(change)
    }

    private func seen(_ change: OverviewAgentChange) {
        changesSeen = change.at
        let app = self.app
        Task { _ = await app.uiState.save(Self.changesSeenKey, .double(change.at)) }
    }

    /// The pages agents work with now.
    var busy: Set<String> { PageAgents.busy(app) }

    /// The tags in use, most used first.
    var tags: [String] { OverviewPages.tags(pages) }

    func keeping(_ page: OverviewPage) -> ArtifactActions.Keeping {
        ArtifactActions.Keeping(
            pinned: pinned.contains(page.id), archived: page.item.archived == true, tags: page.item.tags ?? [],
            allTags: tags, pin: { [weak self] in self?.togglePin([page.id]) },
            archive: { [weak self] in self?.toggleArchive([page]) },
            tag: { [weak self] in self?.toggleTag($0, on: [page]) },
            newTag: { [weak self] in self?.newTag(on: [page]) })
    }
}
