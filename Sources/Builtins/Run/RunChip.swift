import AppKit
import Core
import DesignKit
import KelpKit

/// The title bar's run control, Xcode's Run and scheme in one capsule. ▶ runs what ⌘R would (■ stops what runs here),
/// and the name opens the Run list. A name that nothing ran yet is a guess, and is dimmed. The chip is hidden while
/// the project offers nothing to run. The page a run serves has a capsule of its own (`PageChip`).
@MainActor
final class RunChip: ChipCapsule, WindowBarItem {
    struct Look: Equatable { var name: String, guess: Bool, running: Bool }

    private let app: AppModel
    private let runs: Runs
    private let go = PointerButton(frame: .zero), name = PointerButton(frame: .zero)

    init(app: AppModel, runs: Runs) {
        self.app = app
        self.runs = runs
        super.init()
        hold([go, name], font: .ui(TextSize.row))
        go.imagePosition = .imageOnly
        go.contentTintColor = .labelColor
        go.symbolConfiguration = .chrome(Metrics.iconSmall)
        go.widthAnchor.constraint(equalToConstant: TextSize.barCapsule).isActive = true   // round, as its end is
        go.onClick = { [weak self] in self?.goClicked() }
        name.padding = 6
        name.imagePosition = .imageTrailing
        name.imageHugsTitle = true
        name.image = .symbol("chevron.down", "")
        name.symbolConfiguration = .chrome(Metrics.iconTiny)
        name.lineBreakMode = .byTruncatingTail
        name.onClick = { [weak self] in self?.runs.choose() }
        name.toolTip = app.extensions.hint(String(localized: "Choose What to Run"), "scripts.choose")
        track(owner: self) { [weak self] in
            self?.look
        } changed: { [weak self] in
            self?.show($0)
        }
        // When a workspace shows for the first time, reads what its files offer (the list reads them again when it
        // opens).
        track(owner: self) {
            app.workbench.workspaceId
        } changed: { wid in
            guard let wid, runs.state.found[wid] == nil else { return }
            Task {
                await runs.detect(wid)
                await runs.load(wid)
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The chip keeps its width however short the bar is; its name truncates.
    func fit(barWidth: CGFloat) {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { runs.anchor = name }
    }

    /// What the workspace on screen would run, and what runs there now.
    private var look: Look? {
        guard let wid = app.workbench.workspaceId, let current = runs.current(wid) else { return nil }
        let live = runs.running(in: wid)
        let label = runs.label(current.choice, in: wid) + (live.count > 1 ? " +\(live.count - 1)" : "")
        let host = app.worktree(wid).flatMap { RemoteHost.of($0.path)?.host }
        return Look(name: label + (host.map { " · \($0)" } ?? ""), guess: current.guess, running: !live.isEmpty)
    }

    private func show(_ look: Look?) {
        isHidden = look == nil
        guard let look else { return }
        crossfade()
        go.image = .symbol(
            look.running ? "stop.fill" : "play.fill",
            look.running ? String(localized: "Stop") : String(localized: "Run"))
        go.toolTip =
            look.running
            ? app.extensions.hint(String(localized: "Stop"), "scripts.stop")
            : app.extensions.hint(String(localized: "Run"), "scripts.run")
        name.attributedTitle = NSAttributedString(
            string: look.name,
            attributes: [
                .font: NSFont.ui(TextSize.row),
                .foregroundColor: look.guess ? NSColor.secondaryLabelColor : .labelColor
            ])
    }

    private func goClicked() {
        if runs.canStop { runs.stop() } else { runs.run("run") }
    }
}

/// The title bar's capsule of buttons, shared by the run and page chips: as high as the bar's other capsules
/// (`TextSize.barCapsule`, 22 pt for normal text), with round ends and a resting fill.
@MainActor
class ChipCapsule: NSStackView {
    init() {
        super.init(frame: .zero)
        spacing = 0
        detachesHiddenViews = true
        wantsLayer = true
        heightAnchor.constraint(equalToConstant: TextSize.barCapsule).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Holds its buttons in order. They are capsules too, so they don't square off its ends.
    func hold(_ chips: [PointerButton], font: NSFont) {
        for chip in chips {
            chip.radius = nil   // a capsule, like the capsule it sits in
            chip.font = font
            chip.setContentCompressionResistancePriority(.init(320), for: .horizontal)
        }
        setViews(chips, in: .leading)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        fadeBackground(to: .fillRest)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        fadeBackground(to: .fillRest)
    }
}
