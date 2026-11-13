// The file tree's outline: its rows, expanding folders, and drag and drop.
import AppKit
import Core
import DesignKit
import KelpKit
import Quartz

extension FilesPanel {
    // MARK: outline
    func outlineView(_ tree: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? FileNode)?.children?.count ?? (item == nil ? nodes.count : 0)
    }
    func outlineView(_ tree: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? FileNode)?.children?[index] ?? nodes[index]
    }
    func outlineView(_ tree: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? FileNode)?.children != nil }
    func outlineView(_ tree: NSOutlineView, viewFor tc: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let cell = NSTableCellView()
        let tf = NSTextField(labelWithString: node.name)
        let img = NSImageView()
        img.image = app.fileIcons.image(node.name, folder: node.children != nil, expanded: tree.isItemExpanded(node))
        tf.lineBreakMode = .byTruncatingMiddle
        // The name gives way, not its git letter.
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tf.font = .ui(TextSize.row)
        let badge = NSTextField(labelWithString: "")
        if let change = status[node.path] {
            let (letter, color) = change.badge
            badge.stringValue = letter
            badge.textColor = color
        } else if node.children != nil, changedFolders.contains(node.path) {
            badge.stringValue = "●"
            badge.textColor = .tertiaryLabelColor
            badge.setAccessibilityLabel(String(localized: "Has changes"))
        } else if node.ignored {
            tf.textColor = .secondaryLabelColor
            img.alphaValue = 0.5
        }
        badge.font = badge.stringValue == "●" ? .ui(7) : .ui(TextSize.micro, weight: .bold)
        for subview in [img, tf, badge] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(subview)
        }
        cell.textField = tf
        cell.imageView = img
        NSLayoutConstraint.activate([
            img.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            img.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            img.widthAnchor.constraint(equalToConstant: 16), img.heightAnchor.constraint(equalToConstant: 16),
            tf.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: tf.trailingAnchor, constant: 4),
            badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
    /// An ignored folder's files are read when it opens (node_modules can hold 100k).
    func outlineViewItemWillExpand(_ note: Notification) {
        guard let node = note.userInfo?["NSObject"] as? FileNode, node.unread, let current = worktree else { return }
        node.unread = false
        Task {
            let entries = await app.call(FilesIgnored(id: current.id, folder: node.path + "/")) ?? []
            guard worktree?.id == current.id else { return }
            opened[node.path] = entries
            node.read(entries)
            outline.reloadItem(node, reloadChildren: true)
        }
    }
    // themes may draw open folders differently
    func outlineViewItemDidExpand(_ note: Notification) { reloadRow(of: note) }
    func outlineViewItemDidCollapse(_ note: Notification) {
        if let node = note.userInfo?["NSObject"] as? FileNode, node.ignored, node.children != nil {
            node.unread = true   // read again when it opens: nothing pushes what changed in it
            opened = opened.filter { $0.key != node.path && !$0.key.hasPrefix(node.path + "/") }
        }
        reloadRow(of: note)
    }
    private func reloadRow(of note: Notification) {
        let row = outline.row(forItem: note.userInfo?["NSObject"])
        if row >= 0 { outline.reloadData(forRowIndexes: [row], columnIndexes: [0]) }
    }
    // drag files out (to terminals = into the agent prompt, to Finder) and within the tree (move)
    func outlineView(_ tree: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        (item as? FileNode).map { URL(fileURLWithPath: root).appendingPathComponent($0.path) as NSURL }
    }
    func outlineView(
        _ tree: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard (item as? FileNode)?.children != nil || item == nil else { return [] }
        return info.draggingSource as? NSOutlineView === outline ? .move : .copy
    }
    func outlineView(_ tree: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex: Int) -> Bool {
        let destDir = URL(fileURLWithPath: root).appendingPathComponent((item as? FileNode)?.path ?? "")
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        if info.draggingSource as? NSOutlineView === outline {
            let pairs = urls.filter {
                $0.deletingLastPathComponent().standardizedFileURL != destDir.standardizedFileURL
            }
            .map { FileMove(from: $0.path, to: destDir.appendingPathComponent($0.lastPathComponent).path) }
            move({ pairs }, unique: true, undo: String(localized: "Move"))
            return true
        }
        copy(urls.map(\.path), into: destDir.path, undo: String(localized: "Copy"))
        return true
    }
}
