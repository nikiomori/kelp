import AppKit
import Core
import DesignKit

/// One workspace on the strip: the state that wants you most among its agents, and the agent that is about.
struct StripItem: Equatable {
    var workspace: String, name: String
    var repo: String?
    var cell: DockFace.Cell
    var session: String
    /// How many of its agents are in that state.
    var count: Int
    /// What the agent says, when it asks or failed.
    var words: String?
    var since: Date
}

/// What the strip shows, without a window.
@MainActor
enum StripModel {
    static func items(_ sessions: [Session], workspaces: [(id: String, name: String, repo: String?)]) -> [StripItem] {
        workspaces.compactMap { w in
            let own = sessions.filter { $0.worktreeId == w.id }.compactMap { s in DockIcon.cell(s).map { (s, $0) } }
            guard let worst = own.map(\.1).min() else { return nil }
            let same = own.filter { $0.1 == worst }.map(\.0).sorted { ($0.statusAt ?? $0.createdAt) < ($1.statusAt ?? $1.createdAt) }
            guard let lead = same.first else { return nil }
            let says = lead.summary.isEmpty ? nil : lead.summary
            let words = worst == .asks ? says ?? String(localized: "Needs your input") : worst == .failed ? says ?? String(localized: "Failed") : nil
            return StripItem(workspace: w.id, name: w.name, repo: w.repo, cell: worst, session: lead.id, count: same.count, words: words,
                             since: lead.statusAt ?? lead.createdAt)
        }
    }

    /// The one that opens into a pill: the oldest question, or else what failed. The others stay tiles where they are.
    static func opened(_ items: [StripItem]) -> String? {
        let calling = items.filter { $0.cell <= .failed }.sorted { ($0.cell, $0.since) < ($1.cell, $1.since) }
        return calling.first?.workspace
    }

    /// `front`: Kelp is the active app, and its window already says all this.
    static func shows(_ items: [StripItem], mode: String?, front: Bool) -> Bool {
        guard !front, mode != "off" else { return false }
        return mode == "always" ? !items.isEmpty : items.contains { $0.cell != .working }
    }
}

/// A strip of workspaces over the Dock, for when Kelp is behind another app: the one whose agent asks opens into a pill, and a
/// click answers from a card with Kelp left where it is. It sits at the foot of the visible screen and under the Dock's level:
/// a Dock that stays reserves its room, and a hidden one slides over the strip and away.
@MainActor
final class AgentStrip {
    private struct State: Equatable { var items: [StripItem], mode: String? }

    private let app: AppModel
    private var state = State(items: [], mode: nil)
    private var panel: StripPanel?
    private let row = NSStackView()
    private var buttons: [String: StripButton] = [:]
    private var card: StripCard?
    private var observers: [NSObjectProtocol] = []

    init(app: AppModel) { self.app = app }

    func start() {
        track(owner: self) { [app] in State(items: Self.items(app), mode: app.settings.string("agents.dockStrip")) } changed: { [weak self] in
            self?.state = $0
            self?.refresh()
        }
        let names = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification, NSApplication.didChangeScreenParametersNotification]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }   // queue: .main
            }
        }
    }

    private static func items(_ app: AppModel) -> [StripItem] {
        let shown = app.worktrees.filter { !$0.archived }.map { w in
            (id: w.id, name: app.groupName(w) ?? app.projectName(w.repoId) ?? w.displayName, repo: app.repo(w.repoId)?.path)
        }
        return StripModel.items(app.sessions, workspaces: shown)
    }

    var isShowing: Bool { panel?.isVisible == true }
    var frame: NSRect? { panel?.frame }

    private func refresh() {
        guard wanted else { hide(); return }
        let wasUp = isShowing
        let opened = StripModel.opened(state.items)
        let shownNow = state.items.map { item in
            let b = buttons[item.workspace] ?? StripButton()
            buttons[item.workspace] = b
            b.update(item, open: item.workspace == opened, app: app)
            b.onClick = { [weak self] in self?.clicked(item) }
            b.onMenu = { [weak self] in self?.menu() ?? NSMenu() }
            return b
        }
        row.setViews(shownNow, in: .leading)
        buttons = buttons.filter { key, _ in state.items.contains { $0.workspace == key } }
        if let card, !state.items.contains(where: { $0.session == card.session && $0.cell != .working }) { closeCard() }
        place(appearing: !wasUp)
    }

    private func clicked(_ item: StripItem) {
        guard item.cell != .working else {
            NSApp.activate()
            app.workbench.show(workspace: item.workspace)
            return
        }
        if card?.session == item.session { closeCard(); return }
        closeCard()
        guard let s = app.session(item.session), let panel else { return }
        let c = StripCard(s, app: app) { [weak self] in self?.closeCard() }
        c.show(above: panel.frame)
        card = c
    }

    private func closeCard() {
        card?.close()
        card = nil
    }

    private func menu() -> NSMenu {
        let m = NSMenu()
        m.addChoices("agents.dockStrip", app, heading: String(localized: "Show Agents Above the Dock"), tryOn: false)
        m.addItem(.separator())
        m.add(String(localized: "Open Kelp")) { NSApp.activate() }
        return m
    }

    private func hide() {
        closeCard()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { c in
            c.duration = Motion.duration(Motion.fast)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {   // AppKit runs it on the main thread
                if self?.wanted != true { panel.orderOut(nil) }   // it may have been wanted again meanwhile
            }
        }
    }

    private var wanted: Bool { StripModel.shows(state.items, mode: state.mode, front: NSApp.isActive) }

    /// On the screen the pointer is on when it comes up: the one being looked at, as the Dock's own can't be told.
    private func place(appearing: Bool) {
        let p = panel ?? makePanel()
        let mouse = NSEvent.mouseLocation
        let screen = (appearing ? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } : p.screen) ?? NSScreen.main
        guard let area = screen?.visibleFrame, let content = p.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = NSSize(width: content.fittingSize.width, height: StripButton.stripHeight)
        let frame = NSRect(x: area.midX - size.width / 2, y: area.minY + Metrics.gap + 2, width: size.width, height: size.height)
        guard appearing else {
            NSAnimationContext.runAnimationGroup { c in
                c.duration = Motion.duration(Motion.appear)
                p.animator().setFrame(frame, display: true)
                p.animator().alphaValue = 1
            }
            return
        }
        p.setFrame(frame.offsetBy(dx: 0, dy: Motion.reduced ? 0 : -8), display: false)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { c in
            c.duration = Motion.duration(Motion.appear)
            p.animator().setFrame(frame, display: true)
            p.animator().alphaValue = 1
        }
    }

    private func makePanel() -> StripPanel {
        row.spacing = 2
        row.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        let p = StripPanel.floating(row, radius: StripButton.stripHeight / 2)
        panel = p
        return p
    }
}
