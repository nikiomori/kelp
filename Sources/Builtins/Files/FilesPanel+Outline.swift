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
        let cell = tree.makeView(withIdentifier: FileRowCell.id, owner: nil) as? FileRowCell ?? FileRowCell()
        let badge: (String, NSColor)? =
            status[node.path]?.badge
            ?? (node.children != nil && changedFolders.contains(node.path) ? ("●", .tertiaryLabelColor) : nil)
        cell.show(
            node.name,
            icon: app.fileIcons.image(node.name, folder: node.children != nil, expanded: tree.isItemExpanded(node)),
            badge: badge, dimmed: badge == nil && node.ignored)
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
    /// A listing with a few files in or out: they go in where they belong and out where they were, and only those rows
    /// move (the rest keep their cells, the folders opened, the selection and the scroll). False: the tree is to be built
    /// again (a file became a folder).
    func patchTree(added: [String], removed: [String]) -> Bool {
        guard let edits = FileNode.patch(&nodes, added: added, removed: removed) else { return false }
        // Rows into a folder on show; a closed one (or one inside one) is asked again when it opens.
        let live = edits.map { edit in
            edit.parent.map { outline.row(forItem: $0) >= 0 && outline.isItemExpanded($0) } ?? true
        }
        outline.beginUpdates()
        for (edit, live) in zip(edits, live) where live {
            if edit.inserted {
                outline.insertItems(at: [edit.index], inParent: edit.parent, withAnimation: [])
            } else {
                outline.removeItems(at: [edit.index], inParent: edit.parent, withAnimation: [])
            }
        }
        outline.endUpdates()
        for case let (edit, false) in zip(edits, live) { outline.reloadItem(edit.parent, reloadChildren: true) }
        return true
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

/// The row for a file or folder: its icon, its name and git's status letter (a dot on a folder that holds a change). It
/// is made once, and `show` sets everything it shows, because the outline hands back the rows it set aside.
final class FileRowCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("files.row")
    private let name = NSTextField(labelWithString: ""), icon = NSImageView(), badge = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        name.lineBreakMode = .byTruncatingMiddle
        // The name gives way, not its git letter.
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.font = .ui(TextSize.row)
        for subview in [icon, name, badge] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        textField = name
        imageView = icon
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 4),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `dimmed`: what git ignores, drawn as VS Code does.
    func show(_ text: String, icon image: NSImage, badge mark: (String, NSColor)?, dimmed: Bool) {
        name.stringValue = text
        name.isEditable = false   // a row renamed in place before
        name.textColor = dimmed ? .secondaryLabelColor : .labelColor
        icon.image = image
        icon.alphaValue = dimmed ? 0.5 : 1
        let dot = mark?.0 == "●"
        badge.stringValue = mark?.0 ?? ""
        badge.textColor = mark?.1
        badge.font = dot ? .ui(7) : .ui(TextSize.micro, weight: .bold)
        badge.setAccessibilityLabel(dot ? String(localized: "Has changes") : nil)
    }
}
