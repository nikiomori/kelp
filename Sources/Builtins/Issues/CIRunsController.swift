import AppKit
import Core
import DesignKit
import KelpKit

/// CI of the branch on screen: runs → jobs → steps, the failed job's log under them (the latest failure opens by itself),
/// Re-run Failed, Ask Agent to Fix, and Run Workflow… for workflows started by hand. GitHub Actions (gh) or GitLab (glab);
/// without them, a button that installs and signs in. The globe opens the project's pages on its site.
@MainActor
final class CIRunsController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let app: AppModel
    init(app: AppModel) { self.app = app; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    private final class Item: NSObject {
        enum Kind { case run(CIRuns.Run), job(CIRuns.Job, run: Int), step(CIRuns.Step) }
        let kind: Kind
        var children: [Item]?
        init(_ k: Kind) { kind = k }
        var id: Int? {
            switch kind {
            case .run(let r): r.id
            case .job(let j, _): j.id
            case .step: nil
            }
        }
    }
    private let outline = NSOutlineView()
    private let branch = NSTextField(labelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private let setupButton = NSButton()
    private var setup: Forge.Setup?
    private let webButton = IconButton(nil, tip: "", target: nil, action: nil)
    private var moreButton: NSButton?
    private var pages: GitWebPages.Pages?
    private let log = NSTextView()
    private let logBar = NSStackView()
    private let workflowsButton = IconButton(nil, tip: "", target: nil, action: nil)
    private var runs: [Item] = []
    private var workflows: [CIRuns.Workflow] = []
    private var worktree: String?
    private var shownLog = "", shownJob: (job: CIRuns.Job, run: Int)?
    private var branchName = ""
    /// The branch's runs, watched while the panel shows: the daemon looks again while one runs, and says when they changed.
    private lazy var ciWatch = Watched(.ci, in: app)
    private var autoOpened = Set<Int>()

    override func loadView() {
        branch.font = .ui(12, weight: .semibold); branch.lineBreakMode = .byTruncatingMiddle
        let more = IconButton(.symbol("ellipsis.circle"), tip: String(localized: "More")) { [weak self] in self?.showMore() }
        workflowsButton.isHidden = true
        for (b, symbol, tip) in [(workflowsButton, "play.circle", String(localized: "Run Workflow…")),
                                 (webButton, "arrow.up.forward.square", String(localized: "Open in Browser"))] {
            b.image = .symbol(symbol, tip)
            b.toolTip = tip
            b.target = self
        }
        moreButton = more
        workflowsButton.action = #selector(runWorkflow)
        webButton.action = #selector(showPages)
        webButton.isHidden = true
        let header = Bar.panel([NSImageView(image: Glyph.image("arrow.triangle.branch", size: 14) ?? NSImage()), branch], [workflowsButton, webButton, more])

        let col = NSTableColumn(identifier: .init("ci")); col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .custom
        outline.dataSource = self
        outline.delegate = self
        outline.menu = NSMenu(); outline.menu?.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        note.textColor = .secondaryLabelColor; note.alignment = .center
        setupButton.bezelStyle = .push
        setupButton.target = self
        setupButton.action = #selector(runSetup)
        if #available(macOS 26, *) { setupButton.tintProminence = .primary }
        let checkAgain = textButton(String(localized: "Check Again")) { [weak self] in self?.reload() }
        checkAgain.controlSize = .regular
        let setupRow = NSStackView(views: [setupButton, checkAgain]); setupRow.spacing = 8
        let empty = NSStackView(views: [note, setupRow])
        empty.orientation = .vertical
        empty.spacing = 14
        empty.isHidden = true

        let bottom = logPane()

        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(scroll); split.addArrangedSubview(bottom)
        split.setHoldingPriority(.init(260), forSubviewAt: 0)   // the runs keep their room; the log takes what's left
        let v = stacked(header, split)
        empty.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: v.centerXAnchor), empty.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 40),
            empty.widthAnchor.constraint(lessThanOrEqualTo: v.widthAnchor, constant: -40),
            bottom.heightAnchor.constraint(greaterThanOrEqualToConstant: 120), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])
        view = v
        track(owner: self) { [app] in app.workbench.workspaceId } changed: { [weak self] in
            self?.worktree = $0
            self?.follow()
            self?.loadPages()
        }
        track(owner: self) { [weak self, app] in app.ci[self?.worktree ?? ""] } changed: { [weak self] in self?.apply($0) }
    }

    /// The selected job's log under the runs, with what can be done with it above it (hidden until a job is picked).
    private func logPane() -> NSStackView {
        log.isEditable = false
        log.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        log.textContainerInset = NSSize(width: 6, height: 6)
        log.isVerticallyResizable = true
        log.autoresizingMask = .width
        log.drawsBackground = false
        let logScroll = NSScrollView()
        logScroll.documentView = log
        logScroll.hasVerticalScroller = true
        logScroll.drawsBackground = false
        let copy = textButton(String(localized: "Copy Log")) { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(shownLog, forType: .string)
            Banner.show(String(localized: "Log copied"))
        }
        let fix = textButton(String(localized: "Ask Agent to Fix")) { [weak self] in self?.askAgent() }
        let rerun = textButton(String(localized: "Re-run Failed")) { [weak self] in self?.rerun() }
        let web = textButton(String(localized: "Open in Browser")) { [weak self] in if let u = self?.shownJob?.job.url { Forge.open(u) } }
        [copy, fix, rerun, web].forEach { logBar.addArrangedSubview($0) }
        logBar.spacing = 6; logBar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        let bottom = NSStackView(views: [logBar, logScroll])
        bottom.orientation = .vertical
        bottom.spacing = 0
        logBar.isHidden = true
        return bottom
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

    private func textButton(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let b = ClosureButton(title: title, action: action)
        b.bezelStyle = .push
        b.controlSize = .small
        return b
    }

    // MARK: loading

    /// Watched while on screen: shown again (another panel was on screen), what ran meanwhile comes at once.
    override func viewDidAppear() { super.viewDidAppear(); follow() }
    override func viewDidDisappear() { super.viewDidDisappear(); follow() }
    private func follow() { ciWatch.key = view.window != nil ? worktree : nil }

    /// Refresh, and after starting runs: the daemon reads them now, and keeps looking for a while.
    private func reload() { if let w = worktree { app.watchAgain(.ci, w) } }

    private func apply(_ e: CIEvent?) {
        guard let e, e.worktree == worktree else { return }
        Task {
            if let error = e.error {
                branch.stringValue = ""; workflowsButton.isHidden = true
                show(note: error, setup: Forge.setup(for: error)); return
            }
            branchName = e.result?.branch ?? ""
            branch.stringValue = branchName
            // What was open stays open across a refresh, its jobs read again.
            let openRuns = Set(runs.filter { outline.isItemExpanded($0) }.compactMap(\.id))
            let openJobs = Set(runs.flatMap { $0.children ?? [] }.filter { outline.isItemExpanded($0) }.compactMap(\.id))
            let selected = (outline.item(atRow: outline.selectedRow) as? Item)?.id
            runs = (e.result?.runs ?? []).map { Item(.run($0)) }
            workflows = e.result?.workflows ?? []
            workflowsButton.isHidden = workflows.isEmpty
            show(note: runs.isEmpty ? String(localized: "No CI runs on \(branchName) yet.") : nil)
            outline.reloadData()
            for run in runs where openRuns.contains(run.id ?? -1) {
                await expand(run, openFailed: false)
                for job in run.children ?? [] where openJobs.contains(job.id ?? -1) { outline.expandItem(job) }
                if let job = run.children?.first(where: { $0.id == selected }) {
                    outline.selectRowIndexes([outline.row(forItem: job)], byExtendingSelection: false)
                }
            }
            // A workflow's latest run failed (what Source Control's CI line shows): open it at the first failed job,
            // with its log (once, so closing it sticks).
            let failing = Set(CIRuns.latest(runs.compactMap { if case .run(let r) = $0.kind { r } else { nil } }).filter(\.failed).map(\.id))
            if let item = runs.first(where: { failing.contains($0.id ?? -1) }), let id = item.id, autoOpened.insert(id).inserted {
                await expand(item, openFailed: true)
            }
        }
    }

    /// `setup`: gh or glab isn't installed or signed in; what it says, and the button that runs the fix in a terminal.
    private func show(note text: String?, setup: Forge.Setup? = nil) {
        self.setup = setup
        note.stringValue = setup.map { $0.note + "\n" + String(localized: "It runs in a terminal tab; then Check Again.") } ?? text ?? ""
        note.superview?.isHidden = text == nil
        setupButton.superview?.isHidden = setup == nil
        if let setup { setupButton.title = setup.title; setupButton.toolTip = setup.command }
        outline.enclosingScrollView?.isHidden = text != nil
        if text != nil { logBar.isHidden = true; log.string = "" }
    }

    private func expand(_ item: Item, openFailed: Bool) async {
        guard case .run(let run) = item.kind, let w = worktree else { return }
        if item.children == nil {
            guard let jobs = await app.call(CIJobs(worktreeId: w, run: run.id)) else { return }   // the banner says why; asked again next time
            item.children = jobs.map { j in
                let i = Item(.job(j, run: run.id))
                i.children = j.steps.map { Item(.step($0)) }
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
        shownJob = (job, run)
        logBar.isHidden = false
        log.string = ""
        // gh hands out a job's log only once it's over; the next refresh after that brings it.
        guard job.status == "completed" else {
            shownLog = ""
            log.string = String(localized: "The log appears when the job finishes.")
            return
        }
        let slow = whileSlow { [weak self] in if self?.shownJob?.job.id == job.id { self?.log.string = String(localized: "Loading the log…") } }
        Task {
            defer { slow.cancel() }
            let r = await app.tryCall(CILog(worktreeId: w, job: job.id))
            guard shownJob?.job.id == job.id else { return }
            shownLog = r.value ?? r.error ?? ""
            log.string = shownLog
            log.scrollToEndOfDocument(nil)
        }
    }

    // MARK: actions

    private func askAgent() {
        guard let w = worktree, let j = shownJob else { return }
        guard FileActions(app).targetAgent != nil else {
            Banner.show(String(localized: "No agent in this workspace. Start one with ⌥⌘T, then ask again."), style: .error)
            return
        }
        GitFix(app).send("fixCI", worktree: w, vars: ["check": j.job.name, "error": shownLog])
    }

    private func rerun() { if let w = worktree, let j = shownJob { rerun(w, run: j.run) } }

    private func rerun(_ w: String, run: Int) {
        Task {
            if await app.call(CIRerun(worktreeId: w, run: run)) != nil {
                Banner.show(String(localized: "Re-running the failed jobs")); reload()
            }
        }
    }

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

    /// Right-click a run or a job: its page on the site, and Re-run Failed for a failed run.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let item = outline.item(atRow: outline.clickedRow) as? Item else { return }
        switch item.kind {
        case .run(let r):
            menu.add(String(localized: "Open in Browser"), symbol: "globe") { Forge.open(r.url) }
            if r.failed, let w = worktree {
                menu.add(String(localized: "Re-run Failed"), symbol: "arrow.clockwise") { [weak self] in self?.rerun(w, run: r.id) }
            }
        case .job(let j, _): if let u = j.url { menu.add(String(localized: "Open in Browser"), symbol: "globe") { Forge.open(u) } }
        case .step: break
        }
    }

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
        return i.children.map { !$0.isEmpty } ?? true
    }
    func outlineView(_ o: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { TextSize.of({ if case .run? = (item as? Item)?.kind { 38 } else { 22 } }()) }
    func outlineViewItemWillExpand(_ n: Notification) {
        guard let i = n.userInfo?["NSObject"] as? Item, case .run = i.kind, i.children == nil else { return }
        Task { await expand(i, openFailed: false) }
    }
    func outlineViewSelectionDidChange(_ n: Notification) {
        guard let i = outline.item(atRow: outline.selectedRow) as? Item, case .job(let j, let run) = i.kind else { return }
        if let s = shownJob, s.job.id == j.id, s.job.status == j.status { shownJob = (j, run); return }   // a refresh, nothing new to read
        showLog(j, run: run)
    }

    func outlineView(_ o: NSOutlineView, viewFor c: NSTableColumn?, item: Any) -> NSView? {
        guard let i = item as? Item else { return nil }
        switch i.kind {
        case .run(let r):
            let t = NSTextField(labelWithString: r.title)
            t.font = .ui(12)
            t.lineBreakMode = .byTruncatingTail
            // What tells runs apart: the workflow only when there are several, the event only when it isn't a push.
            let several = Set(runs.compactMap { if case .run(let x) = $0.kind { x.workflow } else { nil } }).count > 1
            let parts = [r.status == "completed" ? nil : CIRunLook.words(r.status, nil), several ? r.workflow : nil,
                         r.event == "push" ? nil : r.event, CIRunLook.ago(r.createdAt)]
            let s = NSTextField(labelWithString: parts.compactMap { $0 }.joined(separator: " · ")); s.font = .ui(11)
            s.textColor = .secondaryLabelColor; s.lineBreakMode = .byTruncatingTail
            let text = NSStackView(views: [t, s])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 1
            for x in [t, s, text] { x.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
            return row([CIRunLook.mark(r.status, r.conclusion), text])
        case .job(let j, _):
            let t = NSTextField(labelWithString: j.name)
            t.font = .ui(12)
            t.lineBreakMode = .byTruncatingTail
            t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            guard j.status != "completed", !j.steps.isEmpty else { return row([CIRunLook.mark(j.status, j.conclusion), t]) }
            // How far it got: "6/12" steps.
            let n = NSTextField(labelWithString: "\(j.steps.filter { $0.status == "completed" }.count)/\(j.steps.count)")
            n.font = .uiDigits(11, weight: .regular); n.textColor = .tertiaryLabelColor
            return row([CIRunLook.mark(j.status, j.conclusion), t, NSView(), n])
        case .step(let s):
            let t = NSTextField(labelWithString: s.name)
            t.font = .ui(11)
            t.lineBreakMode = .byTruncatingTail
            // The step running now reads like a title; done ones grey, the ones still to come quieter still.
            t.textColor = s.status == "in_progress" ? .labelColor : s.status == "completed" ? .secondaryLabelColor : .tertiaryLabelColor
            t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return row([CIRunLook.mark(s.status, s.conclusion), t])
        }
    }

    private func row(_ views: [NSView]) -> NSView {
        let r = NSStackView(views: views)
        r.spacing = 6
        r.alignment = .centerY
        let cell = NSTableCellView()
        r.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(r)
        NSLayoutConstraint.activate([r.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                                     r.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                                     r.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
}
