import AppKit
import Core
import DesignKit
import KelpKit
import Markdown
import Quartz
import WorkbenchKit

/// The workspace's files: tree with git status (click opens a tab), file operations, and project search.
@MainActor
final class FilesPanel: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource,
    NSTableViewDelegate, NSSearchFieldDelegate,
    NSMenuDelegate
{
    let app: AppModel
    init(app: AppModel) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    let outline = FilesOutline()
    /// The row whose name is being edited in place (a rename, or a new file).
    var renaming: (field: NSTextField, url: URL, open: Bool)?
    /// Rows fading on their way to the Trash.
    var fadedRows: [NSTableRowView] = []
    let results = ResultsTable()
    let search = NSSearchField()
    let leftScroll = NSScrollView(), resultsScroll = NSScrollView()
    var nodes: [FileNode] = []
    var status: [String: FileChange] = [:]
    /// Folders with a changed file somewhere under them (a grey dot).
    private var changedFolders = Set<String>()
    /// The paths the tree was built from (listed, ignored): an edit that adds or removes none only changes badges.
    var shownPaths: ([String], [String]?)?
    /// Those paths in lower case, for the name filter: made once per listing, not for every path on every key.
    var lowered: (of: [String], paths: [String]) = ([], [])
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
        outline.plainList("f", in: leftScroll)
        results.plainList("r", in: resultsScroll)
        styleLists()
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(openSelected)
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        outline.onSpace = { [weak self] in self?.togglePreview() }
        outline.onReturn = { [weak self] in if self?.isNarrowed == true { self?.openSelected() } else { self?.rename() }
        }
        outline.onDelete = { [weak self] in self?.trashSelected() }
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        results.menu = NSMenu()
        results.menu?.delegate = self
        results.dataSource = self
        results.delegate = self
        results.target = self
        results.action = #selector(openResult)
        search.delegate = self
        resultsScroll.isHidden = true
        // One field, like Finder's: empty shows the tree, a search (↩) shows matches in their place, clearing it goes back.
        setUpSearchMode()
        search.target = self
        search.action = #selector(runSearch)
        search.sendsSearchStringImmediately = false
        search.controlSize = .small
        let content = NSView()
        let bar = header()
        setUpSearchRows()
        for subview in [bar, replaceRow, leftScroll, resultsScroll, patternError] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(subview)
        }
        noResults.place(in: content, under: bar)
        loadError.place(in: content, under: bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            leftScroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            leftScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            leftScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            leftScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            replaceRow.topAnchor.constraint(equalTo: bar.bottomAnchor),
            replaceRow.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            replaceRow.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            replaceRow.heightAnchor.constraint(equalToConstant: Metrics.row + Metrics.gap),
            patternError.topAnchor.constraint(equalTo: bar.bottomAnchor),
            patternError.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Metrics.inset),
            patternError.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -Metrics.inset),
            resultsTop, resultsScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            resultsScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            resultsScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        view = content
        track(owner: self) { [app] in
            app.workbench.workspaceId
        } changed: { [weak self] in
            self?.bind($0)
        }
        track(owner: self) { [app] in
            app.latest(FilesEvent.self, app.workbench.workspaceId ?? "")
        } changed: { [weak self] in
            self?.listed($0)
        }
        track(owner: self) { [app] in
            app.latest(GitEvent.self, app.workbench.workspaceId ?? "")?.changes
        } changed: { [weak self] in
            self?.badges($0)
        }
        track(owner: self) {
            app.fileIcons.revision
        } changed: { [weak self] _ in
            self?.reloadIcons()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === results.menu { return fillResult(menu, row: results.clickedRow) }
        fill(menu, row: outline.clickedRow)
    }

    /// The tree's right-click menu, for what's under the pointer. Over empty space `clickedRow` is -1 and `selectedNode`
    /// answers with the selected row, so nothing here goes through it: Move to Trash would reach a file nobody clicked.
    func fill(_ menu: NSMenu, row: Int) {
        menu.removeAllItems()
        guard worktree != nil else { return }
        guard let node = outline.item(atRow: row) as? FileNode else { return folderItems(menu, "") }
        if node.children == nil { fileItems(menu, node.path) } else { folderItems(menu, node.path) }
    }

    /// What goes into a folder, the project's own over empty space.
    private func folderItems(_ menu: NSMenu, _ dir: String) {
        menu.add(String(localized: "New File")) { [weak self] in self?.addFile(in: dir) }
        menu.add(String(localized: "New Folder…")) { [weak self] in self?.addFolder(in: dir) }
        menu.add(String(localized: "New from Template…")) { [weak self] in self?.addFromTemplate(in: dir) }
        menu.addItem(.separator())
        if dir.isEmpty { return WorkspaceActions.addLocate(to: menu, path: root) }
        changeItems(menu, dir)
    }

    private func fileItems(_ menu: NSMenu, _ rel: String) {
        let app = app, path = root + "/" + rel, wid = worktree?.id
        menu.add(String(localized: "Open")) { [weak self] in self?.openFile(rel) }
        menu.add(String(localized: "Open to the Side")) { app.workbench.open(TabURI.file(path), split: .right) }
        if let wid, status[rel] != nil {
            menu.add(String(localized: "Open Changes")) { app.workbench.open(TabURI.diff(wid, file: rel)) }
        }
        menu.addItem(withTitle: String(localized: "Quick Look"), action: #selector(togglePreview), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        changeItems(menu, rel)
    }

    /// A file's and a folder's alike: hand it over, name it, find it, throw it away.
    private func changeItems(_ menu: NSMenu, _ rel: String) {
        let app = app, path = root + "/" + rel
        menu.add(String(localized: "Send to Agent")) { FileActions(app).sendToAgent(path) }
        menu.add(String(localized: "Rename")) { [weak self] in self?.beginRename(rel) }
        menu.addItem(.separator())
        WorkspaceActions.addLocate(
            to: menu, path: path,
            copies: [
                (String(localized: "Relative Path"), { @MainActor in copyText(rel) }),
                (String(localized: "Web Link"), { @MainActor in FileActions(app).copyWebLink(path) })
            ])
        menu.addItem(.separator())
        menu.add(String(localized: "Move to Trash")) { [weak self] in
            self?.trash({ [path] }, undo: String(localized: "Move to Trash"))
        }
    }

    private func reloadIcons() {
        outline.reloadData(forRowIndexes: IndexSet(0..<outline.numberOfRows), columnIndexes: [0])
    }

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
        searchOptions = next.map { SearchOptions(app, workspace: $0.id) } ?? SearchOptions()
        showSearchOptions()
        matches = []
        results.reloadData()
        watchShown()
        if let next {
            badges(app.latest(GitEvent.self, next.id)?.changes)
            listed(app.latest(FilesEvent.self, next.id))
        }
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
    private func watchShown() {
        filesWatch.key = shown ? worktree?.id : nil
        gitWatch.key = shown ? worktree?.id : nil
    }

    /// The files listed now, then `done`: after an operation of its own, which selects or renames what it made (the
    /// daemon's push follows a moment later). Otherwise the tree follows what's pushed.
    func reloadTree(then done: (() -> Void)? = nil) {
        guard let current = worktree else {
            nodes = []
            outline.reloadData()
            return
        }
        Task {
            let result = await app.tryCall(FilesList(id: current.id))
            // What it made or moved may be in an open ignored folder, which the list doesn't say: those are read again.
            for folder in opened.keys {
                let entries = await app.quiet(FilesIgnored(id: current.id, folder: folder + "/"))
                guard worktree?.id == current.id else { return }
                opened[folder] = entries   // gone: nil drops it
            }
            shownPaths = nil
            listed(
                FilesEvent(
                    worktree: current.id, paths: result.value, ignored: await app.quiet(FilesIgnored(id: current.id)),
                    error: result.error))
            done?()
        }
    }

    /// The workspace's files as listed (pushed, or read after an operation): the tree, or why there's none.
    private func listed(_ event: FilesEvent?) {
        // Another workspace's (switched meanwhile), or a rename in place, which a reload would end (it reads after).
        guard let event, event.worktree == worktree?.id, renaming == nil else { return }
        showLoadError(event.error)
        // an agent saving a file changes its badge, not the tree
        guard let paths = event.paths, shownPaths.map({ $0 != paths || $1 != event.ignored }) ?? true else { return }
        shownPaths = (paths, event.ignored)
        let expanded = Set(
            (0..<outline.numberOfRows).compactMap {
                (outline.item(atRow: $0) as? FileNode).flatMap { outline.isItemExpanded($0) ? $0.path : nil }
            })
        let selected = (outline.item(atRow: outline.selectedRow) as? FileNode)?.path
        let places = outline.rowPlaces(rowKey)
        showFadedRows()
        nodes = treeShown(paths, ignored: event.ignored ?? [])
        // outer first
        for folder in opened.keys.sorted(by: { $0.count < $1.count }) {
            FileNode.find(folder, in: nodes).map { if $0.ignored { $0.read(opened[folder] ?? []) } }
        }
        outline.reloadData()
        @MainActor func expand(_ ns: [FileNode]) {
            for node in ns where node.children != nil && expanded.contains(node.path) {
                outline.expandItem(node)
                expand(node.children ?? [])
            }
        }
        expand(nodes)
        if isNarrowed { outline.expandItem(nil, expandChildren: true) }
        if let selected, let found = node(at: selected) {
            outline.selectRowIndexes([outline.row(forItem: found)], byExtendingSelection: false)
        }
        outline.settleRows(from: places, rowKey)
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().reloadData()
        }
    }

    /// Git's letters on the rows (only the letters: Source Control says what failed), and folders holding a change.
    private func badges(_ changes: [FileChange]?) {
        status = Dictionary((changes ?? []).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        changedFolders = Set(
            status.keys.flatMap { path in path.indices.filter { path[$0] == "/" }.map { String(path[..<$0]) } })
        reloadIcons()
    }

    func openFile(_ rel: String, line: Int? = nil, focus: Bool = true) {
        app.workbench.open(TabURI.file(root + "/" + rel, line: line), focus: focus)
    }

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
        tf.font = .ui(12)
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
        badge.font = badge.stringValue == "●" ? .ui(7) : .ui(10, weight: .bold)
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

    // MARK: rename in place

    private func beginRename(_ rel: String, open: Bool = false) {
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
    private func node(at rel: String) -> FileNode? {
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
    @objc private func openSelected() {
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
    private func addFile(in dir: String) {
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
    private func addFromTemplate(in dir: String) {
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
    private func addFolder(in dir: String) { Task { await newFolderNamed(in: dir) } }
    private func newFolderNamed(in dir: String) async {
        guard let name = await prompt(String(localized: "New folder"), String(localized: "In /\(dir)")), !name.isEmpty
        else { return }
        let path = URL(fileURLWithPath: root).appendingPathComponent(dir).appendingPathComponent(name).path
        guard await app.call(FilesCreate(path: path, folder: true)) != nil else { return }
        reloadTree()   // empty folders are invisible to git; it appears once it has a file
    }
    @objc private func rename() {
        guard let node = selectedNode else {
            NSSound.beep()
            return
        }
        beginRename(node.path)
    }
    @objc private func trashSelected() {
        guard let node = selectedNode else {
            NSSound.beep()
            return
        }
        let path = URL(fileURLWithPath: root).appendingPathComponent(node.path).path
        trash({ [path] }, undo: String(localized: "Move to Trash"))
    }
    /// The files couldn't be listed (a folder moved away, git refusing it): say why where the tree would be, not an empty tree.
    let loadError = EmptyStateView()
    /// A search that found nothing says so (and the tree is one click away), rather than an empty list.
    let noResults = EmptyStateView()
    let typing = Debounce()
    var searchOptions = SearchOptions()
    /// What the field looks through: names narrow the tree in place, contents list matches instead of it.
    var byName = UserDefaults.standard.bool(forKey: "files.searchByName")
    private(set) lazy var resultsTop = resultsScroll.topAnchor.constraint(equalTo: leftScroll.topAnchor)
    private(set) lazy var caseToggle = TextToggle("Aa", tip: String(localized: "Match Case")) { [weak self] in
        self?.toggle(\.matchCase)
    }
    private(set) lazy var wordToggle = TextToggle("ab", tip: String(localized: "Whole Word")) { [weak self] in
        self?.toggle(\.wholeWord)
    }
    private(set) lazy var regexToggle = TextToggle(".*", tip: String(localized: "Regular Expression")) { [weak self] in
        self?.toggle(\.regex)
    }
    /// Under the search, while it has found something.
    let replaceField = NSSearchField()
    private(set) lazy var replaceButton = ClosureButton(title: String(localized: "Replace All…")) { [weak self] in
        self?.replaceAll()
    }
    lazy var replaceRow = NSStackView(views: [replaceField, replaceButton])
    /// Under the field: a pattern that isn't valid, while the last results stay.
    let patternError = NSTextField(labelWithString: "")
}
