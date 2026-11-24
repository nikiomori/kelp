// The CI runs outline: runs, jobs and steps as rows, and what selecting one shows.
import AppKit
import Core
import DesignKit
import KelpKit

extension CIRunsController {
    // MARK: outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? Item else { return runs.count }
        if case .run = item.kind, item.children == nil { return 1 }   // a placeholder row until the run is opened
        return item.children?.count ?? 0
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? Item else { return runs[index] }
        return item.children?[index]
            ?? Item(.step(.init(name: String(localized: "Reading the steps…"), status: "reading", conclusion: nil)))
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? Item else { return false }
        if case .step = item.kind { return false }
        return item.children.map { !$0.isEmpty } ?? true   // a fold, a job with steps, or a run not yet read
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
    /// A ⌘-click leaves the pick as it was, because it opens the row's page (`rowClicked`), not its log.
    func outlineView(_ outlineView: NSOutlineView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet
    {
        NSApp.currentEvent?.isClick(with: .command) == true ? outlineView.selectedRowIndexes : proposed
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let item = outline.item(atRow: outline.selectedRow) as? Item, case .job(let job, let run) = item.kind
        else {
            return
        }
        if let shown = jobPane.shown, shown.job.id == job.id, shown.job.status == job.status {
            jobPane.keep(job, run: run)
            return
        }   // a refresh brought nothing new to read
        showLog(job, run: run)
    }

    /// A fold opens from anywhere on its row. A step goes to its place in the job's log, which is read once the job is
    /// over. A ⌘-click opens the row's page in the browser.
    @objc func rowClicked() {
        guard let item = outline.item(atRow: outline.actedRow) as? Item else { return }
        if NSApp.currentEvent?.isClick(with: .command) == true, let page = page(item) { return Forge.open(page) }
        switch item.kind {
        case .fold: if outline.isItemExpanded(item) { outline.collapseItem(item) } else { outline.expandItem(item) }
        case .step(let step): showInLog(step, of: item)
        case .run, .job: break
        }
    }

    private func showInLog(_ step: CIRuns.Step, of item: Item) {
        guard let worktree, let job = job(of: item), job.status == "completed" else { return }
        if step.failed, jobPane.shown?.job.id == job.id { return }   // what broke is already on show under the runs
        CILogTab.open(app, worktree: worktree, job: job, step: step.name)
    }

    /// The row's page on the site: the run's, the job's, or the step's place in its job's.
    func page(_ item: Item) -> String? {
        switch item.kind {
        case .run(let run): run.url
        case .job(let job, _): job.url
        case .step(let step): job(of: item)?.url.flatMap { url in step.number.map { "\(url)#step:\($0):1" } }
        case .fold: nil
        }
    }

    /// The job a step belongs to, looking past the fold the step may sit in.
    func job(of item: Item) -> CIRuns.Job? {
        var up = outline.parent(forItem: item) as? Item
        while let parent = up {
            if case .job(let job, _) = parent.kind { return job }
            up = outline.parent(forItem: parent) as? Item
        }
        return nil
    }

    /// A row with a page says in its tooltip that a ⌘-click opens it, on the site the project's origin is on.
    func outlineView(_ outlineView: NSOutlineView, viewFor column: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? Item else { return nil }
        let view = cell(item)
        if page(item) != nil {
            let site = ["gitlab": "GitLab", "bitbucket": "Bitbucket"][pages?.forge ?? ""] ?? "GitHub"
            view.toolTip = [view.toolTip, String(localized: "⌘-click: open on \(site)")].compactMap { $0 }
                .joined(separator: "\n")
        }
        return view
    }

    private func cell(_ item: Item) -> NSView {
        switch item.kind {
        case .run(let run): return runRow(run)
        case .job(let job, _):
            let done = job.steps.filter { $0.status == "completed" }.count
            let right =
                job.status == "completed" || job.steps.isEmpty
                ? job.seconds().map(ciSpan) : "\(done)/\(job.steps.count)"
            let cell = CIRow.line(
                CIRunLook.mark(job.status, job.conclusion), job.name, font: .ui(TextSize.row), color: .labelColor,
                right: right
            ).cell
            cell.toolTip = job.name   // a narrow panel cuts the name
            return cell
        case .step(let step):
            // The step running now reads like a title and the others are grey: their marks tell a done step from one
            // still to come (tertiary grey would be the only copy of its name).
            let color: NSColor = step.status == "in_progress" ? .labelColor : .secondaryLabelColor
            let mark = step.status == "reading" ? readingMark() : CIRunLook.mark(step.status, step.conclusion)
            let line = CIRow.line(
                mark, step.shortName, font: .ui(TextSize.caption), color: color, right: step.seconds().map(ciSpan))
            if step.status == "in_progress", let time = line.time { clock.follow(time) { step.seconds().map(ciSpan) } }
            line.cell.toolTip = step.name
            return line.cell
        case .fold(let fold, _): return CIRow.fold(fold)
        }
    }

    /// The placeholder's mark while a run's steps are read: the system's spinner, as the interface waits, not a step's
    /// empty circle.
    private func readingMark() -> NSView {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .mini   // drawn to fit the 12 pt of the step marks under it
        spinner.startAnimation(nil)
        for side in [spinner.widthAnchor, spinner.heightAnchor] { side.constraint(equalToConstant: 12).isActive = true }
        return spinner
    }

    /// The title, then `CIRunMeta`: which run, how long, and when. The tooltip has the whole title, because a commit's
    /// first line rarely fits, and the commit, which a narrow panel cuts.
    private func runRow(_ run: CIRuns.Run) -> NSView {
        let title = NSTextField(labelWithString: run.title)
        title.font = .ui(TextSize.row)
        title.lineBreakMode = .byTruncatingTail
        // What tells runs apart: the workflow only when there are several, and the event only when it isn't a push.
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
