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
