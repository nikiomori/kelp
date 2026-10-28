import AppKit
import DesignKit

/// What a click on a project's row has set off: the fold it made, and whether the click opened the row's workspace
/// (then it doesn't fold).
struct ClickFold {
    var done: (key: String, at: Date)?
    var opened = false
}

/// Folding a project or a workspace, and the cards under the projects. The rows under it close up (or open out) and
/// fade while the card and the rows below follow, in one movement; the outline's own animation dropped the leaving
/// rows' text and card, and brought new rows in one by one over a card that grew in steps.
extension SidebarController {
    /// One click on a project's row folds or unfolds it at once, unless that click opened the workspace the row stands
    /// for. A double click renames it instead: its second click puts the fold back.
    @objc func clicked() {
        defer { clickFold.opened = false }
        guard NSApp.currentEvent?.clickCount == 1, !clickFold.opened, let node = outline.item(atRow: outline.clickedRow) as? Node,
              case .project = node.kind, !node.children.isEmpty else { return }
        toggle(node)
        clickFold.done = (node.key, Date())
    }

    @objc func doubleClicked() {
        guard let node = outline.item(atRow: outline.clickedRow) as? Node else { return }
        if let d = clickFold.done, d.key == node.key, Date().timeIntervalSince(d.at) < NSEvent.doubleClickInterval { toggle(node) }
        clickFold.done = nil
        // A project's row edits the name it shows: the project's, even when it stands for its only workspace.
        switch node.kind {
        case .workspace(let id): startRename(id)
        case .project(let id): startRename(id, project: true)
        default: break
        }
    }

    /// Folds or opens a row (at once under Reduce Motion); a click while it moves turns it back.
    func toggle(_ n: Node) {
        if outline.isItemExpanded(n), folding[n.key] == nil { close(n) } else { open(n) }
    }

    /// The rows under `n` close up to nothing; then the outline folds it for real, where nothing has to move any more.
    private func close(_ n: Node) {
        // Nothing to watch (Reduce Motion, a window that isn't on screen): folded at once.
        guard !Motion.reduced, outline.window?.isVisible == true else { return instantly { outline.collapseItem(n) } }
        folds += 1
        let ticket = folds, key = n.key
        folding[key] = ticket
        move(n, rows: 0) { [weak self] in
            guard let self, folding[key] == ticket else { return }   // opened again on the way
            folding[key] = nil
            if let n = node(key) { instantly { outline.collapseItem(n) } }
        }
    }

    /// Folded: the outline opens it with its rows at no height and see-through, and they open out from there. Still
    /// closing: they open out again from where they are.
    func open(_ n: Node) {
        if folding.removeValue(forKey: n.key) == nil {
            folding[n.key] = 0
            instantly { outline.expandItem(n) }
            outline.layoutSubtreeIfNeeded()   // the new rows' views, to start from nothing
            forRows(under: n) { $0.alphaValue = 0 }
            folding[n.key] = nil
        }
        move(n, rows: 1)
    }

    /// One movement: the rows under `n` fade to `alpha`, every row takes its height (none under a fold) and each card
    /// its size. `n`'s own row changes in place: its chevron turns, what its agents do fades in or out (SidebarCell).
    private func move(_ n: Node, rows alpha: CGFloat, then done: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.duration(Motion.base)
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)   // it answers the click at once
            // Leaving, the rows fade before they're cut short; coming in, they show once there's room for them.
            NSAnimationContext.runAnimationGroup { fade in
                fade.duration = Motion.duration(alpha == 0 ? Motion.fast : Motion.base)
                fade.timingFunction = CAMediaTimingFunction(name: alpha == 0 ? .easeOut : .easeIn)
                forRows(under: n) { $0.animator().alphaValue = alpha }
            }
            updateCard()
        }, completionHandler: done)
        refreshCell(n.key)
    }

    /// The row views shown under `n`.
    private func forRows(under n: Node, _ body: (NSTableRowView) -> Void) {
        let top = outline.row(forItem: n)
        guard top >= 0 else { return }
        let level = outline.level(forRow: top)
        var row = top + 1
        while row < outline.numberOfRows, outline.level(forRow: row) > level {
            if let v = outline.rowView(atRow: row, makeIfNecessary: false) { body(v) }
            row += 1
        }
    }

    /// Under a row that is folding: no height.
    func underFold(_ n: Node) -> Bool {
        var up = outline.parent(forItem: n) as? Node
        while let p = up {
            if folding[p.key] != nil { return true }
            up = outline.parent(forItem: p) as? Node
        }
        return false
    }

    /// A project's card from its row to the last row under it: one shape, so it grows and shrinks with the rows (each row
    /// drew a slice of it, which couldn't follow a project opening). A project with nothing under it has none.
    func placeCards() {
        var shown: Set<String> = []
        for p in roots where !p.children.isEmpty {
            guard case .project = p.kind, case let first = outline.row(forItem: p), first >= 0,
                  case let last = outline.row(forItem: lastRow(p)), last >= 0 else { continue }
            var r = SidebarRowView.band(outline.rect(ofRow: first).union(outline.rect(ofRow: last)), 6)
            r.origin.y += 4; r.size.height -= 8   // flipped: 4 in from the first row's top and the last row's bottom
            shown.insert(p.key)
            if let card = cards[p.key] { card.animator().frame = r; continue }
            let card = ProjectCard(frame: r)
            card.autoresizingMask = .width
            outline.addSubview(card, positioned: .below, relativeTo: nil)
            cards[p.key] = card
        }
        for (key, card) in cards where !shown.contains(key) {
            card.removeFromSuperview()
            cards[key] = nil
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
