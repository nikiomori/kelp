import AppKit

/// The card a row shows while the pointer rests on it (a sidebar row, a page, a commit). It opens after half a second,
/// or at once while another card is up or has just gone, so it follows the pointer from row to row. Typing puts it
/// away.
@MainActor
public final class HoverPopover {
    public let popover = NSPopover()
    /// What the owner lets go of when the card goes, whoever closed it.
    public var onClose: () -> Void = {}
    private var pending: Task<Void, Never>?
    private var warmUntil = Date.distantPast
    private var keys: Any?

    public init() {
        popover.behavior = .applicationDefined
        popover.animates = false
    }

    public var isShown: Bool { popover.isShown }

    /// Runs `show` after the wait, in a task that a later `open`, `closeSoon`, `cancel` or `close` cancels.
    public func open(_ show: @escaping @MainActor () async -> Void) {
        let warm = popover.isShown || Date() < warmUntil
        after(warm ? Motion.hoverOpenWarm : Motion.hoverOpen, show)
    }

    /// Called when the pointer left. The card goes in a moment, or with `unlessInside`, as `closeUnlessInside` says.
    public func closeSoon(unlessInside: Bool = false) {
        after(Motion.hoverClose) { [weak self] in if unlessInside { self?.closeUnlessInside() } else { self?.close() } }
    }

    /// Closes the card, but not while the pointer is in it (its buttons are for clicking); then it looks again until
    /// the pointer leaves.
    public func closeUnlessInside() {
        guard popover.contentViewController?.view.window?.frame.contains(NSEvent.mouseLocation) == true else {
            close()
            return
        }
        closeSoon(unlessInside: true)
    }

    /// Cancels what was to happen next, an open or a close.
    public func cancel() { pending?.cancel() }

    public func close() {
        pending?.cancel()
        if popover.isShown {
            warmUntil = Date().addingTimeInterval(0.8)
            popover.close()
        }
        if let keys {
            NSEvent.removeMonitor(keys)
            self.keys = nil
        }
        onClose()
    }

    /// Shows the card at this row; when it's shown already, it moves here.
    public func show(_ content: NSViewController, relativeTo rect: NSRect, of view: NSView, edge: NSRectEdge) {
        popover.contentViewController = content
        popover.show(relativeTo: rect, of: view, preferredEdge: edge)
        keys =
            keys
            ?? NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated { self?.close() }   // local monitors run on the main thread
                return event
            }
    }

    private func after(_ delay: TimeInterval, _ action: @escaping @MainActor () async -> Void) {
        pending?.cancel()
        pending = Task {
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await action()
        }
    }
}
