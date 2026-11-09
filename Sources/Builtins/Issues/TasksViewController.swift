import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI

/// GitHub PRs / issues / Projects and Linear tasks for the selected project, with the actions that close the loop:
/// issue → worktree + agent, failed check / review comments → agent, PR merge, Linear state.
@MainActor
final class TasksViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let app: AppModel
    init(app: AppModel) {
        self.app = app
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
    var rows: [Row] = []
    private(set) var repoId: String?
    private var projectOwner: String?
    /// Bumped by every reload and every filter menu built: a reply for an older one (another project, list or filter)
    /// lands nowhere.
    private var reloads = 0, menus = 0
    private var jiraJQL = "project = ENG AND statusCategory != Done ORDER BY priority DESC"

    override func loadView() {
        source.addItems(withTitles: [
            String(localized: "Pull Requests"), String(localized: "Issues"),
            String(localized: "Linear"), String(localized: "Jira"), String(localized: "Projects")
        ])
        source.selectItem(at: 0)
        source.target = self
        source.action = #selector(sourceChanged)
        filter.target = self
        filter.action = #selector(filterChanged)
        let bar = makeBar()

        let ts = table.plainList("t")
        table.rowHeight = TextSize.of(Metrics.rowTwoLine)
        table.dataSource = self
        table.delegate = self
        table.menu = NSMenu()
        table.menu?.delegate = self
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 10
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
        showAll.isHidden = true
        setupButton.isHidden = true   // until a list is empty because of them
        view = root
        sourceChanged()
        nameSources()   // the workspace came before the view: show(worktree:) left naming to here
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        placeDivider()
    }

    /// Once it's on screen with a height (a hidden split ignores the position): the list gets the larger part, details the rest.
    func placeDivider() {
        guard !dividerPlaced, !split.isHidden, split.bounds.height > 100 else { return }
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
            source.item(at: 0)?.title =
                forge == "gitlab" ? String(localized: "Merge Requests") : String(localized: "Pull Requests")
        }
    }

    @objc private func sourceChanged() {
        filter.removeAllItems()
        menus += 1
        let menu = menus
        switch source.indexOfSelectedItem {
        case 0:
            filter.addItems(withTitles: [
                String(localized: "All open"), String(localized: "Mine"), String(localized: "Review requested")
            ])
        case 1: filter.addItems(withTitles: [String(localized: "All open"), String(localized: "Assigned to me")])
        case 3: filter.addItems(withTitles: [String(localized: "My open issues"), String(localized: "Custom JQL…")])
        case 2:
            filter.addItems(withTitles: [String(localized: "My issues")])
            Task {   // team boards
                for team in await app.quiet(LinearTeams()) ?? [] where menu == menus {   // the list's own load says what failed
                    filter.addItem(withTitle: String(localized: "Team: \(team.name)"))
                    filter.lastItem?.representedObject = team.id
                }
            }
        default: filter.addItems(withTitles: [String(localized: "Loading projects…")])
        }
        reload()
    }

    /// Custom JQL asks for its query when picked, not on every refresh or workspace switch.
    @objc private func filterChanged() {
        guard source.indexOfSelectedItem == 3, filter.indexOfSelectedItem == 1 else {
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

    @objc func reload() {
        reloads += 1
        let gen = reloads
        guard let repoId else {
            rows = []
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
                showEmpty(String(localized: "Loading…"), symbol: "ellipsis")
            } else {
                status.stringValue = String(localized: "Loading…")
            }
        }
        let src = source.indexOfSelectedItem, filterIndex = filter.indexOfSelectedItem
        Task {
            defer { slow.cancel() }
            var rows: [Row] = []
            do {
                switch src {
                case 0:
                    rows = try await app.get(
                        GitHubPRs(repoId: repoId, filter: ["open", "mine", "review"][max(0, filterIndex)])
                    )
                    .map(Row.pr)
                case 1:
                    rows = try await app.get(GitHubIssues(repoId: repoId, filter: filterIndex == 1 ? "mine" : "open"))
                        .map(Row.issue)
                case 2:
                    let team = filter.selectedItem?.representedObject as? String
                    var issues = try await app.get(LinearIssues(teamId: team))
                    if team != nil { issues.sort { $0.state.name < $1.state.name } }
                    rows = issues.map(Row.linear)
                case 3:
                    rows = try await app.get(JiraIssues(jql: filterIndex == 1 ? jiraJQL : nil)).map(Row.jira)
                default:
                    if filter.itemTitles.first == String(localized: "Loading projects…") {
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
                filter.isHidden = false
                // Empty because of the filter isn't the same as empty: say which, and offer the way back.
                let narrowed = rows.isEmpty && filterIndex > 0 && src < 2
                let none = [String(localized: "No open pull requests"), String(localized: "No open issues")]
                status.stringValue = ""
                let picked = filter.titleOfSelectedItem ?? ""
                let why =
                    narrowed
                    ? String(localized: "None in “\(picked)”.")
                    : src < 2 ? none[src] : String(localized: "Nothing here")
                showAll.isHidden = !narrowed
                setupButton.isHidden = true
                showEmpty(rows.isEmpty ? why : nil)
            } catch {
                guard gen == reloads else { return }
                showAll.isHidden = true
                let message = (error as? RPCError)?.message ?? "\(error)"
                setup = src == 2 || src == 3 ? nil : Forge.setup(for: message)
                setupButton.title = setup?.title ?? ""
                setupButton.toolTip = setup?.command
                setupButton.isHidden = setup == nil
                self.rows = []
                var why = setup?.note ?? message
                if src == 2 { why = String(localized: "Connect Linear in Settings › Integrations") }
                if src == 3 { why = String(localized: "Connect Jira in Settings › Integrations") }
                if src == 4, setup == nil { why = String(localized: "Projects need `gh auth refresh -s read:project`") }
                status.stringValue = ""
                let quiet = Forge.noRemote(why)
                filter.isHidden = quiet != nil   // the source stays: Linear and Jira need no remote
                if let quiet {
                    showEmpty(quiet.text, symbol: "network", title: quiet.title, retry: true)
                } else if src == 2 || src == 3 {
                    showEmpty(why, symbol: "link")
                } else {
                    showEmpty(why, error: String(localized: "Couldn't load the list"))
                }
            }
            table.reloadData()
            showDetail(nil)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let (title, sub): (String, String) =
            switch rows[row] {
            case .pr(let pr):
                ("#\(pr.number)  \(pr.title)", "\(pr.author) · \(pr.headRefName)\(Self.checksText(pr.checks))")
            case .issue(let issue): ("#\(issue.number)  \(issue.title)", issue.labels.joined(separator: ", "))
            case .linear(let issue): ("\(issue.identifier)  \(issue.title)", "\(issue.state.name) · \(issue.team.name)")
            case .jira(let issue):
                ("\(issue.key)  \(issue.title)", "\(issue.status) · \(issue.type) · \(issue.project)")
            case .item(let item): (item.title, "\(item.status ?? String(localized: "No status")) · \(item.type)")
            }
        let t1 = NSTextField(labelWithString: title)
        t1.font = .ui(13, weight: .medium)
        t1.lineBreakMode = .byTruncatingTail
        let t2 = NSTextField(labelWithString: sub)
        t2.font = .ui(11)
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
    static func checksText(_ checks: GitHub.PullRequest.Checks) -> String {
        if checks.failed > 0 { return String(localized: " · ✕ \(checks.failed) failing") }
        if checks.pending > 0 { return String(localized: " · ◌ \(checks.pending) pending") }
        return checks.passed > 0 ? String(localized: " · ✓ checks passed") : ""
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ListRowView() }
    func tableViewSelectionDidChange(_ notification: Notification) {
        showDetail(table.selectedRow >= 0 ? rows[table.selectedRow] : nil)
    }

}
