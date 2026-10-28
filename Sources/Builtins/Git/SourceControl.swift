import AppKit
import Core
import DesignKit
import WorkbenchKit
import KelpKit

/// Source Control, modeled on VS Code's: branch and sync up top, the commit message, merge / staged / unstaged
/// changes (click → diff), and the history graph. All git work happens in the daemon; this only lays out the answers.
@MainActor
final class SourceControlController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let app: AppModel
    init(app: AppModel) { self.app = app; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    enum Section: String { case merge = "Merge Changes", staged = "Staged Changes", changes = "Changes", graph = "Graph" }

    final class Node: NSObject {
        enum Kind { case section(Section), file(FileChange, Section), commit(Int), commitFile(String, FileChange), note(String) }
        let kind: Kind
        var children: [Node] = []
        var files: [FileChange] = []   // a section's, also while it's folded
        init(_ k: Kind) { kind = k }
    }

    let outline = NSOutlineView()
    let graphOutline = NSOutlineView()
    private let graphBar = GraphBar()
    private var graphHeight: NSLayoutConstraint?, graphClosed: NSLayoutConstraint?, barHeight: NSLayoutConstraint?
    /// Never dragged, the open graph has the lower half; the changes keep at least their rows' height up to 80 pt.
    private var graphHalf: NSLayoutConstraint?, changesRoom: NSLayoutConstraint?
    let branchButton = PointerButton(frame: .zero)   // greys in under the pointer, as the window bar's branch chip
    lazy var bar = SourceControlBar(self)
    let message = CommitTextView()
    private let placeholder = NSTextField(labelWithString: "")
    private var messageHeight: NSLayoutConstraint?
    private var commitButton: SplitPushButton?
    /// Beside Commit: its other ways (Commit & Push, Amend), or Push / Pull while it offers to sync.
    private let commitMenu = NSMenu(), syncMenu = NSMenu()
    private var moreMenu: NSMenu?
    private var pullItem: NSMenuItem?
    var moreButton: NSButton?
    var commitArea: NSView?, separator: NSView?
    let empty = EmptyStateView()

    var worktreeId: String?
    var changes: [FileChange] = []
    var info: BranchInfo?
    var commits: [GraphCommit] = []
    var unpushed = Set<String>()
    /// Commits that just reached the remote, and when each one lands: oldest first, as they left.
    var landing: [String: Double] = [:]
    /// While a push, pull or sync runs: what the button says, and whether the ↑ arrows pulse.
    var syncing: (title: String, push: Bool)? { didSet { updateCommitButton(); pulseArrows() } }
    var more = false, limit = 200, loadingMore = false
    var commitFiles: [String: [FileChange]] = [:]
    var openCommits = Set<String>()
    /// The card of the commit under the pointer, with the daemon's details (quiet: without them it shows the row's).
    lazy var card: CommitCard = {
        let c = CommitCard()
        c.load = { [weak self] hash in
            guard let self, let wid = self.worktreeId else { return nil }
            return await self.app.quiet(GitCommitDetails(id: wid, commit: hash))
        }
        c.picture = { [weak self] email in
            guard let self, let wid = self.worktreeId, let data = await self.app.quiet(GitAuthorAvatar(id: wid, email: email)) ?? nil else { return nil }
            return NSImage(data: data)
        }
        return c
    }()
    private var collapsed = Set(UserDefaults.standard.stringArray(forKey: "scm.collapsed") ?? [])
    private(set) var roots: [Node] = []
    private var graphRoots: [Node] = []
    var graphWidth: CGFloat = GraphView.width(lanes: 1)
    /// The workspace's git and its branch's CI, watched while the panel is on screen (the daemon pushes changes).
    lazy var gitWatch = Watched(.git, in: app)
    lazy var ciWatch = Watched(.ci, in: app)
    var busy = false { didSet { updateCommitButton() } }
    let stats = NSTextField(labelWithString: "")
    let ciRow = CIStatusRow()
    var ciRuns: [CIRuns.Run] = []
    /// Where each failed run broke ("job › step"), read once: a finished run doesn't change.
    var ciFailures: [Int: String] = [:]

    // MARK: view

    override func loadView() {
        let app = self.app
        branchButton.padding = 4
        branchButton.imagePosition = .imageLeading
        branchButton.imageHugsTitle = true
        branchButton.image = Glyph.image("arrow.triangle.branch", size: 14); branchButton.font = .ui(12, weight: .semibold)
        branchButton.lineBreakMode = .byTruncatingMiddle
        branchButton.target = self
        branchButton.action = #selector(branchMenu)
        branchButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        branchButton.toolTip = String(localized: "Switch or create a branch")
        branchButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        moreButton = bar.more
        stats.font = .uiDigits(10, weight: .medium)
        let header = bar.header(branchButton)

        let box = commitBox(); commitArea = box
        let scroll = list(outline), graphScroll = list(graphOutline)
        graphBar.onToggle = { [weak self] in self?.toggle(.graph) }
        graphBar.onResize = { [weak self] in self?.resizeGraph(by: $0) }
        graphBar.onRefresh = { [weak self] in Task { await self?.loadGraph() } }

        let v = NSView()
        let sep = NSBox()
        sep.boxType = .separator
        separator = sep
        for x in [header, box, sep, scroll, graphBar, graphScroll] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        // Open, the graph is the height it was dragged to. Under windowSizeStayPut: it never stretches the window.
        let gh = graphScroll.heightAnchor.constraint(equalToConstant: 260)
        gh.priority = .init(495)
        graphHeight = gh
        graphHalf = graphScroll.heightAnchor.constraint(equalTo: v.heightAnchor, multiplier: 0.5)
        graphHalf?.priority = .init(495)
        graphClosed = graphScroll.heightAnchor.constraint(equalToConstant: 0)
        graphClosed?.priority = .defaultHigh
        let bh = graphBar.heightAnchor.constraint(equalToConstant: 0); barHeight = bh
        let room = scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80); room.priority = .init(760)   // the graph gives way first
        changesRoom = room
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: v.topAnchor),
            header.leadingAnchor.constraint(equalTo: v.leadingAnchor), header.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            box.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            box.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12), box.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            sep.topAnchor.constraint(equalTo: box.bottomAnchor, constant: 10),
            sep.leadingAnchor.constraint(equalTo: v.leadingAnchor), sep.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            sep.heightAnchor.constraint(equalToConstant: 1),   // unset, a rebuilt panel's layout can stretch it tall (and vertical)
            scroll.topAnchor.constraint(equalTo: sep.bottomAnchor), scroll.bottomAnchor.constraint(equalTo: graphBar.topAnchor), room,
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            graphBar.leadingAnchor.constraint(equalTo: v.leadingAnchor), graphBar.trailingAnchor.constraint(equalTo: v.trailingAnchor), bh,
            graphScroll.topAnchor.constraint(equalTo: graphBar.bottomAnchor), graphScroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            graphScroll.leadingAnchor.constraint(equalTo: v.leadingAnchor), graphScroll.trailingAnchor.constraint(equalTo: v.trailingAnchor)
        ])
        empty.place(in: v, under: header)
        view = v
        updateHeader()   // NSButton's own "Button" title must not show while the branch loads
        track(owner: self) { [app] in app.workbench.workspaceId } changed: { [weak self] in self?.bind($0) }
        track(owner: self) { [weak self, app] in app.git[self?.worktreeId ?? ""] } changed: { [weak self] in self?.apply($0) }
        track(owner: self) { [weak self, app] in app.ci[self?.worktreeId ?? ""] } changed: { [weak self] in self?.applyCI($0) }
        track(owner: self) { app.fileIcons.revision } changed: { [weak self] _ in
            for o in [self?.outline, self?.graphOutline].compactMap({ $0 }) { o.reloadData(forRowIndexes: IndexSet(0..<o.numberOfRows), columnIndexes: [0]) }
        }
    }

    /// A list in the panel: one column, no header, rows drawn by the cells.
    private func list(_ o: NSOutlineView) -> NSScrollView {
        let col = NSTableColumn(identifier: .init("scm")); col.resizingMask = .autoresizingMask
        o.addTableColumn(col); o.outlineTableColumn = col
        o.headerView = nil
        o.style = .plain
        o.backgroundColor = .clear
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
        let s = NSScrollView()
        s.documentView = o
        s.hasVerticalScroller = true
        s.drawsBackground = false
        s.autohidesScrollers = true
        return s
    }

    /// The message field (grows to six lines) and Commit with its split menu.
    private func commitBox() -> NSView {
        message.isRichText = false
        message.font = .ui(13)
        message.drawsBackground = false
        message.textContainerInset = NSSize(width: 4, height: 6); message.allowsUndo = true
        message.isAutomaticQuoteSubstitutionEnabled = false; message.isAutomaticDashSubstitutionEnabled = false
        message.isVerticallyResizable = true; message.autoresizingMask = .width
        message.onCommit = { [weak self] in self?.commit(push: false, amend: false) }
        message.onChange = { [weak self] in self?.messageChanged() }
        let s = NSScrollView()
        s.documentView = message
        s.drawsBackground = false
        s.hasVerticalScroller = false
        placeholder.textColor = .placeholderTextColor
        placeholder.font = .ui(13)
        placeholder.lineBreakMode = .byTruncatingTail
        placeholder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)   // a long branch name truncates, not widens the panel
        let field = FieldBox(); field.wantsLayer = true
        commitMenu.add(String(localized: "Commit & Push")) { [weak self] in self?.commit(push: true, amend: false) }
        commitMenu.add(String(localized: "Commit (Amend)")) { [weak self] in self?.commit(push: false, amend: true) }
        syncMenu.add(String(localized: "Push")) { [weak self] in self?.run(done: String(localized: "Pushed")) { GitRemoteOp(id: $0, op: "push") } }
        pullItem = syncMenu.add(String(localized: "Pull")) { [weak self] in self?.run(done: String(localized: "Pulled")) { GitRemoteOp(id: $0, op: "pull") } }
        // The panel's main action: the accent colour while there's something to commit (macOS 26's primary tint).
        // Words alone, as macOS's push buttons: a ✓ or an arrow before them only crowded the title.
        let cb = SplitPushButton(title: String(localized: "Commit"), arrowTip: String(localized: "Commit & Push, Amend…"))
        cb.target = self; cb.action = #selector(commitPressed)
        cb.toolTip = String(localized: "Commit (⌘↩ in the message)")
        cb.arrow.target = self; cb.arrow.action = #selector(showCommitMenu)
        commitButton = cb
        let buttons = cb
        cb.setContentHuggingPriority(.defaultLow, for: .horizontal)
        ciRow.onClick = { [weak self] in self?.openCI() }
        let stack = NSStackView(views: [buttons, ciRow])
        stack.orientation = .vertical
        stack.spacing = 6   // a hidden CI line takes no room
        let box = NSView()
        for x in [field, s, placeholder, stack] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(x) }
        let h = s.heightAnchor.constraint(equalToConstant: 30); messageHeight = h
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: box.topAnchor), field.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            s.topAnchor.constraint(equalTo: field.topAnchor, constant: 1), s.bottomAnchor.constraint(equalTo: field.bottomAnchor, constant: -1),
            s.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 2), s.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -2), h,
            placeholder.leadingAnchor.constraint(equalTo: s.leadingAnchor, constant: 9), placeholder.topAnchor.constraint(equalTo: s.topAnchor, constant: 7),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: s.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8), stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor), stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor), ciRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
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
        cb.title = syncing?.title ?? next ?? (count == 0 ? String(localized: "Commit") : String(localized: "Commit \(count) Files"))
        let idle = next == nil && syncing == nil
        moreMenu = next == nil ? commitMenu : syncMenu
        pullItem?.isHidden = info?.upstream == nil
        cb.action = next == nil ? #selector(commitPressed) : #selector(sync)
        let branch = info?.current ?? "HEAD"
        let what = files > 0 ? String(localized: "Commit the staged files on “\(branch)” (⌘↩ in the message)")
            : String(localized: "Commit all changes on “\(branch)” (⌘↩ in the message)")
        cb.toolTip = next == nil ? what : info?.upstream.map { String(localized: "Pull from and push to \($0)") }
        cb.isEnabled = !busy && (!changes.isEmpty || next != nil)   // with no message, Commit opens a page to write one
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

    func rebuild() { rebuildChanges(); rebuildGraph() }

    /// Sections fold through `collapsed`, not the outline's own expansion state, which goes stale across reloads
    /// (a click then "expanded" a section already open).
    func rebuildChanges() {
        var out: [Node] = []
        func section(_ s: Section, _ files: [FileChange]) {
            guard !files.isEmpty else { return }
            let n = Node(.section(s)); n.files = files
            if !collapsed.contains(s.rawValue) { n.children = files.map { Node(.file($0, s)) } }
            out.append(n)
        }
        let g = changes.grouped
        section(.merge, g.merge)
        section(.staged, g.staged)
        section(.changes, g.changes)
        if changes.isEmpty, info != nil { out.append(Node(.note(String(localized: "No changes")))) }
        if changes.count >= FileChange.limit { out.append(Node(.note(String(localized: "Showing the first \(FileChange.limit) changes")))) }
        roots = out
        outline.reloadData(); outline.expandItem(nil, expandChildren: true)
        let rows = outline.numberOfRows
        let height = rows > 0 ? outline.rect(ofRow: rows - 1).maxY : 0
        changesRoom?.constant = min(80, height)
    }

    private func rebuildGraph() {
        card.close()   // its row is about to be rebuilt
        graphRoots = commits.indices.map { i in
            let n = Node(.commit(i)), h = commits[i].hash
            if openCommits.contains(h) { n.children = (commitFiles[h] ?? []).map { Node(.commitFile(h, $0)) } }
            return n
        }
        graphOutline.reloadData(); graphOutline.expandItem(nil, expandChildren: true)
        layoutGraph()
    }

    /// The graph is a pane of its own under the changes, as in VS Code, so a long list of changes never pushes it
    /// out of sight: its header folds it, dragging the header sizes it.
    func layoutGraph() {
        let has = !commits.isEmpty && empty.isHidden, open = has && !collapsed.contains(Section.graph.rawValue)
        graphBar.isHidden = !has; graphBar.expanded = open
        graphOutline.enclosingScrollView?.isHidden = !open
        barHeight?.constant = has ? GraphBar.height : 0
        // At most half the screen: a height saved while the window was being stretched stays out.
        let saved = UserDefaults.standard.object(forKey: "scm.graphHeight") as? CGFloat
        graphHeight?.constant = min(saved ?? 0, (NSScreen.main?.visibleFrame.height ?? 800) / 2)
        graphHeight?.isActive = open && saved != nil
        graphHalf?.isActive = open && saved == nil
        graphClosed?.isActive = !open
    }

    private func resizeGraph(by dy: CGFloat) {
        guard let gh = graphHeight, graphClosed?.isActive == false, let changes = outline.enclosingScrollView,
              let graph = graphOutline.enclosingScrollView else { return }
        gh.constant = min(max(60, graph.frame.height + dy), changes.frame.height + graph.frame.height - 80)
        graphHalf?.isActive = false; gh.isActive = true
        UserDefaults.standard.set(gh.constant, forKey: "scm.graphHeight")
    }

    private func toggle(_ s: Section) {
        if collapsed.contains(s.rawValue) { collapsed.remove(s.rawValue) } else { collapsed.insert(s.rawValue) }
        UserDefaults.standard.set(Array(collapsed), forKey: "scm.collapsed")
        if s == .graph { layoutGraph() } else { rebuildChanges() }
    }

    private func roots(of o: NSOutlineView) -> [Node] { o === graphOutline ? graphRoots : roots }
    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Node)?.children.count ?? roots(of: o).count }
    func outlineView(_ o: NSOutlineView, child i: Int, ofItem item: Any?) -> Any { (item as? Node)?.children[i] ?? roots(of: o)[i] }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? Node)?.children.isEmpty ?? true) }
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
        guard let n = item as? Node else { return nil }
        switch n.kind {
        case .section(let s):
            // The first section carries what isn't committed yet ("+120 −30"), the header's room being the quick actions'.
            let cell = SectionCell(title: loc(s.rawValue), count: n.files.count, expanded: !collapsed.contains(s.rawValue), actions: sectionActions(s, n),
                                   detail: n === roots.first && !stats.isHidden ? stats.attributedStringValue : nil)
            cell.toolTip = n === roots.first && !stats.isHidden ? stats.toolTip : nil
            return cell
        case .file(let f, let s):
            return FileCell(f, icon: app.fileIcons.image((f.path as NSString).lastPathComponent), letter: Self.letter(f, s),
                            indent: 16, actions: fileActions(f, s))
        case .commit(let i):
            if more, !loadingMore, i >= commits.count - 30 { loadMore() }
            let c = commits[i]
            let pushed: Bool? = info?.remote.isEmpty ?? true ? nil : !unpushed.contains(c.hash)
            let cell = CommitCell(c, graphWidth: graphWidth, isHead: c.hash.hasPrefix(info?.head ?? "\u{0}"), pushed: pushed, landsAfter: landing[c.hash])
            if syncing?.push == true { cell.pulse(true) }
            cell.onHover = { [weak self, weak cell] on in
                if let self, let cell { self.card.hover(on, commit: c, pushed: pushed, over: cell) }
            }
            return cell
        case .commitFile(let h, let f):
            let cell = FileCell(f, icon: app.fileIcons.image((f.path as NSString).lastPathComponent), letter: Self.letter(f, .graph),
                                indent: graphWidth + 4, actions: [])
            // The lanes below the commit run on through its expanded files, as in VS Code.
            let g = GraphView(); g.through = Array(Set(commits.first { $0.hash == h }?.bottom.compactMap(\.last) ?? []))
            g.frame = NSRect(x: 6, y: 0, width: graphWidth, height: 22); g.autoresizingMask = [.height]
            cell.addSubview(g)
            return cell
        case .note(let t):
            return NoteCell(t)
        }
    }

    private func loadMore() {
        loadingMore = true; limit += 200
        DispatchQueue.main.async { [weak self] in Task { await self?.loadGraph() } }
    }

    // MARK: clicks

    @objc private func clicked(_ o: NSOutlineView) {
        card.close()
        guard let n = o.item(atRow: o.clickedRow) as? Node else { return }
        switch n.kind {
        case .section(let s): toggle(s)
        case .file(let f, let s): open(f, s)
        case .commit(let i): toggle(commit: commits[i].hash)
        case .commitFile(let h, let f): if let w = worktreeId { app.workbench.open(DiffTab.uri(w, file: f.path, commit: h)) }
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
        guard commitFiles[hash] == nil, let wid = worktreeId else { rebuildGraph(); return }
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
    func open(_ f: FileChange, _ s: Section) {
        guard let w = worktreeId else { return }
        if s == .merge { openFile(f); return }
        app.workbench.open(DiffTab.uri(w, file: f.path, source: s == .staged ? "staged" : "unstaged"))
    }
    func openFile(_ f: FileChange) {
        if let w = app.worktree(worktreeId) { app.workbench.open(TabURI.file(w.path + "/" + f.path)) }
    }

    static func letter(_ f: FileChange, _ s: Section) -> (String, NSColor) {
        let l = f.letter(inWorktree: s == .changes, merging: s == .merge)
        return (l, .gitLetter(l))
    }
}

// MARK: - cells
