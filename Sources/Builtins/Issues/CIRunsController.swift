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
    init(app: AppModel) { self.app = app; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    private final class Item: NSObject {
        enum Kind { case run(CIRuns.Run), job(CIRuns.Job, run: Int), step(CIRuns.Step), fold(CIRuns.StepRow, job: Int) }
        let kind: Kind
        var children: [Item]?
        init(_ k: Kind) { kind = k }
        var id: Int? {
            switch kind {
            case .run(let r): r.id
            case .job(let j, _): j.id
            case .step, .fold: nil
            }
        }
        /// What stays open across a refresh, which makes every item anew.
        var key: String? {
            switch kind {
            case .run(let r): "run \(r.id)"
            case .job(let j, _): "job \(j.id)"
            case .fold(let f, let job): "fold \(job) \(f.steps.first?.name ?? "")"
            case .step: nil
            }
        }
    }
    private let outline = ListOutlineView()
    private let branch = BranchChip()   // Source Control's, in the same place: switching panels doesn't move it
    private let empty = EmptyStateView()
    private lazy var checkAgain: NSButton = {   // as large as the setup button beside it
        let b = ClosureButton(title: String(localized: "Check Again")) { [weak self] in self?.reload() }
        b.bezelStyle = .push
        return b
    }()
    private let setupButton = NSButton()
    private var setup: Forge.Setup?
    private let webButton = IconButton(nil, tip: "", target: nil, action: nil)
    private var moreButton: NSButton?
    private var pages: GitWebPages.Pages?
    private lazy var jobPane: CIJobPane = {
        let p = CIJobPane(app: app)
        p.onChange = { [weak self] in self?.reload() }
        p.runOf = { [weak self] id in self?.run(id) }
        return p
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
        let more = IconButton(.symbol("ellipsis.circle"), tip: String(localized: "More")) { [weak self] in self?.showMore() }
        workflowsButton.isHidden = true
        for (b, symbol, tip) in [(workflowsButton, "play.circle", String(localized: "Run Workflow…")),
                                 (webButton, "arrow.up.forward.square", String(localized: "Open in Browser"))] {
            b.image = .symbol(symbol, tip)
            b.toolTip = tip
            b.setAccessibilityLabel(tip)
            b.target = self
        }
        moreButton = more
        workflowsButton.action = #selector(runWorkflow)
        webButton.action = #selector(showPages)
        webButton.isHidden = true
        history.onPick = { [weak self] in self?.reveal($0) }
        let header = Bar.panel([branch], [workflowsButton, webButton, more])

        let col = NSTableColumn(identifier: .init("ci")); col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.indentationPerLevel = 12
        outline.rowSizeStyle = .custom
        outline.dataSource = self
        outline.delegate = self
        outline.menu = NSMenu(); outline.menu?.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        setupButton.bezelStyle = .push
        setupButton.target = self
        setupButton.action = #selector(runSetup)
        if #available(macOS 26, *) { setupButton.tintProminence = .primary }

        let bottom = jobPane.view

        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(scroll); split.addArrangedSubview(bottom)
        split.setHoldingPriority(.init(260), forSubviewAt: 0)   // the runs keep their room; the log takes what's left
        let v = stacked(header, history, split)
        empty.place(in: v, under: header)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        bottom.isHidden = true
        logPane = (bottom, bottom.heightAnchor.constraint(greaterThanOrEqualToConstant: 120), split)
        view = v
        track(owner: self) { [app] in app.workbench.workspaceId } changed: { [weak self, app] in
            self?.worktree = $0
            self?.branch.title = app.worktree($0)?.branch ?? ""   // before the runs come: the header names it at once
            self?.follow()
            self?.loadPages()
        }
        track(owner: self) { [weak self, app] in app.ci[self?.worktree ?? ""] } changed: { [weak self] in self?.apply($0) }
    }

    /// From origin, not gh: there even when gh or glab isn't set up.
    private func loadPages() {
        guard let w = worktree else { return }
        pages = nil; webButton.isHidden = true
        Task {
            let p = await app.quiet(GitWebPages(worktreeId: w)) ?? nil   // a decoration: without it there's no globe
            guard w == worktree else { return }
            pages = p; webButton.isHidden = p == nil
        }
    }

    @objc private func showPages() {
        guard let pages else { return }
        Forge.menu(pages).popUp(positioning: nil, at: NSPoint(x: 0, y: webButton.bounds.height + 4), in: webButton)
    }

    private func showMore() {
        guard let b = moreButton else { return }
        let m = NSMenu()
        m.addItem(withTitle: String(localized: "Refresh"), action: #selector(refreshPressed), keyEquivalent: "").target = self
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b)
    }

    @objc private func refreshPressed() { reload() }

    @objc private func runSetup() { if let setup { Forge.run(setup, in: app) } }

    /// Shown, the log takes about half the height (the runs keep the rest); hidden, the runs have it all.
    private func showLogPane(_ on: Bool) {
        guard let p = logPane, p.view.isHidden == on else { return }
        p.view.isHidden = !on
        p.room.isActive = on
        if on { p.split.setPosition(p.split.bounds.height * 0.45, ofDividerAt: 0) }
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
    private func reload() { if let w = worktree { app.watchAgain(.ci, w) } }

    private func apply(_ e: CIEvent?) {
        guard let e, e.worktree == worktree else { return }
        // A newer list replaces the rows the last one's jobs were being opened in: that one stops at its next step.
        applying?.cancel()
        applying = Task {
            if let error = e.error {
                branch.title = app.worktree(worktree)?.branch ?? ""   // whose runs these would be, still
                workflowsButton.isHidden = true
                show(note: error, setup: Forge.setup(for: error), failed: true); return
            }
            branchName = e.result?.branch ?? ""
            branch.title = branchName
            // What was open stays open across a refresh, its jobs read again.
            let open = Set(runs.flatMap { [$0] + openBelow($0) }.filter { outline.isItemExpanded($0) }.compactMap(\.key))
            let selected = (outline.item(atRow: outline.selectedRow) as? Item)?.id
            runs = (e.result?.runs ?? []).map { Item(.run($0)) }
            workflows = e.result?.workflows ?? []
            workflowsButton.isHidden = workflows.isEmpty
            show(note: runs.isEmpty ? String(localized: "No CI runs on \(branchName) yet.") : nil)
            clock.clear()
            outline.reloadData()
            history.show(CIRuns.history(allRuns))
            for run in runs where open.contains(run.key ?? "") {
                await expand(run, openFailed: false)
                guard !Task.isCancelled else { return }
                for item in openBelow(run) where open.contains(item.key ?? "") { outline.expandItem(item) }
                if let job = run.children?.first(where: { $0.id == selected }), case let row = outline.row(forItem: job), row >= 0 {
                    outline.selectRowIndexes([row], byExtendingSelection: false)
                }
            }
            guard !Task.isCancelled else { return }
            // A workflow's latest run failed (what Source Control's CI line shows): open it at the first failed job,
            // with its log (once, so closing it sticks).
            let failing = Set(CIRuns.latest(allRuns).filter(\.failed).map(\.id))
            if let item = runs.first(where: { failing.contains($0.id ?? -1) }), let id = item.id, autoOpened.insert(id).inserted {
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
            setupButton.title = setup.title; setupButton.toolTip = setup.command
            empty.show(setup.note, symbol: "terminal", text: String(localized: "It runs in a terminal tab; then Check Again."),
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
        guard case .run(let run) = item.kind, let w = worktree else { return }
        if item.children == nil {
            guard let jobs = await app.call(CIJobs(worktreeId: w, run: run.id)) else { return }   // the banner says why; asked again next time
            guard runs.contains(where: { $0 === item }) else { return }   // a newer list came meanwhile: these rows are gone
            item.children = jobs.map { j in
                let i = Item(.job(j, run: run.id))
                i.children = CIRuns.rows(j.steps).map { row in
                    if case .one(let step) = row { return Item(.step(step)) }
                    let fold = Item(.fold(row, job: j.id))
                    fold.children = row.steps.map { Item(.step($0)) }
                    return fold
                }
                return i
            }
            outline.reloadItem(item, reloadChildren: true)
        }
        outline.expandItem(item)
        if openFailed, let failed = item.children?.first(where: { if case .job(let j, _) = $0.kind { j.failed } else { false } }) {
            outline.expandItem(failed)
            let row = outline.row(forItem: failed)
            if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
        }
    }

    private func showLog(_ job: CIRuns.Job, run: Int) {
        guard let w = worktree else { return }
        showLogPane(true)
        jobPane.show(job, run: run, in: w)
    }

    // MARK: actions

    private var allRuns: [CIRuns.Run] { runs.compactMap { if case .run(let r) = $0.kind { r } else { nil } } }
    private func run(_ id: Int) -> CIRuns.Run? { allRuns.first { $0.id == id } }

    private func actions(_ w: String) -> CIActions { CIActions(app: app, worktree: w) { [weak self] in self?.reload() } }

    @objc private func runWorkflow() {
        let m = NSMenu()
        for wf in workflows { m.add(wf.name) { [weak self] in self?.dispatch(wf) } }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: workflowsButton.bounds.height + 4), in: workflowsButton)
    }

    /// The workflow's inputs as a form, then `gh workflow run` on this branch.
    private func dispatch(_ wf: CIRuns.Workflow) {
        guard let w = worktree else { return }
        let a = NSAlert(); a.messageText = String(localized: "Run “\(wf.name)” on \(branchName)?")
        var fields: [(String, NSView)] = []
        let form = NSGridView()
        form.rowAlignment = .firstBaseline
        for input in wf.inputs {
            let control: NSView
            if !input.options.isEmpty {
                let p = NSPopUpButton()
                p.addItems(withTitles: input.options)
                p.selectItem(withTitle: input.defaultValue)
                control = p
            } else {
                let f = NSTextField(string: input.defaultValue); f.placeholderString = input.description
                f.widthAnchor.constraint(equalToConstant: 220).isActive = true; control = f
            }
            fields.append((input.name, control))
            form.addRow(with: [NSTextField(labelWithString: input.name + (input.required ? " *" : "")), control])
        }
        if !wf.inputs.isEmpty { a.accessoryView = form }
        a.informativeText = wf.inputs.isEmpty ? String(localized: "It runs on GitHub Actions.") : String(localized: "Inputs from \(wf.file):")
        a.addButton(withTitle: String(localized: "Run")); a.addButton(withTitle: String(localized: "Cancel"))
        Task {
            guard await runSheet(a) == .alertFirstButtonReturn else { return }
            var inputs: [String: String] = [:]
            for (k, v) in fields { inputs[k] = (v as? NSPopUpButton)?.titleOfSelectedItem ?? (v as? NSTextField)?.stringValue ?? "" }
            if await app.call(CIDispatch(worktreeId: w, workflow: wf.file, branch: branchName, inputs: inputs)) != nil {
                Banner.show(String(localized: "Started \(wf.name)")); reload()
            }
        }
    }

    // MARK: outline

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let i = item as? Item else { return runs.count }
        if case .run = i.kind, i.children == nil { return 1 }   // a placeholder until it's opened
        return i.children?.count ?? 0
    }
    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let i = item as? Item else { return runs[index] }
        return i.children?[index] ?? Item(.step(.init(name: String(localized: "Loading…"), status: "queued", conclusion: nil)))
    }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let i = item as? Item else { return false }
        if case .step = i.kind { return false }
        return i.children.map { !$0.isEmpty } ?? true   // a fold, a job with steps, a run not yet read
    }
    func outlineView(_ o: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        TextSize.of({ if case .run? = (item as? Item)?.kind { Metrics.rowTwoLine } else { Metrics.row } }())
    }
    func outlineView(_ o: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { ListRowView() }
    func outlineViewItemWillExpand(_ n: Notification) {
        guard let i = n.userInfo?["NSObject"] as? Item, case .run = i.kind, i.children == nil else { return }
        Task { await expand(i, openFailed: false) }
    }
    func outlineViewSelectionDidChange(_ n: Notification) {
        guard let i = outline.item(atRow: outline.selectedRow) as? Item, case .job(let j, let run) = i.kind else { return }
        if let s = jobPane.shown, s.job.id == j.id, s.job.status == j.status { jobPane.keep(j, run: run); return }   // a refresh, nothing new to read
        showLog(j, run: run)
    }

    /// A fold opens from anywhere on its row. A step goes to its place in the job's log, which is read when it's over.
    @objc private func rowClicked() {
        guard let item = outline.item(atRow: outline.clickedRow) as? Item else { return }
        switch item.kind {
        case .fold: if outline.isItemExpanded(item) { outline.collapseItem(item) } else { outline.expandItem(item) }
        case .step(let s): showInLog(s, of: item)
        case .run, .job: break
        }
    }

    private func showInLog(_ s: CIRuns.Step, of item: Item) {
        guard let w = worktree, let job = job(of: item), job.status == "completed" else { return }
        if s.failed, jobPane.shown?.job.id == job.id { return }   // what broke is on show under the runs
        CILogTab.open(app, worktree: w, job: job, step: s.name)
    }

    /// The job a step belongs to, past the fold it may sit in.
    private func job(of item: Item) -> CIRuns.Job? {
        var up = outline.parent(forItem: item) as? Item
        while let i = up {
            if case .job(let j, _) = i.kind { return j }
            up = outline.parent(forItem: i) as? Item
        }
        return nil
    }

    func outlineView(_ o: NSOutlineView, viewFor c: NSTableColumn?, item: Any) -> NSView? {
        guard let i = item as? Item else { return nil }
        switch i.kind {
        case .run(let r): return runRow(r)
        case .job(let j, _):
            let done = j.steps.filter { $0.status == "completed" }.count
            let right = j.status == "completed" || j.steps.isEmpty ? j.seconds().map(ciSpan) : "\(done)/\(j.steps.count)"
            return CIRow.line(CIRunLook.mark(j.status, j.conclusion), j.name, font: .ui(12), color: .labelColor, right: right).cell
        case .step(let s):
            // The step running now reads like a title; done ones grey, the ones still to come quieter still.
            let color: NSColor = s.status == "in_progress" ? .labelColor : s.status == "completed" ? .secondaryLabelColor : .tertiaryLabelColor
            let r = CIRow.line(CIRunLook.mark(s.status, s.conclusion), s.shortName, font: .ui(11), color: color, right: s.seconds().map(ciSpan))
            if s.status == "in_progress", let time = r.time { clock.follow(time) { s.seconds().map(ciSpan) } }
            r.cell.toolTip = s.name
            return r.cell
        case .fold(let f, _): return CIRow.fold(f)
        }
    }

    /// The title, then `CIRunMeta`: which run, how long, when. The tooltip has the whole title, as a commit's first line
    /// rarely fits, and the commit, which a narrow panel cuts.
    private func runRow(_ r: CIRuns.Run) -> NSView {
        let t = NSTextField(labelWithString: r.title)
        t.font = .ui(12)
        t.lineBreakMode = .byTruncatingTail
        // What tells runs apart: the workflow only when there are several, the event only when it isn't a push.
        let several = Set(allRuns.map(\.workflow)).count > 1
        let usual = r.finished ? nil : CIRuns.typicalSeconds(allRuns, workflow: r.workflow)
        let meta = CIRunMeta(r, extras: [several ? r.workflow : nil, r.event == "push" ? nil : r.event].compactMap { $0 }, usual: usual, clock: clock)
        let text = NSStackView(views: [t, meta])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Metrics.lineGap
        for x in [t, meta, text] { x.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        meta.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        let cell = CIRow.row([CIRunLook.mark(r.status, r.conclusion), text])
        cell.toolTip = [r.title, [r.workflow, r.shortSHA].compactMap { $0 }.joined(separator: " · ")].joined(separator: "\n")
        return cell
    }
}

extension CIRunsController {
    /// Right-click: what can be done to this run, job or step now.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let item = outline.item(atRow: outline.clickedRow) as? Item, let w = worktree else { return }
        let act = actions(w)
        switch item.kind {
        case .run(let r): addRun(r, act, to: menu)
        case .job(let j, _):
            if j.failed { menu.add(String(localized: "Fix with Agent")) { act.fix(j) } }
            if j.status == "completed" { menu.add(String(localized: "Re-run This Job")) { act.rerunJob(j.id) } }
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            if let u = j.url { addLink(menu, u) }
        case .step(let s):
            if let j = job(of: item), j.status == "completed" {
                menu.add(String(localized: "Show in Log")) { [app] in CILogTab.open(app, worktree: act.worktree, job: j, step: s.name) }
            }
            if let u = job(of: item)?.url, let n = s.number {
                menu.add(String(localized: "Open in Browser")) { Forge.open("\(u)#step:\(n):1") }
            }
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            menu.add(String(localized: "Copy Step Name")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s.name, forType: .string)
            }
        case .fold: break
        }
    }

    private func addRun(_ r: CIRuns.Run, _ act: CIActions, to menu: NSMenu) {
        if r.failed {
            menu.add(String(localized: "Fix with Agent")) { [weak self] in self?.fix(r, in: act.worktree) }
            menu.add(String(localized: "Re-run Failed")) { act.rerunFailed(r.id) }
        }
        if r.finished {
            menu.add(String(localized: "Re-run All")) { act.rerunAll(r.id) }
        } else {
            menu.add(String(localized: "Cancel Run…")) { act.cancel(r) }
        }
        menu.addItem(.separator())
        if r.sha != nil { menu.add(String(localized: "Show Commit")) { act.showCommit(r) } }
        addLink(menu, r.url)
    }

    private func addLink(_ menu: NSMenu, _ url: String) {
        menu.add(String(localized: "Open in Browser")) { Forge.open(url) }
        menu.addItem(.separator())
        menu.add(String(localized: "Copy Link")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string) }
    }
    /// The run's failure typed into the workspace's agent, for the user to send.
    private func fix(_ r: CIRuns.Run, in w: String) {
        let app = app
        guard let repo = app.worktree(w)?.repoId else { return }
        Task {
            let log = await app.call(GitHubFailedLog(repoId: repo, runId: r.id)) ?? ""
            GitFix(app).send("fixCI", worktree: w, vars: ["check": r.workflow, "error": log])
        }
    }
}
