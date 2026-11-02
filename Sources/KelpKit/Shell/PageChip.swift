import AppKit
import Core
import DesignKit
import WorkbenchKit

/// The title bar's way to what the workspace on screen serves, whoever started it: its address opens the page beside you
/// (⇧⌘O; a database's is copied), "+2" opens the Run menu, which lists them all, and a right-click has the rest. There
/// with no run chip too: an agent's server in a project with nothing to run. Hidden while nothing listens.
@MainActor
final class PageChip: NSStackView {
    private struct Look: Equatable { var workspace: String, page: ServedPage, more: Int }

    /// Only the port, when the bar is short of room.
    var compact = false { didSet { if compact != oldValue { show(look) } } }

    private let app: AppModel
    private let ports: Watched
    private let open = PointerButton(frame: .zero), more = PointerButton(frame: .zero)

    init(app: AppModel) {
        self.app = app; ports = Watched(.ports, in: app)
        super.init(frame: .zero)
        for b in [open, more] {
            b.radius = nil   // a capsule, as the capsule it sits in
            b.font = .uiDigits(12)
            b.setContentCompressionResistancePriority(.init(320), for: .horizontal)
        }
        open.padding = 8
        open.imagePosition = .imageLeading
        open.imageHugsTitle = true
        open.image = .symbol("network", "")
        open.symbolConfiguration = .init(pointSize: 11, weight: Metrics.iconWeight)
        open.onClick = { [weak self] in
            guard let self, let l = look else { return }
            app.scripts.open(l.page, in: l.workspace)
        }
        more.padding = 6
        more.contentTintColor = .secondaryLabelColor
        more.toolTip = String(localized: "Everything Running Here (⌃⌘R)")
        more.onClick = { [weak self] in self?.app.scripts.choose(from: self?.more) }
        setViews([open, more], in: .leading)
        spacing = 0
        detachesHiddenViews = true
        wantsLayer = true
        isHidden = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        track(owner: self) { [weak self] in self?.look } changed: { [weak self] in self?.show($0) }
        track(owner: self) { app.workbench.workspaceId } changed: { [weak self] in self?.ports.key = $0 }
    }
    required init?(coder: NSCoder) { fatalError() }

    private var look: Look? {
        guard let wid = app.workbench.workspaceId else { return nil }
        let pages = app.scripts.pages(wid)
        return pages.first.map { Look(workspace: wid, page: $0, more: pages.count - 1) }
    }

    override func layout() { super.layout(); layer?.cornerRadius = bounds.height / 2 }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        fadeBackground(to: .fillRest)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); fadeBackground(to: .fillRest) }

    private func show(_ l: Look?) {
        if isHidden != (l == nil) { crossfade() }
        isHidden = l == nil
        guard let l else { return }
        open.title = compact ? ":\(l.page.port)" : l.page.address
        open.toolTip = l.page.isWeb ? String(localized: "Open \(l.page.url) (⇧⌘O)") : String(localized: "Copy \(l.page.address) (⇧⌘O)")
        open.menu = menu(l)
        more.isHidden = l.more == 0
        more.title = "+\(l.more)"
    }

    /// What a click doesn't do. A page that came from a run's printed address may have no process here: a host's.
    private func menu(_ l: Look) -> NSMenu {
        let m = NSMenu(), app = app
        if l.page.isWeb, let u = URL(string: l.page.url) { m.add(String(localized: "Open in Browser")) { NSWorkspace.shared.open(u) } }
        m.add(String(localized: "Copy Address")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(l.page.address, forType: .string)
        }
        if let pid = l.page.pid {
            m.add(String(localized: "Stop")) {
                Task { if await app.call(PortsStop(worktreeId: l.workspace, pid: Int(pid))) != nil { app.watchAgain(.ports, l.workspace) } }
            }
        }
        return m
    }
}
