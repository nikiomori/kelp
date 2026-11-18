import AppKit
import DesignKit

/// The branch chip at the head of a panel (Source Control, CI). Every panel uses this one chip, so the branch stays in
/// place when the panel changes. Put first in a panel's `Bar`, the chip moves the bar's inset so its glyph sits on
/// `Metrics.inset`, where the rows under the bar start, and its hover fill reaches `padding` past the glyph. Without an
/// action the chip is a label, so it doesn't grey in under the pointer.
@MainActor
package final class BranchChip: PointerButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        padding = Metrics.gap
        imagePosition = .imageLeading
        imageHugsTitle = true
        // The name as the title bar's chip writes it: a row's size and weight, in the text's colour. It was semibold
        // and grey here, a third way to write the one branch (semibold is for news, and the type scale has none at 12).
        image = Glyph.image("arrow.triangle.branch", size: Metrics.iconPoint)
        contentTintColor = .labelColor
        font = .ui(TextSize.row)
        lineBreakMode = .byTruncatingMiddle
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    override package func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let row = superview as? NSStackView, row.superview is Bar, (row.arrangedSubviews.first ?? self) === self
        else { return }
        // Measure with a stand-in name, because the branch comes later and with no title the cell puts the glyph
        // elsewhere.
        var glyph: CGFloat = 0
        if let measure = cell?.copy() as? NSButtonCell {
            measure.title = "main"
            glyph = measure.imageRect(forBounds: NSRect(origin: .zero, size: measure.cellSize)).minX
        }
        row.edgeInsets.left = Metrics.inset - padding - glyph
    }

    override package func mouseEntered(with event: NSEvent) { if action != nil { super.mouseEntered(with: event) } }
}
