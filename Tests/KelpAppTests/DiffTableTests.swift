import AppKit
import Core
import Testing

@testable import BuiltinGit
@testable import KelpApp
@testable import KelpKit

/// A review's table in a window that's never shown, filling it: such a window doesn't lay out the split view around it.
@MainActor private func diffInAWindow() -> (DiffViewController, NSWindow) {
    let vc = DiffViewController(app: AppModel(builtins: Builtins.all))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
    _ = vc.view
    window.contentView = vc.table.enclosingScrollView
    return (vc, window)
}

/// A row of `line` in whichever layout the table has: on the new side, or on both.
@MainActor private func row(_ vc: DiffViewController, _ line: DiffLine, both: Bool = false) -> ReviewRow {
    vc.sideBySide ? .diff(.pair(file: 0, left: both ? line : nil, right: line)) : .diff(.line(file: 0, line))
}

/// Every cell a table shows now, at whatever row and column.
@MainActor func shownCells(_ table: NSTableView) -> [NSView] {
    let rows = table.rows(in: table.visibleRect)
    return (rows.lowerBound..<rows.upperBound).flatMap { r in
        (0..<table.numberOfColumns).compactMap { table.view(atColumn: $0, row: r, makeIfNecessary: false) }
    }
}

/// A long line is measured once: asked again, or after a reload that keeps it, its height comes from what was counted.
@MainActor @Test func aWrappedLineIsMeasuredOnce() {
    let (vc, window) = diffInAWindow()
    defer { withExtendedLifetime(window) {} }
    let long = DiffLine(kind: .add, text: Array(repeating: "words", count: 200).joined(separator: " "), newLine: 1)
    vc.rows = [row(vc, long)]
    let first = vc.height(of: 0)
    #expect(first > DiffViewController.lineHeight)   // it wraps
    #expect(vc.height(of: 0) == first)
    vc.rows = [row(vc, DiffLine(kind: .add, text: "short", newLine: 2)), row(vc, long)]
    #expect(vc.height(of: 1) == first)
    #expect(vc.wraps.measured == 1)
}

/// A cell scrolled away comes back for a row scrolled to, set over in full: no tint of the line it showed before.
@MainActor @Test func diffCellsAreReusedAndReset() throws {
    let (vc, window) = diffInAWindow()
    defer { withExtendedLifetime(window) {} }
    vc.diffs = [FileDiff(path: "f.txt", header: "", hunks: [], binary: false)]   // a row's line is of a file
    vc.rows =
        [row(vc, DiffLine(kind: .add, text: "added", newLine: 1), both: true)]
        + (2...300).map { (n: Int) in
            row(vc, DiffLine(kind: .context, text: "same \(n)", oldLine: n, newLine: n), both: true)
        }
    vc.table.reloadData()

    window.display()
    let added = try #require(
        vc.table.view(atColumn: vc.table.numberOfColumns - 1, row: 0, makeIfNecessary: false) as? NSTextField)
    #expect(added.drawsBackground)
    vc.table.scrollRowToVisible(250)
    window.display()
    // Whichever cell AppKit hands back for the rows now shown (the one that showed "added", or a new one), none keeps
    // its tint.
    let shown = shownCells(vc.table).compactMap { $0 as? NSTextField }
    #expect(!shown.isEmpty && !vc.table.rows(in: vc.table.visibleRect).contains(0))
    #expect(shown.allSatisfy { !$0.drawsBackground })
}

/// Side by side, an added and a removed line carry their sign as they do inline, so neither is told by its tint
/// alone; an unchanged line has a blank as wide, so the code of both columns lines up.
@MainActor @Test func aSideBySideLineCarriesItsSign() throws {
    let (vc, window) = diffInAWindow()
    defer { withExtendedLifetime(window) {} }
    try #require(vc.sideBySide)   // the layout a review opens in
    vc.diffs = [FileDiff(path: "f.txt", header: "", hunks: [], binary: false)]   // a row's line is of a file
    let same = DiffLine(kind: .context, text: "same", oldLine: 2, newLine: 2)
    vc.rows = [
        .diff(
            .pair(
                file: 0, left: DiffLine(kind: .del, text: "old", oldLine: 1),
                right: DiffLine(kind: .add, text: "new", newLine: 1))),
        .diff(.pair(file: 0, left: same, right: same))
    ]
    vc.table.reloadData()
    func code(_ column: String, _ row: Int) -> String? {
        let cell = vc.table.view(
            atColumn: vc.table.column(withIdentifier: .init(column)), row: row, makeIfNecessary: true)
        return (cell as? NSTextField)?.stringValue
    }
    #expect(code("l", 0) == "- old" && code("r", 0) == "+ new")
    #expect(code("l", 1) == "  same" && code("r", 1) == "  same")
}

/// A file's band, a comment's row and the comment card stand on fills that are the appearance's own once the Mac goes
/// light or dark, not the ones they were built in.
@MainActor @Test func aDiffsBandsFollowLightAndDark() {
    let (vc, window) = diffInAWindow()
    defer { withExtendedLifetime(window) {} }
    vc.notes.draft = CommentDraft(file: "f.txt", start: 1, end: 1, quote: "", side: nil)
    let comment = DiffComment(worktreeId: "w", file: "f.txt", startLine: 1, endLine: 1, quote: "", text: "why?")
    for band in [vc.fileBand("f.txt", added: 1, removed: 0), vc.commentRow(comment), vc.draftCard()] {
        func fill(_ name: NSAppearance.Name) -> CGColor? {
            band.appearance = NSAppearance(named: name)
            band.effectiveAppearance.performAsCurrentDrawingAppearance { band.updateLayer() }   // as AppKit draws it
            return band.layer?.backgroundColor
        }
        let light = fill(.aqua)
        #expect(light != nil && light != fill(.darkAqua))
    }
}
