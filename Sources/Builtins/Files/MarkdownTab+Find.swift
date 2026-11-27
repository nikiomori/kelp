import AppKit
import DesignKit
import WebKit

/// ⌘F on the page as shown (a doc, slides, a review, a canvas), as on a web page (`BrowserFind`): Edit › Find reaches
/// the tab through the responder chain when the page has the focus (the source finds in itself), the find card floats
/// over the page, and WebKit finds and selects the match.
extension MarkdownTab {
    /// The find cards over the pages, one a tab.
    private static let cards = NSMapTable<MarkdownTab, FindCard>.weakToStrongObjects()

    @objc func performFindPanelAction(_ sender: Any?) {
        switch NSFindPanelAction(rawValue: UInt((sender as? NSMenuItem)?.tag ?? 1)) {
        case .next?: step(forward: true)
        case .previous?: step(forward: false)
        default: findCard().begin(nil)
        }
    }

    private func findCard() -> FindCard {
        if let card = Self.cards.object(forKey: self) { return card }
        let card = FindCard()
        card.onSearch = { [weak self] _ in
            self?.web.evaluateJavaScript("getSelection()?.collapseToStart()", in: nil, in: Self.world) { _ in }
            self?.step(forward: true)
        }
        card.onStep = { [weak self] in self?.step(forward: $0) }
        card.onClose = { [weak self] in if let self { self.view.window?.makeFirstResponder(self.web) } }
        card.float(in: view, top: web, trailing: view)
        Self.cards.setObject(card, forKey: self)
        return card
    }

    private func step(forward: Bool) {
        guard let card = Self.cards.object(forKey: self), !card.isHidden else { return findCard().begin(nil) }
        let needle = card.field.stringValue
        guard !needle.isEmpty else { return card.show(count: "", canStep: false) }
        let options = WKFindConfiguration()
        options.backwards = !forward
        Task {
            let found: Bool
            do { found = try await web.find(needle, configuration: options).matchFound } catch { found = false }
            guard card.field.stringValue == needle else { return }   // a newer search answers for itself
            card.show(count: found ? "" : String(localized: "No matches"), canStep: found)
        }
    }
}
