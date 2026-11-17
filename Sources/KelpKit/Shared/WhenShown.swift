import AppKit

/// Runs a panel's redraw only while the panel is on screen. The inspector keeps a panel it swapped out, and a collapsed
/// inspector keeps the one it shows. Work asked for then waits (only the latest, replacing what waited) and runs once
/// when the panel shows again, so a hidden list isn't rebuilt on every git or session change.
@MainActor
package final class WhenShown {
    private let probe = Probe()
    private var waiting: (@MainActor () -> Void)?

    /// Follows `view` (the panel's own view) into and out of the window, and out from under a hidden ancestor.
    package init(_ view: NSView) {
        view.addSubview(probe)
        probe.shown = { [weak self] in self?.runWaiting() }
    }

    /// Whether the panel is in a window and not hidden (a collapsed split view item is hidden).
    package var onScreen: Bool { probe.window != nil && !probe.isHiddenOrHasHiddenAncestor }

    /// Runs `work` now when the panel is on screen, else when it next shows.
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

/// A view of no size in the panel, told when it comes into a window or when an ancestor stops hiding it.
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
