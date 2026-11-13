import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI

/// GitHub PRs / issues / Projects, Linear and Jira tasks for the selected project. A PR or an issue opens in a tab of
/// its own (`ForgeItemTab`), where its actions are; a tracker's task shows below the list, with its state.
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
    /// What an action just did ("Merged #12"); a line only while it says something.
    let status = StatusLine(labelWithString: "")
    /// No rows: the list gives way to this, in the middle, with the button that helps (show all, sign in).
    let emptyView = EmptyStateView()
    let loadingView = LoadingView()
    let table = NSTableView()
    let detail = NSStackView()
    /// What the selected source lists.
    enum Row {
        case pr(GitHub.PullRequest), issue(GitHub.Issue), linear(LinearIssue), jira(JiraIssue), item(GitHub.ProjectItem)
        var url: String? {
            switch self {
            case .pr(let pr): pr.url
            case .issue(let issue): issue.url
            case .linear(let issue): issue.url
            case .jira(let issue): issue.url
            case .item(let item): item.url
            }
        }
    }
    /// What the source menu lists, in its order.
    enum Source: Int, CaseIterable {
        case pulls, issues, linear, jira, projects

        var title: String {
            switch self {
            case .pulls: String(localized: "Pull Requests")
            case .issues: String(localized: "Issues")
            case .linear: String(localized: "Linear")
            case .jira: String(localized: "Jira")
            case .projects: String(localized: "Projects")
            }
        }
        /// The filter menu's own items (Linear adds its teams to them, Projects its boards once they're read).
        var filters: [String] {
            switch self {
            case .pulls: [String(localized: "Open"), String(localized: "Recently Closed")]
            case .issues: [String(localized: "All open"), String(localized: "Assigned to me")]
            case .linear: [String(localized: "My issues")]
            case .jira: [String(localized: "My open issues"), String(localized: "Custom JQL…")]
            case .projects: [String(localized: "Loading projects…")]
            }
        }
        /// Read from the project's forge (gh or glab): a missing remote or CLI is what an error says. Linear and Jira
        /// need neither.
        var needsRemote: Bool { self != .linear && self != .jira }
        /// What to do when it can't be read and gh or glab has no fix to offer; nil: the error's own words.
        var connectHint: String? {
            switch self {
            case .linear: String(localized: "Connect Linear in Settings › Integrations")
            case .jira: String(localized: "Connect Jira in Settings › Integrations")
            case .projects: String(localized: "Projects need `gh auth refresh -s read:project`")
            case .pulls, .issues: nil
            }
        }
        /// Empty with no filter; nil: "Nothing here", and no filter narrows it to say so.
        var none: String? {
            switch self {
            case .pulls: String(localized: "No Open Pull Requests")
            case .issues: String(localized: "No Open Issues")
            case .linear, .jira, .projects: nil
            }
        }
    }
    var shown: Source { Source(rawValue: source.selectedTag()) ?? .pulls }
    var rows: [Row] = []
    /// What the table shows: the rows, with headings over the parts of a list of PRs.
    enum Line {
        case heading(String), row(Row)
    }
    var lines: [Line] = []
    func row(at index: Int) -> Row? {
        guard lines.indices.contains(index), case .row(let row) = lines[index] else { return nil }
        return row
    }
    /// Who gh is signed in as, and the branch on screen: which PRs are yours, wait for you, or are this branch's.
    private var viewer: String?
    /// The tab the last click opened: the next click puts its own there, unless a double-click kept it.
    var lastOpened: String?
    /// PRs changed since their tab was last opened: a dot on the row.
    private var unseen: Set<Int> = []
    private(set) var repoId: String?
    private var projectOwner: String?
    /// Bumped by every reload and every filter menu built: a reply for an older one (another project, list or filter)
    /// lands nowhere.
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
        detail.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
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
        setupButton.isHidden = true   // until a list is empty because of them
        view = root
        sourceChanged()
        nameSources()   // the workspace came before the view: show(worktree:) left naming to here
        hideUnconnectedTrackers()
        showDetailPane(false)   // until a tracker's task is picked
        // The project's open PRs as the daemon reads them again: the list follows, without a spinner.
        track(owner: self, now: false) { [weak self] in
            self.flatMap { $0.watch.prs($0.repoId) }
        } changed: { [weak self] in
            if let prs = $0 { self?.pushed(prs) }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(forgeChanged), name: PRWork.changed, object: nil)
    }

    private var laidOutWidth: CGFloat = 0
    override func viewDidLayout() {
        super.viewDidLayout()
        placeDivider()
        // Titles wrap at the panel's width: another width, other heights.
        if abs(table.bounds.width - laidOutWidth) > 1 {
            laidOutWidth = table.bounds.width
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<lines.count))
        }
    }

    /// A tracker's task, which shows below the list: the details' half of the split; anything else, the list alone.
    func showDetailPane(_ on: Bool) {
        guard split.arrangedSubviews.count > 1, split.arrangedSubviews[1].isHidden == on else { return }
        split.arrangedSubviews[1].isHidden = !on
        dividerPlaced = false
        placeDivider()
    }

    /// Once it's on screen with a height (a hidden split ignores the position): the list gets the larger part, details the
    /// rest. Again whenever the list was squeezed to less than a row: auto-hide moves the panel into its floater and back,
    /// a moment with no height that the list, the part that gives way, came back from with none.
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
    /// gh or glab isn't installed or signed in: runs what fixes it in a terminal tab.
    private var setup: Forge.Setup?
    lazy var checkAgain = ClosureButton(title: String(localized: "Check Again")) { [weak self] in self?.reload() }
    lazy var setupButton = ClosureButton(title: "") { [weak self] in
        if let self, let setup = self.setup { Forge.run(setup, in: app) }
    }

    func show(worktree id: String?) {
        let newRepoId = app.worktree(id)?.repoId ?? app.repos.first?.id
        guard newRepoId != repoId else { return }
        repoId = newRepoId
        guard isViewLoaded else { return }
        // Another project: drop its rows now, or Merge on one before the reload would act on a PR number in this repo.
        rows = []
        lines = []
        table.reloadData()
        showDetail(nil)
        reload()
        nameSources()
    }

    /// GitLab calls them merge requests.
    private func nameSources() {
        guard let repoId else { return }
        Task {
            let forge = await app.quiet(GitHubForge(repoId: repoId))   // the list's own load says what failed
            source.menu?.item(withTag: Source.pulls.rawValue)?.title =
                forge == "gitlab" ? String(localized: "Merge Requests") : Source.pulls.title
        }
    }

    /// Linear and Jira only once they're connected; the menu's last item says where to connect them.
    private func hideUnconnectedTrackers() {
        Task {
            let linear = await app.quiet(LinearStatus())?.connected ?? false   // unknown: as if not connected
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
        guard source.selectedTag() >= 0 else {   // "Connect…": Settings, and the list stays what it was
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
                for team in await app.quiet(LinearTeams()) ?? [] where menu == menus {   // the list's own load says what failed
                    filter.addItem(withTitle: String(localized: "Team: \(team.name)"))
                    filter.lastItem?.representedObject = team.id
                }
            }
        }
        reload()
    }

    /// Custom JQL asks for its query when picked, not on every refresh or workspace switch.
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

    /// Open PRs read again while they're the list: shown in place, the row picked kept.
    private func pushed(_ prs: [GitHub.PullRequest]) {
        guard shown == .pulls, filter.indexOfSelectedItem == 0, !filter.isHidden else { return }
        let picked = row(at: table.selectedRow).flatMap(Self.number)
        unseen = PRWatch.unseen(prs)
        rows = prs.map(Row.pr)
        lines = lined(rows)
        table.reloadData()
        reselect(picked)
        showEmpty(rows.isEmpty ? Source.pulls.none : nil)
    }

    /// The row of `number` picked again after the list was read again: the same tab, so nothing opens.
    private func reselect(_ number: Int?) {
        guard let number,
            let index = lines.firstIndex(where: { line in
                if case .row(let row) = line { Self.number(row) == number } else { false }
            })
        else { return }
        table.selectRowIndexes([index], byExtendingSelection: false)
    }
    /// A merge, a PR or a group made from here: the list says so now, not in two minutes.
    @objc private func forgeChanged() { load(quietly: true) }

    @objc func reload() { load() }

    /// `quietly`: a refresh nobody asked for, which says nothing while it reads and keeps the row picked.
    func load(quietly: Bool = false) {
        reloads += 1
        let gen = reloads
        guard let repoId else {
            rows = []
            lines = []
            table.reloadData()
            source.isHidden = true
            filter.isHidden = true   // nothing to choose among yet
            showEmpty(String(localized: "Select a project"))
            return
        }
        source.isHidden = false
        let slow = whileSlow { [weak self] in
            guard let self else { return }
            if rows.isEmpty {
                showLoading()
            } else if !quietly {
                status.stringValue = String(localized: "Loading…")
            }
        }
        let src = shown, filterIndex = filter.indexOfSelectedItem
        let picked = quietly ? row(at: table.selectedRow).flatMap(Self.number) : nil
        Task {
            defer { slow.cancel() }
            var rows: [Row] = []
            do {
                switch src {
                case .pulls:
                    viewer = await Viewer.get(app)
                    let prs = try await app.get(
                        GitHubPRs(repoId: repoId, filter: filterIndex == 1 ? "closed" : "open"))
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
                // Switched project, list or filter meanwhile: these rows belong to the old one.
                guard gen == reloads else { return }
                self.rows = rows
                lines = lined(rows)
                filter.isHidden = false
                // Empty because of the filter isn't the same as empty: say which, and offer the way back.
                let narrowed = rows.isEmpty && filterIndex > 0 && src.none != nil
                status.stringValue = ""
                let picked = filter.titleOfSelectedItem ?? ""
                let why =
                    narrowed ? String(localized: "None in “\(picked)”.") : src.none ?? String(localized: "Nothing here")
                showAll.isHidden = !narrowed
                setupButton.isHidden = true
                showEmpty(rows.isEmpty ? why : nil)
            } catch {
                guard gen == reloads else { return }
                showAll.isHidden = true
                let message = (error as? RPCError)?.message ?? "\(error)"
                self.rows = []
                lines = []
                status.stringValue = ""
                // The source stays: Linear and Jira need no remote.
                filter.isHidden = src.needsRemote && Forge.noRemote(message) != nil
                if src.needsRemote {
                    showList(false)
                    setup = emptyView.showForge(
                        message, failed: String(localized: "Couldn't load the list"), hint: src.connectHint,
                        setupButton: setupButton, checkAgain: checkAgain)
                } else {
                    setup = nil
                    setupButton.isHidden = true
                    showEmpty(src.connectHint ?? message, symbol: "link")
                }
            }
            table.reloadData()
            if picked != nil { reselect(picked) } else { showDetail(nil) }
        }
    }

    /// A PR's or an issue's number, which names it across a refresh.
    private static func number(_ row: Row) -> Int? {
        switch row {
        case .pr(let pr): pr.number
        case .issue(let issue): issue.number
        case .linear, .jira, .item: nil
        }
    }

    /// PRs in their parts (`ForgeRows.sections`), the rest as they came.
    private func lined(_ rows: [Row]) -> [Line] {
        let prs = rows.compactMap { if case .pr(let pr) = $0 { pr } else { nil } }
        guard !prs.isEmpty, prs.count == rows.count else { return rows.map(Line.row) }
        let branch = app.worktree(app.workbench.workspaceId)?.branch
        return ForgeRows.sections(prs, viewer: viewer, branch: branch).flatMap { title, part in
            (title.map { [Line.heading($0)] } ?? []) + part.map { Line.row(.pr($0)) }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { lines.count }
    func tableView(_ tableView: NSTableView, heightOfRow index: Int) -> CGFloat {
        guard let row = row(at: index) else { return TextSize.of(Metrics.rowSection) }
        let width = max(80, table.bounds.width - ForgeRows.titleMargin)
        switch row {
        case .pr(let pr): return ForgeRows.height(title: pr.title, width: width)
        case .issue(let issue): return ForgeRows.height(title: issue.title, width: width)
        case .linear, .jira, .item: return TextSize.of(Metrics.rowTwoLine)
        }
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow index: Int) -> Bool { row(at: index) != nil }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row index: Int) -> NSView? {
        guard let row = row(at: index) else {
            if case .heading(let text) = lines[index] { return ForgeRows.heading(text) }
            return nil
        }
        switch row {
        case .pr(let pr):
            let folder = repoId.map { PRWork(app: app, repoId: $0, pr: pr).worktree != nil } ?? false
            return ForgeRows.pr(pr, worktree: folder, unseen: unseen.contains(pr.number))
        case .issue(let issue):
            let working = app.worktrees.contains {
                $0.repoId == repoId && $0.issue == "#\(issue.number)" && !$0.archived
            }
            return ForgeRows.issue(issue, working: working)
        case .linear, .jira, .item: return trackerCell(row)
        }
    }

    /// A tracker's task, a project's item: its title and a line under it.
    private func trackerCell(_ row: Row) -> NSView {
        let (title, sub): (String, String) =
            switch row {
            case .linear(let issue): ("\(issue.identifier)  \(issue.title)", "\(issue.state.name) · \(issue.team.name)")
            case .jira(let issue):
                ("\(issue.key)  \(issue.title)", "\(issue.status) · \(issue.type) · \(issue.project)")
            case .item(let item): (item.title, "\(item.status ?? String(localized: "No status")) · \(item.type)")
            case .pr(let pr): ("#\(pr.number)  \(pr.title)", pr.author)
            case .issue(let issue): ("#\(issue.number)  \(issue.title)", "")
            }
        let t1 = NSTextField(labelWithString: title)
        t1.font = .ui(TextSize.body, weight: .medium)
        t1.lineBreakMode = .byTruncatingTail
        let t2 = NSTextField(labelWithString: sub)
        t2.font = .ui(TextSize.caption)
        t2.textColor = .secondaryLabelColor
        t2.lineBreakMode = .byTruncatingTail
        // Give way to the stack's insets: a title that doesn't fit is cut there, not pushed out past the line under it.
        for field in [t1, t2] { field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let stack = NSStackView(views: [t1, t2])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.lineGap
        stack.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.inset)
        return stack
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ListRowView() }
    func tableViewSelectionDidChange(_ notification: Notification) {
        let picked = row(at: table.selectedRow)
        switch picked {
        case .pr(let pr)?:
            open(.pr, pr.number)
            PRWatch.saw(pr)
            if unseen.remove(pr.number) != nil {
                table.reloadData(forRowIndexes: [table.selectedRow], columnIndexes: [0])
            }
        case .issue(let issue)?: open(.issue, issue.number)
        case .linear?, .jira?, .item?, nil: break
        }
        let tracker =
            picked.map { if case .pr = $0 { false } else if case .issue = $0 { false } else { true } } ?? false
        showDetailPane(tracker)
        showDetail(tracker ? picked : nil)
    }

    /// In a tab where the last click's was, unless that one was kept (a double-click) or closed since.
    private func open(_ kind: ForgeItemTab.Kind, _ number: Int) {
        guard let repoId else { return }
        let uri = ForgeItemTab.uri(kind, repoId: repoId, number: number)
        guard uri != lastOpened else { return }
        if let old = lastOpened { app.workbench.closeTab(uri: old, remember: false) }
        app.workbench.open(uri, focus: false)
        lastOpened = uri
    }

    /// A double-click keeps the tab: the next click opens one of its own.
    @objc private func keepOpened() { lastOpened = nil }

}
