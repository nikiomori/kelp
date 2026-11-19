import AppKit
import DesignKit
import Observation

/// When a limit's card under the sidebar opens and goes, by the hover card's rule (`HoverPopover`, which is AppKit's):
/// it opens once the pointer has rested on a row for `Motion.hoverOpen`, or after `Motion.hoverOpenWarm` while another
/// card is up or has just gone, and it goes `Motion.hoverClose` after the pointer leaves, or at once on a key. A click
/// opens it at once.
@MainActor
@Observable
final class LimitCardHover {
    /// The row whose card is up.
    private(set) var shown: String?
    @ObservationIgnored private let pending = Debounce()   // the open or close to come; a later one replaces it
    @ObservationIgnored private var warmUntil = Date.distantPast
    @ObservationIgnored private var keys: Any?

    /// The pointer came onto the row `id` (`inside`) or left it.
    func hover(_ id: String, _ inside: Bool) {
        guard inside else { return pending.after(Motion.hoverClose) { [weak self] in self?.close() } }
        let warm = shown != nil || Date() < warmUntil
        pending.after(warm ? Motion.hoverOpenWarm : Motion.hoverOpen) { [weak self] in self?.show(id) }
    }

    /// Opens the card of the row `id` now, as a click does.
    func show(_ id: String) {
        pending.cancel()
        shown = id
        keys =
            keys
            ?? NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated { self?.close() }   // local monitors run on the main thread
                return event
            }
    }

    func close() {
        pending.cancel()
        if shown != nil { warmUntil = Date().addingTimeInterval(0.8) }   // as long as HoverPopover keeps it warm
        shown = nil
        if let keys {
            NSEvent.removeMonitor(keys)
            self.keys = nil
        }
    }
}
