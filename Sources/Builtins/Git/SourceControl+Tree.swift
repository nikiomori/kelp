// Source Control's outline: the changes and graph trees, their rows and cells, and what a click opens.
import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

extension SourceControlController {
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
        let before = Self.flat(roots)   // the nodes kept are filled again below
        var rows = Rows(changeNodes)
        var out: [Node] = []
        func section(_ s: Section, _ files: [FileChange]) {
            guard !files.isEmpty else { return }
            let node = rows.node("s \(s.rawValue)", .section(s))
            node.files = files
            node.children =
                collapsed.contains(s.rawValue)
                ? []
                : files.map { file in
                    let plan = s == .merge ? nil : worktreeId.flatMap { plans[$0]?.number(of: file.path) }
                    return rows.node(
                        "\(s.rawValue) \(file.path)", .file(file, s),
                        look: .file(file, shared: shared[file.path] ?? [], commit: plan))
                }
            out.append(node)
        }
        let grouped = changes.grouped
        section(.merge, grouped.merge)
        section(.staged, grouped.staged)
        section(.changes, grouped.changes)
        if changes.isEmpty, info != nil { out.append(rows.note(String(localized: "No changes"))) }
        if changes.count >= FileChange.limit {
            out.append(rows.note(String(localized: "Showing the first \(FileChange.limit) changes")))
        }
        changeNodes = rows.kept
        roots = out
        _ = show(outline, was: before, rows.redrawn)
        let shown = outline.numberOfRows
        let height = shown > 0 ? outline.rect(ofRow: shown - 1).maxY : 0
        changesRoom?.constant = min(80, height)
        changesHug?.constant = height
        slideStaged(from: places)
    }

    func rebuildGraph() {
        let before = Self.flat(graphRoots)
        var rows = Rows(graphNodes)
        let remote = !(info?.remote.isEmpty ?? true)
        let out = commits.indices.map { index in
            let commit = commits[index], hash = commit.hash
            let look = Node.Look.commit(
                commit, head: hash.hasPrefix(info?.head ?? "\u{0}"), pushed: remote ? !unpushed.contains(hash) : nil,
                lands: landing[hash], arrives: arriving[hash])
            let node = rows.node(hash, .commit(index), look: look)
            let lanes = Array(Set(commit.bottom.compactMap(\.last))).sorted()
            node.children =
                openCommits.contains(hash)
                ? (commitFiles[hash] ?? []).map {
                    rows.node("\(hash) \($0.path)", .commitFile(hash, $0), look: .commitFile($0, lanes: lanes))
                } : []
            return node
        }
        graphNodes = rows.kept
        graphRoots = out
        if show(graphOutline, was: before, rows.redrawn) { card.close() }   // its row was drawn again
        layoutGraph()
    }

    /// The outline after a rebuild. The same rows in the same order: only those whose look changed are drawn again (and
    /// the sections and notes, which say little); else it loads again, the cells set aside coming back for new rows.
    /// Whether any row was drawn again.
    private func show(_ o: NSOutlineView, was before: [Node], _ redrawn: [Node]) -> Bool {
        guard before.elementsEqual(Self.flat(roots(of: o)), by: ===) else {
            o.reloadData()
            o.expandItem(nil, expandChildren: true)
            return true
        }
        let rows = IndexSet(redrawn.map { o.row(forItem: $0) }.filter { $0 >= 0 })
        if !rows.isEmpty { o.reloadData(forRowIndexes: rows, columnIndexes: [0]) }
        return !rows.isEmpty
    }

    /// The rows in order: every node with children is open (folding is `collapsed`'s).
    private static func flat(_ nodes: [Node]) -> [Node] { nodes.flatMap { [$0] + flat($0.children) } }

    /// A rebuild's nodes: the last one's by key, kept, and the ones whose rows are to be drawn again.
    struct Rows {
        private let last: [String: Node]
        private(set) var kept: [String: Node] = [:], redrawn: [Node] = []
        init(_ last: [String: Node]) { self.last = last }
        /// `look` nil: drawn again on every rebuild.
        mutating func node(_ key: String, _ kind: Node.Kind, look: Node.Look? = nil) -> Node {
            let node = last[key] ?? Node(kind)
            if look == nil || node.look != look || last[key] == nil { redrawn.append(node) }
            node.kind = kind
            node.look = look
            kept[key] = node
            return node
        }
        mutating func note(_ text: String) -> Node { node("n \(text)", .note(text)) }
    }

    /// The graph is a pane of its own under the changes, as in VS Code, so a long list of changes never pushes it
    /// out of sight: its header folds it, dragging the header sizes it.
    func layoutGraph() {
        let has = !commits.isEmpty && !empty.showing, open = has && !collapsed.contains(Section.graph.rawValue)
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

    func resizeGraph(by dy: CGFloat) {
        guard let gh = graphHeight, graphClosed?.isActive == false, let changes = outline.enclosingScrollView,
            let graph = graphOutline.enclosingScrollView
        else { return }
        gh.constant = min(max(60, graph.frame.height + dy), changes.frame.height + graph.frame.height - 80)
        changesHug?.isActive = false
        changesCap?.isActive = false
        gh.isActive = true
        UserDefaults.standard.set(gh.constant, forKey: "scm.graphHeight")
    }

    func toggle(_ s: Section) {
        if collapsed.contains(s.rawValue) { collapsed.remove(s.rawValue) } else { collapsed.insert(s.rawValue) }
        UserDefaults.standard.set(Array(collapsed), forKey: "scm.collapsed")
        turning = s
        // What folds isn't moved row by row: it fades into what's there next, as a panel does, not at once.
        if view.window != nil { (s == .graph ? view : outline).crossfade(Motion.base) }
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
    func outlineView(_ o: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { o.listRowView() }
    /// A changed file drags out as itself: into a terminal (an agent's prompt), Finder, another app. A deleted one
    /// has nothing to drag.
    func outlineView(_ o: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard case .file(let file, _)? = (item as? Node)?.kind, let root = app.worktree(worktreeId)?.path else {
            return nil
        }
        let gone = file.worktree == "D" || (file.index == "D" && file.worktree == ".")
        return gone ? nil : URL(fileURLWithPath: root).appendingPathComponent(file.path) as NSURL
    }

    func outlineView(_ o: NSOutlineView, viewFor tc: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        // Each kind's cell: one the outline set aside when its row went, else a new one; `show` sets all it shows.
        switch node.kind {
        case .section(let section):
            let cell = o.makeView(withIdentifier: SectionCell.id, owner: nil) as? SectionCell ?? SectionCell()
            // The first section carries what isn't committed yet ("+120 −30"), the header's room being the quick actions'.
            let first = node === roots.first && !stats.isHidden
            cell.show(
                title: loc(section.rawValue), count: node.files.count, expanded: !collapsed.contains(section.rawValue),
                actions: sectionActions(section, node), detail: first ? stats.attributedStringValue : nil)
            cell.toolTip = first ? stats.toolTip : nil
            cell.turnsIn = turning == section
            return cell
        case .file(let file, let section):
            let cell = o.makeView(withIdentifier: FileCell.id, owner: nil) as? FileCell ?? FileCell()
            cell.show(
                file, icon: app.fileIcons.image((file.path as NSString).lastPathComponent),
                letter: Self.letter(file, section),
                indent: SectionCell.indent, actions: fileActions(file, section), shared: shared[file.path] ?? [],
                commit: section == .merge ? nil : worktreeId.flatMap { plans[$0]?.number(of: file.path) })
            return cell
        case .commit(let index):
            if more, !loadingMore, index >= commits.count - 30 { loadMore() }
            return commitCell(o, commits[index])
        case .commitFile(let hash, let fileChange):
            let commit = commits.first { $0.hash == hash }
            let width = commit.map(Self.graphWidth) ?? GraphView.width(lanes: 1)
            let cell = o.makeView(withIdentifier: FileCell.id, owner: nil) as? FileCell ?? FileCell()
            cell.show(
                fileChange, icon: app.fileIcons.image((fileChange.path as NSString).lastPathComponent),
                letter: Self.letter(fileChange, .graph), indent: width + Metrics.gapWide, actions: [],
                through: (Array(Set(commit?.bottom.compactMap(\.last) ?? [])), width))
            return cell
        case .note(let text):
            let cell = o.makeView(withIdentifier: NoteCell.id, owner: nil) as? NoteCell ?? NoteCell()
            cell.show(text)
            return cell
        }
    }

    private func commitCell(_ o: NSOutlineView, _ commit: GraphCommit) -> CommitCell {
        let cell = o.makeView(withIdentifier: CommitCell.id, owner: nil) as? CommitCell ?? CommitCell()
        let pushed: Bool? = info?.remote.isEmpty ?? true ? nil : !unpushed.contains(commit.hash)
        cell.show(
            commit, graphWidth: Self.graphWidth(commit), isHead: commit.hash.hasPrefix(info?.head ?? "\u{0}"),
            pushed: pushed, landsAfter: landing[commit.hash], arrivesAfter: arriving[commit.hash])
        cell.pulse(syncing?.push == true)
        cell.onHover = { [weak self, weak cell] on in
            if let self, let cell { self.card.hover(on, commit: commit, pushed: pushed, over: cell) }
        }
        return cell
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

    @objc func clicked(_ o: NSOutlineView) {
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
        app.workbench.open(DiffTab.uri(worktree, file: file.path, source: section == .staged ? .staged : .unstaged))
    }
    func openFile(_ file: FileChange) {
        if let worktree = app.worktree(worktreeId) { app.workbench.open(TabURI.file(worktree.path + "/" + file.path)) }
    }

    static func letter(_ file: FileChange, _ section: Section) -> (String, NSColor) {
        let code = file.letter(inWorktree: section == .changes, merging: section == .merge)
        return (code, .gitLetter(code))
    }
}
