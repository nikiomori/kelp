import AppKit
import KelpKit
import WebKit

/// ⌘F on the page as shown (a doc, slides, a review, a canvas), as on a web page (`WebFind`): Edit › Find reaches
/// the tab through the responder chain when the page has the focus (the source finds in itself), the find card floats
/// over the page, and WebKit finds and selects the match.
extension MarkdownTab {
    /// The finds over the pages, one a tab.
    private static let finds = NSMapTable<MarkdownTab, WebFind>.weakToStrongObjects()

    @objc func performFindPanelAction(_ sender: Any?) {
        if Self.finds.object(forKey: self) == nil {
            let find = WebFind(web: web, world: Self.world, over: view) { [weak self] in
                if let self { self.view.window?.makeFirstResponder(self.web) }
            }
            Self.finds.setObject(find, forKey: self)
        }
        Self.finds.object(forKey: self)?.perform(NSFindPanelAction(rawValue: UInt((sender as? NSMenuItem)?.tag ?? 1)))
    }
}
