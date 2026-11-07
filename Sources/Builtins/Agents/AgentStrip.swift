import AppKit
import Core
import DesignKit
import KelpKit

/// One workspace on the strip: the state that wants you most among its agents, and the agent that is about.
struct StripItem: Equatable {
    var workspace: String, name: String
    var repo: String?
    var cell: DockFace.Cell
    var session: String
    /// Each of its agents, "state · title", the one above first with its words: what the tile's one mark leaves out. The state
    /// leads, so a long title is what gets cut.
    var agents: [String] = []
    /// What it says: what the agent asks, what failed or what it did; while they work, just that and how many (their chats'
    /// titles are in the tip), so a pill that says what to do and one that says nothing to do don't read alike.
    var words: String?
    var since: Date
}

/// Where the strip stands: a corner of a screen, or the middle of its foot or head. It snaps to the nearest after a drag, as a
/// picture-in-picture window does, and widens away from its corner when a pill opens. Kept per Mac: it's about this Mac's screens.
enum StripCorner: String, CaseIterable {
    case bottom, bottomLeft, bottomRight, top, topLeft, topRight
    var isTop: Bool { [.top, .topLeft, .topRight].contains(self) }
    var isLeft: Bool { self == .bottomLeft || self == .topLeft }
    var isRight: Bool { self == .bottomRight || self == .topRight }
}

struct StripPlace: Equatable {
    var corner: StripCorner
    var display: UInt32?
    /// Hidden behind this side, `y` up from the foot of the screen's visible part.
    var edge: StripEdge?
    var y: CGFloat = 0

    private static let key = "agents.dockStrip.place"
    static func load() -> StripPlace? {
        guard let saved = UserDefaults.standard.dictionary(forKey: key),
            let corner = (saved["corner"] as? String).flatMap(StripCorner.init)
        else { return nil }
        return StripPlace(
            corner: corner, display: (saved["display"] as? NSNumber)?.uint32Value,
            edge: (saved["edge"] as? String).flatMap(StripEdge.init),
            y: (saved["y"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0)
    }
    static func save(_ place: StripPlace?) {
        guard let place else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        var saved: [String: Any] = ["corner": place.corner.rawValue, "y": Double(place.y)]
        saved["display"] = place.display
        saved["edge"] = place.edge?.rawValue
        UserDefaults.standard.set(saved, forKey: key)
    }
}

/// What the strip shows, without a window.
@MainActor
enum StripModel {
    /// How long finished work stays after it's been seen in Kelp: time to get to it from the strip.
    static let recent: TimeInterval = 600

    /// What an agent says on the strip: as on the Dock's icon, but finished work stays a while once read.
    static func cell(_ s: Session, now: Date) -> DockFace.Cell? {
        if let dockCell = DockIcon.cell(s) { return dockCell }
        let finished = s.isChat && s.parent == nil && s.shownStatus == .done
        return finished && now.timeIntervalSince(s.statusAt ?? .distantPast) < recent ? .done : nil
    }

    /// In a workspace, work going on comes before work finished: a project is done once nothing in it works, as an agent waits
    /// for the ones it started. Across workspaces finished work opens first (`opened`): it's news, work isn't.
    private nonisolated static let inWorkspace: [DockFace.Cell] = [.asks, .failed, .working, .done]

    static func status(_ c: DockFace.Cell) -> AgentStatus {
        switch c {
        case .asks: .waiting
        case .failed: .error
        case .working: .working
        case .done: .done
        }
    }

    static func items(
        _ sessions: [Session], workspaces: [(id: String, name: String, repo: String?)], now: Date = Date()
    ) -> [StripItem] {
        workspaces.compactMap { workspace in
            func rank(_ a: (Session, DockFace.Cell)) -> (Int, Date) {
                (inWorkspace.firstIndex(of: a.1) ?? 0, a.0.statusAt ?? a.0.createdAt)
            }
            let own = sessions.filter { $0.worktreeId == workspace.id }.compactMap { session in
                cell(session, now: now).map { (session, $0) }
            }
            .sorted { rank($0) < rank($1) }
            guard let (lead, worst) = own.first else { return nil }
            let says = lead.summary.isEmpty ? nil : lead.summary, busy = own.count { $0.1 == .working }
            let words =
                switch worst {
                case .asks: says ?? String(localized: "Needs your input")
                case .failed: says ?? String(localized: "Failed")
                case .done: says.map { String(localized: "Done: \($0)") } ?? String(localized: "Done")
                case .working where busy > 1: String(localized: "Working: \(busy)")
                case .working: String(localized: "Working")
                }
            let said = worst == .working ? status(worst).words : brief(words)
            let agents =
                ["\(said) · \(lead.displayTitle)"]
                + own.dropFirst().map { "\(status($0.1).words) · \($0.0.displayTitle)" }
            return StripItem(
                workspace: workspace.id, name: workspace.name, repo: workspace.repo, cell: worst, session: lead.id,
                agents: agents,
                words: words,
                since: lead.statusAt ?? lead.createdAt)
        }
    }

    /// The one that opens into a pill, so the strip always says something in words: the oldest question, else what failed,
    /// what finished, what works. The others stay tiles where they are, and say theirs under the pointer.
    static func opened(_ items: [StripItem]) -> String? {
        items.min { ($0.cell, $0.since) < ($1.cell, $1.since) }?.workspace
    }

    /// `front`: Kelp is the active app, and its window already says all this. `comesFor`: what brings it up (When Needed):
    /// a finished agent can wait for a look, and it would otherwise keep the strip up all day in another app.
    static func shows(_ items: [StripItem], mode: String?, comesFor: String?, front: Bool) -> Bool {
        guard !front, mode != "off" else { return false }
        guard mode == "needed" else { return !items.isEmpty }   // Always, the default: it's where you see them working
        let loudest: DockFace.Cell =
            switch comesFor {
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

    /// From the screen's edges.
    static let margin: CGFloat = 8

    /// At its corner, whole on the screen.
    static func frame(_ size: NSSize, in area: NSRect, at corner: StripCorner) -> NSRect {
        let x =
            corner.isLeft
            ? area.minX + margin : corner.isRight ? area.maxX - size.width - margin : area.midX - size.width / 2
        let y = corner.isTop ? area.maxY - size.height - margin : area.minY + margin
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// The corner a strip let go here goes to.
    static func corner(nearest frame: NSRect, in area: NSRect) -> StripCorner {
        func gap(_ c: StripCorner) -> CGFloat {
            let at = Self.frame(frame.size, in: area, at: c)
            return hypot(at.midX - frame.midX, at.midY - frame.midY)
        }
        return StripCorner.allCases.min { gap($0) < gap($1) } ?? .bottom
    }

    /// A question put off: it comes back as a new one when the agent's state changes.
    static func key(_ s: Session) -> String { "\(s.id)|\(s.statusAt?.timeIntervalSince1970 ?? 0)" }
}

/// A strip of workspaces over the Dock, for when Kelp is behind another app: their agents at a glance, the one that asks opened
/// into a pill, and a click answers from a card with Kelp left where it is. It starts at the foot of the visible screen and under the Dock's level:
/// a Dock that stays reserves its room, and a hidden one slides over the strip and away. Dragged, it goes to the nearest corner.
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
    private var place = StripPlace.load()
    private var corner: StripCorner { place?.corner ?? .bottom }
    private var tip: StripTip?
    /// When finished work read in Kelp leaves the strip.
    private var expiry: Timer?
    private var tipTimer: Timer?
    /// Hidden behind an edge, it's all out while the pointer is on it.
    private var peeking = false
    private var peekTimer: Timer?
    private let line = StripLine()
    /// The questions and failures a line has told of, so each comes out of the edge once.
    private var told: Set<String> = []
    private let glint = StripGlint()
    private var glintSide: [NSLayoutConstraint] = []
    private var panel: StripPanel?
    private let row = StripRow()
    private var buttons: [String: StripButton] = [:]
    private var card: StripCard?
    private var observers: [NSObjectProtocol] = []

    init(app: AppModel) { self.app = app }

    /// The app's one.
    static func of(_ app: AppModel) -> AgentStrip { app.part { AgentStrip(app: app) } }

    /// The Dock icon's menu: hide it for a while, or bring it back.
    func dockItems(_ menu: NSMenu) {
        guard !isOff else { return }
        if hiddenUntil != nil {
            menu.add(String(localized: "Show Agents Above the Dock")) { self.hide(until: nil) }
        } else {
            menu.add(String(localized: "Hide Agents Above the Dock for 1 Hour")) {
                self.hide(until: Date().addingTimeInterval(3600))
            }
        }
    }

    func start() {
        track(owner: self) { [app] in
            Self.state(app, putOff: [])
        } changed: { [weak self] _ in
            self?.refresh()
        }
        let names = [NSApplication.didBecomeActiveNotification, NSApplication.didChangeScreenParametersNotification]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }   // queue: .main
            }
        }
        let behind = NSApplication.didResignActiveNotification
        observers.append(
            NotificationCenter.default.addObserver(forName: behind, object: nil, queue: .main) { [weak self] _ in
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
        let shown = app.worktrees.filter { !$0.archived }.map { worktree in
            (
                id: worktree.id,
                name: app.groupName(worktree) ?? app.projectName(worktree.repoId) ?? worktree.displayName,
                repo: app.repo(worktree.repoId)?.path
            )
        }
        let loud = app.sessions.filter { !Mutes.isMuted($0, in: app) && !putOff.contains(StripModel.key($0)) }
        return State(
            items: StripModel.items(loud, workspaces: shown), mode: app.settings[SettingKeys.dockStrip],
            comesFor: app.settings[SettingKeys.dockStripComesFor],
            fullScreen: app.settings[SettingKeys.dockStripFullScreen])
    }

    var isShowing: Bool { panel?.isVisible == true }
    var frame: NSRect? { panel?.frame }
    var panelForTests: NSPanel? { panel }
    var isOff: Bool { app.settings[SettingKeys.dockStrip] == "off" }

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
        if let found = app.session(session) { putOff.insert(StripModel.key(found)) }
        closeCard()
        refresh()
    }

    private func refresh() {
        let live = Set(app.sessions.map(StripModel.key))
        putOff.formIntersection(live)
        state = Self.state(app, putOff: putOff)
        guard wanted else {
            goAway()
            return
        }
        panel?.apply(fullScreen: state.fullScreen)
        line.apply(fullScreen: state.fullScreen)
        let wasUp = isShowing
        let hidden = place?.edge != nil && !peeking
        let opened = hidden ? nil : StripModel.opened(state.items)
        let shownNow = state.items.map { item in
            let button = buttons[item.workspace] ?? StripButton()
            buttons[item.workspace] = button
            button.update(item, open: item.workspace == opened, app: app)
            button.onClick = { [weak self] in self?.clicked(item) }
            button.onMenu = { [weak self] in self?.menu() ?? NSMenu() }
            button.onHover = { [weak self, weak button] on in
                if let button { self?.hover(item, on: on, over: button, open: item.workspace == opened) }
            }
            return button
        }
        row.setViews(shownNow, in: .leading)
        buttons = buttons.filter { key, _ in state.items.contains { $0.workspace == key } }
        if let card, !state.items.contains(where: { $0.session == card.session && $0.cell != .working }) {
            closeCard()
        }
        // Another question while one was up: the card shows what Allow answers, so the new one comes in a card of its own.
        else if let card, card.question != app.session(card.session)?.summary {
            closeCard()
            goesOn = true
        }
        showEdge(hidden: hidden)
        put(appearing: !wasUp)
        follow(opened)
        expireDone()
        tell(hidden: hidden)
    }

    /// The handle and its sign, on the side away from the edge it hides behind.
    private func showEdge(hidden: Bool) {
        let edge = place?.edge
        if glint.superview == nil {
            row.addSubview(glint)
            glint.centerYAnchor.constraint(equalTo: row.centerYAnchor).isActive = true
        }
        glint.isHidden = edge == nil
        glint.cell = state.items.map(\.cell).min()
        let side: CGFloat = 4, room = StripModel.handle + side
        row.edgeInsets = NSEdgeInsets(
            top: side, left: edge == .right ? room : side, bottom: side, right: edge == .left ? room : side)
        NSLayoutConstraint.deactivate(glintSide)
        guard let edge else { return }
        let inset = (StripModel.sliver - StripGlint.size.width) / 2
        glintSide = [
            edge == .right
                ? glint.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: inset)
                : glint.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -inset)
        ]
        NSLayoutConstraint.activate(glintSide)
    }

    /// A question or a failure that came while it hides comes out of the edge as a line; each once.
    private func tell(hidden: Bool) {
        defer { told = Set(state.items.filter { $0.cell <= .failed }.map(StripModel.newsKey)) }
        guard hidden, let edge = place?.edge, let panel, isShowing, let news = StripModel.news(state.items, told: told)
        else { return }
        line.onClick = { [weak self] in self?.peekFromLine() }
        let stays = news.cell == .asks ? StripModel.questionStays : StripModel.failureStays
        line.show(news, app: app, by: panel.frame, edge: edge, stays: stays)
    }

    /// The pointer on a hidden strip brings it all out at once; off it, it goes back after a moment.
    private func hoverStrip(_ on: Bool) {
        row.pointerOn = on
        peekTimer?.invalidate()
        guard place?.edge != nil, on != peeking, on || card == nil else { return }
        peekTimer = Timer.scheduledTimer(withTimeInterval: on ? Motion.hoverOpenWarm : Motion.hoverOpen, repeats: false)
        { [weak self] _ in
            MainActor.assumeIsolated { self?.settle(on) }   // the main run loop's timer
        }
    }

    /// Off the strip into the gap it left at the edge isn't off: it waits again instead of going under the pointer.
    private func settle(_ on: Bool) {
        if !on, let edge = place?.edge, let panel,
            StripModel.inGap(NSEvent.mouseLocation, beside: panel.frame, edge: edge)
        {
            return hoverStrip(false)
        }
        peek(on)
    }

    /// Out from a click on the line: the pointer isn't on it yet, so it goes back unless the pointer comes.
    private func peekFromLine() {
        peek(true)
        peekTimer = Timer.scheduledTimer(withTimeInterval: Motion.linger, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { if self?.row.pointerOn == false, self?.card == nil { self?.peek(false) } }   // the main run loop's timer
        }
    }

    private func peek(_ on: Bool) {
        peekTimer?.invalidate()
        guard place?.edge != nil, on != peeking else { return }
        peeking = on
        if on { line.hide() } else { tip?.hide() }
        refresh()
    }

    /// Wakes when the next finished-and-read agent's while is up; nothing else changes then, so nothing else would refresh.
    private func expireDone() {
        expiry?.invalidate()
        let ends = app.sessions.filter { DockIcon.cell($0) == nil && StripModel.cell($0, now: Date()) == .done }
            .compactMap { $0.statusAt?.addingTimeInterval(StripModel.recent) }
        guard let next = ends.min() else { return }
        expiry = Timer.scheduledTimer(withTimeInterval: max(1, next.timeIntervalSinceNow), repeats: false) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }   // the main run loop's timer
        }
    }

    /// After an answer, the next question is up at once: several in a row take a click each, not two.
    private func follow(_ opened: String?) {
        guard goesOn, card == nil else { return }
        goesOn = false
        if let item = state.items.first(where: { $0.workspace == opened }), item.cell == .asks { open(item) }
    }

    /// What a tile says under the pointer, in words of its own over the strip: the strip doesn't change size, so the tile
    /// stays under the pointer. A moment's rest brings it, as a hover card; moving to the next tile, at once.
    private func hover(_ item: StripItem, on: Bool, over button: NSView, open: Bool) {
        tipTimer?.invalidate()
        // The open pill says its own; it has a tip for what its words leave out: the other agents, or what one at work does.
        guard on, !open || item.agents.count > 1 || item.cell == .working else {
            tipTimer = Timer.scheduledTimer(withTimeInterval: Motion.hoverClose, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.tip?.hide() }   // the main run loop's timer
            }
            return
        }
        let wait = tip?.isShowing == true ? Motion.hoverOpenWarm : Motion.hoverOpen
        tipTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self, weak button] _ in
            MainActor.assumeIsolated {   // the main run loop's timer
                guard let self, let button, let window = button.window else { return }
                let tip = self.tip ?? StripTip()
                self.tip = tip
                tip.show(
                    item, over: window.convertToScreen(button.convert(button.bounds, to: nil)), below: self.corner.isTop
                )
            }
        }
    }

    /// A question or a failure opens its card; finished work goes to its result in Kelp, and work going on to its workspace.
    private func clicked(_ item: StripItem) {
        tip?.hide()
        switch item.cell {
        case .working:
            NSApp.activate()
            app.workbench.show(workspace: item.workspace)
            return
        case .done:
            closeCard()
            NSApp.activate()
            app.workbench.focus(session: item.session)
            return
        case .asks, .failed: break
        }
        if card?.session == item.session {
            closeCard()
            return
        }
        open(item)
    }

    private func open(_ item: StripItem) {
        closeCard()
        guard let session = app.session(item.session), let panel else { return }
        let newCard = StripCard(session, app: app, fullScreen: state.fullScreen) { [weak self] end in
            switch end {
            case .later: self?.later(item.session)
            case .answered:
                self?.goesOn = true
                self?.closeCard()
            case .left: self?.closeCard()
            }
        }
        newCard.show(by: panel.frame, in: panel.screen?.visibleFrame, at: corner)
        card = newCard
    }

    private func closeCard() {
        card?.close()
        card = nil
        if peeking, !row.pointerOn { hoverStrip(false) }
    }

    private func menu() -> NSMenu {
        let menu = NSMenu(), hide = NSMenu()
        for c in Mutes.choices() where c.until != Mutes.forever {
            hide.add(c.title) { [weak self] in self?.hide(until: c.until) }
        }
        menu.setSubmenu(hide, for: menu.addItem(withTitle: String(localized: "Hide"), action: nil, keyEquivalent: ""))
        menu.addChoiceMenu(SettingKeys.dockStripComesFor, app, title: String(localized: "Comes Up For"), tryOn: false)
        menu.addToggle(SettingKeys.dockStripFullScreen, app, title: String(localized: "Over Full-Screen Apps"))
        menu.addItem(.separator())
        if place?.edge == nil { menu.add(String(localized: "Hide Behind the Edge")) { [weak self] in self?.tuck() } }
        if place != nil {
            menu.add(String(localized: "Move Back Above the Dock")) { [weak self] in self?.moved(to: nil) }
        }
        menu.add(String(localized: "Turn Off")) { [app] in app.settings.set(SettingKeys.dockStrip, "off") }
        menu.addSettingsLink(String(localized: "Strip Settings…"), section: "notifications", group: "Dock", app)
        return menu
    }

    private func goAway() {
        closeCard()
        tip?.hide()
        line.hide()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.duration(Motion.fast)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {   // AppKit runs it on the main thread
                if self?.wanted != true { panel.orderOut(nil) }   // it may have been wanted again meanwhile
            }
        }
    }

    private var wanted: Bool {
        hiddenUntil == nil
            && StripModel.shows(state.items, mode: state.mode, comesFor: state.comesFor, front: NSApp.isActive)
    }

    /// Let go after a drag: it goes to the nearest corner of the screen it's on; a card it left behind goes.
    func dropped() {
        guard let panel, let screen = Self.screen(under: panel.frame) else { return }
        let area = screen.visibleFrame
        if let edge = StripModel.edge(dropped: panel.frame, in: area), Self.outer(edge, of: screen) {
            moved(to: Self.place(behind: edge, of: screen, at: panel.frame))
            return
        }
        let corner = StripModel.corner(nearest: panel.frame, in: area)
        moved(
            to: corner == .bottom && screen == NSScreen.main
                ? nil : StripPlace(corner: corner, display: Self.number(of: screen)))
    }

    /// From the menu: behind the side of its screen it's nearer, where it stands.
    private func tuck() {
        guard let panel, let screen = Self.screen(under: panel.frame) else { return }
        let area = screen.visibleFrame
        let nearer: StripEdge = panel.frame.midX > area.midX ? .right : .left
        guard let edge = [nearer, nearer == .right ? .left : .right].first(where: { Self.outer($0, of: screen) }) else {
            return
        }
        moved(to: Self.place(behind: edge, of: screen, at: panel.frame))
    }

    /// At the height it stands; the corner is the one it would take by that side.
    private static func place(behind edge: StripEdge, of screen: NSScreen, at frame: NSRect) -> StripPlace {
        StripPlace(
            corner: edge == .right ? .bottomRight : .bottomLeft, display: number(of: screen), edge: edge,
            y: frame.minY - screen.visibleFrame.minY)
    }

    /// The screen most of it is on: one pushed past an edge has no `screen` of its own.
    private static func screen(under frame: NSRect) -> NSScreen? {
        NSScreen.screens.max { $0.frame.intersection(frame).width < $1.frame.intersection(frame).width }
            ?? NSScreen.main
    }

    private static func outer(_ edge: StripEdge, of screen: NSScreen) -> Bool {
        StripModel.outer(edge, of: screen.frame, among: NSScreen.screens.filter { $0 != screen }.map(\.frame))
    }

    private func moved(to place: StripPlace?) {
        self.place = place
        StripPlace.save(place)
        peeking = false
        closeCard()
        tip?.hide()
        line.hide()
        refresh()
    }

    private static func number(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Where it was put, or else the screen the pointer is on when it comes up: the one being looked at, as the Dock's can't be told.
    private func screen(appearing: Bool, of p: NSPanel) -> NSScreen? {
        if let display = place?.display, let put = NSScreen.screens.first(where: { Self.number(of: $0) == display }) {
            return put
        }
        let mouse = NSEvent.mouseLocation
        return (appearing ? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } : p.screen)
            ?? NSScreen.main
    }

    private func put(appearing: Bool) {
        let window = panel ?? makePanel()
        guard let area = screen(appearing: appearing, of: window)?.visibleFrame, let content = window.contentView else {
            return
        }
        content.layoutSubtreeIfNeeded()
        let size = NSSize(width: content.fittingSize.width, height: StripButton.stripHeight)
        let behind = place?.edge.map { StripModel.tucked(size, in: area, edge: $0, y: place?.y ?? 0, out: peeking) }
        let frame = behind ?? StripModel.frame(size, in: area, at: corner)
        guard appearing else {
            // nothing moved: no animation to run
            guard window.frame != frame || window.alphaValue != 1 else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.duration(Motion.appear)
                window.animator().setFrame(frame, display: true)
                window.animator().alphaValue = 1
            }
            return
        }
        window.setFrame(frame.offsetBy(dx: 0, dy: Motion.reduced ? 0 : corner.isTop ? 8 : -8), display: false)
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.duration(Motion.appear)
            window.animator().setFrame(frame, display: true)
            window.animator().alphaValue = 1
        }
    }

    private func makePanel() -> StripPanel {
        row.spacing = 2
        showEdge(hidden: place?.edge != nil)
        row.onHover = { [weak self] on in self?.hoverStrip(on) }
        row.onClick = { [weak self] in self?.peek(true) }
        let made = StripPanel.floating(row, radius: StripButton.stripHeight / 2, fullScreen: state.fullScreen)
        made.onDropped = { [weak self] in self?.dropped() }
        panel = made
        return made
    }
}
