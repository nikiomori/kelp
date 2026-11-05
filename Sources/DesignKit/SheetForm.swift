import AppKit

/// The one layout of a sheet that asks for something: its parts top to bottom, `sheetInset` from every edge; a field's
/// name right-aligned in a column of `formLabel`, without a colon, as Settings rows have it; and every field, list,
/// note and the buttons' row as wide as the sheet's inside, so the fields end where the buttons end.
@MainActor
public enum SheetForm {
    /// The names and their fields. Fields stretch to the end once `stack` lays the grid out.
    public static func grid(_ rows: [(String, NSView)]) -> NSGridView {
        let grid = NSGridView(views: rows.map { [NSTextField(labelWithString: $0.0), $0.1] })
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = Metrics.formLabel
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = Metrics.gapWide
        grid.columnSpacing = Metrics.gapWide
        return grid
    }

    /// `parts` stacked for a sheet `width` wide; a grid's fields, and the parts in `wide`, take the whole inside.
    public static func stack(_ parts: [NSView], wide: [NSView], width: CGFloat) -> NSStackView {
        let inside = width - 2 * Metrics.sheetInset
        let stack = NSStackView(views: parts)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.inset
        stack.detachesHiddenViews = true
        let e = Metrics.sheetInset
        stack.edgeInsets = NSEdgeInsets(top: e, left: e, bottom: e, right: e)
        for v in wide {
            v.widthAnchor.constraint(equalToConstant: inside).isActive = true
            (v as? NSTextField)?.preferredMaxLayoutWidth = inside   // a note wraps at the sheet's edge, not past it
        }
        for grid in parts.compactMap({ $0 as? NSGridView }) {
            for r in 0..<grid.numberOfRows {
                grid.cell(atColumnIndex: 1, rowIndex: r).contentView?.widthAnchor
                    .constraint(equalToConstant: inside - Metrics.formLabel - grid.columnSpacing).isActive = true
            }
        }
        return stack
    }
}
