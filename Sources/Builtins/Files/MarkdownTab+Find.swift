import AppKit
import KelpKit
import WebKit

/// ⌘F on the page as shown (a doc, slides, a review, a canvas), as on a web page (`WebFind`): Edit › Find reaches
/// the tab through the responder chain when the page has the focus (the source finds in itself), the find card floats
/// over the page, and WebKit finds and selects the match.
extension MarkdownTab {
    @objc func performFindPanelAction(_ sender: Any?) {
        finding.perform(NSFindPanelAction(rawValue: UInt((sender as? NSMenuItem)?.tag ?? 1)))
    }
}
