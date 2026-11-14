// Where the agent strip stands: dropped in a corner, tucked behind a screen's side, put on its screen.
import AppKit
import Core
import DesignKit
import KelpKit

extension AgentStrip {
    /// Let go after a drag: thrown (`going` fast), it flies as far as it goes that way; else to the nearest corner of the
    /// screen it's on, or behind the side it went past. A card it left behind goes.
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

    /// Two fingers swept over it: as far as it goes that way, behind the side from that side's corner, out again.
    func swipe(_ way: StripWay) {
        guard let panel, let screen = Self.screen(under: panel.frame) else { return }
        let high = panel.frame.midY > screen.visibleFrame.midY
        let corner =
            place?.edge.map { $0 == .left ? (high ? .topLeft : .bottomLeft) : (high ? .topRight : .bottomRight) }
            ?? self.corner
        fling(way, from: corner, edge: place?.edge, on: screen)
    }

    /// Off to where `way` sends it from `corner` (or from behind `edge`); false when there's nowhere further that way.
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

    /// At a corner of that screen; the foot of the main one is where it starts, so that's no place to keep.
    private static func place(_ corner: StripCorner, of screen: NSScreen) -> StripPlace? {
        corner == .bottom && screen == NSScreen.main ? nil : StripPlace(corner: corner, display: number(of: screen))
    }

    /// From the menu: behind the side of its screen it's nearer, where it stands.
    func tuck() {
        if let behind = tucked() { moved(to: behind) }
    }

    /// Behind the side of its screen it's nearer (the other, if a screen stands past that one), at its height.
    func tucked() -> StripPlace? {
        guard let panel, let screen = Self.screen(under: panel.frame) else { return nil }
        let area = screen.visibleFrame
        let nearer: StripEdge = panel.frame.midX > area.midX ? .right : .left
        guard let edge = [nearer, nearer == .right ? .left : .right].first(where: { Self.outer($0, of: screen) }) else {
            return nil
        }
        return Self.place(behind: edge, of: screen, at: panel.frame)
    }

    /// A call began or ended (`CallWatch`): out of the way behind the nearer side while it lasts, and back where it stood
    /// after. Not kept: the place the person chose stays theirs, and one they choose during the call wins.
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

    /// To its new place with a spring, whatever is under the pointer (`refresh` keeps the tiles still there, and a dragged
    /// strip is): not left half past a side where it was let go, but sprung back to where it's whole.
    private func goes() {
        springs = true
        defer { springs = false }
        refresh()
        if springs, isShowing { put(appearing: false) }
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

    /// Where it was put, or else the screen the pointer is on when it comes up: the one being looked at, as the Dock's can't be told.
    private func screen(appearing: Bool, of p: NSPanel) -> NSScreen? {
        if let display = place?.display, let put = NSScreen.screens.first(where: { Self.number(of: $0) == display }) {
            return put
        }
        let mouse = NSEvent.mouseLocation
        return (appearing ? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } : p.screen)
            ?? NSScreen.main
    }

    func put(appearing: Bool) {
        let window = panel ?? makePanel()
        guard let area = screen(appearing: appearing, of: window)?.visibleFrame, let content = window.contentView else {
            return
        }
        content.layoutSubtreeIfNeeded()
        let size = NSSize(width: content.fittingSize.width, height: StripButton.stripHeight)
        let behind = place?.edge.map { StripModel.tucked(size, in: area, edge: $0, y: place?.y ?? 0, out: peeking) }
        let frame = behind ?? StripModel.frame(size, in: area, at: corner)
        guard animates else {   // where it ends, at once
            window.setFrame(frame, display: true)
            window.alphaValue = 1
            if appearing { window.orderFrontRegardless() }
            return
        }
        guard appearing else {
            // nothing moved: no animation to run
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

    /// The spring's way back from a little past its place, unless it was sent somewhere else since.
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
