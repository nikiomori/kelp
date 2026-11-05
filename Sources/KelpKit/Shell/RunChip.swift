import AppKit
import Core
import DesignKit

/// The title bar's run control while something runs in the workspace, as Xcode's activity: ■ stops it, the name opens the
/// Run list (what last ran is there, ticked for ⌘R). Gone while nothing runs: ⌘R and Run › Choose do the rest, and a
/// release isn't a click away all day. The page it serves has a capsule of its own (`PageChip`).
@MainActor
final class RunChip: NSStackView {
    struct Look: Equatable { var name: String }

    private let app: AppModel
    private let go = PointerButton(frame: .zero), name = PointerButton(frame: .zero)

    init(app: AppModel) {
        self.app = app
        super.init(frame: .zero)
        for b in [go, name] {
            b.radius = nil   // a capsule, as the capsule it sits in
            b.font = .ui(12)
            b.setContentCompressionResistancePriority(.init(320), for: .horizontal)
        }
        go.imagePosition = .imageOnly
        go.contentTintColor = .labelColor
        go.symbolConfiguration = .init(pointSize: 10, weight: Metrics.iconWeight)
        go.widthAnchor.constraint(equalToConstant: 22).isActive = true
        go.image = .symbol("stop.fill", String(localized: "Stop"))
        go.toolTip = String(localized: "Stop (⌘.)")
        go.onClick = { app.scripts.stop() }
        name.padding = 6
        name.imagePosition = .imageTrailing
        name.imageHugsTitle = true
        name.image = .symbol("chevron.down", "")
        name.symbolConfiguration = .init(pointSize: 8, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        name.onClick = { [weak self] in self?.app.scripts.choose() }
        name.toolTip = String(localized: "Choose What to Run (⌃⌘R)")
        setViews([go, name], in: .leading)
        spacing = 0
        detachesHiddenViews = true
        wantsLayer = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        track(owner: self) { [weak self] in self?.look } changed: { [weak self] in self?.show($0) }
        // A workspace shown the first time: what its files offer (the list reads them again when it opens).
        track(owner: self) { app.workbench.workspaceId } changed: { wid in
            guard let wid, app.scripts.state.found[wid] == nil else { return }
            Task { await app.scripts.detect(wid); await app.scripts.load(wid) }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() { super.layout(); layer?.cornerRadius = bounds.height / 2 }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        fadeBackground(to: .fillRest)
        if window != nil { app.scripts.anchor = name }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); fadeBackground(to: .fillRest) }

    /// What runs in the workspace on screen; nil while nothing does.
    private var look: Look? {
        let s = app.scripts
        guard let wid = app.workbench.workspaceId, let current = s.current(wid) else { return nil }
        let live = s.running(in: wid)
        guard !live.isEmpty else { return nil }
        let label = s.label(current.choice, in: wid) + (live.count > 1 ? " +\(live.count - 1)" : "")
        let host = app.worktree(wid).flatMap { RemoteHost.of($0.path)?.host }
        return Look(name: label + (host.map { " · \($0)" } ?? ""))
    }

    private func show(_ l: Look?) {
        isHidden = l == nil
        guard let l else { return }
        crossfade()
        name.attributedTitle = NSAttributedString(string: l.name, attributes: [.font: NSFont.ui(12), .foregroundColor: NSColor.labelColor])
    }
}
