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
        side.pinned = false
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
        // The side that stays is the one whose panel isn't moving. With both moving, what's shown travels with the
        // left.
        editors.holdWidth(trailing: !moves.contains { $0.side === right })
        // Columns that only close leave as panels do: sooner, speeding away.
        let leaving = moves.allSatisfy(\.collapsed)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = leaving ? Motion.fast : Motion.base
            ctx.timingFunction = CAMediaTimingFunction(name: leaving ? .easeIn : .easeOut)
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

    func hides(_ side: Side) -> Bool { inFocusMode || side.autoHide && !side.pinned }

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
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.duration(away ? Motion.fast : Motion.base)
                ctx.timingFunction = CAMediaTimingFunction(name: away ? .easeIn : .easeOut)
                toggleFloor?.animator().constant = floor
                pillFloor?.animator().constant = floor
            }
        }
        let shown = !away || peeking === left
        let lights: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for view in lights.compactMap({ window?.standardWindowButton($0) }) where view.isHidden == shown {
            fade(view, hidden: !shown)
        }
    }

    func peek(_ side: Side) {
        guard hides(side), peeking !== side else { return }
        endPeek()
        peeking = side
        peekedAt = Date()
        peekReached = false
        side.floater.slide(in: true)
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
        if Self.overPeek(point, panel: side.floater.frame, edge: side.edge.frame) {
            peekReached = true
            return
        }
        // Don't end the peek while the panel slides in, because it isn't where the pointer is headed yet.
        if peekReached, Date().timeIntervalSince(peekedAt) > 0.4 { endPeek() }
    }
    /// Whether `point` is over a peeking panel, which counts anywhere from the window's edge through the panel. The
    /// panel stands 6 pt in from the edge, past the 4 pt strip, and a slow move across that gap closed it under the
    /// pointer.
    static func overPeek(_ point: NSPoint, panel: NSRect, edge: NSRect) -> Bool { panel.union(edge).contains(point) }
    func endPeek(animated: Bool = true) {
        if let monitor = peekMoves {
            NSEvent.removeMonitor(monitor)
            peekMoves = nil
        }
        guard let side = peeking else { return }
        peeking = nil
        side.floater.slide(in: false, animated: animated)
        followLights()
    }
    /// Called when the panels change for good (focus mode, auto-hide switched, pinned), so the peeking panel goes at
    /// once.
    func stopPeek() { endPeek(animated: false) }
    func togglePeek(_ side: Side) {
        if peeking === side { endPeek() } else { peek(side) }
    }
    /// With auto-hide, a pinned panel stays in its column (a peeking panel moves there). Unpinned, it goes away and
    /// comes in at the edge again.
    func togglePin(_ side: Side) {
        side.pinned.toggle()
        if side.pinned { return land([(side, false)]) }
        if peeking === side { stopPeek() }
        floatWidths()
        slide([(side, true)]) { [weak self] in self?.place() }
    }

    /// Opens columns for panels that no longer hide. A panel in its floater comes in there (or stays, peeking) over its
    /// opening column, and is put in the column once the column stands. Moving a panel takes the main thread some
    /// 40 ms, and when the panel moved first, that was a wait between the key and anything happening.
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
                side.floater.slide(in: true)
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
    /// Settings › Appearance › Auto-hide. When on, the panel stays away as in focus mode, for good.
    var autoHide = false
    /// True when the toggle (⌘0 / ⌥⌘0) pinned an auto-hidden panel. It then stays in like a normal panel until the
    /// toggle is pressed again.
    var pinned = false
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
    func holdWidth(closing: Bool) {
        guard panel.superview === column, held == nil else { return }
        if closing { openWidth = panel.frame.width }
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
