import AppKit
import DesignKit
import WebKit

/// ⌘F on a web view, for the tabs that show one: the find card floats over `over` the first time Edit › Find reaches
/// the tab (`perform`), and WebKit finds and selects the match. WebKit says only whether there is a match, so the card
/// shows no count.
@MainActor
package final class WebFind {
    private let web: WKWebView, world: WKContentWorld, over: NSView, onClose: () -> Void
    private var card: FindCard?

    /// `onClose` hears the card close (it gives the page the keys back); `world` is where its script runs.
    package init(web: WKWebView, world: WKContentWorld, over: NSView, onClose: @escaping () -> Void) {
        (self.web, self.world, self.over, self.onClose) = (web, world, over, onClose)
    }

    package func perform(_ action: NSFindPanelAction?) {
        switch action {
        case .next?: step(forward: true)
        case .previous?: step(forward: false)
        default: shown().begin(nil)
        }
    }

    private func shown() -> FindCard {
        if let card { return card }
        let card = FindCard()
        card.onSearch = { [weak self] _ in
            guard let self else { return }
            // Search from the match shown, so typing a longer word finds the same match again instead of the next one.
            web.evaluateJavaScript("getSelection()?.collapseToStart()", in: nil, in: world) { _ in }
            step(forward: true)
        }
        card.onStep = { [weak self] in self?.step(forward: $0) }
        card.onClose = onClose
        card.float(in: over, top: web, trailing: over)
        self.card = card
        return card
    }

    private func step(forward: Bool) {
        guard let card, !card.isHidden else { return shown().begin(nil) }
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
