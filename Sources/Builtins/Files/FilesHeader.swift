import AppKit
import DesignKit
import KelpKit

/// The bar over the tree, as every inspector panel has one: the search field, New File, and the rest in ⋯.
extension FilesPanel {
    func header() -> NSView {
        let plus = IconButton(.symbol("plus"), tip: String(localized: "New File"), target: self, action: #selector(newFile))
        let more = IconButton(.symbol("ellipsis.circle"), tip: String(localized: "More"), target: self, action: #selector(showMore(_:)))
        return Bar.panel([search], [plus, more], stretching: search)
    }

    @objc private func showMore(_ sender: NSButton) {
        let m = NSMenu()
        m.addItem(withTitle: String(localized: "New Folder…"), action: #selector(newFolder), keyEquivalent: "").target = self
        m.addItem(withTitle: String(localized: "New from Template…"), action: #selector(newFromTemplate), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: String(localized: "Collapse All"), action: #selector(collapseAll), keyEquivalent: "").target = self
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func collapseAll() { outline.collapseItem(nil, collapseChildren: true) }
}
