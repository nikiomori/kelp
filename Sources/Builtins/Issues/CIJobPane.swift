import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// The picked job under the runs: what broke, or its log, and what can be done about it. Over them, as every tab's tools
/// (DS content bar), the actions are icons with their names in tooltips, and only those that can do something for this job.
@MainActor
final class CIJobPane: NSObject {
    let view = NSStackView()
    /// The job on show and its run.
    private(set) var shown: (job: CIRuns.Job, run: Int)?
    /// After an action: the runs are worth reading again.
    var onChange: (() -> Void)?
    /// The job's run, for Cancel while it runs.
    var runOf: ((Int) -> CIRuns.Run?)?

    private let app: AppModel
    private var worktree: String?
    private var report: CIRuns.Report?
    /// What the run's earlier try says of this failure.
    private var note: String?
    private let failures = CIFailuresView()
    // Lines wrap at the pane's width: a long one (a URL, a command) was cut off at the edge.
    private let logScroll = NSTextView.scrollableTextView()
    private var log: NSTextView { logScroll.documentView as? NSTextView ?? NSTextView() }
    private let title = NSTextField(labelWithString: "")
    private lazy var mode = NSSegmentedControl(
        labels: [String(localized: "Failure"), String(localized: "Log")], trackingMode: .selectOne,
        target: self, action: #selector(modeChanged))
    private lazy var copyButton = IconButton(.symbol("doc.on.doc"), tip: String(localized: "Copy")) { [weak self] in
        self?.copy()
    }
    private lazy var askButton = IconButton(.symbol("sparkles"), tip: String(localized: "Ask Agent to Fix")) {
        [weak self] in self?.askAgent()
    }
    private lazy var rerunButton = IconButton(.symbol("arrow.clockwise"), tip: String(localized: "Re-run Failed")) {
        [weak self] in self?.rerun()
    }
    private lazy var stopButton = IconButton(.symbol("stop.circle"), tip: String(localized: "Cancel Run…")) {
        [weak self] in
        if let self, let shown, let run = runOf?(shown.run) { actions?.cancel(run) }
    }
    private lazy var fullLogButton = IconButton(
        .symbol("arrow.up.forward.square"), tip: String(localized: "Open Full Log")
    ) { [weak self] in
        if let self, let shown, let worktree { CILogTab.open(app, worktree: worktree, job: shown.job) }
    }
    private var actions: CIActions? {
        worktree.map { CIActions(app: app, worktree: $0) { [weak self] in self?.onChange?() } }
    }

    init(app: AppModel) {
        self.app = app
        super.init()
        log.isEditable = false
        log.font = .uiMono(TextSize.caption)
        log.textContainerInset = NSSize(width: 6, height: 6)
        log.drawsBackground = false
        logScroll.drawsBackground = false
        title.font = .ui(TextSize.row, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        mode.controlSize = .small
        mode.selectedSegment = 0
        failures.onOpen = { [weak self] in self?.open($0) }
        failures.onFix = { [weak self] in self?.fix($0) }
        view.orientation = .vertical
        view.spacing = 0
        view.setViews(
            [
                Bar.content([mode, title], [copyButton, askButton, rerunButton, stopButton, fullLogButton]), logScroll,
                failures
            ], in: .top)
        for pane in [logScroll, failures] { pane.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true }
    }

    func clear() {
        shown = nil
        report = nil
        log.string = ""
    }

    /// Picked, or finished since: reads what broke, which comes with the log's tail.
    func show(_ job: CIRuns.Job, run: Int, in worktree: String) {
        shown = (job, run)
        self.worktree = worktree
        report = nil
        note = nil
        log.string = ""
        arrange()
        // gh hands out a job's log only once it's over; the next refresh after that brings it.
        guard job.status == "completed" else {
            log.string = String(localized: "The log appears when the job finishes.")
            return
        }
        let slow = whileSlow { [weak self] in
            if self?.shown?.job.id == job.id { self?.log.string = String(localized: "Loading the log…") }
        }
        Task {
            defer { slow.cancel() }
            let result = await app.tryCall(CIFailures(worktreeId: worktree, job: job.id))
            guard shown?.job.id == job.id else { return }
            report = result.value
            log.string = result.value?.log ?? result.error ?? ""
            log.scrollToEndOfDocument(nil)
            arrange()
            await compareWithEarlierTry(job, run: run, in: worktree)
        }
    }

    /// From the second try on: did the last one break the same way? That tells the code from a fluke of the runner, at the
    /// price of one more log, read only for the job on show.
    private func compareWithEarlierTry(_ job: CIRuns.Job, run: Int, in worktree: String) async {
        guard job.failed, let now = report, let attempt = runOf?(run)?.attempt, attempt > 1 else { return }
        let before = await app.quiet(CIFailures(worktreeId: worktree, run: run, attempt: attempt - 1))   // a remark: without it, none
        guard shown?.job.id == job.id, let before, !before.failures.isEmpty else { return }
        note =
            now.failsLike(before)
            ? String(localized: "The same failed on attempt \(attempt - 1).")
            : String(localized: "Attempt \(attempt - 1) failed differently.")
        arrange()
    }

    /// A refresh brought the same job: nothing new to read.
    func keep(_ job: CIRuns.Job, run: Int) { shown = (job, run) }

    private var canShowFailure: Bool {
        shown?.job.failed == true && report.map { failures.show($0, note: note) } == true
    }

    /// What this job can show and do. A green job has nothing to fix and only its log to read.
    private func arrange() {
        let failed = shown?.job.failed == true, why = canShowFailure
        mode.isHidden = !why
        askButton.isHidden = !failed
        rerunButton.isHidden = !failed
        stopButton.isHidden = shown?.job.status == "completed"
        copyButton.isHidden = shown?.job.status != "completed"
        fullLogButton.isHidden = copyButton.isHidden
        title.isHidden = why
        // While it runs, what it's doing.
        title.stringValue = shown?.job.steps.first { $0.status == "in_progress" }?.shortName ?? shown?.job.name ?? ""
        let showFailure = why && mode.selectedSegment == 0
        failures.isHidden = !showFailure
        logScroll.isHidden = showFailure
    }

    @objc private func modeChanged() { arrange() }

    private func copy() {
        let text = !failures.isHidden ? report?.summary ?? "" : log.string
        copyText(text)
        Banner.show(!failures.isHidden ? String(localized: "Failures copied") : String(localized: "Log copied"))
    }

    private func askAgent() {
        guard let shown, let worktree, actions?.hasAgent == true else { return }
        GitFix(app).send(
            "fixCI", worktree: worktree, vars: ["check": shown.job.name, "error": report?.forAgent ?? log.string])
    }

    private func fix(_ failure: CIRuns.Failure) {
        guard let shown, let worktree, actions?.hasAgent == true else { return }
        GitFix(app).send(
            "fixCI", worktree: worktree, vars: ["check": shown.job.name, "error": CIRuns.Report.text(of: [failure])])
    }

    private func rerun() { if let shown { actions?.rerunFailed(shown.run) } }

    /// The project's copy of the file, which can differ from the commit the run tested: the line is the run's.
    private func open(_ failure: CIRuns.Failure) {
        guard let file = failure.file, let root = app.worktree(worktree)?.path else { return }
        app.workbench.open(
            TabURI.file(
                file.hasPrefix("/") ? file : (root as NSString).appendingPathComponent(file), line: failure.line))
    }
}
