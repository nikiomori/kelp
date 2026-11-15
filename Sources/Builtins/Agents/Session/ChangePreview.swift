import AppKit
import Core
import DesignKit

/// The first rows of a change, in the card that asks for it: an update's key and the columns it changes, each value as
/// it was and as it becomes; a delete's rows struck out in red, an insert's in green, by their first columns.
@MainActor
final class ChangePreview: NSView {
    /// Rows and columns it shows at most: the rest are a click away, in the database's tab.
    static let rows = 3, columns = 5
    private static let widest: CGFloat = 280
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
        while grid.numberOfRows > 0 { grid.removeRow(at: 0) }
        for view in grid.subviews { view.removeFromSuperview() }
        guard let change = result.change else { return 0 }
        let columns = Self.columns(of: result)
        guard !columns.isEmpty, !result.rows.isEmpty else { return 0 }
        grid.addRow(
            with: columns.map {
                NSTextField.label(
                    result.columns[$0], font: .ui(TextSize.caption, weight: .semibold), color: .secondaryLabelColor)
            })
        let shown = result.rows.prefix(Self.rows)
        for (index, row) in shown.enumerated() {
            let was = change.before.flatMap { $0.indices.contains(index) ? $0[index] : nil }
            grid.addRow(with: columns.map { cell(row, was, $0, change.kind) })
        }
        // Each column as wide as its widest value, up to a width past which it's cut: the box takes its rows' width,
        // not the card's shared out among them
        for column in 0..<grid.numberOfColumns {
            let widest = (0..<grid.numberOfRows).compactMap {
                grid.cell(atColumnIndex: column, rowIndex: $0).contentView?.fittingSize.width
            }.max()
            grid.column(at: column).width = min(Self.widest, ceil(widest ?? 0))
        }
        return shown.count
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
