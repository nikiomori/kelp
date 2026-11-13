import AppKit
import Core
import DesignKit
import KelpKit
import Quartz
import WorkbenchKit

/// The workspace's files: tree with git status (click opens a tab), file operations, and project search.
@MainActor
final class FilesPanel: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate,
    NSMenuDelegate
{
    let app: AppModel
    init(app: AppModel) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    /// Brings the Files panel up and hands it to `then` once built: the inspector makes it on the next turn, when it
    /// follows the panel just chosen.
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
    /// The paths the tree was built from (listed, ignored): an edit that adds or removes none only changes badges.
    var shownPaths: ([String], [String]?)?
    /// Those paths in lower case, for the name filter: made once per listing, not for every path on every key.
    var lowered: (of: [String], paths: [String]) = ([], [])
    /// What the open ignored folders hold, by folder: kept when the tree is built again, read again after an operation.
    var opened: [String: [String]] = [:]
    /// Its files and their git status, pushed by the daemon while the panel is on screen (`WatchTopic.files`, `.git`):
    /// a hidden one costs no listing on every change, and the list comes again when it shows.
    private lazy var filesWatch = Watched(.files, in: app)
    private lazy var gitWatch = Watched(.git, in: app)
    private var shown = false
    /// Badges redrawn while hidden wait for it to show.
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
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        search.delegate = self
        // One field, like Finder's: empty shows the tree, a search (↩) shows matches in their place, clearing it goes back.
        setUpSearchMode()
        search.target = self
        search.action = #selector(runSearch)
        search.sendsSearchStringImmediately = false
        search.controlSize = .small
        let content = NSView()
        let bar = header()
        setUpSearchRows()
        for subview in [bar, replaceRow, leftScroll, results.scroll, patternError] as [NSView] {
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
            resultsTop, results.scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            results.scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            results.scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor)
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
            self?.whenShown.run { self?.reloadIcons() }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { fill(menu, row: outline.clickedRow) }

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
        // Another folder: drop the old tree now, or a click before the reload would act on its paths under the new root.
        if next?.path != worktree?.path {
            nodes = []
            status = [:]
            shownPaths = nil
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
    /// The status is kept at once (menus and the name filter read it); only the rows whose badge or dot changed are
    /// drawn again, and a hidden panel's all of them once it shows.
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
    /// The files couldn't be listed (a folder moved away, git refusing it): say why where the tree would be, not an empty tree.
    let loadError = EmptyStateView()
    /// A search that found nothing says so (and the tree is one click away), rather than an empty list.
    let noResults = EmptyStateView()
    let typing = Debounce()
    var searchOptions = SearchOptions()
    /// What the field looks through: names narrow the tree in place, contents list matches instead of it.
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
    /// Under the search, while it has found something.
    let replaceField = NSSearchField()
    private(set) lazy var replaceButton = ClosureButton(title: String(localized: "Replace All…")) { [weak self] in
        self?.replaceAll()
    }
    lazy var replaceRow = NSStackView(views: [replaceField, replaceButton])
    /// Under the field: a pattern that isn't valid, while the last results stay.
    let patternError = NSTextField(labelWithString: "")
}
