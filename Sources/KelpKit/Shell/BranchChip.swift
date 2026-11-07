import AppKit
import DesignKit

/// The branch at the head of a panel (Source Control, CI): one chip, so the branch stays where it was when the panel
/// changes. Put first in a panel's `Bar`, it moves the bar's inset so its glyph sits on `Metrics.inset`, where the rows
/// under the bar start, its hover fill reaching `padding` past it. Without an action it's a label: it doesn't grey in
/// under the pointer.
@MainActor
package final class BranchChip: PointerButton {
    override package init(frame: NSRect) {
        super.init(frame: frame)
        padding = Metrics.gap
        imagePosition = .imageLeading
        imageHugsTitle = true
        image = Glyph.image("arrow.triangle.branch", size: Metrics.segmentPoint)
        font = .ui(12, weight: .semibold)
        lineBreakMode = .byTruncatingMiddle
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    override package func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let row = superview as? NSStackView, row.superview is Bar, (row.arrangedSubviews.first ?? self) === self
        else { return }
        // Measured with a name: the branch comes later, and with no title the cell puts the glyph elsewhere.
        var glyph: CGFloat = 0
        if let c = cell?.copy() as? NSButtonCell {
            c.title = "main"
            glyph = c.imageRect(forBounds: NSRect(origin: .zero, size: c.cellSize)).minX
        }
        row.edgeInsets.left = Metrics.inset - padding - glyph
    }

    override package func mouseEntered(with event: NSEvent) { if action != nil { super.mouseEntered(with: event) } }
}
