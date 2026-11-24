import AppKit
import Core
import TestSupport
import DesignKit
import Testing

@testable import BuiltinDatabases
@testable import KelpKit

/// A grid of `rows` in a window, as a tab shows it, with its cells editable.
@MainActor private func editableGrid(_ rows: [[String?]]) -> (ResultGrid, NSWindow) {
    let grid = ResultGrid()
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    window.contentView = grid.scroll
    grid.editable = true
    grid.show(columns: ["note"], rows: rows)
    window.display()
    return (grid, window)
}

/// Typing in a cell: what it showed (⏎ for a line break, NULL, DEFAULT) left as it was is no change; a ⏎ left in a
/// value with line breaks is a line break; DEFAULT typed in a new row is its default.
@MainActor @Test func typingInACellChangesOnlyWhatWasTyped() {
    let (grid, window) = editableGrid([["a\nb"], [nil], ["x"]])
    defer { withExtendedLifetime(window) {} }
    grid.addRow()
    grid.edits.set(row: 2, column: 0, to: nil, was: "x")   // Set to NULL
    let cases: [(row: Int, typed: String, made: String??)] = [
        (0, "a⏎b", nil), (0, "a⏎c", .some("a\nc")), (1, "NULL", nil), (1, "", nil), (1, "NULL!", .some("NULL!")),
        (2, "NULL", nil), (2, "", nil), (2, "y", .some("y")),
        (3, "DEFAULT", nil), (3, "", nil), (3, "default", .some(nil)), (3, "7", .some("7"))
    ]
    for (row, typed, made) in cases {
        #expect(grid.change(typed, row: row, column: 0) == made, "row \(row): \(typed)")
    }
}

/// Entering a cell and leaving it without typing leaves the row as it was, in every kind of cell.
@MainActor @Test func aCellEnteredAndLeftKeepsItsValue() throws {
    let (grid, window) = editableGrid([["a\nb"], [nil], ["x"]])
    defer { withExtendedLifetime(window) {} }
    grid.addRow()
    grid.edits.set(row: 2, column: 0, to: nil, was: "x")
    let before = grid.edits
    for row in 0..<grid.count {
        grid.table.editColumn(1, row: row, with: nil, select: true)
        #expect(window.firstResponder is NSTextView, "row \(row) wasn't entered")
        #expect(!grid.typing)
        window.makeFirstResponder(grid.table)
    }
    #expect(grid.edits == before)
}

/// A table tab showing `orders` (one column, `note`) with its rows in a window of their own, on screen for a sheet.
@MainActor private func editableTab(_ rows: [[String?]]) -> (DatabaseTab, NSWindow) {
    let tab = DatabaseTab(uri: "db:w1/shop?table=orders", app: AppModel(builtins: []))
    tab.schema = DatabaseSchema(tables: [
        DatabaseSchema.Table(name: "orders", columns: [.init(name: "note", type: "text", nullable: true, primary: false)])
    ])
    tab.mode = .table("orders")
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    window.contentView = tab.grid.area
    tab.grid.editable = true
    tab.grid.source = ("orders", .sqlite)
    tab.grid.show(columns: ["note"], rows: rows)
    window.display()
    return (tab, window)
}

/// What is typed in a cell not yet left is an edit: the tab counts as edited, and Save takes it with the rest.
@MainActor @Test func aCellStillBeingTypedInIsSaved() async throws {
    let (tab, window) = editableTab([["a"]])
    defer { withExtendedLifetime(window) {} }
    tab.grid.table.editColumn(1, row: 0, with: nil, select: true)
    let editor = try #require(window.firstResponder as? NSTextView)
    #expect(!tab.isEdited)
    editor.insertText("z", replacementRange: editor.selectedRange())
    #expect(tab.isEdited && tab.grid.edits.isEmpty)
    await tab.saveChanges()   // no kelpd here: nothing is written, and the edit stays to save again
    #expect(tab.grid.edits.value(row: 0, column: 0) == .some("z"))
}

/// A header click with unsaved edits asks first; Cancel keeps the edits and the order the rows are in. Don't Save
/// from the quit question drops them.
@MainActor @Test func aSortAsksBeforeItDropsTheEdits() async throws {
    let (tab, window) = editableTab([["a"], ["b"]])
    window.orderFrontRegardless()   // a window never on screen gets no sheet
    defer { window.orderOut(nil) }
    tab.grid.edits.set(row: 0, column: 0, to: "z", was: "a")
    tab.grid.orders = [("note", true)]
    tab.sorted(was: [])
    #expect(try await waitFor(10) { window.attachedSheet != nil })
    if let asked = window.attachedSheet { window.endSheet(asked, returnCode: .alertSecondButtonReturn) }   // Cancel
    #expect(try await waitFor(10) { tab.grid.orders.isEmpty })
    #expect(tab.grid.edits.count == 1 && tab.grid.rows.count == 2)
    #expect(await UnsavedChanges.settle([tab], .alertThirdButtonReturn))   // Don't Save
    #expect(!tab.isEdited)
}

/// Opening the details takes their width from the rows, never from the window: a window too narrow for the foot's
/// buttons beside them keeps its size.
@MainActor @Test func theDetailsTakeTheirWidthFromTheRows() {
    let tab = DatabaseTab(uri: "db:w1/shop?table=orders", app: AppModel(builtins: []))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled, .resizable], backing: .buffered,
        defer: true)
    window.contentView = NSView()
    window.contentView?.pin(tab.view)   // held by constraints, as the editor area holds a tab
    tab.whole.isHidden = false
    tab.mode = .table("orders")
    tab.grid.editable = true
    tab.grid.show(columns: ["note"], rows: [["a"]])
    tab.grid.edits.set(row: 0, column: 0, to: "b", was: "a")   // the foot's edit buttons show too
    tab.arrange()
    window.layoutIfNeeded()
    tab.toggleDetails()
    window.layoutIfNeeded()
    #expect(!tab.details.view.isHidden)
    #expect(window.frame.width == 800, "the window grew to \(window.frame.width)")
    #expect(tab.details.view.frame.maxX <= tab.view.bounds.width + 0.5)
}

/// A statement runs one at a time, and its answer, coming once the tab shows a table, leaves the table's rows and
/// edits as they are.
@MainActor @Test func aQuerysLateAnswerStaysOutOfATablesGrid() async throws {
    let (tab, window) = editableTab([])
    defer { withExtendedLifetime(window) {} }
    tab.mode = .query
    tab.editor.setText("SELECT 1")
    tab.runQuery()
    #expect(!tab.run.isEnabled && !tab.explain.isEnabled)
    tab.mode = .table("orders")   // a table picked while the statement runs (no kelpd here: it fails)
    tab.sidebar.current = "orders"
    tab.grid.show(columns: ["note"], rows: [["a"], ["b"]])
    tab.grid.edits.set(row: 0, column: 0, to: "z", was: "a")
    #expect(try await waitFor(10) { tab.run.isEnabled })
    #expect(tab.grid.rows.count == 2 && tab.grid.edits.count == 1)
}
