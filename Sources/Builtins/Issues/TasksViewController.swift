import AppKit
import SwiftUI
import Core
import DesignKit
import KelpKit

/// GitHub PRs / issues / Projects and Linear tasks for the selected project, with the actions that close the loop:
/// issue → worktree + agent, failed check / review comments → agent, PR merge, Linear state.
@MainActor
final class TasksViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let app: AppModel
    init(app: AppModel) { self.app = app; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    let source = NSPopUpButton()
    let split = NSSplitView()
    private var dividerPlaced = false
    let filter = NSPopUpButton()
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
            case .pr(let p): p.url
            case .issue(let i): i.url
            case .linear(let l): l.url
            case .jira(let j): j.url
            case .item(let i): i.url
            }
        }
    }
    var rows: [Row] = []
    private var repoId: String?
    private var projectOwner: String?
    private var jiraJQL = "project = ENG AND statusCategory != Done ORDER BY priority DESC"

    override func loadView() {
        source.addItems(withTitles: [String(localized: "Pull Requests"), String(localized: "Issues"),
            String(localized: "Linear"), String(localized: "Jira"), String(localized: "Projects")])
        source.selectItem(at: 0)
        source.target = self
        source.action = #selector(sourceChanged)
        filter.target = self; filter.action = #selector(filterChanged)
        let bar = makeBar()

        let col = NSTableColumn(identifier: .init("t"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = TextSize.of(Metrics.rowTwoLine)
        table.dataSource = self
        table.delegate = self
        table.style = .plain
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
        flip.pin(detail); flip.widthAnchor.constraint(equalTo: ds.contentView.widthAnchor).isActive = true
        split.isVertical = false; split.dividerStyle = .thin
        split.addArrangedSubview(ts); split.addArrangedSubview(ds)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 1)
        let v = stacked(bar, split)
        emptyView.place(in: v, under: bar)
        showAll.isHidden = true; setupButton.isHidden = true   // until a list is empty because of them
        view = v
        sourceChanged(); nameSources()   // the workspace came before the view: show(worktree:) left naming to here
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Once it has a height: the list gets the larger part, details the rest.
        guard !dividerPlaced, split.bounds.height > 100 else { return }
        dividerPlaced = true; split.setPosition(split.bounds.height * 0.55, ofDividerAt: 0)
    }

    lazy var showAll = ClosureButton(title: String(localized: "Show All Open")) { [weak self] in self?.filter.selectItem(at: 0); self?.reload() }
    /// gh or glab isn't installed or signed in: runs what fixes it in a terminal tab.
    private var setup: Forge.Setup?
    lazy var setupButton = ClosureButton(title: "") { [weak self] in if let self, let s = setup { Forge.run(s, in: app) } }

    func show(worktree id: String?) {
        let r = app.worktree(id)?.repoId ?? app.repos.first?.id
        guard r != repoId else { return }
        repoId = r
        guard isViewLoaded else { return }
        // Another project: drop its rows now, or Merge on one before the reload would act on a PR number in this repo.
        rows = []
        table.reloadData()
        showDetail(nil)
        reload(); nameSources()
    }

    /// GitLab calls them merge requests.
    private func nameSources() {
        guard let repoId else { return }
        Task {
            let forge = await app.quiet(GitHubForge(repoId: repoId))   // the list's own load says what failed
            source.item(at: 0)?.title = forge == "gitlab" ? String(localized: "Merge Requests") : String(localized: "Pull Requests")
        }
    }

    @objc private func sourceChanged() {
        filter.removeAllItems()
        switch source.indexOfSelectedItem {
        case 0: filter.addItems(withTitles: [String(localized: "All open"), String(localized: "Mine"), String(localized: "Review requested")])
        case 1: filter.addItems(withTitles: [String(localized: "All open"), String(localized: "Assigned to me")])
        case 3: filter.addItems(withTitles: [String(localized: "My open issues"), String(localized: "Custom JQL…")])
        case 2:
            filter.addItems(withTitles: [String(localized: "My issues")])
            Task {   // team boards
                for t in await app.quiet(LinearTeams()) ?? [] {   // the list's own load says what failed
                    filter.addItem(withTitle: String(localized: "Team: \(t.name)")); filter.lastItem?.representedObject = t.id
                }
            }
        default: filter.addItems(withTitles: [String(localized: "Loading projects…")])
        }
        reload()
    }

    /// Custom JQL asks for its query when picked, not on every refresh or workspace switch.
    @objc private func filterChanged() {
        guard source.indexOfSelectedItem == 3, filter.indexOfSelectedItem == 1 else { reload(); return }
        Task {
            if let jql = await prompt(String(localized: "Jira search"), "JQL", initial: jiraJQL) { jiraJQL = jql } else { filter.selectItem(at: 0) }
            reload()
        }
    }

    @objc func reload() {
        guard let repoId else {
            rows = []
            table.reloadData()
            showEmpty(String(localized: "Select a project"))
            return
        }
        let slow = whileSlow { [weak self] in
            guard let self else { return }
            if rows.isEmpty { showEmpty(String(localized: "Loading…"), symbol: "ellipsis") } else { status.stringValue = String(localized: "Loading…") }
        }
        let src = source.indexOfSelectedItem, f = filter.indexOfSelectedItem
        Task {
            defer { slow.cancel() }
            var rows: [Row] = []
            do {
                let m = app
                switch src {
                case 0: rows = try await m.get(GitHubPRs(repoId: repoId, filter: ["open", "mine", "review"][max(0, f)])).map(Row.pr)
                case 1: rows = try await m.get(GitHubIssues(repoId: repoId, filter: f == 1 ? "mine" : "open")).map(Row.issue)
                case 2:
                    let team = filter.selectedItem?.representedObject as? String
                    var issues = try await m.get(LinearIssues(teamId: team))
                    if team != nil { issues.sort { $0.state.name < $1.state.name } }
                    rows = issues.map(Row.linear)
                case 3:
                    rows = try await m.get(JiraIssues(jql: f == 1 ? jiraJQL : nil)).map(Row.jira)
                default:
                    if filter.itemTitles.first == String(localized: "Loading projects…") {
                        let ps = try await m.get(GitHubProjects(repoId: repoId))
                        filter.removeAllItems()
                        for p in ps { filter.addItem(withTitle: p.title); filter.lastItem?.tag = p.number }
                        projectOwner = ps.first.flatMap { URL(string: $0.url)?.pathComponents.dropFirst(2).first }
                    }
                    if let owner = projectOwner, let n = filter.selectedItem?.tag {
                        rows = try await m.get(GitHubProjectItems(owner: owner, number: n))
                            .sorted { ($0.status ?? "~") < ($1.status ?? "~") }.map(Row.item)
                    } else { rows = [] }
                }
                // Switched project or list meanwhile: these rows belong to the old one.
                guard repoId == self.repoId, src == source.indexOfSelectedItem else { return }
                self.rows = rows
                // Empty because of the filter isn't the same as empty: say which, and offer the way back.
                let narrowed = rows.isEmpty && f > 0 && src < 2
                let none = [String(localized: "No open pull requests"), String(localized: "No open issues")]
                status.stringValue = ""
                let picked = filter.titleOfSelectedItem ?? ""
                let why = narrowed ? String(localized: "None in “\(picked)”.") : src < 2 ? none[src] : String(localized: "Nothing here")
                showAll.isHidden = !narrowed; setupButton.isHidden = true
                showEmpty(rows.isEmpty ? why : nil)
            } catch {
                guard repoId == self.repoId, src == source.indexOfSelectedItem else { return }
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
                if src == 2 || src == 3 { showEmpty(why, symbol: "link") } else { showEmpty(why, error: String(localized: "Couldn't load the list")) }
            }
            table.reloadData(); showDetail(nil)
        }
    }

    func numberOfRows(in t: NSTableView) -> Int { rows.count }
    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let (title, sub): (String, String) = switch rows[row] {
        case .pr(let p): ("#\(p.number)  \(p.title)", "\(p.author) · \(p.headRefName)\(Self.checksText(p.checks))")
        case .issue(let i): ("#\(i.number)  \(i.title)", i.labels.joined(separator: ", "))
        case .linear(let l): ("\(l.identifier)  \(l.title)", "\(l.state.name) · \(l.team.name)")
        case .jira(let j): ("\(j.key)  \(j.title)", "\(j.status) · \(j.type) · \(j.project)")
        case .item(let i): (i.title, "\(i.status ?? String(localized: "No status")) · \(i.type)")
        }
        let t1 = NSTextField(labelWithString: title)
        t1.font = .ui(13, weight: .medium)
        t1.lineBreakMode = .byTruncatingTail
        let t2 = NSTextField(labelWithString: sub)
        t2.font = .ui(11)
        t2.textColor = .secondaryLabelColor
        t2.lineBreakMode = .byTruncatingTail
        let s = NSStackView(views: [t1, t2])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = Metrics.lineGap
        s.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.inset)
        return s
    }
    static func checksText(_ c: GitHub.PullRequest.Checks) -> String {
        if c.failed > 0 { return String(localized: " · ✕ \(c.failed) failing") }
        if c.pending > 0 { return String(localized: " · ◌ \(c.pending) pending") }
        return c.passed > 0 ? String(localized: " · ✓ checks passed") : ""
    }
    func tableView(_ t: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ListRowView() }
    func tableViewSelectionDidChange(_ n: Notification) { showDetail(table.selectedRow >= 0 ? rows[table.selectedRow] : nil) }

    // MARK: detail
    private func label(_ s: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .ui(size, weight: weight)
        l.textColor = color
        l.isSelectable = true
        l.preferredMaxLayoutWidth = 520; return l
    }
    private func button(_ t: String, _ sym: String, _ action: @escaping () -> Void) -> NSButton {
        let b = ClosureButton(title: t, action: action)
        b.image = .symbol(sym)   // Kelp's own drawing where it has one (a branch, a pull request)
        b.imagePosition = .imageLeading
        b.bezelStyle = .push; return b
    }

    private func showDetail(_ r: Row?) {
        detail.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let r else {
            detail.addArrangedSubview(label(rows.isEmpty ? "" : String(localized: "Select an item"), color: .secondaryLabelColor)); return
        }
        switch r {
        case .pr(let p): prDetail(p)
        case .jira(let j):
            detail.addArrangedSubview(label("\(j.key)  \(j.title)", size: 17, weight: .semibold))
            detail.addArrangedSubview(jiraTransitions(j.key, current: j.status))
            detail.addArrangedSubview(button(String(localized: "Start Agent on This"), "sparkles") { [weak self] in
                self?.startTask(ref: j.key, title: j.title, body: j.description, url: j.url)
            })
            body(j.description)
        case .issue(let i):
            detail.addArrangedSubview(label("#\(i.number)  \(i.title)", size: 17, weight: .semibold))
            detail.addArrangedSubview(button(String(localized: "Start Agent on This"), "sparkles") { [weak self] in
                self?.startTask(ref: "#\(i.number)", title: i.title, body: i.body, url: i.url)
            })
            body(i.body)
        case .linear(let l):
            detail.addArrangedSubview(label("\(l.identifier)  \(l.title)", size: 17, weight: .semibold))
            detail.addArrangedSubview(statePicker(l))
            detail.addArrangedSubview(button(String(localized: "Start Agent on This"), "sparkles") { [weak self] in
                self?.startTask(ref: l.identifier, title: l.title, body: l.description ?? "", url: l.url)
            })
            body(l.description ?? "")
        case .item(let i):
            detail.addArrangedSubview(label(i.title, size: 17, weight: .semibold))
            detail.addArrangedSubview(label(String(localized: "Status: \(i.status ?? "—")"), color: .secondaryLabelColor))
        }
        if let url = r.url { detail.addArrangedSubview(button(String(localized: "Open on the Web"), "safari") { Forge.open(url) }) }
    }

    private func body(_ text: String) {
        detail.addArrangedSubview(label(text.isEmpty ? String(localized: "No description.") : String(text.prefix(6000)),
            color: text.isEmpty ? .secondaryLabelColor : .labelColor))
    }

    private func worktreeFor(branch: String) -> Worktree? { app.worktrees.first { $0.branch == branch && !$0.archived } }

    private func prDetail(_ r: GitHub.PullRequest) {
        let app = self.app
        let n = r.number, branch = r.headRefName
        detail.addArrangedSubview(label("#\(n)  \(r.title)", size: 17, weight: .semibold))
        let draft = r.isDraft ? String(localized: " · draft") : ""
        let decision = r.reviewDecision.map { " · " + $0.lowercased().replacingOccurrences(of: "_", with: " ") } ?? ""
        detail.addArrangedSubview(label(String(localized: "\(r.author) wants to merge \(branch)\(draft)\(decision)"), color: .secondaryLabelColor))
        let wt = worktreeFor(branch: branch)
        let actions = NSStackView(); actions.spacing = 8
        if let wt {
            actions.addArrangedSubview(button(String(localized: "Open Worktree"), "arrow.triangle.branch") { app.workbench.show(workspace: wt.id) })
            actions.addArrangedSubview(button(String(localized: "Send Review Comments to Agent"), "text.bubble") { [weak self] in self?.sendReview(n, wt) })
        }
        actions.addArrangedSubview(button(String(localized: "Merge (squash)"), "arrow.triangle.merge") { [weak self] in self?.merge(n, wt) })
        detail.addArrangedSubview(actions)
        let checksBox = NSStackView()
        checksBox.orientation = .vertical
        checksBox.alignment = .leading
        checksBox.spacing = 4
        detail.addArrangedSubview(label(String(localized: "Checks"), weight: .semibold)); detail.addArrangedSubview(checksBox)
        guard let repoId else { return }
        Task { [weak self] in
            guard let self else { return }
            let read = await app.tryCall(GitHubChecks(repoId: repoId, pr: n))
            let checks = read.value ?? []
            if let e = read.error { checksBox.addArrangedSubview(label(String(localized: "Couldn't read the checks: \(e)"), color: .secondaryLabelColor)) }
            else if checks.isEmpty { checksBox.addArrangedSubview(label(String(localized: "No checks reported."), color: .secondaryLabelColor)) }
            for c in checks {
                let icon = c.bucket == "pass" ? "✓" : c.bucket == "fail" ? "✕" : c.bucket == "pending" ? "◌" : "–"
                let row = NSStackView(views: [label("\(icon)  \(c.name)", color: c.bucket == "fail" ? .systemRed : .labelColor)]); row.spacing = 8
                if c.bucket == "fail", let run = c.runId, let wt {
                    row.addArrangedSubview(button(String(localized: "Fix with Agent"), "wrench.and.screwdriver") { [weak self] in
                        self?.fixCheck(c.name, run, wt)
                    })
                }
                checksBox.addArrangedSubview(row)
            }
        }
    }

    private func statePicker(_ r: LinearIssue) -> NSView {
        let pop = NSPopUpButton(); pop.addItem(withTitle: r.state.name)
        Task {
            guard let states = await app.quiet(LinearStates(teamId: r.team.id)) else { return }   // keeps the current state
            pop.removeAllItems()
            for s in states { pop.addItem(withTitle: s.name); pop.lastItem?.representedObject = s.id }
            pop.selectItem(withTitle: r.state.name)
        }
        let id = r.id
        let sink = ClosureTarget { [weak pop, app] in
            guard let sid = pop?.selectedItem?.representedObject as? String else { return }
            Task { await app.call(LinearSetState(issueId: id, stateId: sid)) }
        }
        pop.target = sink
        pop.action = #selector(ClosureTarget.fire)
        objc_setAssociatedObject(pop, "sink", sink, .OBJC_ASSOCIATION_RETAIN)
        let row = NSStackView(views: [NSTextField(labelWithString: String(localized: "State:")), pop]); row.spacing = 6
        return row
    }

    private func jiraTransitions(_ key: String, current: String) -> NSView {
        let pop = NSPopUpButton(); pop.addItem(withTitle: current.isEmpty ? String(localized: "Status") : current)
        Task {
            let ts = await app.quiet(JiraTransitions(key: key)) ?? []   // none offered: the status stays as shown
            for t in ts { pop.addItem(withTitle: "→ " + t.name); pop.lastItem?.representedObject = t.id }
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
        let row = NSStackView(views: [NSTextField(labelWithString: String(localized: "Status:")), pop]); row.spacing = 6
        return row
    }

    /// The default agent starts on the issue in the workspace on screen, its text typed in but not sent: whoever filed the
    /// issue wrote it, so the user reads it before the agent acts on it.
    private func startTask(ref: String, title: String, body: String, url: String) {
        let brief = ["Work on \(ref): \(title)", body, url].filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard let editor = app.workbench.editor else { NSSound.beep(); return }
        editor.newAgent(nil, prompt: brief, draft: true)
    }

    private func agentSession(_ wt: Worktree) -> String? {
        app.sessions.last { $0.worktreeId == wt.id && $0.status != .exited && $0.agent != "shell" && $0.agent != "custom" }?.id
    }
    private func sendRecipe(_ name: String, _ wt: Worktree, _ vars: [String: String]) async {
        guard let sid = agentSession(wt) else { status.stringValue = String(localized: "No running agent in \(wt.branch) — start one first"); return }
        guard await GitFix(app).type(name, worktree: wt.id, vars: vars, into: sid) else { return }
        status.stringValue = String(localized: "Typed into \(app.session(sid)?.displayTitle ?? "agent") — press Return there to send")
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
            guard !cs.isEmpty else { status.stringValue = String(localized: "No review comments"); return }
            var parts: [String] = []
            for (i, c) in cs.enumerated() {
                let line: String = c.line.map { ":\($0)" } ?? ""
                let loc: String = c.path.map { $0 + line } ?? String(localized: "General")
                parts.append("\(i + 1). \(loc) (\(c.author)):\n   \(c.body)")
            }
            let text = parts.joined(separator: "\n\n")
            await sendRecipe("review", wt, ["comments": text])
        }
    }
    private func merge(_ n: Int, _ wt: Worktree?) {
        let a = NSAlert()
        a.messageText = String(localized: "Squash and merge #\(n)?")
        a.addButton(withTitle: String(localized: "Merge"))
        a.addButton(withTitle: String(localized: "Cancel"))
        Task {
            guard await runSheet(a) == .alertFirstButtonReturn else { return }
            // The merge runs in a workspace of the project (gh needs a checkout); the PR's own if it has one.
            guard let wid = wt?.id ?? app.worktrees.first(where: { $0.repoId == repoId })?.id else { NSSound.beep(); return }
            if await app.call(GitHubPRMerge(worktreeId: wid, pr: n)) != nil { status.stringValue = String(localized: "Merged #\(n)"); reload() }
        }
    }
}
