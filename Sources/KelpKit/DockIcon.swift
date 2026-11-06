import AppKit
import Core

/// Kelp's Dock icon as a small status display, chosen in its Dock menu like Activity Monitor's: the agents, how full the
/// plan is, or the plain icon. Drawn when what it shows changes, with no clock running.
@MainActor
final class DockIcon {
    private let app: AppModel
    private let view = DockFaceView()
    init(app: AppModel) { self.app = app }

    func start() {
        track(owner: self) { [app] in Self.face(app) } changed: { [weak self] in self?.show($0) }
    }

    private func show(_ face: DockFace) {
        view.face = face
        NSApp.dockTile.contentView = face == .icon ? nil : view
        NSApp.dockTile.display()
    }

    /// Right-click on the icon: the agents waiting for you, like Mail's dock menu offers what's new. A permission is
    /// answered from here without Kelp coming forward, as from its banner.
    func menu() -> NSMenu {
        let m = NSMenu()
        for s in AttentionQueue(app).sessions { add(s, to: m) }
        let busy = Self.onSidebar(app).filter { $0.isChat && SidebarCell.shownStatus($0) == .working }.count
        if busy > 0 { m.addItem(withTitle: String(localized: "\(busy) working"), action: nil, keyEquivalent: "") }
        if !m.items.isEmpty { m.addItem(.separator()) }
        m.add(String(localized: "New Chat")) { [app] in NSApp.activate(); app.workbench.newChat() }
        if let strip = app.agentStrip, !strip.isOff {
            if strip.hiddenUntil != nil {
                m.add(String(localized: "Show Agents Above the Dock")) { strip.hide(until: nil) }
            } else {
                m.add(String(localized: "Hide Agents Above the Dock for 1 Hour")) { strip.hide(until: Date().addingTimeInterval(3600)) }
            }
        }
        m.addChoiceMenu("agents.dockIcon", app, title: String(localized: "Dock Icon"), tryOn: false)
        return m
    }

    private func add(_ s: Session, to m: NSMenu) {
        let w = app.worktree(s.worktreeId), place = app.groupName(w) ?? app.projectName(w?.repoId) ?? ""
        let name = app.catalog.displayName(s), icon = app.catalog.icon(s.agent, size: 16)
        let show: @MainActor @Sendable () -> Void = { [app] in NSApp.activate(); app.workbench.focus(session: s.id) }
        guard Notifier.asksPermission(s) else {
            let state = s.status == .waiting ? String(localized: "needs you")
                : s.status == .error ? String(localized: "failed") : String(localized: "finished")
            m.add("\(name) — \(state) · \(place)", show).show(icon)
            return
        }
        let answers = NSMenu()
        for (word, action) in [(String(localized: "Allow"), "allow"), (String(localized: "Deny"), "deny")] {
            answers.add(word) { [app] in app.notifier?.answer(s.id, action, question: s.summary) }
        }
        answers.addItem(.separator())
        answers.add(String(localized: "Open in Kelp"), show)
        let item = m.addItem(withTitle: "\(name) — \(s.summary) · \(place)", action: nil, keyEquivalent: "")
        item.show(icon)
        m.setSubmenu(answers, for: item)
    }

    /// With nothing to show the plain icon stands in: no agents, or an agent without a plan's numbers.
    static func face(_ app: AppModel) -> DockFace {
        switch app.settings.string("agents.dockIcon") {
        case "usage":
            guard let u = app.limits, let fullest = LimitAlerts.readings(u).map(\.limit.percent).max() else { return .icon }
            return usage(fullest, warnAt: app.settings.usageAlertAt)
        case "agents":
            let cells = cells(onSidebar(app))
            return cells.isEmpty ? .icon : .agents(cells)
        default: return .icon
        }
    }

    /// In a workspace on the sidebar: an archived one isn't loaded.
    private static func onSidebar(_ app: AppModel) -> [Session] {
        app.sessions.filter { app.worktree($0.worktreeId).map { !$0.archived } == true }
    }

    static func usage(_ percent: Double, warnAt: Int?) -> DockFace {
        .usage(percent: Int(percent.rounded()), high: warnAt.map { percent >= Double($0) } ?? false)
    }

    /// The agents in the order to deal with them.
    static func cells(_ sessions: [Session]) -> [DockFace.Cell] { sessions.compactMap(cell).sorted() }

    static func cell(_ s: Session) -> DockFace.Cell? {
        guard s.isChat else { return nil }
        switch SidebarCell.shownStatus(s) {
        case .waiting: return .asks
        case .error: return .failed
        case .working: return .working
        case .done: return s.unread && s.parent == nil ? .done : nil   // a child's result goes to its parent, not you
        default: return nil
        }
    }
}
