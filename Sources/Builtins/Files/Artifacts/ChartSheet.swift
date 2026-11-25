import AppKit
import Core
import DesignKit
import KelpKit

/// The sheet with a chart's numbers (`ChartData`): its table on the shared grid (`RowsGrid`), whose cells are typed
/// over, the column names on top; Save ends it with `.OK`.
@MainActor
final class ChartSheet: NSObject {
    let grid = RowsGrid(autosave: nil, fits: true)
    let window = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: Metrics.sheetWidth, height: 1), styleMask: [.titled],
        backing: .buffered, defer: true)

    init(_ rows: [[String]]) {
        super.init()
        grid.show(rows)
        let title = NSTextField.label(
            String(localized: "The Chart’s Numbers"), font: .ui(TextSize.body, weight: .semibold))
        let note = NSTextField(
            wrappingLabelWithString: String(
                localized: "Type over a number or a name. The agent draws the chart again from them."))
        note.font = .ui(TextSize.row)
        note.textColor = .secondaryLabelColor
        grid.scroll.borderType = .bezelBorder
        let rowsHigh = CGFloat(min(max(rows.count, 3), 10)) + 1   // the names' head, then up to ten rows
        grid.area.heightAnchor.constraint(equalToConstant: TextSize.of(Metrics.row) * rowsHigh).isActive = true
        let cancel = ClosureButton(title: String(localized: "Cancel")) { [weak self] in self?.end(.cancel) }
        cancel.keyEquivalent = "\u{1b}"
        let save = ClosureButton(title: String(localized: "Save")) { [weak self] in self?.end(.OK) }
        save.keyEquivalent = "\r"
        for button in [cancel, save] { button.bezelStyle = .push }
        let buttons = NSStackView(views: [NSView(), cancel, save])
        window.contentView = SheetForm.stack(
            [title, note, grid.area, buttons], wide: [note, grid.area, buttons], width: Metrics.sheetWidth)
        SheetForm.fit(window)
    }

    private func end(_ code: NSApplication.ModalResponse) {
        grid.commit()
        window.sheetParent?.endSheet(window, returnCode: code)
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
            let sheet = ChartSheet(rows)
            guard await runSheet(sheet.window) == .OK else { return }
            let now = sheet.grid.rows
            guard now != rows else { return }
            let edit = HandEdit(board: board, id: id, what: "chart data", from: nil, to: "\(now.count - 1) rows")
            rewrite(board, edit: { _ in edit }) { ChartData.write($0, id: id, rows: now) }
            // Asked at once: the numbers are the request.
            send(
                "Chart [data-id=\(id)] on \(board) of \(Artifacts.projectPath(url.path)): its numbers were changed by "
                    + "hand in its table. Draw it again from them.")
        }
    }
}
