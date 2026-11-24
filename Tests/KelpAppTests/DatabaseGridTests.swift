import AppKit
import Core
import DesignKit
import TestSupport
import Testing

@testable import BuiltinDatabases
@testable import KelpKit

/// A grid of `rows` in a window, as a tab shows it, with its cells editable.
@MainActor func editableGrid(_ rows: [[String?]]) -> (ResultGrid, NSWindow) {
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
@MainActor func editableTab(_ rows: [[String?]]) -> (DatabaseTab, NSWindow) {
    let tab = DatabaseTab(uri: "db:w1/shop?table=orders", app: AppModel(builtins: []))
    tab.schema = DatabaseSchema(tables: [
        DatabaseSchema.Table(
            name: "orders", columns: [.init(name: "note", type: "text", nullable: true, primary: false)])
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
    tab.schema = DatabaseSchema(tables: [DatabaseSchema.Table(name: "orders", rows: 1240)])
    tab.arrange()
    tab.pageChanged(shown: 200, ms: 3)
    window.layoutIfNeeded()
    // The row count stays whole beside the edits' buttons: the rest of the status shortens first.
    #expect(tab.rowCount.stringValue.hasPrefix("1–200 of"))
    #expect(tab.rowCount.frame.width >= tab.rowCount.intrinsicContentSize.width - 0.5, "\(tab.rowCount.frame)")
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

/// The same table read again keeps the columns' widths and the ones hidden; another table's columns start afresh.
@MainActor @Test func aTableReadAgainKeepsItsColumnsLook() {
    let (grid, window) = editableGrid([["a"]])
    defer { withExtendedLifetime(window) {} }
    grid.show(columns: ["id", "note"], rows: [["1", "a"]])
    grid.table.tableColumns[1].width = 211
    grid.table.tableColumns[2].isHidden = true
    grid.show(columns: ["id", "note"], rows: [["2", "b"]], keeping: true)
    #expect(grid.table.tableColumns[1].width == 211 && grid.table.tableColumns[2].isHidden)
    grid.show(columns: ["id", "note"], rows: [["2", "b"]])
    #expect(grid.table.tableColumns[1].width != 211 && !grid.table.tableColumns[2].isHidden)
}

/// A statement that gave more rows than the grid holds says so; leaving a slow read stops its wheel and its words.
@MainActor @Test func theFootSaysWhatItShows() async throws {
    #expect(DatabaseTab.shown(2, of: 5) == "2 of 5 rows shown" && DatabaseTab.shown(5, of: 5) == "5 rows")
    let (tab, window) = editableTab([["a"]])
    defer { withExtendedLifetime(window) {} }
    // The tab's own first read is over: no kelpd here, so it failed under the rows.
    #expect(try await waitFor { !tab.failureBar.isHidden })
    tab.startReading("orders")
    await tab.leave(to: .query)
    try await Task.sleep(for: .seconds(1.3))   // the wheel and its words come only past a second
    #expect(!tab.status.stringValue.contains("Reading"), "\(tab.status.stringValue)")
}

/// What is wrong with a database takes a second line in a narrow panel rather than being cut ("Its compose
/// service…" lost the part that says what happened).
@MainActor @Test func aDatabasesReasonTakesASecondLine() throws {
    let rows = DatabasePanelRows(panel: DatabasesPanel(app: AppModel(builtins: [])))
    let said = "Its compose service db isn’t running: Start starts it."
    let row = rows.problem(
        DatabaseInfo(name: "app_dev", engine: .postgres),
        DatabaseHealth(name: "app_dev", state: .stopped, reason: said))
    row.frame = NSRect(x: 0, y: 0, width: 260, height: TextSize.of(Metrics.rowTwoLine))
    row.layoutSubtreeIfNeeded()
    func fields(_ v: NSView) -> [NSTextField] { [v as? NSTextField].compactMap { $0 } + v.subviews.flatMap(fields) }
    let why = try #require(fields(row).first { $0.stringValue == said })
    let font = try #require(why.font)
    let wide = (said as NSString).size(withAttributes: [.font: font]).width
    let lines = (why.frame.height / (font.ascender - font.descender + font.leading)).rounded(.down)
    #expect(lines * why.frame.width >= wide, "\(why.frame) for \(wide)")
}

/// Structure lists the columns in the grid and the indexes in a block of their own under it, not as grid rows.
@MainActor @Test func structuresIndexesStandApart() async throws {
    let (tab, window) = editableTab([])
    defer { withExtendedLifetime(window) {} }
    tab.schema = DatabaseSchema(tables: [
        DatabaseSchema.Table(
            name: "orders", columns: [.init(name: "id", type: "integer", nullable: false, primary: true)],
            indexes: ["orders_status (status, placed_at)"])
    ])
    tab.part.selectedSegment = 1
    await tab.showTable("orders")
    #expect(tab.grid.rows.count == 1)
    #expect(!tab.indexesBox.isHidden && tab.indexesText.stringValue == "orders_status (status, placed_at)")
    tab.showPart(0)
    #expect(try await waitFor { tab.indexesBox.isHidden })
}

/// A row's number says, besides its colour, what saving does to it (• edited, − deleted, + new), and VoiceOver hears
/// that and an agent's change too.
@MainActor @Test func aRowsNumberSaysWhatHappensToIt() {
    let (grid, window) = editableGrid([["a"], ["b"], ["c"], ["d"]])
    defer { withExtendedLifetime(window) {} }
    grid.edits.set(row: 0, column: 0, to: "z", was: "a")
    grid.edits.toggleDeleted(1)
    grid.marked = [2]
    grid.addRow()
    window.display()
    let cases: [(row: Int, shown: String, said: String)] = [
        (0, "• 1", "Row 1, changed"), (1, "− 2", "Row 2, to be deleted"), (2, "3", "Row 3, changed by an agent"),
        (3, "4", "Row 4"), (4, "+", "New row")
    ]
    for (row, shown, said) in cases {
        let cell = grid.table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTextField
        #expect(cell?.stringValue == shown && cell?.accessibilityLabel() == said, "row \(row)")
    }
}

/// What only a right click did has keys too: Set to NULL on the cell being typed in, Duplicate Row on the rows picked;
/// Undo This Change is for an agent's finished change only. The filter's fields have names for VoiceOver.
@MainActor @Test func rightClickItemsHaveKeys() throws {
    let (grid, window) = editableGrid([["a"]])
    defer { withExtendedLifetime(window) {} }
    grid.table.editColumn(1, row: 0, with: nil, select: true)
    grid.setTypingToNull()
    #expect(grid.edits.value(row: 0, column: 0) == .some(nil))
    grid.table.selectRowIndexes([0], byExtendingSelection: false)
    grid.duplicateSelected()
    #expect(grid.edits.added == [["a"]])
    func run(_ session: String?, _ state: DatabaseRun.State, changed: Int?) -> DatabaseRun {
        DatabaseRun(
            id: "r", database: "shop", sql: "UPDATE t", session: session, at: Date(), state: state, changed: changed)
    }
    #expect(DatabaseTab.undoable(run("s1", .done, changed: 2)))
    for other in [run(nil, .done, changed: 2), run("s1", .failed, changed: nil), run("s1", .done, changed: 0)] {
        #expect(!DatabaseTab.undoable(other))
    }
    let filters = DatabaseFilters()
    filters.use(columns: ["a"], engine: .sqlite)
    func controls(_ v: NSView) -> [NSControl] { [v as? NSControl].compactMap { $0 } + v.subviews.flatMap(controls) }
    for control in controls(filters.view) where control is NSPopUpButton || type(of: control) == NSTextField.self {
        #expect(control.accessibilityLabel()?.isEmpty == false, "\(control)")
    }
}

/// Show SQL and the Production question hold their statements in a box that scrolls: sixty edits keep the sheet on
/// the screen.
@MainActor @Test func manyStatementsScrollInTheirSheet() {
    let statements = (0..<60).map { "UPDATE \"orders\" SET \"status\" = 'paid' WHERE \"id\" = '\($0)'" }
    let alert = DatabaseTab.question("60 statements", statements, action: "Copy", cancel: "Close")
    alert.layout()
    #expect(alert.window.frame.height < 500, "\(alert.window.frame)")
    let shown = (alert.accessoryView as? NSScrollView)?.documentView as? NSTextView
    #expect(shown?.string == DatabaseTab.sql(statements))
}

/// The questions are sheets on the front window, so the tests that answer one take turns.
extension OneAtATime {
    /// Following a key's arrow with unsaved edits asks; Cancel stays on the table, its edits and its filter.
    @Test func cancellingAKeysArrowStaysOnTheTable() async throws {
        let (tab, window) = editableTab([["a"]])
        window.orderFrontRegardless()   // a window never on screen gets no sheet
        defer { window.orderOut(nil) }
        tab.grid.edits.set(row: 0, column: 0, to: "z", was: "a")
        tab.filters.use(columns: ["note"], engine: .sqlite)
        let following = Task { await tab.followed("orders", "note", "b") }   // a key to a row of the same table
        let asking = { NSApp.windows.first { $0.attachedSheet != nil } }
        #expect(try await waitFor(10) { asking() != nil })
        if let window = asking(), let asked = window.attachedSheet {
            window.endSheet(asked, returnCode: .alertSecondButtonReturn)   // Cancel
        }
        await following.value
        #expect(tab.mode == .table("orders") && !tab.filters.isActive && tab.grid.edits.count == 1)
        #expect(asking() == nil)   // not asked again
        if let window = asking(), let asked = window.attachedSheet {
            window.endSheet(asked, returnCode: .alertSecondButtonReturn)
        }
    }

    /// A header click with unsaved edits asks first; Cancel keeps the edits and the order the rows are in. Don't Save
    /// from the quit question drops them.
    @Test func aSortAsksBeforeItDropsTheEdits() async throws {
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

    /// ⌫ on a saved query forgets it, once asked.
    @Test func deleteForgetsASavedQueryAfterAsking() async throws {
        let sidebar = DatabaseSidebar(app: AppModel(builtins: []))
        let shown = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.titled], backing: .buffered,
            defer: true)
        shown.contentView = sidebar.view
        shown.orderFrontRegardless()   // a window never on screen gets no sheet
        defer { shown.orderOut(nil) }
        var forgot: [DatabaseSidebar.SavedQuery] = []
        sidebar.onForget = { forgot.append($0) }
        sidebar.part.selectedSegment = 1   // Queries
        sidebar.saved = [.init(name: "big", sql: "SELECT 1")]
        sidebar.list.selectRowIndexes([1], byExtendingSelection: false)   // under New Query
        let delete = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: shown.windowNumber,
                context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false,
                keyCode: 51))
        sidebar.list.keyDown(with: delete)
        let asking = { NSApp.windows.first { $0.attachedSheet != nil } }
        #expect(sidebar.list.selectedRow == 1)
        #expect(try await waitFor { asking() != nil })
        if let window = asking(), let asked = window.attachedSheet {
            window.endSheet(asked, returnCode: .alertFirstButtonReturn)
        }
        #expect(try await waitFor { forgot.map(\.name) == ["big"] })
    }
}
