import AppKit

/// Holds a browser tab. While the focus is in the tab (the page or its address field), ⌘R reloads the page before the
/// menu bar can give the key to Run, as in Safari. Elsewhere ⌘R stays Run. ⌘F in the tab finds on the page.
final class BrowserBox: NSView {
    var reload: () -> Void = {}
    var find: (NSFindPanelAction?) -> Void = { _ in }

    /// Answers Edit › Find and ⌘G from the page, which WKWebView doesn't answer, with the tab's find card.
    @objc func performFindPanelAction(_ sender: Any?) {
        find(NSFindPanelAction(rawValue: UInt((sender as? NSMenuItem)?.tag ?? 1)))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods == .command, let focus = window?.firstResponder as? NSView, focus.isDescendant(of: self) else {
            return super.performKeyEquivalent(with: event)
        }
        // ⌘F is matched by key code, because a Russian layout sends another letter. Otherwise the address field's
        // editor would take it.
        if event.keyCode == 3 {
            find(nil)
            return true
        }
        guard event.charactersIgnoringModifiers?.lowercased() == "r" else {
            return super.performKeyEquivalent(with: event)
        }
        reload()
        return true
    }
}
