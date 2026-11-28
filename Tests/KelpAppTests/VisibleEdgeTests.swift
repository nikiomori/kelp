import AppKit
import Core
import DesignKit
import Testing

@testable import BuiltinGit
@testable import KelpKit

// Rows and bars line up what they show, not the frames of their controls: a glyph or words without a plate end on the
// row's edge, as a label's words do.
private let atlas = Repo(id: "r1", name: "Atlas", path: "/tmp/kelp-edge-atlas")
private let home = Worktree(id: "w1", repoId: "r1", branch: "main", path: atlas.path)

/// Where a button draws at rest, in its own bounds: its plate when it rests on one, else its image and words.
@MainActor private func drawn(_ button: PointerButton) -> NSRect {
    if button.restFill != nil { return button.bounds }
    let cell = button.cell as? NSButtonCell
    var rect = NSRect.null
    if button.image != nil, button.imagePosition != .noImage, let cell {
        rect = cell.imageRect(forBounds: button.bounds)
    }
    let words = button.attributedTitle.size().width
    if words > 0, button.imagePosition != .imageOnly, let room = cell?.titleRect(forBounds: button.bounds) {
        rect = rect.union(NSRect(x: room.midX - words / 2, y: room.minY, width: words, height: room.height))
    }
    return rect
}

/// The mark that ends a project's row in each case, and how to make it the last.
enum RowEnd: CaseIterable, Sendable {
    case dot, pr, ci, count, plus
}

extension OneAtATime {
    /// Whichever mark ends a project's row (the changes dot, the PR's pill, the CI mark, a folded project's count, the
    /// "+" under the pointer), it ends on one line, the cell's edge, 8 pt inside the card, and so does what it draws.
    @Test(arguments: RowEnd.allCases)
    func aRowsLastMarkEndsOnTheRowsEdge(_ last: RowEnd) throws {
        let idle = Session(worktreeId: "w1", cwd: "/", command: "claude", agent: "claude", status: .idle, title: "A")
        try withSidebar(repos: [atlas], worktrees: [home], sessions: last == .count ? [idle] : []) { vc, o in
            if last == .count { vc.toggle(try #require(o.item(atRow: 0) as? SidebarController.Node)) }
            vc.view.frame.size.width = 280
            vc.view.layoutSubtreeIfNeeded()
            let cell = try #require(o.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SidebarCell)
            cell.pr.attributedTitle = NSAttributedString(
                string: "#3", attributes: [.font: NSFont.ui(TextSize.caption), .foregroundColor: NSColor.labelColor])
            cell.pr.restFill = .fillRest
            cell.pr.padding = Metrics.gap
            cell.hasBadge = (last == .dot, last == .pr, last == .ci)
            cell.fitBadges()
            if last == .plus { cell.showHoverControls(true) }
            cell.layoutSubtreeIfNeeded()
            let row = try #require(cell.changes.superview as? NSStackView)
            let shown = row.arrangedSubviews.filter { !$0.isHidden && $0.superview != nil && $0.frame.width > 0 }
            // The + stands over the row's end, not in the row.
            let end = try #require(last == .plus ? cell.add : shown.last)
            let expected: NSView =
                switch last {
                case .dot: cell.changes
                case .pr: cell.pr
                case .ci: cell.ci
                case .count: cell.stack
                case .plus: end
                }
            #expect(end === expected)
            let edge = cell.bounds.maxX
            let lined = cell.convert(end.alignmentRect(forFrame: end.frame), from: end.superview)
            #expect(abs(lined.maxX - edge) < 0.01, "\(last): lined up at \(lined.maxX), the edge is \(edge)")
            // What it draws ends there too: the dot, the pill, the CI mark's place, the count's words, the "+".
            let button = try #require(
                last == .count
                    ? end.subviews.compactMap { $0 as? PointerButton }.first { !$0.isHidden && !$0.title.isEmpty }
                    : end as? PointerButton)
            let ink = cell.convert(drawn(button), from: button)
            #expect(abs(ink.maxX - edge) <= 0.5, "\(last): drawn to \(ink.maxX), the edge is \(edge)")
        }
    }

    /// The + comes in under the pointer where the row's last mark is, over it, so no mark moves: each keeps its frame,
    /// the one under the + fades while it shows, and the +'s glyph ends on the row's edge.
    @Test func theRowsPlusComesInWithoutMovingItsMarks() throws {
        let idle = Session(worktreeId: "w1", cwd: "/", command: "claude", agent: "claude", status: .idle, title: "A")
        try withSidebar(repos: [atlas], worktrees: [home], sessions: [idle]) { vc, o in
            vc.toggle(try #require(o.item(atRow: 0) as? SidebarController.Node))
            vc.view.frame.size.width = 280
            vc.view.layoutSubtreeIfNeeded()
            let cell = try #require(o.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SidebarCell)
            let add = try #require(cell.add as? PointerButton)
            cell.hasBadge = (true, false, false)
            cell.fitBadges()
            cell.layoutSubtreeIfNeeded()
            let row = try #require(cell.changes.superview as? NSStackView)
            let frames = { row.arrangedSubviews.map { $0.isHidden ? NSRect.zero : $0.frame } }
            let before = frames()
            #expect(!cell.changes.isHidden && !cell.stack.isHidden)   // the count, then the dot
            cell.showHoverControls(true)
            cell.layoutSubtreeIfNeeded()
            #expect(frames() == before)
            #expect(!add.isHidden && cell.changes.alphaValue == 0 && cell.stack.alphaValue == 1)
            let glyph = cell.convert(drawn(add), from: add)
            #expect(abs(glyph.maxX - cell.bounds.maxX) <= 0.5, "the + ends at \(glyph.maxX)")
            cell.showHoverControls(false)
            cell.layoutSubtreeIfNeeded()
            #expect(frames() == before && add.isHidden && cell.changes.alphaValue == 1)
        }
    }

    /// A panel's bar ends its last icon's glyph at the bar's trailing inset, and two icons side by side keep their
    /// squares `iconGap` apart, so their hover greys don't meet.
    @Test func aPanelBarEndsItsLastGlyphAtItsInset() throws {
        let first = IconButton(.symbol("arrow.clockwise"), tip: "Refresh") {}
        let last = IconButton(.symbol("ellipsis"), tip: "More") {}
        let bar = Bar.panel([NSTextField(labelWithString: "Changes")], [first, last])
        bar.frame = NSRect(x: 0, y: 0, width: 300, height: 37)
        bar.layoutSubtreeIfNeeded()
        let lined = bar.convert(last.alignmentRect(forFrame: last.frame), from: last.superview)
        #expect(abs(lined.maxX - (300 - Metrics.insetTrailing)) < 0.01)
        let glyph = bar.convert(drawn(last), from: last)
        #expect(abs(glyph.maxX - lined.maxX) <= 0.5)
        #expect(last.frame.width == Metrics.iconButton && first.frame.width == Metrics.iconButton)
        // Within a pixel at 1x: the stack rounds the glyphs' rects, and a square is a fraction of a point round them.
        let apart = last.frame.minX - first.frame.maxX
        #expect(abs(apart - Metrics.iconGap) <= 0.5, "the squares are \(apart) pt apart")
    }

    /// The branch popover's Commit, before a message is typed, is its word alone, and the word ends on the column, as
    /// the "+2 −1" over it does.
    @Test func theCommitWordEndsOnThePopoversColumn() throws {
        _ = testHome
        let app = AppModel(builtins: [])
        app.repos = [atlas]
        app.worktrees = [home]
        app.land(
            GitEvent(
                worktree: app.gitKey("w1"), changes: [FileChange(path: "a.txt", index: ".", worktree: "M")],
                stats: LineStats(added: [.code: 2], removed: [.code: 1])))
        let popover = SyncPopover(app: app, worktree: "w1")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 600), styleMask: [.titled], backing: .buffered,
            defer: true)   // never shown
        window.contentViewController = popover
        popover.update()
        popover.view.layoutSubtreeIfNeeded()
        let commit = popover.commit, root = popover.view, stats = popover.stats
        #expect(!commit.isEnabled && !commit.isBordered && !stats.stringValue.isEmpty)
        let cell = try #require(commit.cell as? NSButtonCell)
        let words = commit.attributedTitle.size().width, room = cell.titleRect(forBounds: commit.bounds)
        let right = commit.alignment == .right ? room.maxX : room.midX + words / 2
        let end = root.convert(NSPoint(x: right, y: 0), from: commit).x
        let column = root.convert(stats.alignmentRect(forFrame: stats.frame), from: stats.superview).maxX
        #expect(abs(end - column) <= 0.5, "Commit ends at \(end), the column at \(column)")
    }
}
