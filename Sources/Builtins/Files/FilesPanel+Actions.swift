// The file tree's actions: rename in place, open, new file/folder/from template, move to Trash.
import AppKit
import Core
import DesignKit
import KelpKit
import Markdown
import Quartz
import WorkbenchKit

extension FilesPanel {
    // MARK: rename in place

    func beginRename(_ rel: String, open: Bool = false) {
        guard let target = node(at: rel) else { return }
        let row = outline.row(forItem: target)
        guard row >= 0 else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        guard let tf = (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField
        else { return }
        tf.isEditable = true
        tf.delegate = self
        renaming = (tf, URL(fileURLWithPath: root).appendingPathComponent(rel), open)
        view.window?.makeFirstResponder(tf)
        let name = tf.stringValue as NSString   // the name without its extension, like Finder
        tf.currentEditor()?.selectedRange = NSRange(
            location: 0, length: target.children == nil ? (name.deletingPathExtension as NSString).length : name.length)
    }

    func controlTextDidEndEditing(_ note: Notification) {
        guard let edit = renaming, note.object as? NSTextField === edit.field else { return }
        renaming = nil
        edit.field.isEditable = false
        view.window?.makeFirstResponder(outline)
        let name = edit.field.stringValue.trimmingCharacters(in: .whitespaces), root = root
        let dst = edit.url.deletingLastPathComponent().appendingPathComponent(name)
        // A name that's taken fails, and the daemon says so (Readme.md → README.md is the same file, renamed).
        let moving =
            !name.isEmpty && !name.contains("/") && name != edit.url.lastPathComponent
            ? move({ [FileMove(from: edit.url.path, to: dst.path)] }, undo: String(localized: "Rename")) : nil
        Task { [self] in
            let moved = await moving?.value.count == 1
            let url = moved ? dst : edit.url
            edit.field.stringValue = url.lastPathComponent
            let rel = String(url.path.dropFirst(root.count + 1))
            reloadTree { [weak self] in
                guard let self, let target = node(at: rel) else { return }
                outline.selectRowIndexes([outline.row(forItem: target)], byExtendingSelection: false)
            }
            if edit.open { openFile(rel) }
        }
    }

    /// The node at a relative path, its folders opened.
    func node(at rel: String) -> FileNode? {
        var list = nodes, found: FileNode?, acc = ""
        for part in rel.split(separator: "/") {
            acc = acc.isEmpty ? String(part) : acc + "/" + part
            guard let child = list.first(where: { $0.path == acc }) else { return nil }
            if child.children != nil, acc != rel { outline.expandItem(child) }
            found = child
            list = child.children ?? []
        }
        return found
    }

    func outlineViewSelectionDidChange(_ note: Notification) {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().reloadData()
        }
    }

    var selectedNode: FileNode? {
        (outline.clickedRow >= 0 ? outline.item(atRow: outline.clickedRow) : outline.item(atRow: outline.selectedRow))
            as? FileNode
    }
    var selectedDir: String {
        guard let node = selectedNode else { return "" }
        return node.children != nil ? node.path : (node.path as NSString).deletingLastPathComponent
    }
    @objc func openSelected() {
        guard let node = selectedNode, NSApp.currentEvent?.type != .rightMouseDown else { return }
        guard node.children == nil else {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
            return
        }
        // Like Xcode's navigator: the file opens, the keys stay here (↑↓, Space, ↩, ⌘C).
        openFile(node.path, focus: false)
    }
    /// Like Finder's new folder: "untitled" appears with its name selected; type one and it opens.
    @objc func newFile() { addFile(in: selectedDir) }
    func addFile(in dir: String) {
        let
            made = create(
                in: URL(fileURLWithPath: root).appendingPathComponent(dir).path, undo: String(localized: "New File")),
            root = root
        Task { [self] in
            guard let path = await made.value else { return }
            let rel = String(path.dropFirst(root.count + 1))
            reloadTree { [weak self] in self?.beginRename(rel, open: true) }
        }
    }
    /// Markdown templates from <repo>/.kelp/templates and ~/.kelp/templates with {{date}}, {{branch}}, {{title}}…
    @objc func newFromTemplate() { addFromTemplate(in: selectedDir) }
    func addFromTemplate(in dir: String) {
        let repo = app.repo(worktree?.repoId)
        let dirs = [
            URL(fileURLWithPath: root).appendingPathComponent(".kelp/templates"),
            Paths.root.appendingPathComponent("templates")
        ]
        let all = dirs.flatMap { Templates.list(in: $0) }
        guard !all.isEmpty else {
            // Nothing to decide, so no question: a note in the corner says where templates go.
            let how = String(
                localized:
                    "Add Markdown files to .kelp/templates in the repo or ~/.kelp/templates. Placeholders: {{date}}, {{time}}, {{branch}}, {{title}}, {{repo}}."
            )
            return Banner.show(String(localized: "No templates yet") + ". " + how)
        }
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        for template in all { pop.addItem(withTitle: template.deletingPathExtension().lastPathComponent) }
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        name.placeholderString = String(localized: "File name, e.g. plan-login.md")
        let box = NSStackView(views: [pop, name])
        box.orientation = .vertical
        box.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        let alert = NSAlert()
        alert.messageText = String(localized: "New from Template")
        alert.accessoryView = box
        alert.addButton(withTitle: String(localized: "Create"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        Task {
            guard await runSheet(alert) == .alertFirstButtonReturn, !name.stringValue.isEmpty,
                let text = await app.call(FilesRead(path: all[pop.indexOfSelectedItem].path))?.text
            else { return }
            var file = name.stringValue
            if (file as NSString).pathExtension.isEmpty { file += ".md" }
            let title = (file as NSString).deletingPathExtension.replacingOccurrences(of: "-", with: " ")
            let body = Templates.expand(
                text, vars: ["branch": worktree?.branch ?? "", "title": title, "repo": repo?.name ?? ""])
            let rel = dir.isEmpty ? file : dir + "/" + file
            // Its folders made too; a name that's taken fails rather than being written over.
            guard await app.call(FilesCreate(path: root + "/" + rel, text: body)) != nil else { return }
            reloadTree()
            openFile(rel)
        }
    }

    @objc func newFolder() { addFolder(in: selectedDir) }
    func addFolder(in dir: String) { Task { await newFolderNamed(in: dir) } }
    private func newFolderNamed(in dir: String) async {
        guard let name = await prompt(String(localized: "New folder"), String(localized: "In /\(dir)")), !name.isEmpty
        else { return }
        let path = URL(fileURLWithPath: root).appendingPathComponent(dir).appendingPathComponent(name).path
        guard await app.call(FilesCreate(path: path, folder: true)) != nil else { return }
        reloadTree()   // empty folders are invisible to git; it appears once it has a file
    }
    @objc func rename() {
        guard let node = selectedNode else {
            NSSound.beep()
            return
        }
        beginRename(node.path)
    }
    @objc func trashSelected() {
        guard let node = selectedNode else {
            NSSound.beep()
            return
        }
        let path = URL(fileURLWithPath: root).appendingPathComponent(node.path).path
        trash({ [path] }, undo: String(localized: "Move to Trash"))
    }
}
