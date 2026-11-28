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

    /// Runs `show` after the wait, in a task that a later `open`, `closeSoon`, `cancel` or `close` cancels. With
    /// `patientWhileShown`, a card already up waits the whole `hoverOpen` before it moves to another item, so a pointer
    /// on its way to the card's buttons can cross other rows.
    public func open(patientWhileShown: Bool = false, _ show: @escaping @MainActor () async -> Void) {
        let warm = popover.isShown || Date() < warmUntil
        after(warm && !(patientWhileShown && popover.isShown) ? Motion.hoverOpenWarm : Motion.hoverOpen, show)
    }

    /// Called when the pointer left. The card goes in a moment, or with `unlessInside`, as `closeUnlessInside` says.
    public func closeSoon(unlessInside: Bool = false) {
        after(Motion.hoverClose) { [weak self] in if unlessInside { self?.closeUnlessInside() } else { self?.close() } }
    }

    /// Closes the card, but not while the pointer is in it (its buttons are for clicking); then it looks again until
    /// the pointer leaves. A card already gone, or left behind when Kelp went to the back, stops the looking.
    public func closeUnlessInside() {
        guard popover.isShown, NSApplication.shared.isActive,
            popover.contentViewController?.view.window?.frame.contains(NSEvent.mouseLocation) == true
        else {
            close()
            return
        }
        closeSoon(unlessInside: true)
    }

    /// The words selected in the card's text, if any.
    private func selectedWords() -> String? {
        guard popover.isShown, let root = popover.contentViewController?.view else { return nil }
        // The field being selected in holds the window's field editor, its first responder.
        guard let editor = root.window?.firstResponder as? NSText, editor.selectedRange.length > 0 else { return nil }
        return (editor.string as NSString).substring(with: editor.selectedRange)
    }

    /// Cancels what was to happen next, an open or a close.
    public func cancel() { pending?.cancel() }

    public func close() {
        pending?.cancel()
        if popover.isShown {
            warmUntil = Date().addingTimeInterval(Motion.hoverWarm)
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
        popover.animates = false   // it opens at once, where the pointer rests
        popover.show(relativeTo: rect, of: view, preferredEdge: edge)
        // Once up, it grows and shrinks to what comes in (a part read later) instead of jumping to the new size.
        popover.animates = !Motion.reduced
        keys =
            keys
            ?? NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let copy = event.isCopy
                let copied = MainActor.assumeIsolated {   // local monitors run on the main thread
                    // ⌘C with words selected in the card copies them, and the card stays. The card is never key, so
                    // the key goes to the window under it, and Edit › Copy would copy what that window has selected.
                    if copy, let words = self?.selectedWords() {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(words, forType: .string)
                        return true
                    }
                    self?.close()   // typing elsewhere closes it
                    return false
                }
                return copied ? nil : event
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

extension NSEvent {
    /// ⌘C and nothing else.
    package var isCopy: Bool {
        modifierFlags.intersection(.deviceIndependentFlagsMask) == .command && charactersIgnoringModifiers == "c"
    }
}
