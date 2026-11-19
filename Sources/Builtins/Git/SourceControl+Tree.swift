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

    /// Sections fold through `collapsed`, not through the outline's own expansion state, which goes stale across
    /// reloads (a click then "expanded" a section that was already open).
    func rebuildChanges() {
        let places = stagingPlaces()
        if clearing {
            clearing = false
            outline.crossfade(Motion.base)
        }
        let before = Self.flat(roots)   // the nodes that are kept get filled again below
        var rows = Rows(changeNodes)
        var out: [Node] = []
        func section(_ section: Section, _ files: [FileChange]) {
            guard !files.isEmpty else { return }
            let node = rows.node("s \(section.rawValue)", .section(section))
            node.files = files
            node.children =
                collapsed.contains(section.rawValue)
                ? []
                : files.map { file in
                    let plan = section == .merge ? nil : worktreeId.flatMap { plans[$0]?.number(of: file.path) }
                    return rows.node(
                        "\(section.rawValue) \(file.path)", .file(file, section),
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
        changesRows = height
        fitChanges()
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
        if show(graphOutline, was: before, rows.redrawn) { card.close() }   // the card's row was drawn again
        layoutGraph()
    }

    /// Shows the outline after a rebuild and returns whether any row was drawn again. When the rows are the same and
    /// in the same order, only those whose look changed are drawn again (and the sections and notes, which say
    /// little). Otherwise the outline loads again, and the cells it set aside come back for new rows.
    private func show(_ outline: NSOutlineView, was before: [Node], _ redrawn: [Node]) -> Bool {
        guard before.elementsEqual(Self.flat(roots(of: outline)), by: ===) else {
            outline.reloadData()
            outline.expandItem(nil, expandChildren: true)
            return true
        }
        let rows = IndexSet(redrawn.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
        if !rows.isEmpty { outline.reloadData(forRowIndexes: rows, columnIndexes: [0]) }
        return !rows.isEmpty
    }

    /// The rows in order, with every node that has children open (folding is up to `collapsed`).
    private static func flat(_ nodes: [Node]) -> [Node] { nodes.flatMap { [$0] + flat($0.children) } }

    /// A rebuild's nodes: the nodes of the previous rebuild kept by key, and the ones whose rows must be drawn again.
    struct Rows {
        private let last: [String: Node]
        private(set) var kept: [String: Node] = [:], redrawn: [Node] = []
        init(_ last: [String: Node]) { self.last = last }
        /// When `look` is nil, the node is drawn again on every rebuild.
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

    /// The graph is a pane of its own under the changes, as in VS Code, so a long list of changes never pushes it out
    /// of sight. Its header folds it, and dragging the header sizes it.
    func layoutGraph() {
        let has = !commits.isEmpty && !empty.showing, open = has && !collapsed.contains(Section.graph.rawValue)
        graphBar.isHidden = !has
        graphBar.expanded = open
        graphOutline.enclosingScrollView?.isHidden = !open
        barHeight?.constant = has ? GraphBar.height : 0
        // At most half the screen, so a height saved while the window was being stretched stays out.
        let saved = UserDefaults.standard.object(forKey: "scm.graphHeight") as? CGFloat
        graphHeight?.constant = min(saved ?? 0, (NSScreen.main?.visibleFrame.height ?? 800) / 2)
        graphHeight?.isActive = open && saved != nil
        changesHug?.isActive = open   // the changes are as tall as their rows; the graph has the rest
        changesCap?.isActive = false
        fitChanges()
        graphClosed?.isActive = !open
    }

    /// Gives the changes their rows' height, up to what leaves the graph its least: the height it was dragged to, or
    /// else half the room the two lists share. The graph takes the rest. Worked out from the lists' room as it stands,
    /// so it never asks the window to grow.
    func fitChanges() {
        guard let hug = changesHug, hug.isActive, let changes = outline.enclosingScrollView,
            let graph = graphOutline.enclosingScrollView
        else { return }
        let both = changes.frame.height + graph.frame.height
        guard both > 0 else { return }
        let saved = UserDefaults.standard.object(forKey: "scm.graphHeight") as? CGFloat
        let least = min(saved ?? both / 2, max(0, both - 80))
        let fit = max(min(changesRows, both - least), min(80, changesRows))
        if abs(hug.constant - fit) > 0.5 { hug.constant = fit }
    }

    func resizeGraph(by dy: CGFloat) {
        guard let gh = graphHeight, graphClosed?.isActive == false, let changes = outline.enclosingScrollView,
            let graph = graphOutline.enclosingScrollView
        else { return }
        gh.constant = min(max(60, graph.frame.height + dy), changes.frame.height + graph.frame.height - 80)
        gh.isActive = true
        fitChanges()   // the changes still hug their rows: dragging never opens empty room
        UserDefaults.standard.set(gh.constant, forKey: "scm.graphHeight")
    }

    func toggle(_ section: Section) {
        if collapsed.contains(section.rawValue) {
            collapsed.remove(section.rawValue)
        } else {
            collapsed.insert(section.rawValue)
        }
        UserDefaults.standard.set(Array(collapsed), forKey: "scm.collapsed")
        turning = section
        // What folds isn't moved row by row. It fades into what's there next, as a panel does, rather than at once.
        if view.window != nil { (section == .graph ? view : outline).crossfade(Motion.base) }
        if section == .graph { layoutGraph() } else { rebuildChanges() }
        // The outline asks for the cell when it lays out, so `turning` is cleared after that.
        DispatchQueue.main.async { [weak self] in self?.turning = nil }
    }

    private func roots(of outline: NSOutlineView) -> [Node] { outline === graphOutline ? graphRoots : roots }
    func outlineView(_ outline: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? roots(of: outline).count
    }
    func outlineView(_ outline: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? roots(of: outline)[index]
    }
    func outlineView(_ outline: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Node)?.children.isEmpty ?? true)
    }
    func outlineView(_ outline: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { false }
    func outlineView(_ outline: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        switch (item as? Node)?.kind {
        case .section?, .note?: TextSize.of(Metrics.rowSection)
        case .commit?: CommitCell.lineHeight
        default: TextSize.of(Metrics.row)
        }
    }
    func outlineView(_ outline: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        if case .note? = (item as? Node)?.kind { return false }
        return true
    }
    func outlineView(_ outline: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { outline.listRowView() }
    /// A changed file drags out as itself: into a terminal (an agent's prompt), Finder, or another app. A deleted file
    /// has nothing to drag.
    func outlineView(_ outline: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard case .file(let file, _)? = (item as? Node)?.kind, let root = app.worktree(worktreeId)?.path else {
            return nil
        }
        let gone = file.worktree == "D" || (file.index == "D" && file.worktree == ".")
        return gone ? nil : URL(fileURLWithPath: root).appendingPathComponent(file.path) as NSURL
    }

    func outlineView(_ outline: NSOutlineView, viewFor tc: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        // Each kind has its cell: one the outline set aside when its row went, else a new one. `show` sets everything
        // the cell shows.
        switch node.kind {
        case .section(let section):
            let cell = outline.makeView(withIdentifier: SectionCell.id, owner: nil) as? SectionCell ?? SectionCell()
            // The first section shows what isn't committed yet ("+120 −30"), because the header's room is for the
            // quick actions.
            let first = node === roots.first && !stats.isHidden
            cell.show(
                title: loc(section.rawValue), count: node.files.count, expanded: !collapsed.contains(section.rawValue),
                actions: sectionActions(section, node), detail: first ? stats.attributedStringValue : nil)
            cell.toolTip = first ? stats.toolTip : nil
            cell.turnsIn = turning == section
            return cell
        case .file(let file, let section):
            let cell = outline.makeView(withIdentifier: FileCell.id, owner: nil) as? FileCell ?? FileCell()
            cell.show(
                file, icon: app.fileIcons.image((file.path as NSString).lastPathComponent),
                letter: Self.letter(file, section),
                indent: SectionCell.indent, actions: fileActions(file, section), shared: shared[file.path] ?? [],
                commit: section == .merge ? nil : worktreeId.flatMap { plans[$0]?.number(of: file.path) })
            return cell
        case .commit(let index):
            if more, !loadingMore, index >= commits.count - 30 { loadMore() }
            return commitCell(outline, commits[index])
        case .commitFile(let hash, let fileChange):
            let commit = commits.first { $0.hash == hash }
            let width = commit.map(Self.graphWidth) ?? GraphView.width(lanes: 1)
            let cell = outline.makeView(withIdentifier: FileCell.id, owner: nil) as? FileCell ?? FileCell()
            cell.show(
                fileChange, icon: app.fileIcons.image((fileChange.path as NSString).lastPathComponent),
                letter: Self.letter(fileChange, .graph), indent: width + Metrics.gapWide, actions: [],
                through: (Array(Set(commit?.bottom.compactMap(\.last) ?? [])), width))
            return cell
        case .note(let text):
            let cell = outline.makeView(withIdentifier: NoteCell.id, owner: nil) as? NoteCell ?? NoteCell()
            cell.show(text)
            return cell
        }
    }

    private func commitCell(_ outline: NSOutlineView, _ commit: GraphCommit) -> CommitCell {
        let cell = outline.makeView(withIdentifier: CommitCell.id, owner: nil) as? CommitCell ?? CommitCell()
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

    /// As wide as the lanes this commit's row draws, not the widest point of the whole graph, because one crossing far
    /// down made every row start its subject two lanes away from its line.
    static func graphWidth(_ commit: GraphCommit) -> CGFloat {
        let lanes = ([commit.lane] + commit.top.flatMap { $0 } + commit.bottom.flatMap { $0 }).max() ?? 0
        return GraphView.width(lanes: min(lanes + 1, GraphView.maxLanes))
    }

    private func loadMore() {
        loadingMore = true
        limit += 200
        DispatchQueue.main.async { [weak self] in Task { await self?.loadGraph() } }
    }

    // MARK: clicks

    @objc func clicked(_ outline: NSOutlineView) {
        card.close()
        guard let node = outline.item(atRow: outline.actedRow) as? Node else { return }
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
            // When a click unfolds the commit and its files can't be read, a banner says why and the commit folds back,
            // so the user can ask again.
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
        // When a review beside it shows the file, the review scrolls there instead.
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
