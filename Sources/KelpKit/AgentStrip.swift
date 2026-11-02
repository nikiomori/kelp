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

/// Where the strip was put, as parts of a screen's visible area, so it survives another resolution; the middle of its foot, as it
/// widens both ways when a pill opens. Kept per Mac: it's about this Mac's screens.
struct StripSpot: Equatable {
    var x: Double, y: Double
    var display: UInt32?

    private static let key = "agents.dockStrip.spot"
    static func load() -> StripSpot? {
        guard let d = UserDefaults.standard.dictionary(forKey: key), let x = d["x"] as? Double, let y = d["y"] as? Double else { return nil }
        return StripSpot(x: x, y: y, display: (d["display"] as? NSNumber)?.uint32Value)
    }
    static func save(_ spot: StripSpot?) {
        guard let spot else { UserDefaults.standard.removeObject(forKey: key); return }
        var d: [String: Any] = ["x": spot.x, "y": spot.y]
        d["display"] = spot.display
        UserDefaults.standard.set(d, forKey: key)
    }
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

    /// `front`: Kelp is the active app, and its window already says all this. `comesFor`: what brings it up (When Needed):
    /// a finished agent can wait for a look, and it would otherwise keep the strip up all day in another app.
    static func shows(_ items: [StripItem], mode: String?, comesFor: String?, front: Bool) -> Bool {
        guard !front, mode != "off" else { return false }
        guard mode == "needed" else { return !items.isEmpty }   // Always, the default: it's where you see them working
        let loudest: DockFace.Cell = switch comesFor {
        case "questions": .asks
        case "all": .done
        default: .failed
        }
        return items.contains { $0.cell != .working && $0.cell <= loudest }
    }

    /// The pill's words: what a command is, without the variables set before it. Only here, for a glance: the card beside Allow
    /// says the whole command, as `LD_PRELOAD=… npm test` isn't `npm test`.
    static func brief(_ words: String) -> String {
        guard words.hasPrefix("Allow ") else { return words }
        let parts = words.dropFirst(6).split(separator: " ", omittingEmptySubsequences: true)
        let rest = parts.drop { $0.range(of: #"^[A-Za-z_][A-Za-z0-9_]*=\S*$"#, options: .regularExpression) != nil }
        return rest.isEmpty ? words : "Allow " + rest.joined(separator: " ")
    }

    /// From the screen's edge when it stands above the Dock, and from any edge wherever it was put.
    private static let margin: CGFloat = 8
    /// Let go this close to its place above the Dock, it goes back there.
    private static let snap: CGFloat = 40

    /// Above the Dock, or where it was put, always whole on the screen.
    static func frame(_ size: NSSize, in area: NSRect, spot: StripSpot?) -> NSRect {
        guard let spot else { return NSRect(x: area.midX - size.width / 2, y: area.minY + margin, width: size.width, height: size.height) }
        let x = area.minX + spot.x * area.width - size.width / 2, y = area.minY + spot.y * area.height
        return NSRect(x: min(max(x, area.minX + margin), area.maxX - size.width - margin),
                      y: min(max(y, area.minY + margin), area.maxY - size.height - margin), width: size.width, height: size.height)
    }

    static func spot(of frame: NSRect, in area: NSRect, display: UInt32?) -> StripSpot? {
        if abs(frame.midX - area.midX) < snap, frame.minY - area.minY < margin + snap { return nil }
        return StripSpot(x: (frame.midX - area.minX) / area.width, y: (frame.minY - area.minY) / area.height, display: display)
    }

    /// A question put off: it comes back as a new one when the agent's state changes.
    static func key(_ s: Session) -> String { "\(s.id)|\(s.statusAt?.timeIntervalSince1970 ?? 0)" }
}

/// A strip of workspaces over the Dock, for when Kelp is behind another app: their agents at a glance, the one that asks opened
/// into a pill, and a click answers from a card with Kelp left where it is. It starts at the foot of the visible screen and under the Dock's level:
/// a Dock that stays reserves its room, and a hidden one slides over the strip and away. It can be dragged anywhere.
@MainActor
final class AgentStrip {
    private struct State: Equatable { var items: [StripItem], mode: String?, comesFor: String?, fullScreen: Bool }
    /// After Kelp goes behind: a quick trip to another app and back doesn't flash the strip.
    private static let settle: TimeInterval = 0.6

    private let app: AppModel
    private var state = State(items: [], mode: nil, comesFor: nil, fullScreen: true)
    /// Put off with Later, until the agent's state changes.
    private var putOff: Set<String> = []
    /// Hidden for a while (a call, a talk); it isn't kept: a restart brings it back.
    private(set) var hiddenUntil: Date?
    private var hideEnds: Timer?
    private var settling: Timer?
    /// Just answered: the next question follows in the card.
    private var goesOn = false
    private var spot = StripSpot.load()
    private var panel: StripPanel?
    private let row = StripRow()
    private var buttons: [String: StripButton] = [:]
    private var card: StripCard?
    private var observers: [NSObjectProtocol] = []

    init(app: AppModel) { self.app = app }

    func start() {
        track(owner: self) { [app] in Self.state(app, putOff: []) } changed: { [weak self] _ in self?.refresh() }
        let names = [NSApplication.didBecomeActiveNotification, NSApplication.didChangeScreenParametersNotification]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }   // queue: .main
            }
        }
        let behind = NSApplication.didResignActiveNotification
        observers.append(NotificationCenter.default.addObserver(forName: behind, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settleThenRefresh() }   // queue: .main
        })
    }

    private func settleThenRefresh() {
        settling?.invalidate()
        settling = Timer.scheduledTimer(withTimeInterval: Self.settle, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }   // the main run loop's timer
        }
    }

    /// A row muted is quiet here as on a banner, and so is what was put off.
    private static func state(_ app: AppModel, putOff: Set<String>) -> State {
        let shown = app.worktrees.filter { !$0.archived }.map { w in
            (id: w.id, name: app.groupName(w) ?? app.projectName(w.repoId) ?? w.displayName, repo: app.repo(w.repoId)?.path)
        }
        let loud = app.sessions.filter { !app.isMuted($0) && !putOff.contains(StripModel.key($0)) }
        return State(items: StripModel.items(loud, workspaces: shown), mode: app.settings.string("agents.dockStrip"),
                     comesFor: app.settings.string("agents.dockStrip.comesFor"), fullScreen: app.settings.bool("agents.dockStrip.fullScreen") ?? true)
    }

    var isShowing: Bool { panel?.isVisible == true }
    var frame: NSRect? { panel?.frame }
    var panelForTests: NSPanel? { panel }
    var isOff: Bool { app.settings.string("agents.dockStrip") == "off" }

    /// Out of the way for a while, whatever comes meanwhile; nil brings it back now.
    func hide(until: Date?) {
        hiddenUntil = until
        hideEnds?.invalidate()
        hideEnds = until.map { end in
            Timer.scheduledTimer(withTimeInterval: end.timeIntervalSinceNow, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {   // the main run loop's timer
                    self?.hiddenUntil = nil
                    self?.refresh()
                }
            }
        }
        refresh()
    }

    /// This agent stops calling until its state changes.
    func later(_ session: String) {
        if let s = app.session(session) { putOff.insert(StripModel.key(s)) }
        closeCard()
        refresh()
    }

    private func refresh() {
        let live = Set(app.sessions.map(StripModel.key))
        putOff.formIntersection(live)
        state = Self.state(app, putOff: putOff)
        guard wanted else { goAway(); return }
        panel?.apply(fullScreen: state.fullScreen)
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
        follow(opened)
    }

    /// After an answer, the next question is up at once: several in a row take a click each, not two.
    private func follow(_ opened: String?) {
        guard goesOn, card == nil else { return }
        goesOn = false
        if let item = state.items.first(where: { $0.workspace == opened }), item.cell == .asks { open(item) }
    }

    private func clicked(_ item: StripItem) {
        guard item.cell != .working else {
            NSApp.activate()
            app.workbench.show(workspace: item.workspace)
            return
        }
        if card?.session == item.session { closeCard(); return }
        open(item)
    }

    private func open(_ item: StripItem) {
        closeCard()
        guard let s = app.session(item.session), let panel else { return }
        let c = StripCard(s, app: app, fullScreen: state.fullScreen) { [weak self] end in
            switch end {
            case .later: self?.later(item.session)
            case .answered:
                self?.goesOn = true
                self?.closeCard()
            case .left: self?.closeCard()
            }
        }
        c.show(by: panel.frame, in: panel.screen?.visibleFrame)
        card = c
    }

    private func closeCard() {
        card?.close()
        card = nil
    }

    private func menu() -> NSMenu {
        let m = NSMenu(), hide = NSMenu()
        for c in Mutes.choices() where c.until != Mutes.forever { hide.add(c.title) { [weak self] in self?.hide(until: c.until) } }
        m.setSubmenu(hide, for: m.addItem(withTitle: String(localized: "Hide"), action: nil, keyEquivalent: ""))
        m.addChoiceMenu("agents.dockStrip.comesFor", app, title: String(localized: "Comes Up For"), tryOn: false)
        m.addToggle("agents.dockStrip.fullScreen", app, title: String(localized: "Over Full-Screen Apps"))
        m.addItem(.separator())
        if spot != nil { m.add(String(localized: "Move Back Above the Dock")) { [weak self] in self?.moved(to: nil) } }
        m.add(String(localized: "Turn Off")) { [app] in app.settings.set("agents.dockStrip", .string("off")) }
        m.addSettingsLink(String(localized: "Strip Settings…"), section: "notifications", group: "Dock", app)
        return m
    }

    private func goAway() {
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

    private var wanted: Bool {
        hiddenUntil == nil && StripModel.shows(state.items, mode: state.mode, comesFor: state.comesFor, front: NSApp.isActive)
    }

    /// Let go after a drag: it stays there, or goes back above the Dock if it's nearly there; a card it left behind goes.
    func dropped() {
        guard let panel, let screen = panel.screen else { return }
        moved(to: StripModel.spot(of: panel.frame, in: screen.visibleFrame, display: Self.number(of: screen)))
    }

    private func moved(to place: StripSpot?) {
        spot = place
        StripSpot.save(place)
        closeCard()
        self.place(appearing: false)
    }

    private static func number(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Where it was put, or else the screen the pointer is on when it comes up: the one being looked at, as the Dock's can't be told.
    private func screen(appearing: Bool, of p: NSPanel) -> NSScreen? {
        if let display = spot?.display, let put = NSScreen.screens.first(where: { Self.number(of: $0) == display }) { return put }
        let mouse = NSEvent.mouseLocation
        return (appearing ? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } : p.screen) ?? NSScreen.main
    }

    private func place(appearing: Bool) {
        let p = panel ?? makePanel()
        guard let area = screen(appearing: appearing, of: p)?.visibleFrame, let content = p.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = NSSize(width: content.fittingSize.width, height: StripButton.stripHeight)
        let frame = StripModel.frame(size, in: area, spot: spot)
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
        let p = StripPanel.floating(row, radius: StripButton.stripHeight / 2, fullScreen: state.fullScreen)
        p.onDropped = { [weak self] in self?.dropped() }
        panel = p
        return p
    }
}
