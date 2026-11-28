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
            ?? (node.children != nil && changedFolders.contains(node.path)
                ? (FileRowCell.changesDot, .secondaryLabelColor) : nil)
        cell.show(
            node.name,
            icon: app.fileIcons.image(node.name, folder: node.children != nil, expanded: tree.isItemExpanded(node)),
            badge: badge, dimmed: badge == nil && node.ignored)
        return cell
    }
    /// Reads an ignored folder's files only when the folder opens, because node_modules can hold 100k.
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
    // Reloads the row, because themes may draw open folders differently.
    func outlineViewItemDidExpand(_ note: Notification) { reloadRow(of: note) }
    func outlineViewItemDidCollapse(_ note: Notification) {
        if let node = note.userInfo?["NSObject"] as? FileNode, node.ignored, node.children != nil {
            node.unread = true   // nothing pushes changes in it, so read it again when it opens
            opened = opened.filter { $0.key != node.path && !$0.key.hasPrefix(node.path + "/") }
        }
        reloadRow(of: note)
    }
    private func reloadRow(of note: Notification) {
        let row = outline.row(forItem: note.userInfo?["NSObject"])
        if row >= 0 { outline.reloadData(forRowIndexes: [row], columnIndexes: [0]) }
    }
    /// Applies a listing with a few files added or removed. They go in where they belong and out where they were, and
    /// only those rows move, so the rest keep their cells, open folders, selection and scroll. Returns false when the
    /// tree must be built again (a file became a folder).
    func patchTree(added: [String], removed: [String]) -> Bool {
        guard let edits = FileNode.patch(&nodes, added: added, removed: removed) else { return false }
        // Only rows in a folder on show are inserted or removed. A closed folder, or one inside a closed folder, is
        // reloaded instead, and asks for its rows again when it opens.
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

    // Dragging files out of the tree (to Finder, or to a terminal, which puts them in the agent's prompt), and within
    // the tree, which moves them.
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
/// is made once, and `show` sets everything it shows, because the outline reuses rows it set aside.
final class FileRowCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("files.row")
    private let name = NSTextField(labelWithString: ""), icon = NSImageView(), badge = NSTextField(labelWithString: "")
    /// The mark of a folder with changes inside: a 6 pt dot, drawn, in place of the letter a file has.
    static let changesDot = "●", dotSide: CGFloat = 6
    private let dot = NSImageView(
        image: NSImage(size: NSSize(width: FileRowCell.dotSide, height: FileRowCell.dotSide), flipped: false) { rect in
            NSBezierPath(ovalIn: rect).fill()
            return true
        })

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        name.lineBreakMode = .byTruncatingMiddle
        // The name gives way, not its git letter.
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.font = .ui(TextSize.row)
        dot.image?.isTemplate = true   // tinted by `contentTintColor`
        for subview in [icon, name, badge, dot] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        textField = name
        imageView = icon
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Metrics.gap),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 4),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.inset),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Shows a row. `dimmed` is for what git ignores, which is drawn dimmed as VS Code does.
    func show(_ text: String, icon image: NSImage, badge mark: (String, NSColor)?, dimmed: Bool) {
        name.stringValue = text
        name.isEditable = false   // the row may have been renamed in place before
        name.textColor = dimmed ? .secondaryLabelColor : .labelColor
        icon.image = image
        icon.alphaValue = dimmed ? 0.5 : 1
        let isDot = mark?.0 == Self.changesDot
        // The dot stands where the letter would, so the badge keeps its width as a space.
        badge.stringValue = isDot ? " " : mark?.0 ?? ""
        badge.textColor = mark?.1
        badge.font = .ui(TextSize.micro, weight: .bold)
        dot.isHidden = !isDot
        dot.contentTintColor = mark?.1
        // VoiceOver reads a bare "M" as a letter, so the letter says its word.
        badge.setAccessibilityLabel(isDot ? String(localized: "Has changes") : mark.flatMap { gitLetterWord($0.0) })
    }
}
