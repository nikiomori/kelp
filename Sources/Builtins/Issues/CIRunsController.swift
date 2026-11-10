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
    final class Item: NSObject {
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
    let outline = ListOutlineView()
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
    lazy var jobPane: CIJobPane = {
        let pane = CIJobPane(app: app)
        pane.onChange = { [weak self] in self?.reload() }
        pane.runOf = { [weak self] id in self?.run(id) }
        return pane
    }()
    /// The log's half of the split, shown once a job is picked: empty, it took most of the height and left the runs a strip.
    private var logPane: (view: NSView, room: NSLayoutConstraint, split: NSSplitView)?
    let workflowsButton = IconButton(nil, tip: "", target: nil, action: nil)
    var runs: [Item] = []
    var workflows: [CIRuns.Workflow] = []
    var worktree: String?
    var branchName = ""
    /// The branch's runs, watched while the panel shows: the daemon looks again while one runs, and says when they changed.
    private lazy var ciWatch = Watched(.ci, in: app)
    private var autoOpened = Set<Int>()
    /// The list being shown, its open runs read again.
    private var applying: Task<Void, Never>?
    let clock = CIClock()
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
        if view.window != nil { pane.split.crossfade(Motion.base) }   // half the panel changes hands: not at once
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
    func reload() { if let worktree { app.watchAgain(.ci, worktree) } }

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
            let was = Dictionary(runs.compactMap { run in run.key.map { ($0, run) } }) { first, _ in first }
            runs = (event.result?.runs ?? []).map { run in
                let item = Item(.run(run))
                // An open run keeps its rows until they're read again: shut and opened a moment later, the list jumped.
                if let key = item.key, open.contains(key) { item.children = was[key]?.children }
                return item
            }
            workflows = event.result?.workflows ?? []
            workflowsButton.isHidden = workflows.isEmpty
            show(note: runs.isEmpty ? String(localized: "No CI runs on \(branchName) yet.") : nil)
            clock.clear()
            outline.reloadData()
            history.show(CIRuns.history(allRuns))
            let reopen = { [self] (run: Item) in
                outline.expandItem(run)
                for item in openBelow(run) where open.contains(item.key ?? "") { outline.expandItem(item) }
                if let job = run.children?.first(where: { $0.id == selected }),
                    case let row = outline.row(forItem: job), row >= 0
                {
                    outline.selectRowIndexes([row], byExtendingSelection: false)
                }
            }
            for run in runs where open.contains(run.key ?? "") && run.children != nil { reopen(run) }
            for run in runs where open.contains(run.key ?? "") {
                // A run that was over when its jobs were last read has nothing new to say.
                if run.children != nil, case .run(let before)? = was[run.key ?? ""]?.kind, before.finished { continue }
                let read = await readJobs(run)
                guard !Task.isCancelled else { return }
                if read { reopen(run) }
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

    /// A run's jobs, read (again) into its rows. False: they couldn't be read, or a newer list came meanwhile.
    private func readJobs(_ item: Item) async -> Bool {
        guard case .run(let run) = item.kind, let worktree else { return false }
        // the banner says why; asked again next time
        guard let jobs = await app.call(CIJobs(worktreeId: worktree, run: run.id)) else { return false }
        guard runs.contains(where: { $0 === item }) else { return false }   // these rows are gone
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
        return true
    }

    func expand(_ item: Item, openFailed: Bool) async {
        guard case .run = item.kind else { return }
        if item.children == nil, await !readJobs(item) { return }
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

    func showLog(_ job: CIRuns.Job, run: Int) {
        guard let worktree else { return }
        showLogPane(true)
        jobPane.show(job, run: run, in: worktree)
    }

}
