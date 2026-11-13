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
        + (2...300).map { row(vc, DiffLine(kind: .context, text: "same \($0)", oldLine: $0, newLine: $0), both: true) }
    vc.table.reloadData()

    window.display()
    let added = try #require(
        vc.table.view(atColumn: vc.table.numberOfColumns - 1, row: 0, makeIfNecessary: false) as? NSTextField)
    #expect(added.drawsBackground)
    vc.table.scrollRowToVisible(250)
    window.display()
    let back = try #require(shownCells(vc.table).first { $0 === added } as? NSTextField)
    #expect(!back.drawsBackground && back.stringValue.contains("same"))
}
