import AppKit
import Core
import DesignKit
import KelpKit
import Quartz
import SwiftUI
import WorkbenchKit

/// The Files panel: the workspace's files as a tree with git status (a click opens a tab), file operations, and
/// project search.
@MainActor
final class FilesPanel: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate,
    NSMenuDelegate
{
    let app: AppModel
    /// The project's size on disk, shown in the panel's foot. The Files built-in owns it, and the Disk Usage tab reads
    /// it too.
    let disk: DiskSizes
    init(app: AppModel, disk: DiskSizes = DiskSizes()) {
        self.app = app
        self.disk = disk
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    /// Brings the Files panel up and hands it to `then` once it's built. The inspector builds the panel on the next
    /// run-loop turn, when the inspector follows the panel just chosen.
    static func shown(_ app: AppModel, _ then: @escaping @MainActor (FilesPanel) -> Void) {
        app.workbench.showPanel("files")
        DispatchQueue.main.async { (app.workbench.builtPanel("files") as? FilesPanel).map(then) }
    }
    let outline = FilesOutline()
    /// The row whose name is being edited in place (a rename, or a new file).
    var renaming: (field: NSTextField, url: URL, open: Bool)?
    /// Rows fading on their way to the Trash.
    var fadedRows: [NSTableRowView] = []
    private(set) lazy var results = SearchResults(app: app)
    let search = NSSearchField()
    let leftScroll = NSScrollView()
    var nodes: [FileNode] = []
    var status: [String: FileChange] = [:]
    /// Folders with a changed file somewhere under them (a grey dot).
    var changedFolders = Set<String>()
    /// The latest listing, as (listed paths, ignored paths), which the name filter narrows.
    var shownPaths: ([String], [String]?)?
    /// The listing that the whole tree on show was built from, which the next listing is compared with. It's nil while
    /// the tree is narrowed or not built, and then the next listing builds a new tree.
    var treeBase: (paths: [String], ignored: [String])?
    /// Counts listings, so a listing still being worked out off the main actor gives way to a newer one.
    var listing = 0
    /// The listed paths in lower case, for the name filter. They're made once per listing, not for every path on every
    /// key.
    var lowered: (of: [String], paths: [String]) = ([], [])
    /// The content search in progress, and the narrowing by the name filter in progress. The next key's search or
    /// narrowing replaces them.
    var searching: Task<Void, Never>?
    var narrowing: Task<Void, Never>?
    /// The files in each open ignored folder, by folder. They're kept when the tree is built again, and read again
    /// after an operation.
    var opened: [String: [String]] = [:]
    /// The workspace's files and their git status, which the daemon pushes while the panel is on screen
    /// (`WatchTopic.files`, `.git`). A hidden panel costs no listing on every change, and the list comes again when the
    /// panel shows.
    private lazy var filesWatch = Watched(.files, in: app)
    private lazy var gitWatch = Watched(.git, in: app)
    private var shown = false
    /// Badges that change while the panel is hidden are redrawn when it shows.
    private lazy var whenShown = WhenShown(view)
    var worktree: Worktree?
    var root: String { worktree?.path ?? "/" }

    override func loadView() {
        let app = self.app
        outline.plainList("f", in: leftScroll)
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
        outline.onOpen = { [weak self] in self?.openSelected() }
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        search.delegate = self
        // One field, like Finder's. When empty, it shows the tree. A search (↩) shows matches in the tree's place, and
        // clearing the field goes back to the tree.
        setUpSearchMode()
        search.target = self
        search.action = #selector(runSearch)
        search.sendsSearchStringImmediately = false
        search.controlSize = .small
        let content = NSView()
        let bar = header()
        setUpSearchRows()
        let foot = NSHostingView(rootView: DiskFoot(app: app, sizes: disk))
        foot.sizingOptions = [.intrinsicContentSize]
        for subview in [bar, replaceRow, leftScroll, results.scroll, patternError, foot] as [NSView] {
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
            leftScroll.bottomAnchor.constraint(equalTo: foot.topAnchor),
            replaceRow.topAnchor.constraint(equalTo: bar.bottomAnchor),
            replaceRow.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            replaceRow.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            replaceRow.heightAnchor.constraint(equalToConstant: TextSize.of(Metrics.row) + Metrics.gap),
            patternError.topAnchor.constraint(equalTo: bar.bottomAnchor),
            patternError.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Metrics.inset),
            patternError.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -Metrics.inset),
            resultsTop, results.scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            results.scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            results.scroll.bottomAnchor.constraint(equalTo: foot.topAnchor),
            foot.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            foot.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            foot.bottomAnchor.constraint(equalTo: content.bottomAnchor)
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
            app.latest(GitEvent.self, app.gitKey(app.workbench.workspaceId))?.changes
        } changed: { [weak self] in
            self?.badges($0)
        }
        track(owner: self) {
            app.fileIcons.revision
        } changed: { [weak self] _ in
            self?.whenShown.run { self?.reloadIcons() }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { fill(menu, row: outline.clickedRow) }

    /// Fills the tree's right-click menu for the row under the pointer. Over empty space `clickedRow` is -1, and
    /// `selectedNode` would answer with the selected row instead. So nothing here uses `selectedNode`, or Move to Trash
    /// could reach a file nobody clicked.
    func fill(_ menu: NSMenu, row: Int) {
        menu.removeAllItems()
        guard worktree != nil else { return }
        guard let node = outline.item(atRow: row) as? FileNode else { return folderItems(menu, "") }
        if node.children == nil { fileItems(menu, node.path) } else { folderItems(menu, node.path) }
    }

    /// The items for a folder. Over empty space, they're for the project's top folder.
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

    /// The menu items that files and folders share: hand it to an agent, rename it, find it, and move it to the Trash.
    private func changeItems(_ menu: NSMenu, _ rel: String) {
        let app = app, path = root + "/" + rel
        menu.add(String(localized: "Send to Agent")) { FileActions(app).sendToAgent(path) }
        menu.add(String(localized: "Rename")) { [weak self] in self?.beginRename(rel) }
        menu.addItem(.separator())
        WorkspaceActions.addLocate(
            to: menu, path: path,
            copies: [
                (String(localized: "Relative Path"), { @MainActor in copyText(rel) }),
                (String(localized: "Web Link"), { @MainActor in copyWebLink(app, path) })
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
        // For another folder, drop the old tree now, or a click before the reload would act on the old paths under the
        // new root.
        if next?.path != worktree?.path {
            nodes = []
            status = [:]
            shownPaths = nil
            treeBase = nil
            listing += 1
            opened = [:]
            outline.reloadData()
        }
        worktree = next
        results.root = root
        searchOptions = next.map { SearchOptions(app, workspace: $0.id) } ?? SearchOptions()
        showSearchOptions()
        results.show([])
        watchShown()
        if let next {
            badges(app.latest(GitEvent.self, app.gitKey(next.id))?.changes)
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
        gitWatch.key = shown ? worktree.map { app.gitKey($0.id) } : nil
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

    /// Shows the workspace's files as listed, whether pushed or read after an operation: the tree, or why there's none.
    /// How the tree changed is worked out off the main actor. A few files added or removed go where they belong, and
    /// more changes build the tree again.
    @discardableResult
    func listed(_ event: FilesEvent?) -> Task<Void, Never>? {
        // Skips a listing for another workspace (the user switched meanwhile). It also skips while a name is being
        // edited in place, because a reload would end the rename, which reads the files after.
        guard let event, event.worktree == worktree?.id, renaming == nil else { return nil }
        showLoadError(event.error)
        guard let paths = event.paths else { return nil }
        let ignored = event.ignored ?? []
        let same = isNarrowed && shownPaths.map { $0 == paths && $1 == event.ignored } == true
        shownPaths = (paths, event.ignored)
        listing += 1
        guard !isNarrowed else {
            if !same { showTree(treeShown(paths, ignored: ignored), base: nil) }   // a few thousand rows at most
            return nil
        }
        let ticket = listing, was = treeBase, opened = opened
        return Task {
            let update = await Task.detached {
                FileNode.update(was: was, paths: paths, ignored: ignored, opened: opened)
            }.value
            guard ticket == listing, renaming == nil, worktree?.id == event.worktree else { return }
            switch update {
            case .same: break   // an agent saving a file changes its badge, not the tree
            case .tree(let tree): showTree(tree, base: (paths, ignored))
            case .patch(let added, let removed):
                let places = outline.rowPlaces(rowKey)
                showFadedRows()
                guard patchTree(added: added, removed: removed) else {
                    treeBase = nil   // a file became a folder, so build a new tree
                    return await listed(event)?.value ?? ()
                }
                treeBase = (paths, ignored)
                settled(places)
            }
        }
    }

    /// Shows a newly built tree. The folders that were open open again, and the selection stays on its file.
    func showTree(_ tree: [FileNode], base: (paths: [String], ignored: [String])?) {
        let expanded = Set(
            (0..<outline.numberOfRows).compactMap {
                (outline.item(atRow: $0) as? FileNode).flatMap { outline.isItemExpanded($0) ? $0.path : nil }
            })
        let selected = (outline.item(atRow: outline.selectedRow) as? FileNode)?.path
        let places = outline.rowPlaces(rowKey)
        showFadedRows()
        nodes = tree
        treeBase = base
        if base == nil { FileNode.open(opened, in: nodes) }   // `update` already filled a whole tree's open folders
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
        settled(places)
    }

    /// Runs after the tree changed. The rows that stayed slide from their old `places`, and Quick Look reloads.
    private func settled(_ places: [String: NSPoint]) {
        outline.settleRows(from: places, rowKey)
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().reloadData()
        }
    }

    /// Shows git's letters on the rows, and a dot on folders holding a change. Only the letters show, because Source
    /// Control says what failed. The status is stored at once, because menus and the name filter read it. Only the
    /// rows whose badge or dot changed are drawn again, and a hidden panel redraws all its rows once it shows.
    private func badges(_ changes: [FileChange]?) {
        let was = (status, changedFolders)
        status = Dictionary((changes ?? []).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        changedFolders = Set(
            status.keys.flatMap { path in path.indices.filter { path[$0] == "/" }.map { String(path[..<$0]) } })
        let moved = Set(status.keys.filter { status[$0] != was.0[$0] } + was.0.keys.filter { status[$0] == nil })
            .union(changedFolders.symmetricDifference(was.1))
        guard !moved.isEmpty else { return }
        guard whenShown.onScreen else { return whenShown.run { [weak self] in self?.reloadIcons() } }
        let rows = IndexSet((0..<outline.numberOfRows).filter { rowKey($0).map(moved.contains) ?? false })
        outline.reloadData(forRowIndexes: rows, columnIndexes: [0])
    }

    func openFile(_ rel: String, line: Int? = nil, focus: Bool = true) {
        app.workbench.open(TabURI.file(root + "/" + rel, line: line), focus: focus)
    }
    /// Says why the files couldn't be listed (a folder moved away, git refusing it), where the tree would be, instead
    /// of showing an empty tree.
    let loadError = EmptyStateView()
    /// Says that a search found nothing (and the tree is one click away), instead of showing an empty list.
    let noResults = EmptyStateView()
    let typing = Debounce()
    var searchOptions = SearchOptions()
    /// What the field searches. Names narrow the tree in place, and contents list matches in place of the tree.
    var byName = UserDefaults.standard.bool(forKey: "files.searchByName")
    private(set) lazy var resultsTop = results.scroll.topAnchor.constraint(equalTo: leftScroll.topAnchor)
    private(set) lazy var caseToggle = TextToggle("Aa", tip: String(localized: "Match Case")) { [weak self] in
        self?.toggle(\.matchCase)
    }
    private(set) lazy var wordToggle = TextToggle("ab", tip: String(localized: "Whole Word")) { [weak self] in
        self?.toggle(\.wholeWord)
    }
    private(set) lazy var regexToggle = TextToggle(".*", tip: String(localized: "Regular Expression")) { [weak self] in
        self?.toggle(\.regex)
    }
    /// The replace field, shown under the search while the search has found something.
    let replaceField = NSSearchField()
    private(set) lazy var replaceButton = ClosureButton(title: String(localized: "Replace All…")) { [weak self] in
        self?.replaceAll()
    }
    lazy var replaceRow = NSStackView(views: [replaceField, replaceButton])
    /// Says, under the field, that a pattern isn't valid, while the last results stay.
    let patternError = NSTextField(labelWithString: "")
}
