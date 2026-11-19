import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI

/// GitHub PRs, issues and Projects, and Linear and Jira tasks, for the selected project. A PR or an issue opens in a
/// tab of its own (`ForgeItemTab`), where its actions are. A tracker's task shows below the list, with its state.
@MainActor
final class TasksViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let app: AppModel
    let watch: PRWatch
    init(app: AppModel, watch: PRWatch) {
        self.app = app
        self.watch = watch
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }
    let source = PointerPopUpButton()
    let split = NSSplitView()
    private var dividerPlaced = false
    let filter = PointerPopUpButton()
    /// What an action just did ("Merged #12"). The line shows only while it says something.
    let status = StatusLine(labelWithString: "")
    /// With no rows, the list gives way to this, in the middle, with the button that helps (show all, sign in).
    let emptyView = EmptyStateView()
    let loadingView = LoadingView(rows: true)
    lazy var refresh = IconButton(
        .symbol("arrow.clockwise"), tip: String(localized: "Refresh"), target: self, action: #selector(reload))
    let table = NSTableView()
    let detail = NSStackView()
    var shown: Source { Source(rawValue: source.selectedTag()) ?? .pulls }
    var rows: [Row] = []
    var lines: [Line] = []
    /// The project, list and filter the rows were read for: another list's rows don't stay under this one's error.
    var listed: String?
    private(set) lazy var failureBar = FailureBar { [weak self] in self?.reload() }
    func row(at index: Int) -> Row? {
        guard lines.indices.contains(index), case .row(let row) = lines[index] else { return nil }
        return row
    }
    /// Who gh is signed in as, used with the branch on screen to tell which PRs are yours, wait for you, or are this
    /// branch's.
    private var viewer: String?
    /// The tab the last click opened. The next click puts its own tab there, unless a double-click kept it.
    var lastOpened: String?
    /// PRs that changed since their tab was last opened, which get a dot on the row.
    var unseen: Set<Int> = []
    private(set) var repoId: String?
    private var projectOwner: String?
    /// Bumped by every reload and every filter menu built, so a reply for an older one (another project, list or
    /// filter) lands nowhere.
    private var reloads = 0, menus = 0
    private var jiraJQL = "project = ENG AND statusCategory != Done ORDER BY priority DESC"

    override func loadView() {
        for item in Source.allCases {
            source.addItem(withTitle: item.title)
            source.lastItem?.tag = item.rawValue
        }
        source.selectItem(withTag: Source.pulls.rawValue)
        source.target = self
        source.action = #selector(sourceChanged)
        filter.target = self
        filter.action = #selector(filterChanged)
        let bar = makeBar()

        let ts = table.plainList("t")
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(keepOpened)
        table.delegate = self
        table.menu = NSMenu()
        table.menu?.delegate = self
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = Metrics.gapWide
        detail.edgeInsets = NSEdgeInsets(
            top: Metrics.inset, left: Metrics.inset, bottom: Metrics.inset, right: Metrics.inset)
        let ds = NSScrollView()
        ds.hasVerticalScroller = true
        ds.drawsBackground = false
        let flip = FlippedView()
        flip.translatesAutoresizingMaskIntoConstraints = false
        ds.documentView = flip
        flip.pin(detail)
        flip.widthAnchor.constraint(equalTo: ds.contentView.widthAnchor).isActive = true
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(ts)
        split.addArrangedSubview(ds)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 1)
        let root = stacked(bar, split)
        emptyView.place(in: root, under: bar)
        loadingView.place(in: root, under: bar)
        showAll.isHidden = true
        setupButton.isHidden = true   // until a list is empty because gh or glab isn't set up
        view = root
        sourceChanged()
        nameSources()   // the workspace came before the view, so show(worktree:) left the naming to here
        hideUnconnectedTrackers()
        showDetailPane(false)   // until a tracker's task is picked
        // As the daemon reads the project's open PRs again, the list follows, without a spinner.
        track(owner: self, now: false) { [weak self] in
            self.flatMap { $0.watch.prs($0.repoId) }
        } changed: { [weak self] in
            if let prs = $0 { self?.pushed(prs) }
        }
        // A task started from an item makes its project a workspace, so the list reads again, quietly, to mark it.
        track(owner: self, now: false) { [weak self] in
            self.map { vc in vc.app.worktrees.filter { $0.repoId == vc.repoId }.map(\.id) } ?? []
        } changed: { [weak self] _ in
            self?.load(quietly: true)
        }
    }

    private var laidOutWidth: CGFloat = 0
    private let resized = Debounce()
    override func viewDidLayout() {
        super.viewDidLayout()
        placeDivider()
        // Titles wrap at the panel's width, so another width means other heights. While the inspector's edge is
        // dragged, they are measured once it rests, because measuring at each step of the drag remeasured every title.
        guard abs(table.bounds.width - laidOutWidth) > 1 else { return }
        if laidOutWidth == 0 { return remeasure() }
        resized.after(0.1) { [weak self] in self?.remeasure() }
    }
    private func remeasure() {
        guard abs(table.bounds.width - laidOutWidth) > 1 else { return }
        laidOutWidth = table.bounds.width
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<lines.count))
    }

    /// Shows the details' half of the split for a tracker's task, which shows below the list; anything else shows the
    /// list alone.
    func showDetailPane(_ on: Bool) {
        guard split.arrangedSubviews.count > 1, split.arrangedSubviews[1].isHidden == on else { return }
        split.arrangedSubviews[1].isHidden = !on
        dividerPlaced = false
        placeDivider()
    }

    /// Places the divider once the split is on screen with a height (a hidden split ignores the position), giving the
    /// list the larger part and the details the rest. It runs again whenever the list was squeezed to less than a row,
    /// because auto-hide moves the panel into its floater and back. That is a moment with no height, and the list, the
    /// part that gives way, came back from it with none.
    func placeDivider() {
        guard !split.isHidden, split.arrangedSubviews.last?.isHidden == false, split.bounds.height > 100 else { return }
        split.layoutSubtreeIfNeeded()   // its panes' heights for its height now, not the last one
        let squeezed = (split.arrangedSubviews.first?.frame.height ?? 0) < table.rowHeight
        guard !dividerPlaced || squeezed else { return }
        dividerPlaced = true
        split.setPosition(split.bounds.height * 0.55, ofDividerAt: 0)
    }

    lazy var showAll = ClosureButton(title: String(localized: "Show All Open")) { [weak self] in
        self?.filter.selectItem(at: 0)
        self?.reload()
    }
    /// The setup that runs in a terminal tab when gh or glab isn't installed or signed in.
    var setup: Forge.Setup?
    lazy var checkAgain = ClosureButton(title: String(localized: "Try Again")) { [weak self] in self?.reload() }
    lazy var setupButton = ClosureButton(title: "") { [weak self] in
        if let self, let setup = self.setup { Forge.run(setup, in: app) }
    }

    func show(worktree id: String?) {
        let newRepoId = app.worktree(id)?.repoId ?? app.repos.first?.id
        guard newRepoId != repoId else { return }
        repoId = newRepoId
        guard isViewLoaded else { return }
        // For another project, drop the rows now, or Merge on one of them before the reload would act on a PR number
        // in this repo.
        rows = []
        lines = []
        failureBar.show(nil)
        table.reloadData()
        showDetail(nil)
        reload()
        nameSources()
    }

    /// Names the sources for the project's forge, because GitLab calls them merge requests.
    private func nameSources() {
        guard let repoId else { return }
        Task {
            let forge = await app.quiet(GitHubForge(repoId: repoId))   // the list's own load says what failed
            source.menu?.item(withTag: Source.pulls.rawValue)?.title =
                forge == "gitlab" ? String(localized: "Merge Requests") : Source.pulls.title
        }
    }

    /// Lists Linear and Jira only once they're connected; the menu's last item says where to connect them.
    private func hideUnconnectedTrackers() {
        Task {
            let linear = await app.quiet(LinearStatus())?.connected ?? false   // unknown counts as not connected
            let jira = await app.quiet(JiraStatus())?.connected ?? false
            for (tracker, on) in [(Source.linear, linear), (Source.jira, jira)] where !on {
                if let item = source.menu?.item(withTag: tracker.rawValue) { source.menu?.removeItem(item) }
            }
            guard !linear || !jira else { return }
            source.menu?.addItem(.separator())
            source.addItem(withTitle: String(localized: "Connect Linear or Jira…"))
            source.lastItem?.tag = -1
        }
    }

    @objc private func sourceChanged() {
        guard source.selectedTag() >= 0 else {   // "Connect…" opens Settings, and the list stays what it was
            source.selectItem(withTag: Source.pulls.rawValue)
            app.extensions.run("workbench.openSettings", ["section": .string("integrations")])
            return
        }
        filter.removeAllItems()
        menus += 1
        let menu = menus
        filter.addItems(withTitles: shown.filters)
        if shown == .linear {
            Task {   // team boards
                // The list's own load says what failed.
                for team in await app.quiet(LinearTeams()) ?? [] where menu == menus {
                    filter.addItem(withTitle: String(localized: "Team: \(team.name)"))
                    filter.lastItem?.representedObject = team.id
                }
            }
        }
        reload()
    }

    /// Custom JQL asks for its query when it's picked, not on every refresh or workspace switch.
    @objc private func filterChanged() {
        guard shown == .jira, filter.indexOfSelectedItem == 1 else {
            reload()
            return
        }
        Task {
            if let jql = await prompt(String(localized: "Jira search"), "JQL", initial: jiraJQL) {
                jiraJQL = jql
            } else {
                filter.selectItem(at: 0)
            }
            reload()
        }
    }

    /// Shows the open PRs, read again while they're the list, in place, keeping the row picked.
    private func pushed(_ prs: [GitHub.PullRequest]) {
        guard shown == .pulls, filter.indexOfSelectedItem == 0, !filter.isHidden else { return }
        let picked = row(at: table.selectedRow).flatMap(Self.number)
        unseen = PRWatch.unseen(prs)
        let places = table.rowPlaces(lineKey), old = Self.keys(rows)
        rows = prs.map(Row.pr)
        lines = lined(rows)
        listed = listKey(.pulls, 0)
        failureBar.show(nil)
        let now = Self.keys(rows)
        table.reloadSettling(from: places, came: now.subtracting(old), gone: old.subtracting(now), lineKey) {
            table.reloadData()
            reselect(picked)
        }
        showEmpty(rows.isEmpty ? Source.pulls.none : nil)
    }

    func listKey(_ source: Source, _ filter: Int) -> String { "\(repoId ?? "")/\(source.rawValue)/\(filter)" }

    /// Picks the row of `number` again after the list was read again. It is the same tab, so nothing opens.
    func reselect(_ number: Int?) {
        guard let number,
            let index = lines.firstIndex(where: { line in
                if case .row(let row) = line { Self.number(row) == number } else { false }
            })
        else { return }
        table.selectRowIndexes([index], byExtendingSelection: false)
    }
    /// Reads the list again after a merge, a PR or a group made from here, so the list says so now, not in two minutes.
    @objc func reload() { load() }

    /// `quietly` means a refresh nobody asked for, which says nothing while it reads and keeps the row picked.
    func load(quietly: Bool = false) {
        reloads += 1
        let gen = reloads
        guard let repoId else {
            rows = []
            lines = []
            failureBar.show(nil)
            table.reloadData()
            source.isHidden = true
            filter.isHidden = true   // there is nothing to choose among yet
            showEmpty(String(localized: "Select a project"))
            return
        }
        source.isHidden = false
        let slow = showWait(quietly: quietly)
        // When the user asked, over rows it keeps showing, Refresh answers the click at once.
        if !quietly, !rows.isEmpty { refresh.busy = true }
        let src = shown, filterIndex = filter.indexOfSelectedItem
        let picked = quietly ? row(at: table.selectedRow).flatMap(Self.number) : nil
        Task {
            defer {
                slow?.cancel()
                if gen == reloads { refresh.busy = false }
            }
            var rows: [Row] = []
            do {
                switch src {
                case .pulls:
                    viewer = await Viewer.get(app)
                    // Open PRs come from the project's watch (asked again on a click), the latest closed ones from gh.
                    let prs =
                        filterIndex == 1
                        ? try await app.get(GitHubPRs(repoId: repoId, filter: .closed))
                        : try await PRsEvent.open(repoId, in: app, again: !quietly)
                    unseen = PRWatch.unseen(prs)
                    rows = prs.map(Row.pr)
                case .issues:
                    rows = try await app.get(GitHubIssues(repoId: repoId, filter: filterIndex == 1 ? "mine" : "open"))
                        .map(Row.issue)
                case .linear:
                    let team = filter.selectedItem?.representedObject as? String
                    var issues = try await app.get(LinearIssues(teamId: team))
                    if team != nil { issues.sort { $0.state.name < $1.state.name } }
                    rows = issues.map(Row.linear)
                case .jira:
                    rows = try await app.get(JiraIssues(jql: filterIndex == 1 ? jiraJQL : nil)).map(Row.jira)
                case .projects:
                    if filter.itemTitles == Source.projects.filters {
                        let ps = try await app.get(GitHubProjects(repoId: repoId))
                        guard gen == reloads else { return }
                        filter.removeAllItems()
                        for project in ps {
                            filter.addItem(withTitle: project.title)
                            filter.lastItem?.tag = project.number
                        }
                        projectOwner = ps.first.flatMap { URL(string: $0.url)?.pathComponents.dropFirst(2).first }
                    }
                    if let owner = projectOwner, let number = filter.selectedItem?.tag {
                        rows = try await app.get(GitHubProjectItems(owner: owner, number: number))
                            .sorted { ($0.status ?? "~") < ($1.status ?? "~") }.map(Row.item)
                    } else {
                        rows = []
                    }
                }
                await loadingView.settled()
                // When the project, list or filter switched meanwhile, these rows belong to the old one.
                guard gen == reloads else { return }
                show(rows, of: src, filter: filterIndex, picked: picked)
            } catch {
                await loadingView.settled()
                guard gen == reloads else { return }
                let message = (error as? RPCError)?.message ?? "\(error)"
                // The same list's rows, read before, stay under a line that says why they couldn't be read again.
                if !self.rows.isEmpty, listed == listKey(src, filterIndex), Forge.passing(message) {
                    return failureBar.show(message)
                }
                showFailure(message, of: src)
            }
        }
    }

    /// PRs in their parts (`ForgeRows.sections`), and the other rows as they came.
    func lined(_ rows: [Row]) -> [Line] {
        let prs = rows.compactMap { if case .pr(let pr) = $0 { pr } else { nil } }
        guard !prs.isEmpty, prs.count == rows.count else { return rows.map(Line.row) }
        let branch = app.worktree(app.workbench.workspaceId)?.branch
        return ForgeRows.sections(prs, viewer: viewer, branch: branch).flatMap { title, part in
            (title.map { [Line.heading($0)] } ?? []) + part.map { Line.row(.pr($0)) }
        }
    }

    /// Opens the item in place of the tab the last click opened, unless that tab was kept (a double-click) or closed
    /// since.
    func open(_ kind: ForgeItemTab.Kind, _ number: Int) {
        guard let repoId else { return }
        let uri = ForgeItemTab.uri(kind, repoId: repoId, number: number)
        guard uri != lastOpened else { return }
        if let old = lastOpened { app.workbench.closeTab(uri: old, remember: false) }
        app.workbench.open(uri, focus: false)
        lastOpened = uri
    }

    /// A double-click keeps the tab, so the next click opens one of its own.
    @objc private func keepOpened() { lastOpened = nil }

}
