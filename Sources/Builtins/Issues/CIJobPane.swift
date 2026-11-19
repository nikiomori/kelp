import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// The picked job, under the runs: what broke, or its log, and what can be done about it. Over them, as with every
/// tab's tools (DS content bar), the actions are icons with their names in tooltips, and only the actions that can do
/// something for this job show.
@MainActor
final class CIJobPane: NSObject {
    let view = NSStackView()
    /// The job on show, and its run.
    private(set) var shown: (job: CIRuns.Job, run: Int)?
    /// Called after an action, because the runs are worth reading again.
    var onChange: (() -> Void)?
    /// Looks up the job's run, for Cancel while it runs.
    var runOf: ((Int) -> CIRuns.Run?)?

    private let app: AppModel
    private var worktree: String?
    private var report: CIRuns.Report?
    /// What the run's earlier try says of this failure.
    private var note: String?
    private let failures = CIFailuresView()
    // Lines wrap at the pane's width, because a long one (a URL, a command) was cut off at the edge.
    private let logScroll = NSTextView.scrollableTextView()
    private var log: NSTextView { logScroll.documentView as? NSTextView ?? NSTextView() }
    /// The log, with the wait for it and what went wrong standing in its place, as in every panel.
    private let logArea = NSView()
    private let loading = LoadingView(), empty = EmptyStateView()
    private lazy var tryAgain = ClosureButton(title: String(localized: "Try Again")) { [weak self] in
        if let self, let shown, let worktree { show(shown.job, run: shown.run, in: worktree) }
    }
    private let title = NSTextField(labelWithString: "")
    private lazy var mode = CapsuleSegments(
        labels: [String(localized: "Failure"), String(localized: "Log")],
        target: self, action: #selector(modeChanged))
    private lazy var copyButton = IconButton(.symbol("doc.on.doc"), tip: String(localized: "Copy")) { [weak self] in
        self?.copy()
    }
    private lazy var askButton = IconButton(.symbol("sparkles"), tip: String(localized: "Ask Agent to Fix")) {
        [weak self] in self?.askAgent()
    }
    // Not Refresh's clockwise arrow: this runs the jobs again on GitHub.
    private lazy var rerunButton = IconButton(
        .symbol("arrow.counterclockwise"), tip: String(localized: "Re-run Failed")
    ) { [weak self] in self?.rerun() }
    private lazy var stopButton = IconButton(.symbol("stop.fill"), tip: String(localized: "Cancel Run…")) {
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
        log.textContainerInset = NSSize(width: Metrics.gap, height: Metrics.gap)
        log.drawsBackground = false
        logScroll.drawsBackground = false
        title.font = .ui(TextSize.row, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        mode.controlSize = .small
        mode.selectedSegment = 0
        failures.onOpen = { [weak self] in self?.open($0) }
        failures.onFix = { [weak self] in self?.fix($0) }
        logArea.pin(logScroll)
        loading.place(in: logArea)
        empty.place(in: logArea)
        view.orientation = .vertical
        view.spacing = 0
        view.setViews(
            [
                Bar.content([mode, title], [copyButton, askButton, rerunButton, stopButton, fullLogButton]), logArea,
                failures
            ], in: .top)
        for pane in [logArea, failures] { pane.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true }
    }

    func clear() {
        shown = nil
        report = nil
        log.string = ""
        loading.show(nil)
        empty.show(nil)
    }

    /// Called when a job is picked or has finished since. It reads what broke, which comes with the log's tail.
    func show(_ job: CIRuns.Job, run: Int, in worktree: String) {
        shown = (job, run)
        self.worktree = worktree
        report = nil
        note = nil
        log.string = ""
        loading.show(nil)
        empty.show(nil)
        arrange()
        // gh hands out a job's log only once the job is over, and the next refresh after that brings it.
        guard job.status == "completed" else {
            empty.show(
                String(localized: "No Log Yet"), symbol: "doc.text",
                text: String(localized: "The log appears when the job finishes."))
            return
        }
        loading.wait(String(localized: "Loading the log…"))
        Task {
            let result = await app.tryCall(CIFailures(worktreeId: worktree, job: job.id))
            guard shown?.job.id == job.id else { return }
            await loading.settled()
            guard shown?.job.id == job.id else { return }
            loading.show(nil)
            report = result.value
            if let error = result.error, result.value == nil {
                empty.showError(String(localized: "Couldn’t Read the Log"), text: error, buttons: [tryAgain])
            }
            log.string = result.value?.log ?? ""
            log.scrollToEndOfDocument(nil)
            arrange()
            await compareWithEarlierTry(job, run: run, in: worktree)
        }
    }

    /// From the second try on, checks whether the last try broke the same way. That tells a bug in the code from a
    /// fluke of the runner, at the price of one more log, read only for the job on show.
    private func compareWithEarlierTry(_ job: CIRuns.Job, run: Int, in worktree: String) async {
        guard job.failed, let now = report, let attempt = runOf?(run)?.attempt, attempt > 1 else { return }
        // Only a remark, so without the earlier try there is none.
        let before = await app.quiet(CIFailures(worktreeId: worktree, run: run, attempt: attempt - 1))
        guard shown?.job.id == job.id, let before, !before.failures.isEmpty else { return }
        note =
            now.failsLike(before)
            ? String(localized: "The same failed on attempt \(attempt - 1).")
            : String(localized: "Attempt \(attempt - 1) failed differently.")
        arrange()
    }

    /// Called when a refresh brought the same job, so there's nothing new to read.
    func keep(_ job: CIRuns.Job, run: Int) { shown = (job, run) }

    private var canShowFailure: Bool {
        shown?.job.failed == true && report.map { failures.show($0, note: note) } == true
    }

    /// Arranges what this job can show and do. A green job has nothing to fix and only its log to read.
    private func arrange() {
        let failed = shown?.job.failed == true, why = canShowFailure
        mode.isHidden = !why
        askButton.isHidden = !failed
        rerunButton.isHidden = !failed
        stopButton.isHidden = shown?.job.status == "completed"
        copyButton.isHidden = shown?.job.status != "completed"
        fullLogButton.isHidden = copyButton.isHidden
        title.isHidden = why
        // While the job runs, the title says what it's doing.
        title.stringValue = shown?.job.steps.first { $0.status == "in_progress" }?.shortName ?? shown?.job.name ?? ""
        let showFailure = why && mode.selectedSegment == 0
        failures.isHidden = !showFailure
        logArea.isHidden = showFailure
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

    /// Opens the project's copy of the file, which can differ from the commit the run tested; the line number is the
    /// run's.
    private func open(_ failure: CIRuns.Failure) {
        guard let file = failure.file, let root = app.worktree(worktree)?.path else { return }
        app.workbench.open(
            TabURI.file(
                file.hasPrefix("/") ? file : (root as NSString).appendingPathComponent(file), line: failure.line))
    }
}
