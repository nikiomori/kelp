import AppKit
import DesignKit

/// Folding a project or a workspace, and the cards under the projects. The rows under it close up (or open out) and
/// fade while the card and the rows below follow, in one movement; the outline's own animation dropped the leaving
/// rows' text and card, and brought new rows in one by one over a card that grew in steps.
extension SidebarController {
    func updateCard() {
        // Only rows that changed: told of all of them, the table lays every one out, on every session's change.
        let heights = (0..<outline.numberOfRows).map {
            outline.item(atRow: $0).map { outlineView(outline, heightOfRowByItem: $0) } ?? 0
        }
        let changed = heights.indices.filter { !rowHeights.indices.contains($0) || rowHeights[$0] != heights[$0] }
        rowHeights = heights
        if !changed.isEmpty { outline.noteHeightOfRows(withIndexesChanged: IndexSet(changed)) }
        outline.enumerateAvailableRowViews { v, row in self.place(v, row) }
        placeCards()
    }

    /// A double click renames: a click only opens.
    @objc func doubleClicked() {
        guard let node = outline.item(atRow: outline.clickedRow) as? Node else { return }
        switch node.kind {
        case .workspace(let id): startRename(id)
        case .project(let id): startRename(id, project: true)
        default: break
        }
    }

    /// Folds or opens a row (at once under Reduce Motion); a click while it moves turns it back.
    func toggle(_ node: Node) {
        if outline.isItemExpanded(node), folding[node.key] == nil { close(node) } else { open(node) }
    }

    /// The rows under `node` close up to nothing; then the outline folds it for real, where nothing has to move any
    /// more.
    private func close(_ node: Node) {
        // Nothing to watch (Reduce Motion, a window that isn't on screen): folded at once.
        guard !Motion.reduced, outline.window?.isVisible == true else {
            return instantly { outline.collapseItem(node) }
        }
        folds += 1
        let ticket = folds, key = node.key
        folding[key] = ticket
        forRows(under: node) { $0.stopCascade() }
        move(node, rows: 0) { [weak self] in
            guard let self, folding[key] == ticket else { return }   // opened again on the way
            folding[key] = nil
            if let folded = self.node(key) { instantly { outline.collapseItem(folded) } }
        }
    }

    /// Folded: the outline opens it with its rows at no height and they open out from there, coming in one after another
    /// (`cascade`). Still closing: they open out again from where they are.
    func open(_ node: Node) {
        guard folding.removeValue(forKey: node.key) == nil else { return move(node, rows: 1) }
        folding[node.key] = 0
        instantly { outline.expandItem(node) }
        outline.layoutSubtreeIfNeeded()   // the new rows' views, to start from nothing
        forRows(under: node) { $0.alphaValue = 1 }   // a reused view a fold left see-through
        folding[node.key] = nil
        move(node, rows: 1)
        // After the move: its fade to 1 would cover theirs.
        var delay: TimeInterval = 0
        forRows(under: node) {
            $0.cascade(after: delay)
            delay = min(delay + Motion.stagger, Motion.fast)
        }
    }

    /// One movement: the rows under `node` fade to `alpha`, every row takes its height (none under a fold) and each
    /// card its size. `node`'s own row changes in place: its chevron turns, what its agents do fades in or out
    /// (SidebarCell).
    private func move(_ node: Node, rows alpha: CGFloat, then done: (@MainActor () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup(
            { ctx in
                ctx.duration = Motion.duration(Motion.fold)
                ctx.timingFunction = Motion.soft   // it answers the click at once and settles slowly
                // Leaving, the rows fade before they're cut short; coming in, they show as there's room for them.
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

    /// Under a row that is folding: no height.
    func underFold(_ node: Node) -> Bool {
        var up = outline.parent(forItem: node) as? Node
        while let parent = up {
            if folding[parent.key] != nil { return true }
            up = outline.parent(forItem: parent) as? Node
        }
        return false
    }

    /// A project's card from its row to the last row under it: one shape, so it grows and shrinks with the rows (each row
    /// drew a slice of it, which couldn't follow a project opening). A project with nothing under it has none unless its
    /// colour is drawn on one: then it's where the row's pill goes. Under them, one hatched card for each server's
    /// header and projects ("s:<host>"), after a gap: where one machine's projects end and another's begin.
    func placeCards() {
        var shown: Set<String> = [], made = false
        let look = app.arrangement.projectLook
        func put(_ key: String, _ frame: NSRect, _ shows: ProjectCard.Look) {
            shown.insert(key)
            if let card = cards[key] {
                if card.frame != frame { card.animator().frame = frame }   // most news moves no row
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
            // 2 pt around the rows' pills, from under the header's gap.
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
            guard !root.children.isEmpty || color != nil else { continue }
            var frame = SidebarRowView.band(rows, 6)
            // Flipped: 4 in from the first row's top and the last row's bottom, 2 round their content (`pads` 6).
            if root.children.isEmpty {
                frame = frame.insetBy(dx: 0, dy: 1)
            } else {
                frame.origin.y += 4
                frame.size.height -= 8
            }
            // No Project's gap over its row stays outside its card, as the row's pill leaves it (SidebarRowView.gap).
            let gap = serverGap(root)
            frame.origin.y += gap
            frame.size.height -= gap
            put(root.key, frame, ProjectCard.Look(color: color, plain: root.children.isEmpty))
        }
        endServer()
        for (key, card) in cards where !shown.contains(key) {
            card.removeFromSuperview()
            cards[key] = nil
        }
        // A project's card made after its server's went under it: the servers' go back to the bottom.
        if made {
            for (key, card) in cards where key.hasPrefix("s:") {
                outline.addSubview(card, positioned: .below, relativeTo: nil)
            }
        }
    }

    /// The project a row is in: its own row's key, or its group's.
    func project(atRow row: Int) -> String? {
        var node = outline.item(atRow: row) as? Node
        while let up = outline.parent(forItem: node) as? Node { node = up }
        guard case .project? = node?.kind else { return nil }
        return node?.key
    }

    /// A project's group lights up while the pointer is over it, in its colour: its card (Card style) or the halo round
    /// its icon (Icon style). One without a colour stays as it is.
    func glow(_ key: String?, _ on: Bool) {
        guard let key, let node = node(key) else { return }
        cards[key]?.glowing = on
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        // The halo spreads past the row, which clips what it holds for a fold; a project's own row never folds, and a
        // reused row view clips again (SidebarRowView.prepareForReuse).
        if on { outline.rowView(atRow: row, makeIfNecessary: false)?.clipsToBounds = false }
        (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell)?.glowIcon(on)
    }

    /// How many rows may come or go in one change and still move: more is the list changing as a whole.
    var fewRows: Int { foldingHost ? .max : 3 }

    /// The rows on show.
    func shownRows() -> Set<String> {
        Set((0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? Node)?.key })
    }

    /// After a reload: rows that came open out and fade in while the rows below make room. More than a few is the list
    /// being narrowed or filled, not something happening: those just show.
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
            // From a value of its own: set first and animated after, it would start from what the view shows now.
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

    /// Rows `next` doesn't have (an agent ended, a workspace deleted) fade where they stood, as long as they're few.
    func leaveGhosts(of shown: Set<String>, next: [Node]) {
        func keys(_ ns: [Node]) -> [String] { ns.flatMap { [$0.key] + keys($0.children) } }
        let gone = shown.subtracting(keys(next))
        guard !gone.isEmpty, gone.count <= fewRows, let list = outline.enclosingScrollView else { return }
        for key in gone {
            guard let node = node(key), case let row = outline.row(forItem: node), row >= 0 else { continue }
            outline.rowView(atRow: row, makeIfNecessary: false)?.leaveGhost(in: list)
        }
    }

    /// Where the rows on show stand, for `closeUp`.
    func rowPlaces() -> [String: NSPoint] {
        var places: [String: NSPoint] = [:]
        outline.enumerateAvailableRowViews { rowView, row in
            if let key = (outline.item(atRow: row) as? Node)?.key { places[key] = rowView.placeInWindow }
        }
        return places
    }

    /// After a reload: rows that went (an agent ended) leave the ones below moving up into their room, and the cards with
    /// them. As in `settle`, more than a few is the list changing, not something happening.
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

    /// `change` with nothing animated: the rows and cards go straight where they end up.
    func instantly(_ change: () -> Void) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            change()
        }
    }
}

/// The servers' headers in the list (`ServerCards.header`): a header folds its projects away as a project folds its rows.
extension SidebarController {
    func hostFolded(_ host: String) -> Bool { collapsed.contains("h:" + host) }

    func foldHost(_ host: String) {
        if hostFolded(host) { collapsed.remove("h:" + host) } else { collapsed.insert("h:" + host) }
        // Its projects come and go as rows do when something happens, however many: it's one thing folding, not the
        // list being filled.
        foldingHost = true
        refresh()
        foldingHost = false
    }

    /// What a server's header asks of the list: its fold, and the plate under its icon (ServerLook.icon).
    func serverRow(_ host: String) -> ServerRow {
        ServerRow(
            folded: { [weak self] in self?.hostFolded(host) == true },
            fold: { [weak self] in self?.foldHost(host) },
            plate: { [weak self] in
                guard let app = self?.app, ServerLook.of(app) == .icon else { return nil }
                return ProjectCard.stripes(over: .fillRest)
            })
    }

    /// The headers follow the rows and their card's look; each its own server's readings too.
    func updateHeaders() {
        for row in 0..<outline.numberOfRows {
            (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarRow)?.update()
        }
    }
}

extension NSTableRowView {
    /// A row a fold opened comes in after `delay`: it fades in as it drops a few points into place, so the rows arrive
    /// one after another rather than as a block.
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
        both.fillMode = .backwards   // see-through and up while it waits its turn
        layer.add(both, forKey: "cascade")
    }

    /// Folded again before it came all the way in: it goes on from what shows, not from where its cascade would end.
    func stopCascade() {
        guard let layer, layer.animation(forKey: "cascade") != nil else { return }
        alphaValue = CGFloat(layer.presentation()?.opacity ?? 1)
        layer.removeAnimation(forKey: "cascade")
    }
}
