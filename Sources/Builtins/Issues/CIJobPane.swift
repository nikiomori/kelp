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
    /// After Re-run: the runs are worth reading again.
    var onRerun: (() -> Void)?

    private let app: AppModel
    private var worktree: String?
    private var report: CIRuns.Report?
    private let log = NSTextView(), failures = CIFailuresView()
    private let logScroll = NSScrollView()
    private let title = NSTextField(labelWithString: "")
    private lazy var mode = NSSegmentedControl(labels: [String(localized: "Failure"), String(localized: "Log")], trackingMode: .selectOne,
                                               target: self, action: #selector(modeChanged))
    private lazy var copyButton = IconButton(.symbol("doc.on.doc"), tip: String(localized: "Copy")) { [weak self] in self?.copy() }
    private lazy var askButton = IconButton(.symbol("sparkles"), tip: String(localized: "Ask Agent to Fix")) { [weak self] in self?.askAgent() }
    private lazy var rerunButton = IconButton(.symbol("arrow.clockwise"), tip: String(localized: "Re-run Failed")) { [weak self] in self?.rerun() }
    private lazy var webButton = IconButton(.symbol("globe"), tip: String(localized: "Open in Browser")) { [weak self] in
        if let u = self?.shown?.job.url { Forge.open(u) }
    }

    init(app: AppModel) {
        self.app = app
        super.init()
        log.isEditable = false
        log.font = .uiMono(11)
        log.textContainerInset = NSSize(width: 6, height: 6)
        log.drawsBackground = false
        // Lines wrap at the pane's width: a long one (a URL, a command) was cut off at the edge.
        log.isVerticallyResizable = true
        log.isHorizontallyResizable = false
        log.autoresizingMask = .width
        log.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        log.textContainer?.widthTracksTextView = true
        logScroll.documentView = log
        logScroll.hasVerticalScroller = true
        logScroll.drawsBackground = false
        title.font = .ui(12, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        mode.controlSize = .small
        mode.selectedSegment = 0
        failures.onOpen = { [weak self] in self?.open($0) }
        failures.onFix = { [weak self] in self?.fix($0) }
        view.orientation = .vertical
        view.spacing = 0
        view.setViews([Bar.content([mode, title], [copyButton, askButton, rerunButton, webButton]), logScroll, failures], in: .top)
        for v in [logScroll, failures] { v.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true }
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
        log.string = ""
        arrange()
        // gh hands out a job's log only once it's over; the next refresh after that brings it.
        guard job.status == "completed" else {
            log.string = String(localized: "The log appears when the job finishes.")
            return
        }
        let slow = whileSlow { [weak self] in if self?.shown?.job.id == job.id { self?.log.string = String(localized: "Loading the log…") } }
        Task {
            defer { slow.cancel() }
            let r = await app.tryCall(CIFailures(worktreeId: worktree, job: job.id))
            guard shown?.job.id == job.id else { return }
            report = r.value
            log.string = r.value?.log ?? r.error ?? ""
            log.scrollToEndOfDocument(nil)
            arrange()
        }
    }

    /// A refresh brought the same job: nothing new to read.
    func keep(_ job: CIRuns.Job, run: Int) { shown = (job, run) }

    private var canShowFailure: Bool { shown?.job.failed == true && report.map(failures.show) == true }

    /// What this job can show and do. A green job has nothing to fix and only its log to read.
    private func arrange() {
        let failed = shown?.job.failed == true, why = canShowFailure
        mode.isHidden = !why
        askButton.isHidden = !failed
        rerunButton.isHidden = !failed
        title.isHidden = why
        title.stringValue = shown?.job.name ?? ""
        let showFailure = why && mode.selectedSegment == 0
        failures.isHidden = !showFailure
        logScroll.isHidden = showFailure
    }

    @objc private func modeChanged() { arrange() }

    private func copy() {
        let text = !failures.isHidden ? report?.summary ?? "" : log.string
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Banner.show(!failures.isHidden ? String(localized: "Failures copied") : String(localized: "Log copied"))
    }

    private func askAgent() {
        guard let j = shown, let worktree, hasAgent else { return }
        GitFix(app).send("fixCI", worktree: worktree, vars: ["check": j.job.name, "error": report?.forAgent ?? log.string])
    }

    private func fix(_ f: CIRuns.Failure) {
        guard let j = shown, let worktree, hasAgent else { return }
        GitFix(app).send("fixCI", worktree: worktree, vars: ["check": j.job.name, "error": CIRuns.Report.text(of: [f])])
    }

    private var hasAgent: Bool {
        if FileActions(app).targetAgent != nil { return true }
        Banner.show(String(localized: "No agent on this screen. Start one with ⌥⌘T, then ask again."), style: .error)
        return false
    }

    private func rerun() {
        guard let worktree, let j = shown else { return }
        Task {
            if await app.call(CIRerun(worktreeId: worktree, run: j.run)) != nil {
                Banner.show(String(localized: "Re-running the failed jobs")); onRerun?()
            }
        }
    }

    /// The project's copy of the file, which can differ from the commit the run tested: the line is the run's.
    private func open(_ f: CIRuns.Failure) {
        guard let file = f.file, let root = app.worktree(worktree)?.path else { return }
        app.workbench.open(TabURI.file(file.hasPrefix("/") ? file : (root as NSString).appendingPathComponent(file), line: f.line))
    }
}
