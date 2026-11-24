import AppKit
import Core
import DesignKit
import KelpKit

/// The sheet with a chart's numbers (`ChartData`): its table as a grid whose cells are typed over, the column names
/// on top, Save writing it into the board.
@MainActor
final class ChartGrid: NSObject, NSTableViewDataSource {
    private(set) var rows: [[String]]
    let table = NSTableView()

    init(_ rows: [[String]]) {
        self.rows = rows
        super.init()
        for (i, name) in (rows.first ?? []).enumerated() {
            let column = NSTableColumn(identifier: .init(String(i)))
            column.title = name
            column.isEditable = true
            column.width = Metrics.alertAccessory / CGFloat(max(rows.first?.count ?? 1, 1)) - Metrics.gap
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.usesAlternatingRowBackgroundColors = true
    }

    func numberOfRows(in _: NSTableView) -> Int { max(rows.count - 1, 0) }

    /// Keeps what is being typed in a cell when Save is pressed before it is finished.
    func commit() {
        guard table.editedRow >= 0, table.editedColumn >= 0, let text = table.currentEditor()?.string else { return }
        tableView(table, setObjectValue: text, for: table.tableColumns[table.editedColumn], row: table.editedRow)
    }

    func tableView(_: NSTableView, objectValueFor column: NSTableColumn?, row: Int) -> Any? {
        guard let i = column.flatMap({ Int($0.identifier.rawValue) }), rows.indices.contains(row + 1) else {
            return nil
        }
        return rows[row + 1].indices.contains(i) ? rows[row + 1][i] : ""
    }

    func tableView(_: NSTableView, setObjectValue value: Any?, for column: NSTableColumn?, row: Int) {
        guard let i = column.flatMap({ Int($0.identifier.rawValue) }), rows.indices.contains(row + 1) else { return }
        while rows[row + 1].count <= i { rows[row + 1].append("") }
        rows[row + 1][i] = value as? String ?? ""
    }
}

extension MarkdownTab {
    /// Edit's double click on a chart with a table: its numbers in a sheet; saved, they are written into the board, and
    /// a mark asks the agent to draw the chart again from them.
    func chartMessage(_ body: [String: Any]) {
        guard let board = body["board"] as? String, let id = body["id"] as? String,
            let rows = body["rows"] as? [[String]], rows.count > 1
        else { return }
        Task {
            let alert = NSAlert()
            alert.messageText = String(localized: "The Chart’s Numbers")
            alert.informativeText = String(
                localized: "Type over a number or a name. The agent draws the chart again from them.")
            let grid = ChartGrid(rows)
            let scroll = NSScrollView(
                frame: NSRect(x: 0, y: 0, width: Metrics.alertAccessory, height: Metrics.alertAccessory * 0.6))
            scroll.documentView = grid.table
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            alert.accessoryView = scroll
            alert.addButton(withTitle: String(localized: "Save"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard await runSheet(alert) == .alertFirstButtonReturn else { return }
            grid.commit()
            let now = grid.rows
            guard now != rows else { return }
            let edit = HandEdit(board: board, id: id, what: "chart data", from: nil, to: "\(now.count - 1) rows")
            rewrite(board, edit: { _ in edit }) { ChartData.write($0, id: id, rows: now) }
            runJS("window.kelpChartChanged?.(\(Self.js(board)), \(Self.js(id)))")
        }
    }
}
