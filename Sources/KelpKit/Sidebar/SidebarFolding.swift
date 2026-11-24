import AppKit
import DesignKit

/// Folding a project or a workspace, and the cards under the projects. The rows under the folding row close up (or
/// open out) and fade while the card and the rows below follow, in one movement. The outline's own animation dropped
/// the text and card of the leaving rows, and brought new rows in one by one over a card that grew in steps.
extension SidebarController {
    /// Updates row heights and cards. `only` names the rows whose height can have changed (after an agent's news), and
    /// the other rows keep the height they had.
    func updateCard(only: Set<Node>? = nil) {
        passRowBase = rowBase   // read once for all the rows asked about
        defer { passRowBase = nil }
        let count = outline.numberOfRows
        let known = only != nil && rowHeights.count == count
        let asked = known ? only?.map { outline.row(forItem: $0) }.filter { $0 >= 0 } ?? [] : Array(0..<count)
        var heights = known ? rowHeights : Array(repeating: 0, count: count)
        // Tell the table only about rows that changed. Told of all of them, it lays every row out on every session's
        // change.
        var changed: [Int] = []
        for row in asked {
            heights[row] = outline.item(atRow: row).map { outlineView(outline, heightOfRowByItem: $0) } ?? 0
            if !rowHeights.indices.contains(row) || rowHeights[row] != heights[row] { changed.append(row) }
        }
        rowHeights = heights
        if !changed.isEmpty { outline.noteHeightOfRows(withIndexesChanged: IndexSet(changed)) }
        outline.enumerateAvailableRowViews { v, row in self.place(v, row) }
        placeCards()
    }

    /// A double click renames the row. A single click only opens it.
    @objc func doubleClicked() {
        guard let node = outline.item(atRow: outline.clickedRow) as? Node else { return }
        switch node.kind {
        case .workspace(let id): startRename(id)
        case .project(let id): startRename(id, project: true)
        default: break
        }
    }

    /// Folds or opens a row (at once under Reduce Motion). A click while the row is moving turns it back. A project
    /// folds in the tree instead (`foldProject`).
    func toggle(_ node: Node) {
        if Self.isHeader(node) { return foldProject(node.key) }
        // A screen's row in a folded project holds its chats as logos: the project's fold hides them, so it opens.
        if !node.hidden.isEmpty, let project = outline.parent(forItem: node) as? Node { return unfold(project) }
        if outline.isItemExpanded(node), folding[node.key] == nil { close(node) } else { open(node) }
    }

    /// Folds or opens a project. Folded, it keeps its screens' rows and its chats show as logos on them, so the tree
    /// is built again; the rows that go or come move as one change, however many there are.
    func foldProject(_ key: String) {
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
        foldingHost = true
        refresh()
        foldingHost = false
        refreshCell(key)
    }

    /// Opens a folded row so the rows under it show: a project in the tree, anything else in the outline.
    func unfold(_ node: Node) {
        if Self.isHeader(node) {
            if collapsed.contains(node.key) { foldProject(node.key) }
        } else {
            open(node)
        }
    }

    /// Closes the rows under `node` up to nothing, and then has the outline fold `node` for real, when nothing has to
    /// move any more.
    private func close(_ node: Node) {
        // When nobody can watch (Reduce Motion, or a window that isn't on screen), fold at once.
        guard !Motion.reduced, outline.window?.isVisible == true else {
            return instantly { outline.collapseItem(node) }
        }
        folds += 1
        let ticket = folds, key = node.key
        folding[key] = ticket
        forRows(under: node) { $0.stopCascade() }
        move(node, rows: 0) { [weak self] in
            guard let self, folding[key] == ticket else { return }   // the row was opened again on the way
            folding[key] = nil
            if let folded = self.node(key) { instantly { outline.collapseItem(folded) } }
        }
    }

    /// Opens a row. When it is folded, the outline opens it with its rows at no height, and they open out from there,
    /// coming in one after another (`cascade`). When it is still closing, the rows open out again from where they are.
    func open(_ node: Node) {
        guard folding.removeValue(forKey: node.key) == nil else { return move(node, rows: 1) }
        folding[node.key] = 0
        instantly { outline.expandItem(node) }
        outline.layoutSubtreeIfNeeded()   // makes the views of the new rows, to start from nothing
        forRows(under: node) { $0.alphaValue = 1 }   // a reused view may have been left see-through by a fold
        folding[node.key] = nil
        move(node, rows: 1)
        // Cascade after the move, because the move's fade to 1 would cover the rows' own fades.
        var delay: TimeInterval = 0
        forRows(under: node) {
            $0.cascade(after: delay)
            delay = min(delay + Motion.stagger, Motion.fast)
        }
    }

    /// Runs one movement. The rows under `node` fade to `alpha`, every row takes its height (zero under a fold), and
    /// each card takes its size. The row of `node` changes in place: its chevron turns, and what its agents do fades in
    /// or out (SidebarCell).
    private func move(_ node: Node, rows alpha: CGFloat, then done: (@MainActor () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup(
            { ctx in
                ctx.duration = Motion.duration(Motion.fold)
                ctx.timingFunction = Motion.soft   // answers the click at once and settles slowly
                // Leaving rows fade before they're cut short. Arriving rows show as there's room for them.
                NSAnimationContext.runAnimationGroup { fade in
                    fade.duration = Motion.duration(alpha == 0 ? Motion.base : Motion.fold)
                    fade.timingFunction = CAMediaTimingFunction(name: alpha == 0 ? .easeOut : .easeInEaseOut)
                    forRows(under: node) { $0.animator().alphaValue = alpha }
                }
                updateCard()
            }, completionHandler: { MainActor.assumeIsolated { done?() } })   // AppKit ends the group on the main thread
        refreshCell(node.key)
    }

    /// The row views shown under `node`, top to bottom.
    private func forRows(under node: Node, _ body: (NSTableRowView) -> Void) {
        let top = outline.row(forItem: node)
        guard top >= 0 else { return }
        let level = outline.level(forRow: top)
        var row = top + 1
        while row < outline.numberOfRows, outline.level(forRow: row) > level {
            if let rowView = outline.rowView(atRow: row, makeIfNecessary: false) { body(rowView) }
            row += 1
        }
    }

    /// Returns whether `node` is under a row that is folding, which gives it no height.
    func underFold(_ node: Node) -> Bool {
        var up = outline.parent(forItem: node) as? Node
        while let parent = up {
            if folding[parent.key] != nil { return true }
            up = outline.parent(forItem: parent) as? Node
        }
        return false
    }

    /// Places the cards. A project's card runs from the project's row to the last row under it, drawn as one shape so
    /// it grows and shrinks with the rows (when each row drew a slice of it, the card couldn't follow a project
    /// opening). A project with nothing under it has no card unless its colour is drawn on one, and then the card is
    /// where the row's pill goes. Below the project cards, after a gap, there is one hatched card for each server's
    /// header and its projects ("s:<host>"), marking where one machine's projects end and another's begin.
    func placeCards() {
        var shown: Set<String> = [], made = false
        let look = app.arrangement.projectLook
        func put(_ key: String, _ frame: NSRect, _ shows: ProjectCard.Look) {
            shown.insert(key)
            if let card = cards[key] {
                if card.frame != frame { card.animator().frame = frame }   // most news doesn't move any row
                card.look = shows
                return
            }
            let card = ProjectCard(frame: frame)
            card.look = shows
            card.glowing = key == glowing
            card.autoresizingMask = .width
            outline.addSubview(card, positioned: .below, relativeTo: nil)
            cards[key] = card
            made = true
        }
        var server: (host: String, rows: NSRect)?
        func endServer() {
            guard let current = server else { return }
            // The card reaches 2 pt past the pills of its rows, starting below the header's gap.
            var frame = SidebarRowView.band(current.rows, 4).insetBy(dx: 0, dy: -1)
            frame.origin.y += Self.serverGap
            frame.size.height -= Self.serverGap
            put("s:" + current.host, frame, ProjectCard.Look(color: nil, plain: true, remote: ServerLook.of(app)))
            server = nil
        }
        for root in roots {
            guard case let first = outline.row(forItem: root), first >= 0,
                case let last = outline.row(forItem: lastRow(root)), last >= 0
            else { continue }
            let rows = outline.rect(ofRow: first).union(outline.rect(ofRow: last))
            if case .host(let host) = root.kind {   // a server's card starts at its header
                endServer()
                server = (host, rows)
                continue
            }
            guard case .project(let id) = root.kind else { continue }
            if let host = projectHosts[id], let current = server, host == current.host {
                server = (host, current.rows.union(rows))
            } else {
                endServer()
            }
            let color = look.style == .card ? look.colors[id] : nil
            guard root.holds || color != nil else { continue }
            var frame = SidebarRowView.band(rows, 6)
            // The outline is flipped. The card starts 4 pt below the first row's top and ends 4 pt above the last row's
            // bottom, which leaves 2 pt round the rows' content (`pads` is 6).
            if !root.holds {
                frame = frame.insetBy(dx: 0, dy: 1)
            } else {
                frame.origin.y += 4
                frame.size.height -= 8
            }
            // The gap above the No Project row stays outside its card, as the row's pill leaves it out
            // (SidebarRowView.gap).
            let gap = serverGap(root)
            frame.origin.y += gap
            frame.size.height -= gap
            put(root.key, frame, ProjectCard.Look(color: color, plain: !root.holds))
        }
        endServer()
        for (key, card) in cards where !shown.contains(key) {
            card.removeFromSuperview()
            cards[key] = nil
        }
        // A project's card made after its server's card went under it, so the server cards go back to the bottom.
        if made {
            for (key, card) in cards where key.hasPrefix("s:") {
                outline.addSubview(card, positioned: .below, relativeTo: nil)
            }
        }
    }

    /// Returns the key of the project row that `row` is in: the row itself, or the row it sits under.
    func project(atRow row: Int) -> String? {
        var node = outline.item(atRow: row) as? Node
        while let up = outline.parent(forItem: node) as? Node { node = up }
        guard case .project? = node?.kind else { return nil }
        return node?.key
    }

    /// Lights up a project's group in its colour while the pointer is over it: the card (Card style) or the halo round
    /// the project's icon (Icon style). A project without a colour stays as it is.
    func glow(_ key: String?, _ on: Bool) {
        guard let key, let node = node(key) else { return }
        cards[key]?.glowing = on
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        // The halo spreads past the row, and rows clip their content for a fold. A project's own row never folds, so it
        // can stop clipping, and a reused row view clips again (SidebarRowView.prepareForReuse).
        if on { outline.rowView(atRow: row, makeIfNecessary: false)?.clipsToBounds = false }
        (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell)?.glowIcon(on)
    }

    /// How many rows may come or go in one change and still animate. More than that means the list is changing as a
    /// whole.
    var fewRows: Int { foldingHost ? .max : 3 }

    /// The keys of the rows on show.
    func shownRows() -> Set<String> {
        Set((0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? Node)?.key })
    }

    /// After a reload, new rows open out and fade in while the rows below make room. More than a few new rows means
    /// the list is being narrowed or filled, not that something happened, so those rows just show.
    func settle(from old: Set<String>) {
        guard !old.isEmpty, !Motion.reduced, outline.window?.isVisible == true else { return }
        let came = shownRows().subtracting(old)
        guard !came.isEmpty, came.count <= fewRows else { return }
        arriving = came
        instantly { updateCard() }
        outline.layoutSubtreeIfNeeded()
        arriving = []
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.appear
            ctx.timingFunction = Motion.soft
            updateCard()
        }
        for key in came {
            // Animate from an explicit start value, because a value set first and animated after would start from what
            // the view shows now.
            guard let node = node(key),
                let rowView = outline.rowView(atRow: outline.row(forItem: node), makeIfNecessary: false)
            else { continue }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = Motion.appear
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            rowView.layer?.add(fade, forKey: "arrive")
        }
    }

    /// Fades out the rows that `next` doesn't have (an agent ended, a workspace was deleted) where they stood, as long
    /// as there are only a few.
    func leaveGhosts(of shown: Set<String>, next: [Node]) {
        func keys(_ ns: [Node]) -> [String] { ns.flatMap { [$0.key] + keys($0.children) } }
        let gone = shown.subtracting(keys(next))
        guard !gone.isEmpty, gone.count <= fewRows, let list = outline.enclosingScrollView else { return }
        for key in gone {
            guard let node = node(key), case let row = outline.row(forItem: node), row >= 0 else { continue }
            // An empty group whose time ran out fades over a fold's time, drifting up into its project.
            let due = (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell)?.ranOut == true
            outline.rowView(atRow: row, makeIfNecessary: false)?.leaveGhost(
                in: list, duration: due ? Motion.fold : Motion.base, drift: due ? Metrics.gap : 0)
        }
    }

    /// The positions of the rows on show, for `closeUp`.
    func rowPlaces() -> [String: NSPoint] {
        var places: [String: NSPoint] = [:]
        outline.enumerateAvailableRowViews { rowView, row in
            if let key = (outline.item(atRow: row) as? Node)?.key { places[key] = rowView.placeInWindow }
        }
        return places
    }

    /// After a reload, when rows went away (an agent ended), the rows below move up into their room and the cards move
    /// with them. As in `settle`, more than a few rows means the list is changing, not that something happened.
    func closeUp(after old: Set<String>, rows: [String: NSPoint], cards was: [String: NSRect]) {
        guard !old.isEmpty, !Motion.reduced, outline.window?.isVisible == true else { return }
        let now = shownRows(), gone = old.subtracting(now)
        guard !gone.isEmpty, gone.count <= fewRows, now.isSubset(of: old) else { return }
        outline.enumerateAvailableRowViews { rowView, row in
            if let key = (outline.item(atRow: row) as? Node)?.key, let place = rows[key] { rowView.slide(from: place) }
        }
        let ends = cards.mapValues(\.frame)
        for (key, card) in cards { if let frame = was[key] { card.frame = frame } }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.appear
            ctx.timingFunction = Motion.soft
            for (key, card) in cards { if let end = ends[key] { card.animator().frame = end } }
        }
    }

    /// Runs `change` with nothing animated, so the rows and cards go straight to where they end up.
    func instantly(_ change: () -> Void) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            change()
        }
    }
}

/// The server headers in the list (`ServerCards.header`). A header folds its projects away as a project folds its rows.
extension SidebarController {
    func hostFolded(_ host: String) -> Bool { collapsed.contains("h:" + host) }

    func foldHost(_ host: String) {
        if hostFolded(host) { collapsed.remove("h:" + host) } else { collapsed.insert("h:" + host) }
        // The server's projects come and go as rows do when something happens, however many there are, because this
        // is one thing folding, not the list being filled.
        foldingHost = true
        refresh()
        foldingHost = false
    }

    /// What a server's header needs from the list: whether it is folded, and the plate under its icon
    /// (ServerLook.icon).
    func serverRow(_ host: String) -> ServerRow {
        ServerRow(
            folded: { [weak self] in self?.hostFolded(host) == true },
            fold: { [weak self] in self?.foldHost(host) },
            plate: { [weak self] in
                guard let app = self?.app, ServerLook.of(app) == .icon else { return nil }
                return ProjectCard.stripes(over: .fillRest)
            })
    }

    /// Updates the headers to follow the rows and the look of their cards. Each header also updates its own server's
    /// readings.
    func updateHeaders() {
        for row in 0..<outline.numberOfRows {
            (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarRow)?.update()
        }
    }
}

extension NSTableRowView {
    /// Brings in a row that a fold opened after `delay`. It fades in as it drops a few points into place, so the rows
    /// arrive one after another instead of as a block.
    fileprivate func cascade(after delay: TimeInterval) {
        guard !Motion.reduced, window?.isVisible == true, let layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let drop = CABasicAnimation(keyPath: "transform.translation.y")
        drop.fromValue = superview?.isFlipped == true ? -Metrics.gap : Metrics.gap   // from above
        drop.toValue = 0
        let both = CAAnimationGroup()
        both.animations = [fade, drop]
        both.duration = Motion.fold
        both.timingFunction = Motion.soft
        both.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        both.fillMode = .backwards   // the row stays see-through and raised while it waits its turn
        layer.add(both, forKey: "cascade")
    }

    /// Stops the cascade of a row that was folded again before it came all the way in. The row goes on from what it
    /// shows now, not from where its cascade would end.
    func stopCascade() {
        guard let layer, layer.animation(forKey: "cascade") != nil else { return }
        alphaValue = CGFloat(layer.presentation()?.opacity ?? 1)
        layer.removeAnimation(forKey: "cascade")
    }
}
