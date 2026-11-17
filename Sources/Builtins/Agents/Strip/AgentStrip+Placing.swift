// Where the agent strip stands. It can be dropped in a corner or tucked behind the side of a screen, and it is put on
// the right screen.
import AppKit
import Core
import DesignKit
import KelpKit

extension AgentStrip {
    /// Places the strip when the user lets go of a drag. A strip thrown fast (`going`) flies as far as it can that way.
    /// Otherwise it goes to the nearest corner of its screen, or behind the side it was dragged past. An open card
    /// closes.
    func dropped(going velocity: CGVector = .zero) {
        guard let panel, let screen = Self.screen(under: panel.frame) else { return }
        let frame = panel.frame, area = screen.visibleFrame
        let nearest = StripModel.corner(nearest: frame, in: area)
        if let way = StripModel.thrown(velocity), fling(way, from: nearest, edge: nil, on: screen) { return }
        if let edge = StripModel.edge(dropped: frame, in: area), Self.outer(edge, of: screen) {
            moved(to: Self.place(behind: edge, of: screen, at: frame))
            return
        }
        moved(to: Self.place(nearest, of: screen))
    }

    /// Moves the strip after a two-finger swipe over it, as far as it can go that way. A swipe toward a side from that
    /// side's corner tucks the strip behind the side, and a swipe away brings it out again.
    func swipe(_ way: StripWay) {
        guard let panel, let screen = Self.screen(under: panel.frame) else { return }
        let high = panel.frame.midY > screen.visibleFrame.midY
        let corner =
            place?.edge.map { $0 == .left ? (high ? .topLeft : .bottomLeft) : (high ? .topRight : .bottomRight) }
            ?? self.corner
        fling(way, from: corner, edge: place?.edge, on: screen)
    }

    /// Moves the strip where `way` sends it from `corner`, or from behind `edge`. Returns false when there's nowhere
    /// further to go that way.
    @discardableResult
    private func fling(_ way: StripWay, from corner: StripCorner, edge: StripEdge?, on screen: NSScreen) -> Bool {
        guard let panel else { return false }
        switch StripModel.flung(from: corner, edge: edge, way) {
        case .corner(let to): moved(to: Self.place(to, of: screen))
        case .edge(let side) where Self.outer(side, of: screen):
            moved(to: Self.place(behind: side, of: screen, at: panel.frame))
        case .edge, nil: return false
        }
        return true
    }

    /// Returns the place at a corner of that screen. The bottom of the main screen is where the strip starts, so that
    /// place is nil and isn't saved.
    private static func place(_ corner: StripCorner, of screen: NSScreen) -> StripPlace? {
        corner == .bottom && screen == NSScreen.main ? nil : StripPlace(corner: corner, display: number(of: screen))
    }

    /// Tucks the strip, from the menu, behind the nearer side of its screen at the height where it stands.
    func tuck() {
        if let behind = tucked() { moved(to: behind) }
    }

    /// Returns the place behind the nearer side of the strip's screen, at the strip's height. When another screen
    /// stands past that side, the place is behind the other side.
    func tucked() -> StripPlace? {
        guard let panel, let screen = Self.screen(under: panel.frame) else { return nil }
        let area = screen.visibleFrame
        let nearer: StripEdge = panel.frame.midX > area.midX ? .right : .left
        guard let edge = [nearer, nearer == .right ? .left : .right].first(where: { Self.outer($0, of: screen) }) else {
            return nil
        }
        return Self.place(behind: edge, of: screen, at: panel.frame)
    }

    /// Called when a call begins or ends (`CallWatch`). During the call the strip moves out of the way behind the
    /// nearer side, and after it the strip goes back where it stood. This move isn't saved, so the place the user chose
    /// stays theirs, and a place they choose during the call wins.
    func call(_ on: Bool) {
        if on, !placedInCall, place?.edge == nil, beforeCall == nil, let behind = tucked() {
            beforeCall = .some(place)
            put(behind)
        } else if !on {
            placedInCall = false
            if let was = beforeCall {
                beforeCall = nil
                put(was)
            }
        }
    }

    private func put(_ place: StripPlace?) {
        self.place = place
        peeking = false
        closeCard()
        tip?.hide()
        line.hide()
        goes()
    }

    /// Moves the strip to its new place with a spring, even while the pointer is on it. (`refresh` keeps the tiles
    /// still under the pointer, and a dragged strip is always under it.) So a strip let go half past a side isn't left
    /// there, but springs back to where it's whole.
    private func goes() {
        springs = true
        defer { springs = false }
        refresh()
        if springs, isShowing { put(appearing: false) }
    }

    /// Returns the place behind `edge` at the height where the strip stands. Its corner is the bottom corner on that
    /// side.
    private static func place(behind edge: StripEdge, of screen: NSScreen, at frame: NSRect) -> StripPlace {
        StripPlace(
            corner: edge == .right ? .bottomRight : .bottomLeft, display: number(of: screen), edge: edge,
            y: frame.minY - screen.visibleFrame.minY)
    }

    /// Returns the screen that most of the frame is on, because a window pushed past an edge has no `screen` of its
    /// own.
    private static func screen(under frame: NSRect) -> NSScreen? {
        NSScreen.screens.max { $0.frame.intersection(frame).width < $1.frame.intersection(frame).width }
            ?? NSScreen.main
    }

    private static func outer(_ edge: StripEdge, of screen: NSScreen) -> Bool {
        StripModel.outer(edge, of: screen.frame, among: NSScreen.screens.filter { $0 != screen }.map(\.frame))
    }

    func moved(to place: StripPlace?) {
        beforeCall = nil
        placedInCall = calls.inCall
        self.place = place
        StripPlace.save(place)
        peeking = false
        closeCard()
        tip?.hide()
        line.hide()
        goes()
    }

    private static func number(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Returns the screen the strip was put on. Otherwise, when the strip comes up, it is the screen the pointer is on,
    /// because that is the one being looked at and the Dock's screen can't be told.
    private func screen(appearing: Bool, of panel: NSPanel) -> NSScreen? {
        if let display = place?.display, let put = NSScreen.screens.first(where: { Self.number(of: $0) == display }) {
            return put
        }
        let mouse = NSEvent.mouseLocation
        return (appearing ? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } : panel.screen)
            ?? NSScreen.main
    }

    func put(appearing: Bool) {
        let window = panel ?? makePanel()
        guard let area = screen(appearing: appearing, of: window)?.visibleFrame, let content = window.contentView else {
            return
        }
        let size = NSSize(width: width(of: content), height: StripButton.stripHeight)
        let behind = place?.edge.map { StripModel.tucked(size, in: area, edge: $0, y: place?.y ?? 0, out: peeking) }
        let frame = behind ?? StripModel.frame(size, in: area, at: corner)
        guard animates else {   // jump to where it ends, with no animation
            window.setFrame(frame, display: true)
            window.alphaValue = 1
            if appearing { window.orderFrontRegardless() }
            return
        }
        guard appearing else {
            // nothing moved, so there's no animation to run
            guard window.frame != frame || window.alphaValue != 1 else { return }
            let past = springs && !Motion.reduced ? StripModel.past(frame, from: window.frame) : frame
            springs = false
            moves += 1
            let move = moves
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration = Motion.duration(Motion.appear)
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    window.animator().setFrame(past, display: true)
                    window.animator().alphaValue = 1
                },
                completionHandler: past == frame
                    ? nil
                    : { @Sendable [weak self] in
                        // AppKit ends its animations on the main thread
                        MainActor.assumeIsolated { self?.springBack(to: frame, after: move) }
                    })
            return
        }
        window.slideIn(to: frame, by: CGVector(dx: 0, dy: Motion.reduced ? 0 : corner.isTop ? 8 : -8))
    }

    /// What the strip's width depends on: its tiles, the open one, the edge it hides behind (which adds room for the
    /// handle) and the text size.
    struct Measured: Equatable {
        let items: [StripItem], opened: String?, edge: StripEdge?, scale: CGFloat
    }

    /// Returns the row's width, measured once for each look of the row, because the panel's `fittingSize` is a whole
    /// Auto Layout pass (about 100 ms, seen when Kelp came to the front). The width isn't kept while the row waits
    /// under the pointer (`deferred`), because the row shows older tiles then.
    private func width(of content: NSView) -> CGFloat {
        let key = Measured(items: state.items, opened: laidOut?.opened, edge: place?.edge, scale: TextSize.scale)
        if !deferred, let measured, measured.key == key { return measured.width }
        measures += 1
        content.layoutSubtreeIfNeeded()
        let width = content.fittingSize.width
        measured = deferred ? nil : (key, width)
        return width
    }

    /// Springs the strip back from a little past its place, unless it was sent somewhere else since.
    private func springBack(to frame: NSRect, after move: Int) {
        guard move == moves, let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.duration(Motion.fast)
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func makePanel() -> StripPanel {
        row.spacing = 2
        showEdge(hidden: place?.edge != nil)
        row.onHover = { [weak self] on in self?.hoverStrip(on) }
        row.onClick = { [weak self] in self?.peek(true) }
        let made = StripPanel.floating(row, radius: StripButton.stripHeight / 2, fullScreen: state.fullScreen)
        made.onDropped = { [weak self] velocity in self?.dropped(going: velocity) }
        row.onSwipe = { [weak self] way in self?.swipe(way) }
        panel = made
        return made
    }
}
