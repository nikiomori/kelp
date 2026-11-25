import AppKit
import Core
import DesignKit
import EditorKit

/// A CSV file shown as a table (the tables dashboards, charts and For Each Row read), on the shared grid (`RowsGrid`):
/// a cell changed, a row added or deleted, changes the file's text, which saves as any file does; a column's head sorts
/// the rows shown, not the file. Table and Text in the status bar switch to the text and back, as Markdown's modes do.
/// Text changed elsewhere (the agent, the text itself) draws it again.
@MainActor
final class CSVGrid: NSObject, NSMenuDelegate {
    let view = NSView()
    /// Table or Text, for the tab's status bar.
    let modes = CapsuleSegments(
        labels: [String(localized: "Table"), String(localized: "Text")], name: String(localized: "Show As"))
    let grid: RowsGrid
    private let editor: CodeEditor
    private var writing = false

    init(editor: CodeEditor, path: String) {
        self.editor = editor
        grid = RowsGrid(autosave: "csv:" + path)
        super.init()
        grid.onEdit = { [weak self] in self?.write() }
        grid.table.onDelete = { [weak self] in self?.deleteRows(self?.grid.table.selectedRowIndexes ?? []) }
        grid.table.menu = NSMenu()
        grid.table.menu?.delegate = self
        modes.selectedSegment = 0
        modes.target = self
        modes.action = #selector(modeChosen)
        show(grid.area)
        grid.show(DataRows.parse(editor.text))
    }

    private func show(_ shown: NSView) {
        view.subviews.forEach { $0.removeFromSuperview() }
        view.pin(shown)
    }

    /// The file's text changed: drawn again, unless the table changed it.
    func changed(_ text: String) { if !writing { grid.show(DataRows.parse(text)) } }

    private func write() {
        writing = true
        defer { writing = false }
        editor.apply(
            text: DataRows.write(grid.rows, separator: DataRows.separator(editor.text)),
            selection: NSRange(location: 0, length: 0))
    }

    private func deleteRows(_ shown: IndexSet) {
        guard !shown.isEmpty else { return }
        grid.delete(shown: shown)
        write()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.add(String(localized: "Add Row")) { [weak self] in
            self?.grid.addRow()
            self?.write()
        }
        let clicked = grid.table.clickedRow
        guard clicked >= 0 else { return }
        let rows = grid.table.selectedRowIndexes.contains(clicked) ? grid.table.selectedRowIndexes : [clicked]
        menu.add(rows.count > 1 ? String(localized: "Delete Rows") : String(localized: "Delete Row"), key: "\u{8}") {
            [weak self] in self?.deleteRows(rows)
        }.keyEquivalentModifierMask = []   // ⌫, as the table takes it
    }

    @objc func modeChosen() {
        if modes.selectedSegment == 1 {
            show(editor.view)
        } else {
            show(grid.area)
            grid.show(DataRows.parse(editor.text))
        }
    }
}
