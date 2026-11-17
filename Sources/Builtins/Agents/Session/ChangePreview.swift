import AppKit
import Core
import DesignKit

/// A preview of the first rows a database change touches, shown in the card that asks the user to allow the change.
/// For an update it shows the key and the changed columns, each value as it was and as it becomes. A delete's rows
/// are struck out in red and an insert's rows are green, by their first columns. When several statements are asked
/// for as one, each statement gets a line with the number of rows it would change.
@MainActor
final class ChangePreview: NSView {
    /// The most rows, columns and statements the preview shows. The rest are a click away, in the database's tab.
    static let rows = 3, columns = 5, statements = 6
    private static let widest: CGFloat = 280, widestStatement: CGFloat = 560
    private let grid = NSGridView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        grid.rowSpacing = Metrics.lineGap
        grid.columnSpacing = Metrics.inset
        pin(
            grid,
            inset: NSEdgeInsets(
                top: Metrics.gap, left: Metrics.gapWide, bottom: Metrics.gap, right: Metrics.gapWide))
    }
    required init?(coder: NSCoder) { fatalError() }

    // AppKit calls updateLayer again when the appearance changes, so the fill follows light and dark mode.
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = Metrics.radiusSM
        layer?.backgroundColor = NSColor.fillRest.cgColor
    }

    /// Shows the first rows of `result` when the result says what the change does to them. Returns how many rows it
    /// shows, or 0 when there is nothing to show.
    func show(_ result: QueryResult) -> Int {
        let columns = Self.columns(of: result)
        guard let change = result.change, !columns.isEmpty, !result.rows.isEmpty else {
            lay([], widest: Self.widest)
            return 0
        }
        let names = columns.map {
            NSTextField.label(
                result.columns[$0], font: .ui(TextSize.caption, weight: .semibold), color: .secondaryLabelColor)
        }
        let shown = result.rows.prefix(Self.rows)
        let rows = shown.enumerated().map { index, row in
            let was = change.before.flatMap { $0.indices.contains(index) ? $0[index] : nil }
            return columns.map { cell(row, was, $0, change.kind) }
        }
        lay([names] + rows, widest: Self.widest)
        return shown.count
    }

    /// Shows several statements asked for as one, each on a line with the number of rows it would change. Returns how
    /// many statements it shows.
    func show(statements parts: [StatementResult]) -> Int {
        let shown = parts.prefix(Self.statements)
        lay(
            shown.enumerated().map { index, part in
                let sql = part.sql.split(whereSeparator: \.isNewline).joined(separator: " ")
                let count = part.changed.map { $0 == 1 ? String(localized: "1 row") : String(localized: "\($0) rows") }
                let text = NSTextField.label(sql, font: .uiMono(TextSize.caption))
                text.toolTip = part.sql
                return [
                    NSTextField.label("\(index + 1)", font: .uiDigits(TextSize.caption), color: .secondaryLabelColor),
                    text, NSTextField.label(count ?? "", font: .uiDigits(TextSize.caption))
                ]
            }, widest: Self.widestStatement)
        return shown.count
    }

    /// Fills the grid with `rows`. Each column is as wide as its widest text, up to `widest`, and longer text is cut.
    /// This way the box is as wide as its rows, instead of sharing out the card's whole width among the columns.
    private func lay(_ rows: [[NSView]], widest: CGFloat) {
        while grid.numberOfRows > 0 { grid.removeRow(at: 0) }
        for view in grid.subviews { view.removeFromSuperview() }
        for row in rows { grid.addRow(with: row) }
        for column in 0..<grid.numberOfColumns {
            let fits = (0..<grid.numberOfRows).compactMap {
                grid.cell(atColumnIndex: column, rowIndex: $0).contentView?.fittingSize.width
            }.max()
            grid.column(at: column).width = min(widest, ceil(fits ?? 0))
        }
    }

    /// Returns the columns to show: the key columns first, then the columns an update changes, or the first columns of
    /// a delete or an insert. Returns none for an update whose old rows aren't known, since there is nothing to
    /// compare.
    static func columns(of result: QueryResult) -> [Int] {
        guard let change = result.change else { return [] }
        let key = change.key.compactMap(result.columns.firstIndex(of:))
        let rest = change.kind == .update ? result.changedColumns : Array(result.columns.indices)
        guard !rest.isEmpty else { return [] }
        return Array((key + rest.filter { !key.contains($0) }).prefix(columns))
    }

    private func cell(_ row: [String?], _ was: [String?]?, _ column: Int, _ kind: RowChange.Kind) -> NSView {
        let font = NSFont.uiMono(TextSize.caption)
        let value = row.indices.contains(column) ? row[column] : nil
        let label = NSTextField.label(value ?? "NULL", font: font)
        if let was, was.indices.contains(column), was[column] != value {
            label.attributedStringValue = .change(from: was[column], to: value, font: font)
        } else if kind == .delete {
            label.attributedStringValue = NSAttributedString(
                string: label.stringValue,
                attributes: [
                    .font: font, .foregroundColor: NSColor.textRed,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue
                ])
        } else if kind == .insert {
            label.textColor = .textGreen
        } else if value == nil {
            label.textColor = .secondaryLabelColor
        }
        label.toolTip = value
        return label
    }
}
