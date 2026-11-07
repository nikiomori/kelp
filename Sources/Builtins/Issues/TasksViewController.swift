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
    private let detail = NSStackView()
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

        let col = NSTableColumn(identifier: .init("t"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = TextSize.of(Metrics.rowTwoLine)
        table.dataSource = self
        table.delegate = self
        table.style = .plain
        table.menu = NSMenu()
        table.menu?.delegate = self
        table.backgroundColor = .clear
        let ts = NSScrollView()
        ts.documentView = table
        ts.hasVerticalScroller = true
        ts.drawsBackground = false
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

    // MARK: detail
    private func label(
        _ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor
    )
        -> NSTextField
    {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .ui(size, weight: weight)
        field.textColor = color
        field.isSelectable = true
        field.preferredMaxLayoutWidth = 520
        return field
    }
    private func button(_ title: String, _ sym: String, _ action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(title: title, action: action)
        button.image = .symbol(sym)   // Kelp's own drawing where it has one (a branch, a pull request)
        button.imagePosition = .imageLeading
        button.bezelStyle = .push
        return button
    }

    private func showDetail(_ row: Row?) {
        detail.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let row else {
            detail.addArrangedSubview(
                label(rows.isEmpty ? "" : String(localized: "Select an item"), color: .secondaryLabelColor))
            return
        }
        switch row {
        case .pr(let pr): prDetail(pr)
        case .jira(let issue):
            detail.addArrangedSubview(label("\(issue.key)  \(issue.title)", size: 17, weight: .semibold))
            detail.addArrangedSubview(jiraTransitions(issue.key, current: issue.status))
            detail.addArrangedSubview(
                button(String(localized: "Start Agent on This"), "sparkles") { [weak self] in
                    self?.startTask(ref: issue.key, title: issue.title, body: issue.description, url: issue.url)
                })
            body(issue.description)
        case .issue(let issue):
            detail.addArrangedSubview(label("#\(issue.number)  \(issue.title)", size: 17, weight: .semibold))
            detail.addArrangedSubview(
                button(String(localized: "Start Agent on This"), "sparkles") { [weak self] in
                    self?.startTask(ref: "#\(issue.number)", title: issue.title, body: issue.body, url: issue.url)
                })
            body(issue.body)
        case .linear(let issue):
            detail.addArrangedSubview(label("\(issue.identifier)  \(issue.title)", size: 17, weight: .semibold))
            detail.addArrangedSubview(statePicker(issue))
            detail.addArrangedSubview(
                button(String(localized: "Start Agent on This"), "sparkles") { [weak self] in
                    self?.startTask(
                        ref: issue.identifier, title: issue.title, body: issue.description ?? "", url: issue.url)
                })
            body(issue.description ?? "")
        case .item(let item):
            detail.addArrangedSubview(label(item.title, size: 17, weight: .semibold))
            detail.addArrangedSubview(
                label(String(localized: "Status: \(item.status ?? "—")"), color: .secondaryLabelColor))
        }
        if let url = row.url {
            detail.addArrangedSubview(button(String(localized: "Open on the Web"), "safari") { Forge.open(url) })
        }
    }

    private func body(_ text: String) {
        detail.addArrangedSubview(
            label(
                text.isEmpty ? String(localized: "No description.") : String(text.prefix(6000)),
                color: text.isEmpty ? .secondaryLabelColor : .labelColor))
    }

    /// The PR's folder: on its own branch, or on `pr-<n>` when that name was taken by another branch (`Git.fetchPullRequest`).
    private func worktreeFor(branch: String, pr number: Int) -> Worktree? {
        // This project's, and never its main checkout: a fork's PR from `main` isn't your main.
        let main = app.repo(repoId ?? "")?.path
        return app.worktrees.first {
            $0.repoId == repoId && ($0.branch == branch || $0.branch == "pr-\(number)") && !$0.archived
                && $0.path != main
        }
    }

    private func prDetail(_ pr: GitHub.PullRequest) {
        let app = self.app
        let number = pr.number, branch = pr.headRefName
        detail.addArrangedSubview(label("#\(number)  \(pr.title)", size: 17, weight: .semibold))
        let draft = pr.isDraft ? String(localized: " · draft") : ""
        let decision = pr.reviewDecision.map { " · " + $0.lowercased().replacingOccurrences(of: "_", with: " ") } ?? ""
        detail.addArrangedSubview(
            label(
                String(localized: "\(pr.author) wants to merge \(branch)\(draft)\(decision)"),
                color: .secondaryLabelColor))
        let wt = worktreeFor(branch: branch, pr: number)
        let actions = NSStackView()
        actions.spacing = 8
        if wt == nil, let repoId {   // a folder of its own on the PR's head, as New Chat on Branch… › Pull Request makes
            actions.addArrangedSubview(
                button(String(localized: "Open in Worktree"), "arrow.triangle.branch") {
                    Task {
                        guard let made = await app.call(WorktreeCreate(repoId: repoId, branch: branch, pr: number))
                        else {
                            return
                        }
                        await app.refresh()
                        app.workbench.show(workspace: made.worktree.id)
                    }
                })
        }
        if let wt {
            actions.addArrangedSubview(
                button(String(localized: "Open Worktree"), "arrow.triangle.branch") {
                    app.workbench.show(workspace: wt.id)
                })
            actions.addArrangedSubview(
                button(String(localized: "Send Review Comments to Agent"), "text.bubble") { [weak self] in
                    self?.sendReview(number, wt)
                })
        }
        actions.addArrangedSubview(mergeButton(pr, wt))
        detail.addArrangedSubview(actions)
        if let why = Self.mergeBlock(pr) { detail.addArrangedSubview(label(why, color: .secondaryLabelColor)) }
        let checksBox = NSStackView()
        checksBox.orientation = .vertical
        checksBox.alignment = .leading
        checksBox.spacing = 4
        detail.addArrangedSubview(label(String(localized: "Checks"), weight: .semibold))
        detail.addArrangedSubview(checksBox)
        guard let repoId else { return }
        Task { [weak self] in
            guard let self else { return }
            let read = await app.tryCall(GitHubChecks(repoId: repoId, pr: number))
            let checks = read.value ?? []
            if let error = read.error {
                checksBox.addArrangedSubview(
                    label(String(localized: "Couldn't read the checks: \(error)"), color: .secondaryLabelColor))
            } else if checks.isEmpty {
                checksBox.addArrangedSubview(
                    label(String(localized: "No checks reported."), color: .secondaryLabelColor))
            }
            for check in checks {
                let icon =
                    check.bucket == "pass" ? "✓" : check.bucket == "fail" ? "✕" : check.bucket == "pending" ? "◌" : "–"
                let row = NSStackView(views: [
                    label("\(icon)  \(check.name)", color: check.bucket == "fail" ? .systemRed : .labelColor)
                ])
                row.spacing = 8
                if check.bucket == "fail", let run = check.runId, let wt {
                    row.addArrangedSubview(
                        button(String(localized: "Fix with Agent"), "wrench.and.screwdriver") { [weak self] in
                            self?.fixCheck(check.name, run, wt)
                        })
                }
                checksBox.addArrangedSubview(row)
            }
        }
    }

    private func statePicker(_ issue: LinearIssue) -> NSView {
        let pop = NSPopUpButton()
        pop.addItem(withTitle: issue.state.name)
        Task {
            guard let states = await app.quiet(LinearStates(teamId: issue.team.id)) else { return }   // keeps the current state
            pop.removeAllItems()
            for state in states {
                pop.addItem(withTitle: state.name)
                pop.lastItem?.representedObject = state.id
            }
            pop.selectItem(withTitle: issue.state.name)
        }
        let id = issue.id
        let sink = ClosureTarget { [weak pop, app] in
            guard let sid = pop?.selectedItem?.representedObject as? String else { return }
            Task { await app.call(LinearSetState(issueId: id, stateId: sid)) }
        }
        pop.target = sink
        pop.action = #selector(ClosureTarget.fire)
        objc_setAssociatedObject(pop, "sink", sink, .OBJC_ASSOCIATION_RETAIN)
        let row = NSStackView(views: [NSTextField(labelWithString: String(localized: "State:")), pop])
        row.spacing = 6
        return row
    }

    private func jiraTransitions(_ key: String, current: String) -> NSView {
        let pop = NSPopUpButton()
        pop.addItem(withTitle: current.isEmpty ? String(localized: "Status") : current)
        Task {
            let ts = await app.quiet(JiraTransitions(key: key)) ?? []   // none offered: the status stays as shown
            for transition in ts {
                pop.addItem(withTitle: "→ " + transition.name)
                pop.lastItem?.representedObject = transition.id
            }
        }
        let sink = ClosureTarget { [weak pop, weak self, app] in
            guard let id = pop?.selectedItem?.representedObject as? String else { return }
            Task {
                if await app.call(JiraTransitionIssue(key: key, id: id)) != nil {
                    self?.status.stringValue = String(localized: "Moved \(key)")
                }
            }
        }
        pop.target = sink
        pop.action = #selector(ClosureTarget.fire)
        objc_setAssociatedObject(pop, "sink", sink, .OBJC_ASSOCIATION_RETAIN)
        let row = NSStackView(views: [NSTextField(labelWithString: String(localized: "Status:")), pop])
        row.spacing = 6
        return row
    }

    /// The default agent starts on the issue in the workspace on screen, its text typed in but not sent: whoever filed the
    /// issue wrote it, so the user reads it before the agent acts on it.
    private func startTask(ref: String, title: String, body: String, url: String) {
        let brief = ["Work on \(ref): \(title)", body, url].filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard let editor = app.workbench.editor else {
            NSSound.beep()
            return
        }
        editor.newAgent(nil, prompt: brief, draft: true)
    }

    private func agentSession(_ wt: Worktree) -> String? {
        app.sessions.last {
            $0.worktreeId == wt.id && $0.status != .exited && $0.agent != "shell" && $0.agent != "custom"
        }?.id
    }
    private func sendRecipe(_ name: String, _ wt: Worktree, _ vars: [String: String]) async {
        guard let sid = agentSession(wt) else {
            status.stringValue = String(localized: "No running agent in \(wt.branch) — start one first")
            return
        }
        guard await GitFix(app).type(name, worktree: wt.id, vars: vars, into: sid) else { return }
        status.stringValue = String(
            localized: "Typed into \(app.session(sid)?.displayTitle ?? "agent") — press Return there to send")
    }
    private func fixCheck(_ name: String, _ run: Int, _ wt: Worktree) {
        guard let repoId else { return }
        Task {
            let log = await app.call(GitHubFailedLog(repoId: repoId, runId: run)) ?? ""
            await sendRecipe("fixCI", wt, ["check": name, "error": log])
        }
    }
    private func sendReview(_ n: Int, _ wt: Worktree) {
        guard let repoId else { return }
        Task {
            guard let cs = await app.call(GitHubReviewComments(repoId: repoId, pr: n)) else { return }   // the banner says why
            guard !cs.isEmpty else {
                status.stringValue = String(localized: "No review comments")
                return
            }
            await sendRecipe("review", wt, ["comments": Self.forAgent(cs)])
        }
    }
}

extension TasksViewController {
    /// Review comments as the agent reads them: 12 at most, each cut at 800 characters, so a long thread stays a prompt.
    static func forAgent(_ cs: [GitHub.ReviewComment]) -> String {
        var parts: [String] = []
        for (index, comment) in cs.prefix(12).enumerated() {
            let line: String = comment.line.map { ":\($0)" } ?? ""
            let loc: String = comment.path.map { $0 + line } ?? String(localized: "General")
            let body = comment.body.count > 800 ? comment.body.prefix(800) + "…" : comment.body
            parts.append("\(index + 1). \(loc) (\(comment.author)):\n   \(body)")
        }
        if cs.count > 12 { parts.append("(\(cs.count - 12) more comments omitted.)") }
        return parts.joined(separator: "\n\n")
    }

    // MARK: right-click
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard rows.indices.contains(table.clickedRow) else { return }
        let row = rows[table.clickedRow]
        if let brief = Self.brief(row) {
            menu.add(String(localized: "Start Agent on This")) { [weak self] in
                self?.startTask(ref: brief.ref, title: brief.title, body: brief.body, url: brief.url)
            }
        }
        guard let url = row.url else { return }
        menu.add(String(localized: "Open in Browser")) { Forge.open(url) }
        menu.addItem(.separator())
        menu.add(String(localized: "Copy Link")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url, forType: .string)
        }
    }
    /// What an agent starts from, for the rows it can start on.
    private static func brief(_ row: Row) -> (ref: String, title: String, body: String, url: String)? {
        switch row {
        case .issue(let issue): ("#\(issue.number)", issue.title, issue.body, issue.url)
        case .linear(let issue): (issue.identifier, issue.title, issue.description ?? "", issue.url)
        case .jira(let issue): (issue.key, issue.title, issue.description, issue.url)
        case .pr, .item: nil
        }
    }
}
