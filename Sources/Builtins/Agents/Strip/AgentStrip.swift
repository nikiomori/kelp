import AppKit
import Core
import DesignKit
import KelpKit

/// A strip of workspaces shown over the Dock while Kelp is behind another app. It shows each workspace's agents at a
/// glance and opens the workspace whose agent asks into a pill, and a click answers from a card without bringing Kelp
/// forward. It starts at the bottom of the visible screen, one level below the Dock, so a Dock that always shows keeps
/// its own room and an auto-hiding Dock slides over the strip and away. When dragged, the strip goes to the nearest
/// corner.
@MainActor
final class AgentStrip {
    struct State: Equatable { var items: [StripItem], mode: String?, comesFor: String?, fullScreen: Bool }
    /// How long the strip waits after Kelp goes behind another app, so a quick trip there and back doesn't flash it.
    private static let settle: TimeInterval = 0.6

    let app: AppModel
    var state = State(items: [], mode: nil, comesFor: nil, fullScreen: true)
    /// The sessions the user put off with Later. Each stays off the strip until its agent's state changes.
    private var putOff: Set<String> = []
    /// When the strip, hidden for a while (say, for a call or a talk), comes back. This isn't saved, so a restart
    /// brings the strip back.
    private(set) var hiddenUntil: Date?
    private var hideEnds: Timer?
    private var settling: Timer?
    /// Set when the user just answered a question, so the next question opens in a card right away.
    private var goesOn = false
    var place = StripPlace.load()
    /// Where the strip stood before a call moved it behind the screen edge (`call(_:)`), or nil outside a call. An
    /// inner nil means the strip stood above the Dock.
    var beforeCall: StripPlace??
    let calls = CallWatch()
    /// Set when the user moves the strip by hand during the current call, so it stays where they put it.
    var placedInCall = false
    var corner: StripCorner { place?.corner ?? .bottom }
    var tip: StripTip?
    /// Fires when finished work that the user already read in Kelp is due to leave the strip.
    private var expiry: Timer?
    private var tipTimer: Timer?
    /// Whether a strip hidden behind a screen edge is all the way out, because the pointer is on it.
    var peeking = false
    private var peekTimer: Timer?
    let line = StripLine()
    /// The news already told, by a line out of the edge or by a flash of a tile, so each piece is told once.
    private var told: Set<String> = []
    /// News waiting its turn to come out of the edge as a line, one after another.
    private var pending: [StripItem] = []
    private let glint = StripGlint()
    private var glintSide: [NSLayoutConstraint] = []
    var panel: StripPanel?
    /// Counts each move the strip is sent on, so the spring back at the end of a move can tell whether a newer move
    /// has started since.
    var moves = 0
    /// Set when the strip moved to a new place, so the next `put` swings a little past it and settles back, as a thrown
    /// thing does.
    var springs = false
    let row = StripRow()
    private var buttons: [String: StripButton] = [:]
    private var card: StripCard?
    private var observers: [NSObjectProtocol] = []
    /// The opened workspace and peek state of the last layout. While the pointer is on the strip, the layout stays as
    /// it was (`frozen`).
    private(set) var laidOut: (opened: String?, peeking: Bool)?
    /// Set when something changed while the strip stood still under the pointer, so it is laid out again once the
    /// pointer leaves.
    private(set) var deferred = false
    private var relayout: Timer?
    /// The row's last measured width and the key it was measured for (`width(of:)`). `measures` counts how many times
    /// the row was measured, for tests.
    var measured: (key: Measured, width: CGFloat)?
    var measures = 0
    /// What the strip showed and where, at its last layout. A refresh that finds the same look lays out nothing.
    private var lastLook: Look?
    private struct Look: Equatable {
        let state: State, place: StripPlace?, peeking: Bool, pointerOn: Bool, screens: [NSRect]
    }

    init(app: AppModel) { self.app = app }

    /// Returns the app's single strip.
    static func of(_ app: AppModel) -> AgentStrip { app.part { AgentStrip(app: app) } }

    /// Adds the strip's items to the Dock icon's menu, to hide the strip for an hour or bring it back.
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
        calls.onChange = { [weak self] on in self?.call(on) }
        calls.start()
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

    /// Builds the strip's state. Sessions on a muted row stay off the strip, as they stay off banners, and so do the
    /// sessions put off with Later.
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
            items: StripModel.items(loud, workspaces: shown).map { ci($0, app) },
            mode: app.settings[SettingKeys.dockStrip],
            comesFor: app.settings[SettingKeys.dockStripComesFor],
            fullScreen: app.settings[SettingKeys.dockStripFullScreen])
    }

    /// Returns the item with its workspace's CI mark, the one a built-in puts on the tile. It runs inside `track`, so
    /// it only reads marks and starts no work.
    private static func ci(_ item: StripItem, _ app: AppModel) -> StripItem {
        var with = item
        with.ci = app.extensions.rowMarks(.workspace(item.workspace)).first { $0.place == .tile }
        return with
    }

    var isShowing: Bool { panel?.isVisible == true }
    var frame: NSRect? { panel?.frame }
    /// Whether Kelp is the front app, in which case the strip steps aside. Tests replace it, because another test
    /// running at the same time may bring the test process to the front.
    var front: () -> Bool = { NSApp.isActive }
    /// Whether the strip moves and fades, or jumps straight to where it ends. Tests turn it off, because a main thread
    /// busy with other tests never runs an animation to its end.
    var animates = true
    var panelForTests: NSPanel? { panel }
    var isOff: Bool { app.settings[SettingKeys.dockStrip] == "off" }

    /// Hides the strip until the given date, whatever news comes meanwhile. Nil brings the strip back now.
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

    /// Keeps this session's agent off the strip until its state changes.
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
        // The strip is up and would show the same things in the same place, on screens of the same size, so this
        // refresh has nothing to change.
        let look = Look(
            state: state, place: place, peeking: peeking, pointerOn: row.pointerOn,
            screens: NSScreen.screens.map(\.visibleFrame))
        if look == lastLook, isShowing, card == nil, !goesOn, !deferred, !calls.inCall { return }
        panel?.apply(fullScreen: state.fullScreen)
        line.apply(fullScreen: state.fullScreen)
        let wasUp = isShowing
        let hidden = place?.edge != nil && !peeking
        // While the pointer is on the strip, the tiles stay where they are, because a pill moving to other news would
        // slide away the tile the user is aiming at. Meanwhile news shows as a mark on its tile, and the strip is laid
        // out again once the pointer leaves.
        let frozen = row.pointerOn && wasUp && laidOut?.peeking == peeking
        var opened = hidden ? nil : StripModel.opened(state.items)
        if frozen, let was = laidOut, state.items.contains(where: { $0.workspace == was.opened }) {
            opened = was.opened
        }
        deferred =
            frozen
            && (opened != StripModel.opened(state.items) || Set(buttons.keys) != Set(state.items.map(\.workspace)))
        let shownNow = state.items.compactMap { item -> StripButton? in
            guard let button = buttons[item.workspace] ?? (frozen ? nil : StripButton()) else { return nil }
            buttons[item.workspace] = button
            button.update(item, open: item.workspace == opened, app: app)
            button.onClick = { [weak self] in self?.clicked(item) }
            button.onMenu = { [weak self] in self?.menu(for: item) ?? NSMenu() }
            button.onHover = { [weak self, weak button] on in
                if let button { self?.hover(item, on: on, over: button, open: item.workspace == opened) }
            }
            return button
        }
        if !frozen {
            row.setViews(shownNow, in: .leading)
            buttons = buttons.filter { key, _ in state.items.contains { $0.workspace == key } }
            laidOut = (opened, peeking)
        }
        if let card, !state.items.contains(where: { $0.session == card.session && $0.cell != .working }) {
            closeCard()
        }
        // A new question came while a card was up. The card shows what Allow answers, so the new question gets a card
        // of its own.
        else if let card, card.question != app.session(card.session)?.summary {
            closeCard()
            goesOn = true
        }
        showEdge(hidden: hidden)
        if !frozen { put(appearing: !wasUp) }
        lastLook = frozen ? nil : look
        follow(opened)
        expireDone()
        tell(hidden: hidden, appeared: !wasUp)
        // When the strip first comes up during a call, it goes behind the edge, as it would have when the call began.
        if calls.inCall, !placedInCall, beforeCall == nil, place?.edge == nil, isShowing { call(true) }
    }

    /// Shows the handle and its glint on the side of the strip away from the edge it hides behind.
    func showEdge(hidden: Bool) {
        let edge = place?.edge
        if glint.superview == nil {
            row.addSubview(glint)
            glint.centerYAnchor.constraint(equalTo: row.centerYAnchor).isActive = true
        }
        glint.isHidden = edge == nil
        glint.cell = state.items.map(\.cell).min()
        glint.twice = state.items.count { $0.cell == .asks } > 1
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

    /// Tells each piece of news once, if it is as loud as what brings the strip up (the Comes Up For setting). While
    /// the strip hides behind an edge, news comes out of the edge as a line, one after another. While the strip is out,
    /// the news flashes its tile. Nothing flashes when the strip has just come up, because that is news enough.
    private func tell(hidden: Bool, appeared: Bool) {
        let upTo = StripModel.loudest(state.comesFor)
        let news = StripModel.news(state.items, told: told, upTo: upTo)
        told = Set(state.items.filter { $0.cell != .working && $0.cell <= upTo }.map(StripModel.newsKey))
        guard hidden else {
            pending = []
            if !appeared { for item in news { buttons[item.workspace]?.flash(item.cell) } }
            return
        }
        let waiting = Set(pending.map(StripModel.newsKey))
        pending += news.filter { !waiting.contains(StripModel.newsKey($0)) }
        if !line.isShowing { tellNext() }
    }

    /// Brings the next pending news that still stands out of the edge as a line. A click on the line opens the agent's
    /// card there.
    private func tellNext() {
        let standing = Set(state.items.map(StripModel.newsKey))
        pending = pending.filter { standing.contains(StripModel.newsKey($0)) }
        guard let edge = place?.edge, let panel, isShowing, !peeking, !pending.isEmpty else { return }
        let news = pending.removeFirst()
        line.onClick = { [weak self] in self?.openFromLine(news) }
        line.onGone = { [weak self] in self?.tellNext() }
        line.show(news, more: pending.count, app: app, by: panel.frame, edge: edge)
    }

    /// Opens the agent's card beside the line, with the strip left behind the edge. Work still going on has no card, so
    /// then the strip peeks out instead.
    private func openFromLine(_ item: StripItem) {
        guard let now = state.items.first(where: { $0.session == item.session }), now.cell != .working else {
            return peekFromLine()
        }
        let by = line.frame
        line.hide()
        open(now, by: by, at: place?.edge == .right ? .bottomRight : .bottomLeft)
    }

    /// Called when the pointer enters or leaves the strip. The pointer on a hidden strip brings all of it out, and when
    /// the pointer leaves, the strip goes back after a moment.
    func hoverStrip(_ on: Bool) {
        row.pointerOn = on
        relayout?.invalidate()
        if !on, deferred {
            relayout = Timer.scheduledTimer(withTimeInterval: Motion.hoverOpen, repeats: false) { [weak self] _ in
                // the main run loop's timer
                MainActor.assumeIsolated { if self?.row.pointerOn == false { self?.refresh() } }
            }
        }
        peekTimer?.invalidate()
        guard place?.edge != nil, on != peeking, on || card == nil else { return }
        peekTimer = Timer.scheduledTimer(withTimeInterval: on ? Motion.hoverOpenWarm : Motion.hoverOpen, repeats: false)
        { [weak self] _ in
            MainActor.assumeIsolated { self?.settle(on) }   // the main run loop's timer
        }
    }

    /// A pointer that moves off the strip into the gap it left at the edge still counts as on it, so the strip waits
    /// again instead of sliding back under the pointer.
    private func settle(_ on: Bool) {
        if !on, let edge = place?.edge, let panel,
            StripModel.inGap(NSEvent.mouseLocation, beside: panel.frame, edge: edge)
        {
            return hoverStrip(false)
        }
        peek(on)
    }

    /// Brings the strip out after a click on the line. The pointer isn't on the strip yet, so the strip goes back after
    /// a while unless the pointer comes to it.
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

    /// Sets a timer for when the next finished, already-read agent is due to leave the strip. Nothing else changes at
    /// that moment, so nothing else would refresh the strip.
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

    /// After an answer, opens the next question's card at once, so answering several in a row takes one click each, not
    /// two.
    private func follow(_ opened: String?) {
        guard goesOn, card == nil else { return }
        goesOn = false
        if let item = state.items.first(where: { $0.workspace == opened }), item.cell == .asks { open(item) }
    }

    /// Shows a tip over the strip that says what the tile under the pointer stands for. The tip floats above, so the
    /// strip doesn't change size and the tile stays under the pointer. The tip comes after a moment's rest, like a
    /// hover card, and at once when the pointer moves on to the next tile.
    private func hover(_ item: StripItem, on: Bool, over button: NSView, open: Bool) {
        tipTimer?.invalidate()
        // The open pill already says what its agent is doing. It gets a tip only for what its words leave out, such as
        // the other agents, the CI mark, or what a working agent does.
        guard on, !open || item.agents.count > 1 || item.cell == .working || item.ci != nil else {
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

    /// A click on a question, a failure or finished work opens its card, to answer from the strip. A click on work
    /// going on shows its workspace in Kelp.
    private func clicked(_ item: StripItem) {
        tip?.hide()
        if item.cell == .working {
            NSApp.activate()
            app.workbench.show(workspace: item.workspace)
            return
        }
        if card?.session == item.session {
            closeCard()
            return
        }
        open(item)
    }

    /// Opens the item's card. `by` and `at` say where the card stands when it isn't over the strip, as when it opens
    /// from the line out of the edge.
    private func open(_ item: StripItem, by anchor: NSRect? = nil, at side: StripCorner? = nil) {
        closeCard()
        guard let session = app.session(item.session), let panel else { return }
        let asking = state.items.filter { $0.cell == .asks }.sorted { $0.since < $1.since }
        let index = asking.firstIndex { $0.session == item.session }
        let position = index.flatMap { asking.count > 1 ? ($0 + 1, asking.count) : nil }
        let newCard = StripCard(session, app: app, fullScreen: state.fullScreen, position: position) {
            [weak self] end in
            switch end {
            case .later: self?.later(item.session)
            case .answered:
                self?.goesOn = true
                self?.closeCard()
            case .left: self?.closeCard()
            }
        }
        let by = anchor ?? panel.frame
        newCard.show(
            by: by, in: NSScreen.screens.first { $0.frame.intersects(by) }?.visibleFrame, at: side ?? corner)
        card = newCard
    }

    func closeCard() {
        card?.close()
        card = nil
        if peeking, !row.pointerOn { hoverStrip(false) }
    }

    private func goAway() {
        lastLook = nil   // the panel is still up while it fades, so if it's wanted back, it's laid out again
        closeCard()
        tip?.hide()
        line.hide()
        guard let panel, panel.isVisible else { return }
        guard animates else {
            panel.alphaValue = 0
            panel.orderOut(nil)
            return
        }
        panel.fadeOut { [weak self] in self?.wanted == true }
    }

    private var wanted: Bool {
        hiddenUntil == nil
            && StripModel.shows(state.items, mode: state.mode, comesFor: state.comesFor, front: front())
    }

}
