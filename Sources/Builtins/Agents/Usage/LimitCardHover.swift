import AppKit
import DesignKit
import Observation

/// When a limit's card under the sidebar opens and goes, by the hover card's rule (`HoverPopover`, which is AppKit's):
/// it opens once the pointer has rested on a row for `Motion.hoverOpen`, or after `Motion.hoverOpenWarm` while another
/// card is up or has just gone, and it goes `Motion.hoverClose` after the pointer leaves, or at once on a key. A click
/// opens it at once. It stays while the pointer is on the card itself, whose eyes are for clicking.
@MainActor
@Observable
final class LimitCardHover {
    /// The row whose card is up.
    private(set) var shown: String?
    /// The open or close to come; a later one replaces it. A test flushes it.
    @ObservationIgnored let pending = Debounce()
    @ObservationIgnored private var warmUntil = Date.distantPast
    @ObservationIgnored private var keys: Any?
    /// Whether the pointer is on the card.
    @ObservationIgnored private var inCard = false

    /// The pointer came onto the row `id` (`inside`) or left it.
    func hover(_ id: String, _ inside: Bool) {
        guard inside else { return closeSoon() }
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

    /// The pointer came onto the card or left it.
    func card(_ inside: Bool) {
        inCard = inside
        if inside { pending.cancel() } else { closeSoon() }
    }

    /// Closes the card in a moment, unless the pointer is on it by then: on its way from the row to the card, it leaves
    /// the row first.
    private func closeSoon() {
        pending.after(Motion.hoverClose) { [weak self] in
            guard let self, !self.inCard else { return }
            self.close()
        }
    }

    func close() {
        pending.cancel()
        inCard = false
        if shown != nil { warmUntil = Date().addingTimeInterval(0.8) }   // as long as HoverPopover keeps it warm
        shown = nil
        if let keys {
            NSEvent.removeMonitor(keys)
            self.keys = nil
        }
    }
}
