import AppKit
import Core
import DesignKit
import TestSupport
import Testing

@testable import BuiltinDatabases
@testable import KelpKit

/// A statement that runs past a second shows Stop where Run is, with ⌘.; once it ends, Run is back.
@MainActor @Test func stopTakesRunsPlaceWhileAStatementRuns() async throws {
    let (tab, window) = editableTab([])
    defer { withExtendedLifetime(window) {} }
    #expect(try await waitFor { !tab.failureBar.isHidden })   // the tab's own first read is over (no kelpd here)
    tab.mode = .query
    tab.arrange()
    tab.running = "r1"
    tab.startReading()
    #expect(tab.stopButton.isHidden && !tab.run.isHidden)   // a quick statement changes nothing
    #expect(try await waitFor(5) { !tab.stopButton.isHidden })
    #expect(tab.run.isHidden && tab.stopButton.keyEquivalent == ".")
    tab.arrange()
    #expect(tab.run.isHidden)
    tab.running = nil
    tab.readingEnded()
    #expect(tab.stopButton.isHidden && !tab.run.isHidden)
}

/// A table's rows take no edits while they are read again, because the answer replaces them: edits made meanwhile
/// would be dropped unasked. Once the read is over, they take edits again.
@MainActor @Test func rowsBeingReadAgainTakeNoEdits() async throws {
    let (tab, window) = editableTab([["a"]])
    defer { withExtendedLifetime(window) {} }
    #expect(try await waitFor { !tab.failureBar.isHidden })   // the tab's own first read is over (no kelpd here)
    #expect(tab.grid.editable)
    tab.startReading("orders")
    #expect(!tab.grid.editable && tab.addRow.isHidden)
    tab.grid.table.editColumn(1, row: 0, with: nil, select: true)
    #expect(!(window.firstResponder is NSTextView))   // the cell can't be typed in
    tab.readingEnded()
    #expect(tab.grid.editable)
    #expect(DatabaseTab.order([("a", true)]) != DatabaseTab.order([("a", false)]))
}

/// ⌘C copies the selected rows as TSV with their header, or the one cell looked at as its value; ⌘V puts TSV into
/// the cells from there on as edits, saving nothing: the header line is left out, NULL is NULL, and a line past the
/// rows adds one.
@MainActor @Test func copyAndPasteGoThroughTheGrid() {
    let (grid, window) = editableGrid([])
    defer { withExtendedLifetime(window) {} }
    grid.source = ("orders", .sqlite)
    grid.show(columns: ["id", "note"], rows: [["1", "a"], ["2", nil]])
    grid.table.selectRowIndexes([0, 1], byExtendingSelection: false)
    grid.table.copy(nil)
    #expect(NSPasteboard.general.string(forType: .string) == "id\tnote\n1\ta\n2\tNULL")
    grid.table.lookedAt = (1, 1)
    grid.table.selectRowIndexes([1], byExtendingSelection: false)
    grid.table.copy(nil)
    #expect(NSPasteboard.general.string(forType: .string) == "NULL")
    grid.table.selectRowIndexes([0], byExtendingSelection: false)   // the cell looked at is another row's now
    copyText("id\tnote\n1\tz\n2\tNULL\n3\tnew\n")
    grid.table.paste(nil)
    #expect(grid.edits.value(row: 0, column: 1) == .some("z") && grid.edits.added == [["3", "new"]])
    #expect(grid.edits.count == 2 && grid.count == 3)
}
