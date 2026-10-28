import AppKit
import Core
import DesignKit

/// The title bar's run control, Xcode's Run and scheme in one capsule: ▶ runs what ⌘R would (■ stops what runs here),
/// the name opens the Run list, ":5173" opens the page a run serves — only then, never by itself. A name nothing ran
/// yet is a guess, dimmed. Hidden while the project offers nothing to run.
@MainActor
final class RunChip: NSStackView {
    struct Look: Equatable { var name: String, guess: Bool, running: Bool, port: String?, tip: String }

    private let app: AppModel
    private let go = PointerButton(frame: .zero), name = PointerButton(frame: .zero), page = PointerButton(frame: .zero)

    init(app: AppModel) {
        self.app = app
        super.init(frame: .zero)
        for b in [go, name, page] {
            b.radius = nil   // a capsule, as the capsule it sits in
            b.font = .ui(12)
            b.setContentCompressionResistancePriority(.init(320), for: .horizontal)
        }
        go.imagePosition = .imageOnly
        go.contentTintColor = .labelColor
        go.symbolConfiguration = .init(pointSize: 10, weight: Metrics.iconWeight)
        go.widthAnchor.constraint(equalToConstant: 22).isActive = true
        go.onClick = { [weak self] in self?.goClicked() }
        name.padding = 6
        name.imagePosition = .imageTrailing
        name.imageHugsTitle = true
        name.image = .symbol("chevron.down", "")
        name.symbolConfiguration = .init(pointSize: 8, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        name.onClick = { [weak self] in self?.app.scripts.choose() }
        name.toolTip = String(localized: "Choose What to Run (⌃⌘R)")
        page.padding = 4
        page.font = .uiDigits(12)
        page.contentTintColor = .secondaryLabelColor
        page.onClick = { [weak self] in self?.openPage() }
        setViews([go, name, page], in: .leading)
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
        if window != nil { app.scripts.anchor = self }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); fadeBackground(to: .fillRest) }

    /// What the workspace on screen would run, and what runs there now.
    private var look: Look? {
        let s = app.scripts
        guard let wid = app.workbench.workspaceId, let current = s.current(wid) else { return nil }
        let live = s.running(in: wid)
        let url = live.lazy.compactMap { s.state.active[$0]?.url }.first
        let port = url.flatMap { URLComponents(string: $0)?.port }.map { ":\($0)" }
        let label = s.label(current.choice, in: wid) + (live.count > 1 ? " +\(live.count - 1)" : "")
        let host = app.worktree(wid).flatMap { RemoteHost.of($0.path)?.host }
        return Look(name: label + (host.map { " · \($0)" } ?? ""), guess: current.guess, running: !live.isEmpty, port: port, tip: url ?? "")
    }

    private func show(_ l: Look?) {
        isHidden = l == nil
        guard let l else { return }
        crossfade()
        go.image = .symbol(l.running ? "stop.fill" : "play.fill", l.running ? String(localized: "Stop") : String(localized: "Run"))
        go.toolTip = l.running ? String(localized: "Stop (⌘.)") : String(localized: "Run (⌘R)")
        name.attributedTitle = NSAttributedString(string: l.name, attributes: [.font: NSFont.ui(12),
                                                                              .foregroundColor: l.guess ? NSColor.secondaryLabelColor : .labelColor])
        page.isHidden = l.port == nil
        page.title = l.port ?? ""
        page.toolTip = String(localized: "Open \(l.tip)")
    }

    private func goClicked() {
        let s = app.scripts
        if s.canStop { s.stop() } else { s.run("run") }
    }

    private func openPage() {
        let s = app.scripts
        guard let wid = app.workbench.workspaceId, let sid = s.running(in: wid).first(where: { s.state.active[$0]?.url != nil }) else { return }
        app.scripts.openPage(sid)
    }
}
