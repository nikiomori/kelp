import AppKit

/// A row of the grid. The row draws its stripe and the columns' lines itself, so there are none under the last row.
@MainActor
public final class GridRowView: NSTableRowView {
    override public func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let table = superview as? NSTableView else { return }
        NSColor.separatorColor.setFill()
        for column in 0..<table.numberOfColumns {
            NSRect(x: table.rect(ofColumn: column).maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        }
    }

    /// Whether an agent's last change touched the row: a bar at the leading edge of its number says so.
    public var marked = false

    /// The bar goes over the selection too, so it is drawn after it; its colour follows light and dark.
    override public func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard marked, let table = superview as? NSTableView else { return }
        let column = table.column(withIdentifier: .init("#"))
        guard column >= 0 else { return }
        let bar = NSRect(x: table.rect(ofColumn: column).minX + 2, y: 2, width: 2, height: bounds.height - 4)
        NSColor.secondaryLabelColor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: bar.width / 2, yRadius: bar.width / 2).fill()   // a capsule
    }
}
