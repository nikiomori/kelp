import AppKit

/// A panel's redraw while it's on screen only. The inspector keeps a panel it swapped out, and a collapsed inspector
/// keeps the one it shows: asked then, the work waits (the latest only, in place of what waited) and runs once when the
/// panel shows again, so a hidden list isn't rebuilt on every git or session change.
@MainActor
package final class WhenShown {
    private let probe = Probe()
    private var waiting: (@MainActor () -> Void)?

    /// Follows `view` (the panel's own) into and out of the window, and out from under a hidden ancestor.
    package init(_ view: NSView) {
        view.addSubview(probe)
        probe.shown = { [weak self] in self?.runWaiting() }
    }

    /// In a window and not hidden (a collapsed split view item is hidden).
    package var onScreen: Bool { probe.window != nil && !probe.isHiddenOrHasHiddenAncestor }

    /// `work` now when on screen, else when the panel next shows.
    package func run(_ work: @escaping @MainActor () -> Void) {
        guard onScreen else { return waiting = work }
        waiting = nil
        work()
    }

    private func runWaiting() {
        guard onScreen, let work = waiting else { return }
        waiting = nil
        work()
    }
}

/// A view of no size in the panel: told when it comes into a window or an ancestor stops hiding it.
private final class Probe: NSView {
    var shown: () -> Void = {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        shown()
    }
    override func viewDidUnhide() {
        super.viewDidUnhide()
        shown()
    }
}
