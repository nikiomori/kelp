// The CI runs outline: runs, jobs and steps as rows, and what selecting one shows.
import AppKit
import Core
import DesignKit
import KelpKit

extension CIRunsController {
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
    @objc func rowClicked() {
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
    func job(of item: Item) -> CIRuns.Job? {
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
                CIRunLook.mark(job.status, job.conclusion), job.name, font: .ui(TextSize.row), color: .labelColor,
                right: right
            ).cell
        case .step(let step):
            // The step running now reads like a title; done ones grey, the ones still to come quieter still.
            let color: NSColor =
                step.status == "in_progress"
                ? .labelColor : step.status == "completed" ? .secondaryLabelColor : .tertiaryLabelColor
            let line = CIRow.line(
                CIRunLook.mark(step.status, step.conclusion), step.shortName, font: .ui(TextSize.caption), color: color,
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
        title.font = .ui(TextSize.row)
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
