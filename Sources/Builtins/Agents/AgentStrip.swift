import AppKit
import Core
import DesignKit
import KelpKit

/// A strip of workspaces over the Dock, for when Kelp is behind another app: their agents at a glance, the one that asks opened
/// into a pill, and a click answers from a card with Kelp left where it is. It starts at the foot of the visible screen and under the Dock's level:
/// a Dock that stays reserves its room, and a hidden one slides over the strip and away. Dragged, it goes to the nearest corner.
@MainActor
final class AgentStrip {
    struct State: Equatable { var items: [StripItem], mode: String?, comesFor: String?, fullScreen: Bool }
    /// After Kelp goes behind: a quick trip to another app and back doesn't flash the strip.
    private static let settle: TimeInterval = 0.6

    private let app: AppModel
    var state = State(items: [], mode: nil, comesFor: nil, fullScreen: true)
    /// Put off with Later, until the agent's state changes.
    private var putOff: Set<String> = []
    /// Hidden for a while (a call, a talk); it isn't kept: a restart brings it back.
    private(set) var hiddenUntil: Date?
    private var hideEnds: Timer?
    private var settling: Timer?
    /// Just answered: the next question follows in the card.
    private var goesOn = false
    var place = StripPlace.load()
    var corner: StripCorner { place?.corner ?? .bottom }
    var tip: StripTip?
    /// When finished work read in Kelp leaves the strip.
    private var expiry: Timer?
    private var tipTimer: Timer?
    /// Hidden behind an edge, it's all out while the pointer is on it.
    var peeking = false
    private var peekTimer: Timer?
    let line = StripLine()
    /// The questions and failures a line has told of, so each comes out of the edge once.
    private var told: Set<String> = []
    private let glint = StripGlint()
    private var glintSide: [NSLayoutConstraint] = []
    var panel: StripPanel?
    let row = StripRow()
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
    /// Whether Kelp is the app in front, where the strip steps aside. A test's own: another test running beside it
    /// may bring the test process to the front.
    var front: () -> Bool = { NSApp.isActive }
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

    func refresh() {
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
    func showEdge(hidden: Bool) {
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
    func hoverStrip(_ on: Bool) {
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

    func peek(_ on: Bool) {
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

    func closeCard() {
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
            && StripModel.shows(state.items, mode: state.mode, comesFor: state.comesFor, front: front())
    }

}
