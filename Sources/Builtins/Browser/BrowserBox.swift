import AppKit

/// Holds a browser tab. While the focus is in it (the page or its address), ⌘R reloads the page before the menu bar
/// gives it to Run, as in Safari; elsewhere ⌘R stays Run. ⌘F there finds on the page.
final class BrowserBox: NSView {
    var reload: () -> Void = {}
    var find: (NSFindPanelAction?) -> Void = { _ in }

    /// Edit › Find and ⌘G from the page (WKWebView doesn't answer them): the tab's find card.
    @objc func performFindPanelAction(_ sender: Any?) {
        find(NSFindPanelAction(rawValue: UInt((sender as? NSMenuItem)?.tag ?? 1)))
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods == .command, let focus = window?.firstResponder as? NSView, focus.isDescendant(of: self) else {
            return super.performKeyEquivalent(with: e)
        }
        // ⌘F by key code (a Russian layout sends another letter): the address field's editor would take it otherwise.
        if e.keyCode == 3 {
            find(nil)
            return true
        }
        guard e.charactersIgnoringModifiers?.lowercased() == "r" else { return super.performKeyEquivalent(with: e) }
        reload()
        return true
    }
}
