import AppKit
import Core
import DesignKit
import Quartz
import Markdown
import WorkbenchKit
import KelpKit

/// The workspace's files: tree with git status (click opens a tab), file operations, and project search.
@MainActor
final class FilesPanel: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let app: AppModel
    init(app: AppModel) { self.app = app; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    let outline = FilesOutline()
    /// The row whose name is being edited in place (a rename, or a new file).
    var renaming: (field: NSTextField, url: URL, open: Bool)?
    let results = ResultsTable()
    let search = NSSearchField()
    let leftScroll = NSScrollView(), resultsScroll = NSScrollView()
    private var nodes: [FileNode] = []
    private var status: [String: FileChange] = [:]
    /// Folders with a changed file somewhere under them (a grey dot).
    private var changedFolders = Set<String>()
    /// The paths the tree was built from (listed, ignored): an edit that adds or removes none only changes badges.
    private var shownPaths: ([String], [String]?)?
    /// What the open ignored folders hold, by folder: kept when the tree is built again, read again after an operation.
    private var opened: [String: [String]] = [:]
    var matches: [SearchMatch] = []
    /// Its files and their git status, pushed by the daemon while the panel is on screen (`WatchTopic.files`, `.git`):
    /// a hidden one costs no listing on every change, and the list comes again when it shows.
    private lazy var filesWatch = Watched(.files, in: app)
    private lazy var gitWatch = Watched(.git, in: app)
    private var shown = false
    var worktree: Worktree?
    var root: String { worktree?.path ?? "/" }

    override func loadView() {
        let app = self.app
        let col = NSTableColumn(identifier: .init("f"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        styleLists()
        outline.dataSource = self
        outline.delegate = self
        outline.target = self; outline.action = #selector(openSelected)
        outline.registerForDraggedTypes([.fileURL]); outline.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        outline.onSpace = { [weak self] in self?.togglePreview() }
        outline.onReturn = { [weak self] in self?.rename() }
        outline.onDelete = { [weak self] in self?.trashSelected() }
        outline.menu = treeMenu()
        leftScroll.documentView = outline
        leftScroll.hasVerticalScroller = true
        leftScroll.drawsBackground = false
        let rc = NSTableColumn(identifier: .init("r"))
        results.addTableColumn(rc)
        results.headerView = nil
        results.dataSource = self
        results.delegate = self
        results.target = self
        results.action = #selector(openResult)
        search.delegate = self
        resultsScroll.documentView = results
        resultsScroll.hasVerticalScroller = true
        resultsScroll.isHidden = true
        resultsScroll.drawsBackground = false
        // One field, like Finder's: empty shows the tree, a search (↩) shows matches in their place, clearing it goes back.
        search.placeholderString = String(localized: "Search in Files")
        search.target = self
        search.action = #selector(runSearch)
        search.sendsSearchStringImmediately = false
        search.controlSize = .small
        let v = NSView()
        let bar = header()
        for x in [bar, leftScroll, resultsScroll] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        noResults.place(in: v, under: bar)
        loadError.place(in: v, under: bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: v.topAnchor), bar.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            leftScroll.topAnchor.constraint(equalTo: bar.bottomAnchor), leftScroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            leftScroll.trailingAnchor.constraint(equalTo: v.trailingAnchor), leftScroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            resultsScroll.topAnchor.constraint(equalTo: leftScroll.topAnchor), resultsScroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            resultsScroll.trailingAnchor.constraint(equalTo: v.trailingAnchor), resultsScroll.bottomAnchor.constraint(equalTo: v.bottomAnchor)
        ])
        view = v
        track(owner: self) { [app] in app.workbench.workspaceId } changed: { [weak self] in self?.bind($0) }
        track(owner: self) { [app] in app.fileLists[app.workbench.workspaceId ?? ""] } changed: { [weak self] in self?.listed($0) }
        track(owner: self) { [app] in app.git[app.workbench.workspaceId ?? ""]?.changes } changed: { [weak self] in self?.badges($0) }
        track(owner: self) { app.fileIcons.revision } changed: { [weak self] _ in self?.reloadIcons() }
    }

    /// The tree's right-click menu, grouped like Finder's: open, create, change, locate, hand to the agent.
    private func treeMenu() -> NSMenu {
        let m = NSMenu()
        for group in [[("Open", #selector(openSelected))],
                      [("New File", #selector(newFile)),
                       (String(localized: "New Folder…"), #selector(newFolder)), (String(localized: "New from Template…"), #selector(newFromTemplate))],
                      [("Rename", #selector(rename)), (String(localized: "Move to Trash"), #selector(trashSelected)),
                       (String(localized: "Quick Look"), #selector(togglePreview))],
                      [("Reveal in Finder", #selector(reveal)), ("Copy Path", #selector(copyPath)),
                       (String(localized: "Copy Relative Path"), #selector(copyRelativePath))],
                      [("Send to Agent", #selector(insertPath)), ("Copy Web Link", #selector(copyWebLink))]] {
            if !m.items.isEmpty { m.addItem(.separator()) }
            for (t, a) in group { m.addItem(withTitle: loc(t), action: a, keyEquivalent: "").target = self }
        }
        let openIn = NSMenu()
        WorkspaceActions.addOpenIn(to: openIn, path: { [weak self] in self?.selectedPath }, prefix: "")
        if !openIn.items.isEmpty, let i = m.items.firstIndex(where: { $0.action == #selector(reveal) }) {
            m.insertItem(withTitle: String(localized: "Open In"), action: nil, keyEquivalent: "", at: i + 1).submenu = openIn
        }
        return m
    }

    /// ⇧⌘F (Find in Workspace): straight into this field; pressed again there, back to what you were doing.
    func findInFiles() {
        guard let w = view.window else { return }
        if w.firstResponder === search.currentEditor() { app.workbench.editor?.focusSelected(); return }
        w.makeFirstResponder(search); search.currentEditor()?.selectAll(nil)
    }

    private func reloadIcons() { outline.reloadData(forRowIndexes: IndexSet(0..<outline.numberOfRows), columnIndexes: [0]) }

    private func bind(_ wid: String?) {
        guard wid != worktree?.id else { return }
        let next = app.worktree(wid)
        // Another folder: drop the old tree now, or a click before the reload would act on its paths under the new root.
        if next?.path != worktree?.path {
            nodes = []
            status = [:]
            shownPaths = nil
            opened = [:]
            outline.reloadData()
        }
        worktree = next
        matches = []; results.reloadData()
        watchShown()
        if let next { badges(app.git[next.id]?.changes); listed(app.fileLists[next.id]) }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        shown = true
        watchShown()
    }
    override func viewDidDisappear() {
        super.viewDidDisappear()
        shown = false
        watchShown()
    }
    private func watchShown() { filesWatch.key = shown ? worktree?.id : nil; gitWatch.key = shown ? worktree?.id : nil }

    /// The files listed now, then `done`: after an operation of its own, which selects or renames what it made (the
    /// daemon's push follows a moment later). Otherwise the tree follows what's pushed.
    func reloadTree(then done: (() -> Void)? = nil) {
        guard let w = worktree else {
            nodes = []
            outline.reloadData()
            return
        }
        Task {
            let r = await app.tryCall(FilesList(id: w.id))
            // What it made or moved may be in an open ignored folder, which the list doesn't say: those are read again.
            for f in opened.keys {
                let entries = await app.quiet(FilesIgnored(id: w.id, folder: f + "/"))
                guard worktree?.id == w.id else { return }
                opened[f] = entries   // gone: nil drops it
            }
            shownPaths = nil
            listed(FilesEvent(worktree: w.id, paths: r.value, ignored: await app.quiet(FilesIgnored(id: w.id)), error: r.error))
            done?()
        }
    }

    /// The workspace's files as listed (pushed, or read after an operation): the tree, or why there's none.
    private func listed(_ e: FilesEvent?) {
        // Another workspace's (switched meanwhile), or a rename in place, which a reload would end (it reads after).
        guard let e, e.worktree == worktree?.id, renaming == nil else { return }
        showLoadError(e.error)
        // an agent saving a file changes its badge, not the tree
        guard let paths = e.paths, shownPaths.map({ $0 != paths || $1 != e.ignored }) ?? true else { return }
        shownPaths = (paths, e.ignored)
        let expanded = Set((0..<outline.numberOfRows).compactMap {
            (outline.item(atRow: $0) as? FileNode).flatMap { outline.isItemExpanded($0) ? $0.path : nil }
        })
        let selected = (outline.item(atRow: outline.selectedRow) as? FileNode)?.path
        nodes = FileNode.tree(paths, ignored: e.ignored ?? [])
        // outer first
        for f in opened.keys.sorted(by: { $0.count < $1.count }) { FileNode.find(f, in: nodes).map { if $0.ignored { $0.read(opened[f] ?? []) } } }
        outline.reloadData()
        @MainActor func expand(_ ns: [FileNode]) {
            for n in ns where n.children != nil && expanded.contains(n.path) {
                outline.expandItem(n)
                expand(n.children ?? [])
            }
        }
        expand(nodes)
        if let selected, let n = node(at: selected) { outline.selectRowIndexes([outline.row(forItem: n)], byExtendingSelection: false) }
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
    }

    /// Git's letters on the rows (only the letters: Source Control says what failed), and folders holding a change.
    private func badges(_ changes: [FileChange]?) {
        status = Dictionary((changes ?? []).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        changedFolders = Set(status.keys.flatMap { p in p.indices.filter { p[$0] == "/" }.map { String(p[..<$0]) } })
        reloadIcons()
    }

    func openFile(_ rel: String, line: Int? = nil, focus: Bool = true) { app.workbench.open(TabURI.file(root + "/" + rel, line: line), focus: focus) }

    // MARK: outline
    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? FileNode)?.children?.count ?? (item == nil ? nodes.count : 0) }
    func outlineView(_ o: NSOutlineView, child i: Int, ofItem item: Any?) -> Any { (item as? FileNode)?.children?[i] ?? nodes[i] }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? FileNode)?.children != nil }
    func outlineView(_ o: NSOutlineView, viewFor tc: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? FileNode else { return nil }
        let cell = NSTableCellView()
        let tf = NSTextField(labelWithString: n.name)
        let img = NSImageView()
        img.image = app.fileIcons.image(n.name, folder: n.children != nil, expanded: o.isItemExpanded(n))
        tf.lineBreakMode = .byTruncatingMiddle; tf.font = .ui(12)
        let badge = NSTextField(labelWithString: "")
        if let s = status[n.path] {
            let (letter, color) = s.badge
            badge.stringValue = letter
            badge.textColor = color
        } else if n.children != nil, changedFolders.contains(n.path) {
            badge.stringValue = "●"
            badge.textColor = .tertiaryLabelColor
            badge.setAccessibilityLabel(String(localized: "Has changes"))
        } else if n.ignored { tf.textColor = .secondaryLabelColor; img.alphaValue = 0.5 }
        badge.font = badge.stringValue == "●" ? .ui(7) : .ui(10, weight: .bold)
        for v in [img, tf, badge] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(v) }
        cell.textField = tf; cell.imageView = img
        NSLayoutConstraint.activate([
            img.leadingAnchor.constraint(equalTo: cell.leadingAnchor), img.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            img.widthAnchor.constraint(equalToConstant: 16), img.heightAnchor.constraint(equalToConstant: 16),
            tf.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 4), tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: tf.trailingAnchor, constant: 4),
            badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6), badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
    /// An ignored folder's files are read when it opens (node_modules can hold 100k).
    func outlineViewItemWillExpand(_ n: Notification) {
        guard let node = n.userInfo?["NSObject"] as? FileNode, node.unread, let w = worktree else { return }
        node.unread = false
        Task {
            let entries = await app.call(FilesIgnored(id: w.id, folder: node.path + "/")) ?? []
            guard worktree?.id == w.id else { return }
            opened[node.path] = entries; node.read(entries)
            outline.reloadItem(node, reloadChildren: true)
        }
    }
    // themes may draw open folders differently
    func outlineViewItemDidExpand(_ n: Notification) { reloadRow(of: n) }
    func outlineViewItemDidCollapse(_ n: Notification) {
        if let node = n.userInfo?["NSObject"] as? FileNode, node.ignored, node.children != nil {
            node.unread = true   // read again when it opens: nothing pushes what changed in it
            opened = opened.filter { $0.key != node.path && !$0.key.hasPrefix(node.path + "/") }
        }
        reloadRow(of: n)
    }
    private func reloadRow(of n: Notification) {
        let row = outline.row(forItem: n.userInfo?["NSObject"])
        if row >= 0 { outline.reloadData(forRowIndexes: [row], columnIndexes: [0]) }
    }
    // drag files out (to terminals = into the agent prompt, to Finder) and within the tree (move)
    func outlineView(_ o: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        (item as? FileNode).map { URL(fileURLWithPath: root).appendingPathComponent($0.path) as NSURL }
    }
    func outlineView(_ o: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard (item as? FileNode)?.children != nil || item == nil else { return [] }
        return info.draggingSource as? NSOutlineView === outline ? .move : .copy
    }
    func outlineView(_ o: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex: Int) -> Bool {
        let destDir = URL(fileURLWithPath: root).appendingPathComponent((item as? FileNode)?.path ?? "")
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        if info.draggingSource as? NSOutlineView === outline {
            let pairs = urls.filter { $0.deletingLastPathComponent().standardizedFileURL != destDir.standardizedFileURL }
                .map { FileMove(from: $0.path, to: destDir.appendingPathComponent($0.lastPathComponent).path) }
            move({ pairs }, unique: true, undo: String(localized: "Move"))
            return true
        }
        copy(urls.map(\.path), into: destDir.path, undo: String(localized: "Copy"))
        return true
    }

    // MARK: rename in place

    private func beginRename(_ rel: String, open: Bool = false) {
        guard let n = node(at: rel) else { return }
        let row = outline.row(forItem: n)
        guard row >= 0 else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false); outline.scrollRowToVisible(row)
        guard let tf = (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField else { return }
        tf.isEditable = true; tf.delegate = self
        renaming = (tf, URL(fileURLWithPath: root).appendingPathComponent(rel), open)
        view.window?.makeFirstResponder(tf)
        let name = tf.stringValue as NSString   // the name without its extension, like Finder
        tf.currentEditor()?.selectedRange = NSRange(location: 0, length: n.children == nil ? (name.deletingPathExtension as NSString).length : name.length)
    }

    func controlTextDidEndEditing(_ note: Notification) {
        guard let r = renaming, note.object as? NSTextField === r.field else { return }
        renaming = nil; r.field.isEditable = false
        view.window?.makeFirstResponder(outline)
        let name = r.field.stringValue.trimmingCharacters(in: .whitespaces), root = root
        let dst = r.url.deletingLastPathComponent().appendingPathComponent(name)
        // A name that's taken fails, and the daemon says so (Readme.md → README.md is the same file, renamed).
        let moving = !name.isEmpty && !name.contains("/") && name != r.url.lastPathComponent
            ? move({ [FileMove(from: r.url.path, to: dst.path)] }, undo: String(localized: "Rename")) : nil
        Task {
            let moved = await moving?.value.count == 1
            let url = moved ? dst : r.url
            r.field.stringValue = url.lastPathComponent
            let rel = String(url.path.dropFirst(root.count + 1))
            reloadTree { [weak self] in
                guard let self, let n = node(at: rel) else { return }
                outline.selectRowIndexes([outline.row(forItem: n)], byExtendingSelection: false)
            }
            if r.open { openFile(rel) }
        }
    }

    /// The node at a relative path, its folders opened.
    private func node(at rel: String) -> FileNode? {
        var list = nodes, found: FileNode?, acc = ""
        for part in rel.split(separator: "/") {
            acc = acc.isEmpty ? String(part) : acc + "/" + part
            guard let f = list.first(where: { $0.path == acc }) else { return nil }
            if f.children != nil, acc != rel { outline.expandItem(f) }
            found = f; list = f.children ?? []
        }
        return found
    }

    func outlineViewSelectionDidChange(_ n: Notification) {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
    }

    private var selectedPath: String? { selectedNode.map { root + "/" + $0.path } }
    var selectedNode: FileNode? { (outline.clickedRow >= 0 ? outline.item(atRow: outline.clickedRow) : outline.item(atRow: outline.selectedRow)) as? FileNode }
    var selectedDir: String {
        guard let n = selectedNode else { return "" }
        return n.children != nil ? n.path : (n.path as NSString).deletingLastPathComponent
    }
    @objc private func openSelected() {
        guard let n = selectedNode, NSApp.currentEvent?.type != .rightMouseDown else { return }
        guard n.children == nil else { if outline.isItemExpanded(n) { outline.collapseItem(n) } else { outline.expandItem(n) }; return }
        // Like Xcode's navigator: the file opens, the keys stay here (↑↓, Space, ↩, ⌘C).
        openFile(n.path, focus: false)
    }
    /// Like Finder's new folder: "untitled" appears with its name selected; type one and it opens.
    @objc func newFile() {
        let made = create(in: URL(fileURLWithPath: root).appendingPathComponent(selectedDir).path, undo: String(localized: "New File")), root = root
        Task {
            guard let path = await made.value else { return }
            let rel = String(path.dropFirst(root.count + 1))
            reloadTree { [weak self] in self?.beginRename(rel, open: true) }
        }
    }
    /// Markdown templates from <repo>/.kelp/templates and ~/.kelp/templates with {{date}}, {{branch}}, {{title}}…
    @objc func newFromTemplate() {
        let repo = app.repo(worktree?.repoId)
        let dirs = [URL(fileURLWithPath: root).appendingPathComponent(".kelp/templates"), Paths.root.appendingPathComponent("templates")]
        let all = dirs.flatMap { Templates.list(in: $0) }
        guard !all.isEmpty else {
            let a = NSAlert(); a.messageText = String(localized: "No templates yet")
            a.informativeText = String(
                localized: "Add Markdown files to .kelp/templates in the repo or ~/.kelp/templates. Placeholders: {{date}}, {{time}}, {{branch}}, {{title}}, {{repo}}.")
            Task { _ = await runSheet(a) }; return
        }
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        for t in all { pop.addItem(withTitle: t.deletingPathExtension().lastPathComponent) }
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24)); name.placeholderString = String(localized: "File name, e.g. plan-login.md")
        let box = NSStackView(views: [pop, name])
        box.orientation = .vertical
        box.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        let a = NSAlert()
        a.messageText = String(localized: "New from Template")
        a.accessoryView = box
        a.addButton(withTitle: String(localized: "Create")); a.addButton(withTitle: String(localized: "Cancel"))
        Task {
            guard await runSheet(a) == .alertFirstButtonReturn, !name.stringValue.isEmpty,
                let text = await app.call(FilesRead(path: all[pop.indexOfSelectedItem].path))?.text else { return }
            var file = name.stringValue; if (file as NSString).pathExtension.isEmpty { file += ".md" }
            let title = (file as NSString).deletingPathExtension.replacingOccurrences(of: "-", with: " ")
            let body = Templates.expand(text, vars: ["branch": worktree?.branch ?? "", "title": title, "repo": repo?.name ?? ""])
            let rel = selectedDir.isEmpty ? file : selectedDir + "/" + file
            // Its folders made too; a name that's taken fails rather than being written over.
            guard await app.call(FilesCreate(path: root + "/" + rel, text: body)) != nil else { return }
            reloadTree(); openFile(rel)
        }
    }

    @objc func newFolder() { Task { await newFolderNamed() } }
    private func newFolderNamed() async {
        let dir = selectedDir
        guard let name = await prompt(String(localized: "New folder"), String(localized: "In /\(dir)")), !name.isEmpty else { return }
        let path = URL(fileURLWithPath: root).appendingPathComponent(dir).appendingPathComponent(name).path
        guard await app.call(FilesCreate(path: path, folder: true)) != nil else { return }
        reloadTree()   // empty folders are invisible to git; it appears once it has a file
    }
    @objc private func rename() {
        guard let n = selectedNode else { NSSound.beep(); return }
        beginRename(n.path)
    }
    @objc private func trashSelected() {
        guard let n = selectedNode else { NSSound.beep(); return }
        let path = URL(fileURLWithPath: root).appendingPathComponent(n.path).path
        trash({ [path] }, undo: String(localized: "Move to Trash"))
    }
    @objc private func reveal() {
        guard let n = selectedNode else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root).appendingPathComponent(n.path)])
    }
    @objc private func copyPath() { copyText(selectedPath) }
    @objc private func copyRelativePath() { copyText(selectedNode?.path) }
    private func copyText(_ text: String?) {
        guard let text else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    @objc private func insertPath() {
        guard let p = selectedPath else { NSSound.beep(); return }
        FileActions(app).sendToAgent(p)
    }
    @objc private func copyWebLink() {
        guard let p = selectedPath else { NSSound.beep(); return }
        FileActions(app).copyWebLink(p)
    }
    /// The files couldn't be listed (a folder moved away, git refusing it): say why where the tree would be, not an empty tree.
    let loadError = EmptyStateView()
    /// A search that found nothing says so (and the tree is one click away), rather than an empty list.
    let noResults = EmptyStateView()
    let typing = Debounce()
}

/// Finder's keys in the tree: Space previews, ↩ renames, ⌘⌫ moves to the Trash.
final class FilesOutline: ListOutlineView {
    var onSpace: (() -> Void)?, onReturn: (() -> Void)?, onDelete: (() -> Void)?
    override func keyDown(with e: NSEvent) {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (e.keyCode, mods) {
        case (49, []): onSpace?()
        case (36, []), (76, []): onReturn?()
        case (51, .command): onDelete?()
        default: super.keyDown(with: e)
        }
    }
}

/// Return in the results opens the line (a click does too).
final class ResultsTable: NSTableView {
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 36 || e.keyCode == 76, let a = action { NSApp.sendAction(a, to: target, from: self); return }
        super.keyDown(with: e)
    }
}

/// The tree and the search results as the inspector's lists: rows 24 and 38 (with the text size), the rounded selection
/// (DesignKit's ListRowView), no background of their own over the panel.
extension FilesPanel {
    func styleLists() {
        for t in [outline, results] as [NSTableView] {
            t.style = .plain
            t.backgroundColor = .clear
            t.rowSizeStyle = .custom
        }
        outline.rowHeight = TextSize.of(Metrics.row)
        outline.indentationPerLevel = 12
        results.rowHeight = TextSize.of(Metrics.rowTwoLine)
    }

    func outlineView(_ o: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { ListRowView() }
}
