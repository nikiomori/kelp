import AppKit
import Core
import DesignKit
import KelpKit

/// CI of the branch on screen: runs → jobs → steps, what broke in the picked job under them (the latest failure opens by
/// itself; `CIJobPane`), and Run Workflow… for workflows started by hand. GitHub Actions (gh) or GitLab (glab);
/// without them, a button that installs and signs in. The globe opens the project's pages on its site.
@MainActor
final class CIRunsController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let app: AppModel
    init(app: AppModel) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    private final class Item: NSObject {
        enum Kind { case run(CIRuns.Run), job(CIRuns.Job, run: Int), step(CIRuns.Step), fold(CIRuns.StepRow, job: Int) }
        let kind: Kind
        var children: [Item]?
        init(_ kind: Kind) { self.kind = kind }
        var id: Int? {
            switch kind {
            case .run(let run): run.id
            case .job(let job, _): job.id
            case .step, .fold: nil
            }
        }
        /// What stays open across a refresh, which makes every item anew.
        var key: String? {
            switch kind {
            case .run(let run): "run \(run.id)"
            case .job(let job, _): "job \(job.id)"
            case .fold(let fold, let job): "fold \(job) \(fold.steps.first?.name ?? "")"
            case .step: nil
            }
        }
    }
    private let outline = ListOutlineView()
    private let branch = BranchChip()   // Source Control's, in the same place: switching panels doesn't move it
    private let empty = EmptyStateView()
    /// Until the first answer for the workspace (gh can take seconds): the panel isn't blank meanwhile.
    private let loading = LoadingView()
    private lazy var checkAgain: NSButton = {   // as large as the setup button beside it
        let button = ClosureButton(title: String(localized: "Check Again")) { [weak self] in self?.reload() }
        button.bezelStyle = .push
        return button
    }()
    private let setupButton = NSButton()
    private var setup: Forge.Setup?
    private let webButton = IconButton(nil, tip: "", target: nil, action: nil)
    private var moreButton: NSButton?
    private var pages: GitWebPages.Pages?
    private lazy var jobPane: CIJobPane = {
        let pane = CIJobPane(app: app)
        pane.onChange = { [weak self] in self?.reload() }
        pane.runOf = { [weak self] id in self?.run(id) }
        return pane
    }()
    /// The log's half of the split, shown once a job is picked: empty, it took most of the height and left the runs a strip.
    private var logPane: (view: NSView, room: NSLayoutConstraint, split: NSSplitView)?
    private let workflowsButton = IconButton(nil, tip: "", target: nil, action: nil)
    private var runs: [Item] = []
    private var workflows: [CIRuns.Workflow] = []
    private var worktree: String?
    private var branchName = ""
    /// The branch's runs, watched while the panel shows: the daemon looks again while one runs, and says when they changed.
    private lazy var ciWatch = Watched(.ci, in: app)
    private var autoOpened = Set<Int>()
    /// The list being shown, its open runs read again.
    private var applying: Task<Void, Never>?
    private let clock = CIClock()
    private let history = CIHistoryStrip()

    override func loadView() {
        let more = IconButton(.symbol("ellipsis.circle"), tip: String(localized: "More")) { [weak self] in
            self?.showMore()
        }
        workflowsButton.isHidden = true
        for (button, symbol, tip) in [
            (workflowsButton, "play.circle", String(localized: "Run Workflow…")),
            (webButton, "arrow.up.forward.square", String(localized: "Open in Browser"))
        ] {
            button.image = .symbol(symbol, tip)
            button.toolTip = tip
            button.setAccessibilityLabel(tip)
            button.target = self
        }
        moreButton = more
        workflowsButton.action = #selector(runWorkflow)
        webButton.action = #selector(showPages)
        webButton.isHidden = true
        history.onPick = { [weak self] in self?.reveal($0) }
        let header = Bar.panel([branch], [workflowsButton, webButton, more])

        let scroll = outline.plainList("ci")
        outline.indentationPerLevel = 12
        outline.rowSizeStyle = .custom
        outline.dataSource = self
        outline.delegate = self
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        setupButton.bezelStyle = .push
        setupButton.target = self
        setupButton.action = #selector(runSetup)
        if #available(macOS 26, *) { setupButton.tintProminence = .primary }

        let bottom = jobPane.view

        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(scroll)
        split.addArrangedSubview(bottom)
        split.setHoldingPriority(.init(260), forSubviewAt: 0)   // the runs keep their room; the log takes what's left
        let stack = stacked(header, history, split)
        empty.place(in: stack, under: header)
        loading.place(in: stack, under: header)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        bottom.isHidden = true
        logPane = (bottom, bottom.heightAnchor.constraint(greaterThanOrEqualToConstant: 120), split)
        view = stack
        track(owner: self) { [app] in
            app.workbench.workspaceId
        } changed: { [weak self, app] in
            self?.worktree = $0
            self?.branch.title = app.worktree($0)?.branch ?? ""   // before the runs come: the header names it at once
            self?.follow()
            self?.loadPages()
            if app.latest(CIEvent.self, $0 ?? "") == nil { self?.loading.show(String(localized: "Loading…")) }
        }
        track(owner: self) { [weak self, app] in
            app.latest(CIEvent.self, self?.worktree ?? "")
        } changed: { [weak self] in
            self?.apply($0)
        }
    }

    /// From origin, not gh: there even when gh or glab isn't set up.
    private func loadPages() {
        guard let worktreeId = worktree else { return }
        pages = nil
        webButton.isHidden = true
        Task {
            // a decoration: without it there's no globe
            let found = await app.quiet(GitWebPages(worktreeId: worktreeId)) ?? nil
            guard worktreeId == worktree else { return }
            pages = found
            webButton.isHidden = found == nil
        }
    }

    @objc private func showPages() {
        guard let pages else { return }
        Forge.menu(pages).popUp(positioning: nil, at: NSPoint(x: 0, y: webButton.bounds.height + 4), in: webButton)
    }

    private func showMore() {
        guard let button = moreButton else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Refresh"), action: #selector(refreshPressed), keyEquivalent: "")
            .target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func refreshPressed() { reload() }

    @objc private func runSetup() { if let setup { Forge.run(setup, in: app) } }

    /// Shown, the log takes about half the height (the runs keep the rest); hidden, the runs have it all.
    private func showLogPane(_ on: Bool) {
        guard let pane = logPane, pane.view.isHidden == on else { return }
        pane.view.isHidden = !on
        pane.room.isActive = on
        if on { pane.split.setPosition(pane.split.bounds.height * 0.45, ofDividerAt: 0) }
    }

    // MARK: loading

    /// Watched while on screen: shown again (another panel was on screen), what ran meanwhile comes at once.
    override func viewDidAppear() {
        super.viewDidAppear()
        follow()
        clock.start()
    }
    override func viewDidDisappear() {
        super.viewDidDisappear()
        follow()
        clock.stop()
    }
    private func follow() { ciWatch.key = view.window != nil ? worktree : nil }

    /// Refresh, and after starting runs: the daemon reads them now, and keeps looking for a while.
    private func reload() { if let worktree { app.watchAgain(.ci, worktree) } }

    private func apply(_ event: CIEvent?) {
        guard let event, event.worktree == worktree else { return }
        loading.show(nil)
        // A newer list replaces the rows the last one's jobs were being opened in: that one stops at its next step.
        applying?.cancel()
        applying = Task {
            if let error = event.error {
                branch.title = app.worktree(worktree)?.branch ?? ""   // whose runs these would be, still
                workflowsButton.isHidden = true
                show(note: error, setup: Forge.setup(for: error), failed: true)
                return
            }
            branchName = event.result?.branch ?? ""
            branch.title = branchName
            // What was open stays open across a refresh, its jobs read again.
            let open = Set(
                runs.flatMap { [$0] + openBelow($0) }.filter { outline.isItemExpanded($0) }.compactMap(\.key))
            let selected = (outline.item(atRow: outline.selectedRow) as? Item)?.id
            runs = (event.result?.runs ?? []).map { Item(.run($0)) }
            workflows = event.result?.workflows ?? []
            workflowsButton.isHidden = workflows.isEmpty
            show(note: runs.isEmpty ? String(localized: "No CI runs on \(branchName) yet.") : nil)
            clock.clear()
            outline.reloadData()
            history.show(CIRuns.history(allRuns))
            for run in runs where open.contains(run.key ?? "") {
                await expand(run, openFailed: false)
                guard !Task.isCancelled else { return }
                for item in openBelow(run) where open.contains(item.key ?? "") { outline.expandItem(item) }
                if let job = run.children?.first(where: { $0.id == selected }),
                    case let row = outline.row(forItem: job), row >= 0
                {
                    outline.selectRowIndexes([row], byExtendingSelection: false)
                }
            }
            guard !Task.isCancelled else { return }
            // A workflow's latest run failed (what Source Control's CI line shows): open it at the first failed job,
            // with its log (once, so closing it sticks).
            let failing = Set(CIRuns.latest(allRuns).filter(\.failed).map(\.id))
            if let item = runs.first(where: { failing.contains($0.id ?? -1) }), let id = item.id,
                autoOpened.insert(id).inserted
            {
                await expand(item, openFailed: true)
            }
        }
    }

    /// A mark in the strip: its run, in the list.
    private func reveal(_ run: CIRuns.Run) {
        guard let item = runs.first(where: { $0.id == run.id }) else { return }
        let row = outline.row(forItem: item)
        guard row >= 0 else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    /// A run's jobs and the folds of their steps, top down, as they have to be opened.
    private func openBelow(_ run: Item) -> [Item] { (run.children ?? []).flatMap { [$0] + ($0.children ?? []) } }

    /// `setup`: gh or glab isn't installed or signed in; what it says, and the button that runs the fix in a terminal.
    private func show(note text: String?, setup: Forge.Setup? = nil, failed: Bool = false) {
        self.setup = setup
        if let setup {
            setupButton.title = setup.title
            setupButton.toolTip = setup.command
            empty.show(
                setup.note, symbol: "terminal", text: String(localized: "It runs in a terminal tab; then Check Again."),
                buttons: [setupButton, checkAgain])
        } else if let quiet = Forge.noRemote(text) {
            empty.show(quiet.title, symbol: "network", text: quiet.text, buttons: [checkAgain])
        } else if failed {
            empty.showError(String(localized: "Couldn't read the runs"), text: text, buttons: [checkAgain])
        } else {
            empty.show(text, symbol: "checkmark.seal")
        }
        // The runs and the log go together: the log's divider alone under the header drew a second line there.
        outline.enclosingScrollView?.superview?.isHidden = text != nil
        if text != nil {
            showLogPane(false)
            jobPane.clear()
        }
    }

    private func expand(_ item: Item, openFailed: Bool) async {
        guard case .run(let run) = item.kind, let worktree else { return }
        if item.children == nil {
            // the banner says why; asked again next time
            guard let jobs = await app.call(CIJobs(worktreeId: worktree, run: run.id)) else { return }
            guard runs.contains(where: { $0 === item }) else { return }   // a newer list came meanwhile: these rows are gone
            item.children = jobs.map { job in
                let jobItem = Item(.job(job, run: run.id))
                jobItem.children = CIRuns.rows(job.steps).map { row in
                    if case .one(let step) = row { return Item(.step(step)) }
                    let fold = Item(.fold(row, job: job.id))
                    fold.children = row.steps.map { Item(.step($0)) }
                    return fold
                }
                return jobItem
            }
            outline.reloadItem(item, reloadChildren: true)
        }
        outline.expandItem(item)
        if openFailed,
            let failed = item.children?.first(where: {
                if case .job(let job, _) = $0.kind { job.failed } else { false }
            })
        {
            outline.expandItem(failed)
            let row = outline.row(forItem: failed)
            if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
        }
    }

    private func showLog(_ job: CIRuns.Job, run: Int) {
        guard let worktree else { return }
        showLogPane(true)
        jobPane.show(job, run: run, in: worktree)
    }

    // MARK: actions

    private var allRuns: [CIRuns.Run] { runs.compactMap { if case .run(let run) = $0.kind { run } else { nil } } }
    private func run(_ id: Int) -> CIRuns.Run? { allRuns.first { $0.id == id } }

    private func actions(_ worktree: String) -> CIActions {
        CIActions(app: app, worktree: worktree) { [weak self] in self?.reload() }
    }

    @objc private func runWorkflow() {
        let menu = NSMenu()
        for wf in workflows { menu.add(wf.name) { [weak self] in self?.dispatch(wf) } }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: workflowsButton.bounds.height + 4), in: workflowsButton)
    }

    /// The workflow's inputs as a form, then `gh workflow run` on this branch.
    private func dispatch(_ wf: CIRuns.Workflow) {
        guard let worktree else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Run “\(wf.name)” on \(branchName)?")
        var fields: [(String, NSView)] = []
        let form = NSGridView()
        form.rowAlignment = .firstBaseline
        for input in wf.inputs {
            let control: NSView
            if !input.options.isEmpty {
                let popUp = NSPopUpButton()
                popUp.addItems(withTitles: input.options)
                popUp.selectItem(withTitle: input.defaultValue)
                control = popUp
            } else {
                let field = NSTextField(string: input.defaultValue)
                field.placeholderString = input.description
                field.widthAnchor.constraint(equalToConstant: 220).isActive = true
                control = field
            }
            fields.append((input.name, control))
            form.addRow(with: [NSTextField(labelWithString: input.name + (input.required ? " *" : "")), control])
        }
        if !wf.inputs.isEmpty { alert.accessoryView = form }
        alert.informativeText =
            wf.inputs.isEmpty
            ? String(localized: "It runs on GitHub Actions.") : String(localized: "Inputs from \(wf.file):")
        alert.addButton(withTitle: String(localized: "Run"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        Task {
            guard await runSheet(alert) == .alertFirstButtonReturn else { return }
            var inputs: [String: String] = [:]
            for (name, control) in fields {
                inputs[name] =
                    (control as? NSPopUpButton)?.titleOfSelectedItem ?? (control as? NSTextField)?.stringValue ?? ""
            }
            if await app.call(CIDispatch(worktreeId: worktree, workflow: wf.file, branch: branchName, inputs: inputs))
                != nil
            {
                Banner.show(String(localized: "Started \(wf.name)"))
                reload()
            }
        }
    }

    // MARK: outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? Item else { return runs.count }
        if case .run = item.kind, item.children == nil { return 1 }   // a placeholder until it's opened
        return item.children?.count ?? 0
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? Item else { return runs[index] }
        return item.children?[index]
            ?? Item(.step(.init(name: String(localized: "Loading…"), status: "queued", conclusion: nil)))
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? Item else { return false }
        if case .step = item.kind { return false }
        return item.children.map { !$0.isEmpty } ?? true   // a fold, a job with steps, a run not yet read
    }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        TextSize.of({ if case .run? = (item as? Item)?.kind { Metrics.rowTwoLine } else { Metrics.row } }())
    }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { ListRowView() }
    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? Item, case .run = item.kind, item.children == nil else {
            return
        }
        Task { await expand(item, openFailed: false) }
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let item = outline.item(atRow: outline.selectedRow) as? Item, case .job(let job, let run) = item.kind
        else {
            return
        }
        if let shown = jobPane.shown, shown.job.id == job.id, shown.job.status == job.status {
            jobPane.keep(job, run: run)
            return
        }   // a refresh, nothing new to read
        showLog(job, run: run)
    }

    /// A fold opens from anywhere on its row. A step goes to its place in the job's log, which is read when it's over.
    @objc private func rowClicked() {
        guard let item = outline.item(atRow: outline.clickedRow) as? Item else { return }
        switch item.kind {
        case .fold: if outline.isItemExpanded(item) { outline.collapseItem(item) } else { outline.expandItem(item) }
        case .step(let step): showInLog(step, of: item)
        case .run, .job: break
        }
    }

    private func showInLog(_ step: CIRuns.Step, of item: Item) {
        guard let worktree, let job = job(of: item), job.status == "completed" else { return }
        if step.failed, jobPane.shown?.job.id == job.id { return }   // what broke is on show under the runs
        CILogTab.open(app, worktree: worktree, job: job, step: step.name)
    }

    /// The job a step belongs to, past the fold it may sit in.
    private func job(of item: Item) -> CIRuns.Job? {
        var up = outline.parent(forItem: item) as? Item
        while let parent = up {
            if case .job(let job, _) = parent.kind { return job }
            up = outline.parent(forItem: parent) as? Item
        }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor column: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? Item else { return nil }
        switch item.kind {
        case .run(let run): return runRow(run)
        case .job(let job, _):
            let done = job.steps.filter { $0.status == "completed" }.count
            let right =
                job.status == "completed" || job.steps.isEmpty
                ? job.seconds().map(ciSpan) : "\(done)/\(job.steps.count)"
            return CIRow.line(
                CIRunLook.mark(job.status, job.conclusion), job.name, font: .ui(12), color: .labelColor, right: right
            ).cell
        case .step(let step):
            // The step running now reads like a title; done ones grey, the ones still to come quieter still.
            let color: NSColor =
                step.status == "in_progress"
                ? .labelColor : step.status == "completed" ? .secondaryLabelColor : .tertiaryLabelColor
            let line = CIRow.line(
                CIRunLook.mark(step.status, step.conclusion), step.shortName, font: .ui(11), color: color,
                right: step.seconds().map(ciSpan))
            if step.status == "in_progress", let time = line.time { clock.follow(time) { step.seconds().map(ciSpan) } }
            line.cell.toolTip = step.name
            return line.cell
        case .fold(let fold, _): return CIRow.fold(fold)
        }
    }

    /// The title, then `CIRunMeta`: which run, how long, when. The tooltip has the whole title, as a commit's first line
    /// rarely fits, and the commit, which a narrow panel cuts.
    private func runRow(_ run: CIRuns.Run) -> NSView {
        let title = NSTextField(labelWithString: run.title)
        title.font = .ui(12)
        title.lineBreakMode = .byTruncatingTail
        // What tells runs apart: the workflow only when there are several, the event only when it isn't a push.
        let several = Set(allRuns.map(\.workflow)).count > 1
        let usual = run.finished ? nil : CIRuns.typicalSeconds(allRuns, workflow: run.workflow)
        let meta = CIRunMeta(
            run, extras: [several ? run.workflow : nil, run.event == "push" ? nil : run.event].compactMap { $0 },
            usual: usual,
            clock: clock)
        let text = NSStackView(views: [title, meta])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Metrics.lineGap
        for part in [title, meta, text] { part.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        meta.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        let cell = CIRow.row([CIRunLook.mark(run.status, run.conclusion), text])
        cell.toolTip = [run.title, [run.workflow, run.shortSHA].compactMap { $0 }.joined(separator: " · ")].joined(
            separator: "\n")
        return cell
    }
}

extension CIRunsController {
    /// Right-click: what can be done to this run, job or step now.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let item = outline.item(atRow: outline.clickedRow) as? Item, let worktree else { return }
        let act = actions(worktree)
        switch item.kind {
        case .run(let run): addRun(run, act, to: menu)
        case .job(let job, _):
            if job.failed { menu.add(String(localized: "Fix with Agent")) { act.fix(job) } }
            if job.status == "completed" { menu.add(String(localized: "Re-run This Job")) { act.rerunJob(job.id) } }
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            if let url = job.url { addLink(menu, url) }
        case .step(let step):
            if let job = job(of: item), job.status == "completed" {
                menu.add(String(localized: "Show in Log")) { [app] in
                    CILogTab.open(app, worktree: act.worktree, job: job, step: step.name)
                }
            }
            if let url = job(of: item)?.url, let number = step.number {
                menu.add(String(localized: "Open in Browser")) { Forge.open("\(url)#step:\(number):1") }
            }
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            menu.add(String(localized: "Copy Step Name")) {
                copyText(step.name)
            }
        case .fold: break
        }
    }

    private func addRun(_ run: CIRuns.Run, _ act: CIActions, to menu: NSMenu) {
        if run.failed {
            menu.add(String(localized: "Fix with Agent")) { [weak self] in self?.fix(run, in: act.worktree) }
            menu.add(String(localized: "Re-run Failed")) { act.rerunFailed(run.id) }
        }
        if run.finished {
            menu.add(String(localized: "Re-run All")) { act.rerunAll(run.id) }
        } else {
            menu.add(String(localized: "Cancel Run…")) { act.cancel(run) }
        }
        menu.addItem(.separator())
        if run.sha != nil { menu.add(String(localized: "Show Commit")) { act.showCommit(run) } }
        addLink(menu, run.url)
    }

    private func addLink(_ menu: NSMenu, _ url: String) {
        menu.add(String(localized: "Open in Browser")) { Forge.open(url) }
        menu.addItem(.separator())
        menu.add(String(localized: "Copy Link")) {
            copyText(url)
        }
    }
    /// The run's failure typed into the workspace's agent, for the user to send.
    private func fix(_ run: CIRuns.Run, in worktree: String) {
        let app = app
        guard let repo = app.worktree(worktree)?.repoId else { return }
        Task {
            let log = await app.call(GitHubFailedLog(repoId: repo, runId: run.id)) ?? ""
            GitFix(app).send("fixCI", worktree: worktree, vars: ["check": run.workflow, "error": log])
        }
    }
}
