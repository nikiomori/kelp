import AppKit
import DesignKit
import WebKit

/// ⌘F on a page: Edit › Find reaches the tab through the responder chain (`BrowserBox`), the card floats over the page,
/// WebKit finds and selects the match. WebKit says only whether there is one, so the card counts nothing.
extension BrowserTab {
    func find(_ action: NSFindPanelAction?) {
        switch action {
        case .next?: step(forward: true)
        case .previous?: step(forward: false)
        default: findCard().begin(nil)
        }
    }

    private func findCard() -> FindCard {
        if let finding { return finding }
        let card = FindCard()
        card.onSearch = { [weak self] _ in
            // From the match shown: a longer word typed in finds it again instead of the next one.
            self?.web.evaluateJavaScript("getSelection()?.collapseToStart()", in: nil, in: Self.world) { _ in }
            self?.step(forward: true)
        }
        card.onStep = { [weak self] in self?.step(forward: $0) }
        card.onClose = { [weak self] in self?.focus() }
        card.float(in: view, top: web, trailing: view)
        finding = card
        return card
    }

    private func step(forward: Bool) {
        guard let card = finding, !card.isHidden else { return findCard().begin(nil) }
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
