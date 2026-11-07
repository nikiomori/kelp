import AppKit
import Core
import SwiftUI
import WorkbenchKit

/// Dragging rows among their own and folders from Finder.
extension SidebarController {
    // MARK: dragging: rows among their own, folders from Finder

    static let rowType = NSPasteboard.PasteboardType("dev.kelp.sidebar-row")

    /// Projects and a project's groups move.
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? Node, node.id != nil else { return nil }
        if case .project(let id) = node.kind, NoProject.holds(app.repo(id)) { return nil }   // always last
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(node.key, forType: Self.rowType)
        return pasteboardItem
    }
    func outlineView(
        _ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt point: NSPoint,
        forItems items: [Any]
    ) { card.close() }

    /// The dragged row and where it lands among its siblings: before the block (the row and what's under it) the
    /// pointer is over, or after it past its middle. A workspace stays in its project.
    private func move(_ info: NSDraggingInfo) -> (node: Node, parent: Node?, index: Int)? {
        let pb = info.draggingPasteboard
        guard info.draggingSource as? NSOutlineView === outline, pb.pasteboardItems?.count == 1,
            let key = pb.string(forType: Self.rowType), let node = node(key)
        else { return nil }
        let parent = outline.parent(forItem: node) as? Node
        let siblings = parent?.children ?? roots
        let point = outline.convert(info.draggingLocation, from: nil)
        var over = outline.item(atRow: outline.row(at: point)) as? Node
        while let row = over, outline.parent(forItem: row) as? Node !== parent {
            over = outline.parent(forItem: row) as? Node
        }
        guard let target = over, let index = siblings.firstIndex(of: target) else {
            return parent == nil ? (node, nil, siblings.count) : nil
        }
        var last = target
        while outline.isItemExpanded(last), let child = last.children.last { last = child }
        let block = outline.rect(ofRow: outline.row(forItem: target)).union(
            outline.rect(ofRow: outline.row(forItem: last)))
        return (node, parent, point.y < block.midY ? index : index + 1)
    }

    private static func folders(_ info: NSDraggingInfo) -> [String] {
        let urls =
            info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL] ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }.map(\.path)
    }
    func outlineView(
        _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        if info.draggingPasteboard.types?.contains(Self.rowType) == true {
            guard let drop = move(info) else { return [] }
            outlineView.setDropItem(drop.parent, dropChildIndex: drop.index)
            return .move
        }
        guard !Self.folders(info).isEmpty else { return [] }
        outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)   // the whole list, not a row
        return .copy
    }
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int)
        -> Bool
    {
        if let drop = move(info) {
            var rows = drop.parent?.children ?? roots
            guard let from = rows.firstIndex(of: drop.node) else { return false }
            rows.insert(drop.node, at: drop.index)
            rows.remove(at: from < drop.index ? from : from + 1)
            app.reorder(rows.compactMap(\.id))
            return true
        }
        let folders = Self.folders(info)
        folders.forEach(app.workbench.addProject(path:))
        return !folders.isEmpty
    }
}
