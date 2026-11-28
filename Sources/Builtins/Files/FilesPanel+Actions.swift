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
            reloadTree { [weak self] in self?.select(rel) }
            if edit.open { openFile(rel) }
        }
    }

    /// Selects the node at a relative path, opening the folders on the way to it.
    func select(_ rel: String) {
        guard let target = node(at: rel) else { return }
        outline.selectRowIndexes([outline.row(forItem: target)], byExtendingSelection: false)
    }

    /// Returns the node at a relative path, and opens the folders on the way to it.
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
        // Like Xcode's navigator: the file opens, the keys stay here (↑↓, Space, ↩, ⌘C). With ⌥ it opens beside, in a
        // split (in a list ⌘ and ⇧ pick several rows).
        let beside = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        app.workbench.open(TabURI.file(root + "/" + node.path), split: beside ? .right : nil, focus: false)
    }
    /// Adds a file the way Finder adds a new folder: "untitled" appears with its name selected, and once a name is
    /// typed, the file opens.
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
    /// Makes a file from a Markdown template in <repo>/.kelp/templates or ~/.kelp/templates, filling in {{date}},
    /// {{branch}}, {{title}}…
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
        let wide = Metrics.alertAccessory
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: wide, height: 26))
        for template in all { pop.addItem(withTitle: template.deletingPathExtension().lastPathComponent) }
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: wide, height: 24))
        name.placeholderString = String(localized: "File name, e.g. plan-login.md")
        let box = NSStackView(views: [pop, name])
        box.orientation = .vertical
        box.frame = NSRect(x: 0, y: 0, width: wide, height: 60)
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
            // The file's folders are made too. A name that's taken fails rather than being written over.
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
        await makeFolder(dir.isEmpty ? name : dir + "/" + name)
    }
    /// Makes the folder at `rel` and selects it. git doesn't list an empty folder, so the panel keeps it in the tree.
    func makeFolder(_ rel: String) async {
        guard await app.call(FilesCreate(path: root + "/" + rel, folder: true)) != nil else { return }
        madeFolders.insert(rel)
        reloadTree { [weak self] in self?.select(rel) }
    }
    /// The listed `paths` with the empty folders New Folder made, each ending with "/" as a folder does. One that holds
    /// a listed file now isn't kept any longer, and one in an ignored folder shows when that folder is read.
    func withMadeFolders(_ paths: [String], ignored: [String]) -> [String] {
        guard !madeFolders.isEmpty else { return paths }
        madeFolders = madeFolders.filter { folder in
            let inside = folder + "/"
            return !paths.contains { $0.hasPrefix(inside) }
                && !ignored.contains { $0.hasSuffix("/") && inside.hasPrefix($0) }
        }
        return paths + madeFolders.sorted().map { $0 + "/" }
    }
    /// Asks the daemon whether each folder New Folder made is still there (on a remote host too), and shows `event`
    /// again without the ones that are gone.
    func forgetGoneFolders(_ event: FilesEvent) {
        let made = madeFolders, ticket = listing
        Task {
            var gone = Set<String>()
            for folder in made where await app.quiet(FilesIgnored(id: event.worktree, folder: folder + "/")) == nil {
                gone.insert(folder)
            }
            guard !gone.isEmpty, worktree?.id == event.worktree else { return }
            madeFolders.subtract(gone)
            if ticket == listing { listed(event) }   // a newer listing leaves them out itself
        }
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

    /// Lists the files now, then calls `done`. The panel's own operations use this to select or rename what they made,
    /// because the daemon's push only follows a moment later. Otherwise the tree follows what's pushed.
    func reloadTree(then done: (() -> Void)? = nil) {
        guard let current = worktree else {
            nodes = []
            outline.reloadData()
            return
        }
        Task {
            let result = await app.tryCall(FilesList(id: current.id))
            // What the operation made or moved may be in an open ignored folder, which the listing doesn't cover, so
            // those folders are read again.
            for folder in opened.keys {
                let entries = await app.quiet(FilesIgnored(id: current.id, folder: folder + "/"))
                guard worktree?.id == current.id else { return }
                opened[folder] = entries   // a folder that's gone returns nil, which removes it from `opened`
            }
            treeBase = nil   // the ignored folders were just read, so build a whole tree with them
            let event = FilesEvent(
                worktree: current.id, paths: result.value, ignored: await app.quiet(FilesIgnored(id: current.id)),
                error: result.error)
            await listed(event)?.value
            done?()
        }
    }
}
