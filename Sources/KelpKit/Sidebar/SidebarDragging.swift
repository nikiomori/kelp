import AppKit
import SwiftUI
import Core
import WorkbenchKit

/// What a click on a project's row has set off: the fold waiting for a possible second click, the fold it made, and
/// whether the click opened the row's workspace (then it doesn't fold).
@MainActor
struct ClickFold {
    let pending = Debounce()
    var done: (key: String, at: Date)?
    var opened = false
}

/// Dragging rows among their own and folders from Finder.
extension SidebarController {
    // MARK: dragging: rows among their own, folders from Finder

    static let rowType = NSPasteboard.PasteboardType("dev.kelp.sidebar-row")

    /// Projects and pinned or project workspaces move; not while the list is narrowed (the hidden ones would jump).
    func outlineView(_ o: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard query.isEmpty, filter == .all, let n = item as? Node, n.id != nil else { return nil }
        let p = NSPasteboardItem(); p.setString(n.key, forType: Self.rowType)
        return p
    }
    func outlineView(_ o: NSOutlineView, draggingSession s: NSDraggingSession, willBeginAt p: NSPoint, forItems items: [Any]) { card.close() }

    /// The dragged row and where it lands among its siblings: before the block (the row and what's under it) the
    /// pointer is over, or after it past its middle. Projects stay under the sections; a workspace stays in its project.
    private func move(_ info: NSDraggingInfo) -> (node: Node, parent: Node?, index: Int)? {
        let pb = info.draggingPasteboard
        guard info.draggingSource as? NSOutlineView === outline, pb.pasteboardItems?.count == 1,
              let key = pb.string(forType: Self.rowType), let n = node(key) else { return nil }
        let parent = outline.parent(forItem: n) as? Node
        let siblings = parent?.children ?? roots
        let firstProject = parent == nil ? roots.firstIndex { if case .project = $0.kind { true } else { false } } ?? 0 : 0
        let p = outline.convert(info.draggingLocation, from: nil)
        var over = outline.item(atRow: outline.row(at: p)) as? Node
        while let o = over, outline.parent(forItem: o) as? Node !== parent { over = outline.parent(forItem: o) as? Node }
        guard let o = over, let i = siblings.firstIndex(of: o) else { return parent == nil ? (n, nil, siblings.count) : nil }
        var last = o
        while outline.isItemExpanded(last), let c = last.children.last { last = c }
        let block = outline.rect(ofRow: outline.row(forItem: o)).union(outline.rect(ofRow: outline.row(forItem: last)))
        return (n, parent, max(firstProject, p.y < block.midY ? i : i + 1))
    }

    private static func folders(_ info: NSDraggingInfo) -> [String] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }.map(\.path)
    }
    func outlineView(_ o: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        if info.draggingPasteboard.types?.contains(Self.rowType) == true {
            guard let m = move(info) else { return [] }
            o.setDropItem(m.parent, dropChildIndex: m.index)
            return .move
        }
        guard !Self.folders(info).isEmpty else { return [] }
        o.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)   // the whole list, not a row
        return .copy
    }
    func outlineView(_ o: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        if let m = move(info) {
            var rows = m.parent?.children ?? roots
            guard let from = rows.firstIndex(of: m.node) else { return false }
            rows.insert(m.node, at: m.index); rows.remove(at: from < m.index ? from : from + 1)
            let ids = rows.compactMap(\.id)
            if case .section = m.parent?.kind { pinned = ids + pinned.filter { !ids.contains($0) }; refresh() } else { app.reorder(ids) }
            return true
        }
        let folders = Self.folders(info)
        folders.forEach(app.workbench.addProject(path:))
        return !folders.isEmpty
    }

    /// One click on a project's row folds or unfolds it, unless that click opened the workspace the row stands for. A
    /// double click renames it instead: the fold waits a moment for a second click, and one that comes later undoes it.
    @objc func clicked() {
        defer { clickFold.opened = false }
        guard NSApp.currentEvent?.clickCount == 1, !clickFold.opened, let node = outline.item(atRow: outline.clickedRow) as? Node,
              case .project = node.kind, !node.children.isEmpty else { return }
        clickFold.pending.after(min(NSEvent.doubleClickInterval, 0.3)) { [weak self] in
            self?.toggle(node)
            self?.clickFold.done = (node.key, Date())
        }
    }

    @objc func doubleClicked() {
        guard let node = outline.item(atRow: outline.clickedRow) as? Node else { return }
        clickFold.pending.cancel()
        if let d = clickFold.done, d.key == node.key, Date().timeIntervalSince(d.at) < NSEvent.doubleClickInterval { toggle(node) }
        clickFold.done = nil
        // A project's row edits the name it shows: the project's, even when it stands for its only workspace.
        switch node.kind {
        case .workspace(let id): startRename(id)
        case .project(let id): startRename(id, project: true)
        default: break
        }
    }
}
