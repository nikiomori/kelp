import AppKit
import Core
import DesignKit
import KelpKit

/// Over the rows, what an agent last proposed, as Artifacts Overview says what an agent changed: "Claude: 3 tasks
/// proposed", Show (them, in Waiting for You), Remove (the ones not taken) and ✕ (keep them, and close the bar until
/// the next proposal).
@MainActor
final class TaskProposalBar: NSStackView {
    static let seenKey = "tasks.proposalsSeen"
    private let model: TasksModel
    private let face = NSImageView()
    private let line = NSTextField.label("", font: .ui(TextSize.caption))
    private var shown: [TaskRow] = []
    /// The agent who proposed `shown`, as the line names it.
    private var agent = ""

    init(model: TasksModel) {
        self.model = model
        super.init(frame: .zero)
        line.lineBreakMode = .byTruncatingTail
        line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let show = TextButton(String(localized: "Show")) { [weak self] in self?.model.source = .waiting }
        let remove = TextButton(String(localized: "Remove")) { [weak self] in
            guard let self else { return }
            let rows = shown, app = model.app
            let question = String(localized: "Remove \(rows.count) proposals from \(agent)?")
            Task { if await TaskActions.remove(app, rows, question: question) { self.seen() } }
        }
        let close = IconButton(.symbol("xmark"), tip: String(localized: "Close")) { [weak self] in self?.seen() }
        for button in [show, remove, close] as [NSView] {
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        setViews([face, line, NSView(), show, remove, close], in: .leading)
        spacing = Metrics.gap
        edgeInsets = NSEdgeInsets(top: Metrics.gap, left: Metrics.inset, bottom: Metrics.gap, right: Metrics.inset)
        isHidden = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Shows the last agent's proposals still waiting to be taken, made since the bar was last closed.
    func show(_ rows: [TaskRow]) {
        let seen = model.app.uiState[Self.seenKey]?.number ?? 0
        let waiting = rows.filter { $0.task.proposed == true && $0.task.state == .open && ($0.task.at ?? 0) > seen }
        let last = waiting.max { ($0.task.at ?? 0) < ($1.task.at ?? 0) }?.task.by
        shown = waiting.filter { $0.task.by == last }
        if let last {
            let session = model.app.session(last)
            agent = session?.agent.map { model.app.catalog.name($0) } ?? String(localized: "An agent")
            face.image = session?.agent.flatMap { model.app.catalog.icon($0, size: Metrics.iconSmall) }
            line.stringValue = "\(agent): " + String(localized: "\(shown.count) tasks proposed")
        }
        guard isHidden != shown.isEmpty else { return }
        crossfade()
        isHidden = shown.isEmpty
    }

    private func seen() {
        let at = shown.compactMap(\.task.at).max() ?? Date().timeIntervalSince1970
        let app = model.app
        Task { _ = await app.uiState.save(Self.seenKey, .double(at)) }
        shown = []
        isHidden = true
    }
}
