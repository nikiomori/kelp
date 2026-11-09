import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// Source Control, modeled on VS Code's: branch and sync up top, the commit message, merge / staged / unstaged
/// changes (click → diff), and the history graph. All git work happens in the daemon; this only lays out the answers.
@MainActor
final class SourceControlController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let app: AppModel
    init(app: AppModel) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    enum Section: String {
        case merge = "Merge Changes", staged = "Staged Changes", changes = "Changes", graph = "Graph"
    }

    final class Node: NSObject {
        enum Kind {
            case section(Section), file(FileChange, Section), commit(Int), commitFile(String, FileChange), note(String)
        }
        let kind: Kind
        var children: [Node] = []
        var files: [FileChange] = []   // a section's, also while it's folded
        init(_ k: Kind) { kind = k }
    }

    let outline = NSOutlineView()
    let graphOutline = NSOutlineView()
    private let graphBar = GraphBar()
    private var graphHeight: NSLayoutConstraint?, graphClosed: NSLayoutConstraint?, barHeight: NSLayoutConstraint?
    /// Never dragged, the changes are as tall as their rows, up to half the panel, and the open graph follows right under
    /// them (a gap there looked like something still loading); they keep at least their rows' height up to 80 pt.
    private var changesHug: NSLayoutConstraint?, changesCap: NSLayoutConstraint?, changesRoom: NSLayoutConstraint?
    let branchButton = BranchChip()   // greys in under the pointer, as the window bar's branch chip
    lazy var bar = SourceControlBar(self)
    let message = CommitTextView()
    private let placeholder = NSTextField(labelWithString: "")
    private var messageHeight: NSLayoutConstraint?
    var commitButton: SplitPushButton?
    /// Beside Commit: its other ways (Commit & Push, Amend), or Push / Pull while it offers to sync.
    private let commitMenu = NSMenu(), syncMenu = NSMenu()
    private var moreMenu: NSMenu?
    private var pullItem: NSMenuItem?
    var moreButton: NSButton?
    var commitArea: NSView?, separator: NSView?
    let empty = EmptyStateView()
    var headerBar: NSView?

    var worktreeId: String?
    var changes: [FileChange] = []
    /// Its files another folder of the project changes too, with their branches.
    var shared: [String: [String]] = [:]
    var info: BranchInfo?
    var commits: [GraphCommit] = []
    var unpushed = Set<String>()
    /// Commits that just reached the remote, and when each one lands: oldest first, as they left.
    var landing: [String: Double] = [:]
    /// Commits just made or pulled: they come into the graph one after another (hash: when).
    var arriving: [String: Double] = [:]
    /// What the panel's button says it just did, for a moment after.
    var confirmed: String?
    /// Which `finish` is on show: a later one, or new work, takes over its moment.
    var finishes = 0
    /// A commit went through: the list of changes fades to what's left rather than switching.
    var clearing = false
    /// Files were staged, unstaged or discarded: the rows travel to their places when the status shows it (the shape then).
    var staging: Set<String>?
    /// What runs, by workspace: an action outlives a switch to another one, and ends on its own.
    var work: [String: GitWork] = [:]
    /// Commit messages being written in the workspaces not on screen.
    var drafts: [String: String] = [:]
    var syncing: GitWork.Sync? { worktreeId.flatMap { work[$0]?.syncing } }
    var busy: Bool { worktreeId.flatMap { work[$0] } != nil }
    var more = false, limit = 200, loadingMore = false
    var commitFiles: [String: [FileChange]] = [:]
    var openCommits = Set<String>()
    /// The card of the commit under the pointer, with the daemon's details (quiet: without them it shows the row's).
    lazy var card: CommitCard = {
        let commitCard = CommitCard()
        commitCard.load = { [weak self] hash in
            guard let self, let wid = self.worktreeId else { return nil }
            return await self.app.quiet(GitCommitDetails(id: wid, commit: hash))
        }
        commitCard.picture = { [weak self] email in
            guard let self, let wid = self.worktreeId,
                let data = await self.app.quiet(GitAuthorAvatar(id: wid, email: email)) ?? nil
            else { return nil }
            return NSImage(data: data)
        }
        return commitCard
    }()
    private var collapsed = Set(UserDefaults.standard.stringArray(forKey: "scm.collapsed") ?? [])
    /// The section a click just folded or opened: its rebuilt cell's chevron turns.
    private var turning: Section?
    private(set) var roots: [Node] = []
    private var graphRoots: [Node] = []
    /// The workspace's git and its branch's CI, watched while the panel is on screen (the daemon pushes changes).
    lazy var gitWatch = Watched(.git, in: app)
    lazy var ciWatch = Watched(.ci, in: app)
    let stats = NSTextField(labelWithString: "")
    let ciRow = CIStatusRow()
    var ciRuns: [CIRuns.Run] = []
    /// Where each failed run broke ("job › step"), read once: a finished run doesn't change.
    var ciFailures: [Int: String] = [:]

    // MARK: view

    override func loadView() {
        let app = self.app
        branchButton.target = self
        branchButton.action = #selector(branchMenu)
        branchButton.toolTip = String(localized: "Switch or create a branch")
        branchButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        moreButton = bar.more
        stats.font = .uiDigits(10, weight: .medium)
        let header = bar.header(branchButton)
        headerBar = header

        let box = commitBox()
        commitArea = box
        let scroll = list(outline), graphScroll = list(graphOutline)
        graphBar.onToggle = { [weak self] in self?.toggle(.graph) }
        graphBar.onResize = { [weak self] in self?.resizeGraph(by: $0) }
        graphBar.onRefresh = { [weak self] in Task { await self?.loadGraph() } }

        let root = NSView()
        let sep = NSBox()
        sep.boxType = .separator
        separator = sep
        for x in [header, box, sep, scroll, graphBar, graphScroll] as [NSView] {
            x.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(x)
        }
        // Open, the graph is the height it was dragged to. Under windowSizeStayPut: it never stretches the window.
        let gh = graphScroll.heightAnchor.constraint(equalToConstant: 260)
        gh.priority = .init(495)
        graphHeight = gh
        changesHug = scroll.heightAnchor.constraint(equalToConstant: 0)
        changesHug?.priority = .init(495)
        changesCap = scroll.heightAnchor.constraint(lessThanOrEqualTo: root.heightAnchor, multiplier: 0.5)
        changesCap?.priority = .init(750)   // under the 80 pt the changes keep
        graphClosed = graphScroll.heightAnchor.constraint(equalToConstant: 0)
        graphClosed?.priority = .defaultHigh
        let bh = graphBar.heightAnchor.constraint(equalToConstant: 0)
        barHeight = bh
        let room = scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80)
        room.priority = .init(760)   // the graph gives way first
        changesRoom = room
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            box.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            box.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            box.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            sep.topAnchor.constraint(equalTo: box.bottomAnchor, constant: 10),
            sep.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sep.heightAnchor.constraint(equalToConstant: 1),   // unset, a rebuilt panel's layout can stretch it tall (and vertical)
            scroll.topAnchor.constraint(equalTo: sep.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: graphBar.topAnchor), room,
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            graphBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            graphBar.trailingAnchor.constraint(equalTo: root.trailingAnchor), bh,
            graphScroll.topAnchor.constraint(equalTo: graphBar.bottomAnchor),
            graphScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            graphScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            graphScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        ])
        empty.place(in: root, under: header)
        view = root
        updateHeader()   // NSButton's own "Button" title must not show while the branch loads
        if app.workbench.workspaceId == nil { showNoProject(true) }
        track(owner: self) { [app] in
            app.workbench.workspaceId
        } changed: { [weak self] in
            self?.bind($0)
        }
        track(owner: self) { [weak self, app] in
            app.latest(GitEvent.self, self?.worktreeId ?? "")
        } changed: { [weak self] in
            self?.apply($0)
        }
        track(owner: self) { [weak self, app] in
            app.sharedFiles(self?.worktreeId)
        } changed: { [weak self] in
            self?.shared = $0
            self?.rebuildChanges()
        }
        track(owner: self) { [weak self, app] in
            app.latest(CIEvent.self, self?.worktreeId ?? "")
        } changed: { [weak self] in
            self?.applyCI($0)
        }
        track(owner: self) {
            app.fileIcons.revision
        } changed: { [weak self] _ in
            for o in [self?.outline, self?.graphOutline].compactMap({ $0 }) {
                o.reloadData(forRowIndexes: IndexSet(0..<o.numberOfRows), columnIndexes: [0])
            }
        }
    }

    /// A list in the panel: one column, no header, rows drawn by the cells.
    private func list(_ o: NSOutlineView) -> NSScrollView {
        let scrollView = o.plainList("scm")
        scrollView.autohidesScrollers = true
        o.intercellSpacing = .zero
        o.indentationPerLevel = 0
        o.rowSizeStyle = .custom
        o.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        o.dataSource = self
        o.delegate = self
        o.target = self
        o.action = #selector(clicked(_:))
        let menu = NSMenu()
        menu.delegate = self
        o.menu = menu
        return scrollView
    }

    /// The message field (grows to six lines) and Commit with its split menu.
    private func commitBox() -> NSView {
        message.isRichText = false
        message.font = .ui(13)
        message.drawsBackground = false
        message.textContainerInset = NSSize(width: 4, height: 6)
        message.allowsUndo = true
        message.isAutomaticQuoteSubstitutionEnabled = false
        message.isAutomaticDashSubstitutionEnabled = false
        message.isVerticallyResizable = true
        message.autoresizingMask = .width
        message.onCommit = { [weak self] in self?.commit(push: false, amend: false) }
        message.onChange = { [weak self] in self?.messageChanged() }
        let messageScroll = NSScrollView()
        messageScroll.documentView = message
        messageScroll.drawsBackground = false
        messageScroll.hasVerticalScroller = false
        placeholder.textColor = .placeholderTextColor
        placeholder.font = .ui(13)
        placeholder.lineBreakMode = .byTruncatingTail
        placeholder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)   // a long branch name truncates, not widens the panel
        let field = FieldBox()
        field.wantsLayer = true
        commitMenu.add(String(localized: "Commit & Push")) { [weak self] in self?.commit(push: true, amend: false) }
        commitMenu.add(String(localized: "Commit (Amend)")) { [weak self] in self?.commit(push: false, amend: true) }
        syncMenu.add(String(localized: "Push")) { [weak self] in
            self?.run(done: String(localized: "Pushed")) { GitRemoteOp(id: $0, op: "push") }
        }
        pullItem = syncMenu.add(String(localized: "Pull")) { [weak self] in
            self?.run(done: String(localized: "Pulled")) { GitRemoteOp(id: $0, op: "pull") }
        }
        // The panel's main action: the accent colour while there's something to commit (macOS 26's primary tint).
        // Words alone, as macOS's push buttons: a ✓ or an arrow before them only crowded the title.
        let cb = SplitPushButton(
            title: String(localized: "Commit"), arrowTip: String(localized: "Commit & Push, Amend…"))
        cb.target = self
        cb.action = #selector(commitPressed)
        cb.toolTip = String(localized: "Commit (⌘↩ in the message)")
        cb.arrow.target = self
        cb.arrow.action = #selector(showCommitMenu)
        commitButton = cb
        let buttons = cb
        cb.setContentHuggingPriority(.defaultLow, for: .horizontal)
        ciRow.onClick = { [weak self] in self?.openCI() }
        let stack = NSStackView(views: [buttons, ciRow])
        stack.orientation = .vertical
        stack.spacing = 6   // a hidden CI line takes no room
        let box = NSView()
        for x in [field, messageScroll, placeholder, stack] as [NSView] {
            x.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(x)
        }
        let heightConstraint = messageScroll.heightAnchor.constraint(equalToConstant: 30)
        messageHeight = heightConstraint
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: box.topAnchor),
            field.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            messageScroll.topAnchor.constraint(equalTo: field.topAnchor, constant: 1),
            messageScroll.bottomAnchor.constraint(equalTo: field.bottomAnchor, constant: -1),
            messageScroll.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 2),
            messageScroll.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -2), heightConstraint,
            placeholder.leadingAnchor.constraint(equalTo: messageScroll.leadingAnchor, constant: 9),
            placeholder.topAnchor.constraint(equalTo: messageScroll.topAnchor, constant: 7),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: messageScroll.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ciRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return box
    }

    func messageChanged() {
        placeholder.isHidden = !message.string.isEmpty
        if let lm = message.layoutManager, let tc = message.textContainer {
            lm.ensureLayout(for: tc)
            let lines = lm.usedRect(for: tc).height + message.textContainerInset.height * 2
            messageHeight?.constant = min(max(30, ceil(lines)), 6 * 17 + 12)
        }
        updateCommitButton()
    }

    func updateCommitButton() {
        placeholder.stringValue = String(localized: "Message")   // ⌘↩ and what a commit takes are in Commit's tooltip
        guard let cb = commitButton else { return }
        let next = changes.isEmpty ? nextStep : nil
        // What a commit takes: the staged files, or all of them when none are staged.
        let files = changes.filter { $0.staged && !$0.conflicted }.count
        let count = files > 0 ? files : changes.count
        cb.say(
            syncing?.title ?? confirmed ?? next
                ?? (count == 0 ? String(localized: "Commit") : String(localized: "Commit \(count) Files")))
        let idle = next == nil && syncing == nil && confirmed == nil
        moreMenu = next == nil ? commitMenu : syncMenu
        pullItem?.isHidden = info?.upstream == nil
        cb.action = next == nil ? #selector(commitPressed) : #selector(sync)
        let branch = info?.current ?? "HEAD"
        let what =
            files > 0
            ? String(localized: "Commit the staged files on “\(branch)” (⌘↩ in the message)")
            : String(localized: "Commit all changes on “\(branch)” (⌘↩ in the message)")
        cb.toolTip = next == nil ? what : info?.upstream.map { String(localized: "Pull from and push to \($0)") }
        // Saying what it's doing or did, it reads as lit, not switched off, and does nothing when pressed.
        let saying = syncing != nil || confirmed != nil
        if saying { cb.action = nil }
        cb.isEnabled = saying || (!busy && (!changes.isEmpty || next != nil))   // with no message, Commit opens a page to write one
        cb.arrow.isEnabled = !saying && cb.isEnabled
        bar.update(info, changes: changes.count, busy: busy)
        cb.primary = idle && !changes.isEmpty
    }

    @objc private func showCommitMenu() {
        guard let arrow = commitButton?.arrow else { return }
        moreMenu?.popUp(positioning: nil, at: NSPoint(x: 0, y: arrow.bounds.height + 4), in: arrow)
    }

    /// With nothing to commit, the button offers what's left, as in VS Code: sync the commits the remote doesn't
    /// have yet (or pull the ones it has), or publish a branch with no upstream.
    private var nextStep: String? {
        guard let info, info.current != nil else { return nil }
        guard info.upstream != nil else { return info.remote.isEmpty ? nil : String(localized: "Publish Branch") }
        let ahead = info.ahead ?? 0, behind = info.behind ?? 0
        guard ahead + behind > 0 else { return nil }
        // The arrow before the count, as the title bar's chip and the header write it: ↓2 ↑56.
        return String(localized: "Sync Changes") + (behind > 0 ? " ↓\(behind)" : "") + (ahead > 0 ? " ↑\(ahead)" : "")
    }

    // MARK: tree

    func rebuild() {
        rebuildChanges()
        rebuildGraph()
    }

    /// Sections fold through `collapsed`, not the outline's own expansion state, which goes stale across reloads
    /// (a click then "expanded" a section already open).
    func rebuildChanges() {
        let places = stagingPlaces()
        if clearing {
            clearing = false
            outline.crossfade(Motion.base)
        }
        var out: [Node] = []
        func section(_ s: Section, _ files: [FileChange]) {
            guard !files.isEmpty else { return }
            let node = Node(.section(s))
            node.files = files
            if !collapsed.contains(s.rawValue) { node.children = files.map { Node(.file($0, s)) } }
            out.append(node)
        }
        let grouped = changes.grouped
        section(.merge, grouped.merge)
        section(.staged, grouped.staged)
        section(.changes, grouped.changes)
        if changes.isEmpty, info != nil { out.append(Node(.note(String(localized: "No changes")))) }
        if changes.count >= FileChange.limit {
            out.append(Node(.note(String(localized: "Showing the first \(FileChange.limit) changes"))))
        }
        roots = out
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        let rows = outline.numberOfRows
        let height = rows > 0 ? outline.rect(ofRow: rows - 1).maxY : 0
        changesRoom?.constant = min(80, height)
        changesHug?.constant = height
        slideStaged(from: places)
    }

    private func rebuildGraph() {
        card.close()   // its row is about to be rebuilt
        graphRoots = commits.indices.map { index in
            let node = Node(.commit(index)), hash = commits[index].hash
            if openCommits.contains(hash) {
                node.children = (commitFiles[hash] ?? []).map { Node(.commitFile(hash, $0)) }
            }
            return node
        }
        graphOutline.reloadData()
        graphOutline.expandItem(nil, expandChildren: true)
        layoutGraph()
    }

    /// The graph is a pane of its own under the changes, as in VS Code, so a long list of changes never pushes it
    /// out of sight: its header folds it, dragging the header sizes it.
    func layoutGraph() {
        let has = !commits.isEmpty && empty.isHidden, open = has && !collapsed.contains(Section.graph.rawValue)
        graphBar.isHidden = !has
        graphBar.expanded = open
        graphOutline.enclosingScrollView?.isHidden = !open
        barHeight?.constant = has ? GraphBar.height : 0
        // At most half the screen: a height saved while the window was being stretched stays out.
        let saved = UserDefaults.standard.object(forKey: "scm.graphHeight") as? CGFloat
        graphHeight?.constant = min(saved ?? 0, (NSScreen.main?.visibleFrame.height ?? 800) / 2)
        graphHeight?.isActive = open && saved != nil
        changesHug?.isActive = open && saved == nil
        changesCap?.isActive = open && saved == nil
        graphClosed?.isActive = !open
    }

    private func resizeGraph(by dy: CGFloat) {
        guard let gh = graphHeight, graphClosed?.isActive == false, let changes = outline.enclosingScrollView,
            let graph = graphOutline.enclosingScrollView
        else { return }
        gh.constant = min(max(60, graph.frame.height + dy), changes.frame.height + graph.frame.height - 80)
        changesHug?.isActive = false
        changesCap?.isActive = false
        gh.isActive = true
        UserDefaults.standard.set(gh.constant, forKey: "scm.graphHeight")
    }

    private func toggle(_ s: Section) {
        if collapsed.contains(s.rawValue) { collapsed.remove(s.rawValue) } else { collapsed.insert(s.rawValue) }
        UserDefaults.standard.set(Array(collapsed), forKey: "scm.collapsed")
        turning = s
        if s == .graph { layoutGraph() } else { rebuildChanges() }
        DispatchQueue.main.async { [weak self] in self?.turning = nil }   // the outline asks for the cell when it lays out
    }

    private func roots(of o: NSOutlineView) -> [Node] { o === graphOutline ? graphRoots : roots }
    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? roots(of: o).count
    }
    func outlineView(_ o: NSOutlineView, child i: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[i] ?? roots(of: o)[i]
    }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Node)?.children.isEmpty ?? true)
    }
    func outlineView(_ o: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { false }
    func outlineView(_ o: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        switch (item as? Node)?.kind {
        case .section?, .note?: TextSize.of(Metrics.rowSection)
        case .commit?: CommitCell.lineHeight
        default: TextSize.of(Metrics.row)
        }
    }
    func outlineView(_ o: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        if case .note? = (item as? Node)?.kind { return false }
        return true
    }
    func outlineView(_ o: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { ListRowView() }

    func outlineView(_ o: NSOutlineView, viewFor tc: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        switch node.kind {
        case .section(let section):
            // The first section carries what isn't committed yet ("+120 −30"), the header's room being the quick actions'.
            let cell = SectionCell(
                title: loc(section.rawValue), count: node.files.count, expanded: !collapsed.contains(section.rawValue),
                actions: sectionActions(section, node),
                detail: node === roots.first && !stats.isHidden ? stats.attributedStringValue : nil)
            cell.toolTip = node === roots.first && !stats.isHidden ? stats.toolTip : nil
            cell.turnsIn = turning == section
            return cell
        case .file(let file, let section):
            return FileCell(
                file, icon: app.fileIcons.image((file.path as NSString).lastPathComponent),
                letter: Self.letter(file, section),
                indent: SectionCell.indent, actions: fileActions(file, section), shared: shared[file.path] ?? [])
        case .commit(let index):
            if more, !loadingMore, index >= commits.count - 30 { loadMore() }
            let commit = commits[index]
            let pushed: Bool? = info?.remote.isEmpty ?? true ? nil : !unpushed.contains(commit.hash)
            let cell = CommitCell(
                commit, graphWidth: Self.graphWidth(commit), isHead: commit.hash.hasPrefix(info?.head ?? "\u{0}"),
                pushed: pushed,
                landsAfter: landing[commit.hash], arrivesAfter: arriving[commit.hash])
            if syncing?.push == true { cell.pulse(true) }
            cell.onHover = { [weak self, weak cell] on in
                if let self, let cell { self.card.hover(on, commit: commit, pushed: pushed, over: cell) }
            }
            return cell
        case .commitFile(let hash, let fileChange):
            let commit = commits.first { $0.hash == hash }
            let width = commit.map(Self.graphWidth) ?? GraphView.width(lanes: 1)
            let cell = FileCell(
                fileChange, icon: app.fileIcons.image((fileChange.path as NSString).lastPathComponent),
                letter: Self.letter(fileChange, .graph),
                indent: width + Metrics.gapWide, actions: [])
            // The lanes below the commit run on through its expanded files, as in VS Code.
            let graph = GraphView()
            graph.through = Array(Set(commit?.bottom.compactMap(\.last) ?? []))
            graph.frame = NSRect(x: GraphView.leading, y: 0, width: width, height: 22)
            graph.autoresizingMask = [.height]
            cell.addSubview(graph)
            return cell
        case .note(let text):
            return NoteCell(text)
        }
    }

    /// As wide as the lanes this commit's row draws, not the widest point of the whole graph: one crossing far down made
    /// every row start its subject two lanes out from its line.
    static func graphWidth(_ c: GraphCommit) -> CGFloat {
        let lanes = ([c.lane] + c.top.flatMap { $0 } + c.bottom.flatMap { $0 }).max() ?? 0
        return GraphView.width(lanes: min(lanes + 1, GraphView.maxLanes))
    }

    private func loadMore() {
        loadingMore = true
        limit += 200
        DispatchQueue.main.async { [weak self] in Task { await self?.loadGraph() } }
    }

    // MARK: clicks

    @objc private func clicked(_ o: NSOutlineView) {
        card.close()
        guard let node = o.item(atRow: o.clickedRow) as? Node else { return }
        switch node.kind {
        case .section(let section): toggle(section)
        case .file(let file, let section): open(file, section)
        case .commit(let index): toggle(commit: commits[index].hash)
        case .commitFile(let hash, let fileChange):
            if let worktree = worktreeId {
                app.workbench.open(DiffTab.uri(worktree, file: fileChange.path, commit: hash))
            }
        case .note: break
        }
    }

    private func toggle(commit hash: String) {
        if openCommits.contains(hash) {
            openCommits.remove(hash)
            rebuildGraph()
            return
        }
        openCommits.insert(hash)
        guard commitFiles[hash] == nil, let wid = worktreeId else {
            rebuildGraph()
            return
        }
        Task {
            // Unfolded by a click: a banner says why it can't, and it folds back to be asked again.
            guard let files = await app.call(GitCommitFiles(id: wid, commit: hash)) else {
                openCommits.remove(hash)
                rebuildGraph()
                return
            }
            guard wid == worktreeId else { return }
            commitFiles[hash] = files
            rebuildGraph()
        }
    }
}

// MARK: status letters (VS Code's colors)

extension SourceControlController {
    func open(_ file: FileChange, _ section: Section) {
        guard let worktree = worktreeId else { return }
        if section == .merge {
            openFile(file)
            return
        }
        // the review beside it scrolls there instead
        if DiffViewController.reveal(file.path, worktree: worktree) { return }
        app.workbench.open(DiffTab.uri(worktree, file: file.path, source: section == .staged ? "staged" : "unstaged"))
    }
    func openFile(_ file: FileChange) {
        if let worktree = app.worktree(worktreeId) { app.workbench.open(TabURI.file(worktree.path + "/" + file.path)) }
    }

    static func letter(_ file: FileChange, _ section: Section) -> (String, NSColor) {
        let code = file.letter(inWorktree: section == .changes, merging: section == .merge)
        return (code, .gitLetter(code))
    }
}

// MARK: - cells
