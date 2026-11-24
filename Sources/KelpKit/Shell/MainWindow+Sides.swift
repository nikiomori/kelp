import AppKit
import Core
import DesignKit
import SwiftUI
import TerminalKit

/// The window's side columns: auto-hide, a peek from the edge, a pin, and the slide that opens and closes them.
extension MainWindowController {
    /// Fades a window bar's button out or in with the panels moving beside it, instead of in a single frame. It goes
    /// as the floater it rides on does: in about two thirds of the time it took to come.
    func fade(_ button: NSView, hidden: Bool) {
        if !hidden { button.isHidden = false }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.duration(hidden ? Motion.fast : Motion.base)
            ctx.timingFunction = CAMediaTimingFunction(name: hidden ? .easeIn : .easeOut)
            button.animator().alphaValue = hidden ? 0 : 1
        } completionHandler: {
            MainActor.assumeIsolated { if button.alphaValue == 0 { button.isHidden = true } }   // AppKit calls on main
        }
    }

    func setAutoHide(_ side: Side, _ on: Bool) {
        guard on != side.autoHide else { return }   // so the first read, before loading, keeps the saved layout
        side.autoHide = on
        followLights()   // the lights and the toggle move with the column, from its first frame
        if inFocusMode { side.closedBefore = on }
        if peeking === side { stopPeek() }
        guard !inFocusMode else { return place() }
        if on {
            floatWidths()
            // As in focus mode, the column closes over the panel first.
            slide([(side, true)]) { [weak self] in self?.place() }
        } else {
            land([(side, false)])
        }
        if side === right { UserDefaults.standard.set(on, forKey: "inspector.collapsed") }
    }
    /// Opens or closes columns together as a floater slides, and at once under Reduce Motion. The terminals beside
    /// them keep their size until the columns stop, because a program in one would redraw for every width on the way.
    /// `then` runs once the columns stand, or at once when nothing moves.
    func slide(_ columns: [(side: Side, collapsed: Bool)], then: (@MainActor () -> Void)? = nil) {
        let moves = columns.filter { $0.side.item.isCollapsed != $0.collapsed }
        guard !moves.isEmpty else {
            then?()
            return
        }
        // Close the sidebar's hover card, because its row is going, and with it the pointer's way out.
        if moves.contains(where: { $0.side === left && $0.collapsed }) { sidebar.card.close() }
        guard !Motion.reduced else {
            moves.forEach { $0.side.item.isCollapsed = $0.collapsed }
            then?()
            return
        }
        GhosttyTerminalView.holdSize(true)
        moves.forEach { $0.side.holdWidth(closing: $0.collapsed) }
        // What's shown travels with the edge that moves, as a page's content does when its sidebar opens, and the far
        // side takes the new width once the columns stand. When it stood still while the column came over it, the
        // column covered its first tabs and they all jumped over at the end. With both moving, it travels with the
        // left.
        editors.holdWidth(trailing: !moves.contains { $0.side === left })
        // Columns that only close leave as panels do: sooner, speeding away.
        // Columns that open move as a fold does: at once, settling slowly, long enough to follow (as a page's sidebar
        // opens in about 300 ms).
        let leaving = moves.allSatisfy(\.collapsed)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = leaving ? Motion.fast : Motion.fold
            ctx.timingFunction = leaving ? CAMediaTimingFunction(name: .easeIn) : Motion.soft
            moves.forEach { $0.side.item.animator().isCollapsed = $0.collapsed }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {   // AppKit runs the completion handler on the main thread
                self?.editors.letWidthGo()
                self?.sides.forEach { $0.letWidthGo() }
                // Lay out before the terminals take their size, so they take the final size, once.
                self?.window?.contentView?.layoutSubtreeIfNeeded()
                GhosttyTerminalView.holdSize(false)
                then?()
            }
        }
    }

    func hides(_ side: Side) -> Bool { inFocusMode || side.autoHide }

    /// Puts each panel where it belongs now: in its column, or in its floater while it hides. A panel leaving its open
    /// column for the floater keeps its width there.
    /// A floater is as wide as its column was, so the width is read while the column is still open.
    func floatWidths() {
        for side in sides where !side.item.isCollapsed {
            let wide = side.column.frame.width
            if wide >= side.item.minimumThickness { side.floater.width = wide }
        }
    }
    func place() {
        for side in sides {
            let hide = hides(side), floating = side.floater, column = side.column, panel = side.panel
            side.edge.isHidden = !hide
            if hide, panel.superview !== floating.box {
                if !side.item.isCollapsed, column.frame.width >= side.item.minimumThickness {
                    floating.width = column.frame.width
                }
                floating.box.pin(panel)
            } else if !hide, panel.superview !== column {
                column.pin(panel)
            }
        }
        // The sidebar's cards run to the column's edge, and the gap before the editor card is their margin there. In
        // the floater that edge is the floater's border, so a margin goes inside it, as wide as the cards stand from
        // the left (8), and the scroller's knob runs in it.
        sidebar.gutter = hides(left) ? Metrics.gapWide : 0
        followLights()
    }

    /// A sidebar put away takes the traffic lights with it, as Dia's does (decision 109): they come back on it while
    /// it slides in at the edge, and with it in its column. Its toggle stays, at the window's edge where the lights
    /// stood; the toggle and the workspace's name move with the column (`toggleFloor`), never while it slides in.
    func followLights() {
        let away = hides(left)
        let floor = away ? lightsStart : lightsEnd + 12
        if toggleFloor?.constant != floor {
            NSAnimationContext.runAnimationGroup { ctx in   // with the column, as `slide` moves it
                ctx.duration = Motion.duration(away ? Motion.fast : Motion.fold)
                ctx.timingFunction = away ? CAMediaTimingFunction(name: .easeIn) : Motion.soft
                toggleFloor?.animator().constant = floor
                pillFloor?.animator().constant = floor
            }
        }
        let shown = !away || peeking === left
        for view in lights where view.isHidden == shown && !Floater.carries(view) {
            fade(view, hidden: !shown)
        }
    }
    /// The traffic lights. A peeking sidebar carries them in and out at its top, as Arc's does.
    var lights: [NSView] {
        [.closeButton, .miniaturizeButton, .zoomButton].compactMap { window?.standardWindowButton($0) }
    }

    func peek(_ side: Side) {
        guard hides(side), peeking !== side else { return }
        endPeek()
        peeking = side
        peekedAt = Date()
        peekReached = false
        side.floater.slide(in: true, carrying: side === left ? lights : [])
        followLights()
        window?.acceptsMouseMovedEvents = true
        peekMoves = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.pointerMoved(event)
            return event
        }
    }
    func pointerMoved(_ event: NSEvent) {
        guard let side = peeking, event.window === window, let root = window?.contentView else { return }
        let point = root.convert(event.locationInWindow, from: nil)
        // A card the panel opened (a commit's, an agent's) hangs beside it in a window of its own: the way to it and
        // the card itself count as the panel, or the panel went, and the card with it, as the pointer set off for it.
        let cards = (window?.childWindows ?? []).filter(\.isVisible).compactMap { child in
            window.map { root.convert($0.convertFromScreen(child.frame), from: nil) }
        }
        if Self.overPeek(point, panel: side.floater.frame, edge: side.edge.frame, cards: cards) {
            peekReached = true
            return
        }
        // Don't end the peek while the panel slides in, because it isn't where the pointer is headed yet.
        if peekReached, Date().timeIntervalSince(peekedAt) > 0.4 { endPeek() }
    }
    /// Whether `point` is over a peeking panel, which counts anywhere from the window's edge through the panel. The
    /// panel stands 6 pt in from the edge, past the 4 pt strip, and a slow move across that gap closed it under the
    /// pointer.
    /// A card beside the panel counts too, with a margin for the step between them.
    static func overPeek(_ point: NSPoint, panel: NSRect, edge: NSRect, cards: [NSRect] = []) -> Bool {
        panel.union(edge).contains(point)
            || cards.contains { $0.insetBy(dx: -2 * Metrics.gapWide, dy: -2 * Metrics.gapWide).contains(point) }
    }
    func endPeek(animated: Bool = true) {
        if let monitor = peekMoves {
            NSEvent.removeMonitor(monitor)
            peekMoves = nil
        }
        guard let side = peeking else { return }
        peeking = nil
        side.floater.slide(in: false, animated: animated, carrying: side === left && hides(left) ? lights : [])
        followLights()
    }
    /// Called when the panels change for good (focus mode, auto-hide switched), so the peeking panel goes at
    /// once.
    func stopPeek() { endPeek(animated: false) }
    func togglePeek(_ side: Side) {
        if peeking === side { endPeek() } else { peek(side) }
    }
    /// Opens columns for panels that no longer hide. A panel out of sight goes into its column at once and rides in
    /// with it at its width, the editor area moving over with the column's edge: one motion, as a page's sidebar
    /// opens. When it came in on its floater's spring over a column opening on another curve, and then jumped from the
    /// floater (inset, border, shadow) into the column, the two motions and the jump read as lag. Moving the panel
    /// takes the main thread some 40 ms before the motion starts. A panel peeking stays in its floater over the opening
    /// column, and goes into the column once the column stands.
    func land(_ columns: [(side: Side, collapsed: Bool)]) {
        for (side, collapsed) in columns where !collapsed && !hides(side) {
            guard side.panel.superview === side.floater.box else { continue }
            // The column opens as wide as the floater, because the split would reopen a collapsed column at the width
            // it last had.
            if side.item.isCollapsed { side.column.setFrameSize(NSSize(width: side.floater.width, height: 0)) }
            if peeking === side {   // the panel stays where it is, and nothing watches the pointer for it any more
                if let monitor = peekMoves { NSEvent.removeMonitor(monitor) }
                peekMoves = nil
                peeking = nil
            } else {
                let width = side.floater.width
                side.column.pin(side.panel)
                side.holdWidth(closing: false, width: width)
                if side === left { sidebar.gutter = 0 }
            }
        }
        slide(columns) { [weak self] in
            guard let self else { return }
            for side in sides where !hides(side) {
                side.floater.slide(in: false, animated: false)
            }
            place()
        }
    }
}

/// A panel beside the editor area (the sidebar or the inspector), with its column, the floater it hides in, the edge
/// strip that brings it in, and what keeps it away.
@MainActor
final class Side {
    let item: NSSplitViewItem, controller: NSViewController, floater: Floater
    let edge = EdgeTrigger()
    /// The panel's edge next to the editor area, which lets go while its column slides.
    let inner: NSLayoutConstraint.Attribute
    /// Switched by the panel's button (⌘0 / ⌥⌘0). When on, the panel stays away at its edge as in focus mode.
    var autoHide = false
    /// True when the column was closed (or the panel hid) before focus mode, so leaving focus mode puts that back.
    var closedBefore = false
    private var openWidth: CGFloat = 0
    private var held: WidthHold?

    init(
        _ item: NSSplitViewItem, _ controller: NSViewController, _ floater: Floater, inner: NSLayoutConstraint.Attribute
    ) {
        self.item = item
        self.controller = controller
        self.floater = floater
        self.inner = inner
        edge.isHidden = true
    }
    var panel: NSView { controller.view }
    var column: NSView { item.viewController.view }

    /// While its column slides, the panel keeps the width it has when open, and the column uncovers or covers it. When
    /// it was laid out for every width on the way, the sidebar's rows dropped and took back their badges, and a panel's
    /// lines rewrapped.
    func holdWidth(closing: Bool, width: CGFloat? = nil) {
        guard panel.superview === column, held == nil else { return }
        if closing { openWidth = panel.frame.width }
        if let width { openWidth = width }   // the width it had in its floater, coming from there
        // The edge beside the editor area lets go, and the edge on the window's side keeps the panel in place.
        guard openWidth > 0, let hold = WidthHold(panel, in: column, edge: inner, width: openWidth) else { return }
        column.clipsToBounds = true
        held = hold
    }
    func letWidthGo() {
        guard let held else { return }
        held.release()
        column.clipsToBounds = false
        self.held = nil
    }
}
