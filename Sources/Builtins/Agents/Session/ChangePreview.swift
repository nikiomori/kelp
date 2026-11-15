import AppKit
import Core
import DesignKit

/// The first rows of a change, in the card that asks for it: an update's key and the columns it changes, each value as
/// it was and as it becomes; a delete's rows struck out in red, an insert's in green, by their first columns. Several
/// statements asked as one: a line each, with the rows it would change.
@MainActor
final class ChangePreview: NSView {
    /// Rows and columns it shows at most: the rest are a click away, in the database's tab.
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

    // The fill follows the appearance: asked for again when it changes
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = Metrics.radiusSM
        layer?.backgroundColor = NSColor.fillRest.cgColor
    }

    /// Shows `result`'s first rows when it says what the change does to them; how many it shows (0: nothing to show).
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

    /// Several statements asked as one: each on a line with the rows it would change; how many it shows.
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

    /// Each column as wide as its widest text, up to `widest`, past which it's cut: the box takes its rows' width, not
    /// the card's shared out among them.
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

    /// The key's columns first, then the ones an update changes, or the first of a delete's and an insert's. None for
    /// an update whose rows as they were aren't known: there's nothing to compare.
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
