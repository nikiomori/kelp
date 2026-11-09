// Where the agent strip stands: dropped in a corner, tucked behind a screen's side, put on its screen.
import AppKit
import Core
import DesignKit
import KelpKit

extension AgentStrip {
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
    func tuck() {
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

    func moved(to place: StripPlace?) {
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
