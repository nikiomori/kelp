import AppKit
import DesignKit
import KelpKit

/// The few formatting buttons that float over a Markdown selection (as in Notion or Bear): bold, italic, code, link.
@MainActor
final class MarkdownSelectionBar: NSView {
    private let row = NSStackView()

    init(target: AnyObject, items: [(symbol: String, tip: String, action: Selector)]) {
        super.init(frame: .zero)
        for i in items { row.addArrangedSubview(MarkdownTab.toolButton(i.symbol, i.tip, i.action, target: target)) }
        row.spacing = Metrics.iconGap
        row.edgeInsets = NSEdgeInsets(top: 3, left: 5, bottom: 3, right: 5)
        let card = FloatingCard(row, radius: Metrics.radiusMD)   // the popover's material, as the other floating controls
        setFrameSize(card.fittingSize)
        card.frame = bounds; card.autoresizingMask = [.width, .height]
        addSubview(card)
        isHidden = true
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(String(localized: "Format"))
    }

    required init?(coder: NSCoder) { nil }

    /// Over `selection` (in `container`'s coordinates), or under it where there's no room above; kept inside.
    func show(over selection: NSRect, in container: NSView) {
        let size = frame.size, gap: CGFloat = 6
        let above = container.isFlipped ? selection.minY - gap - size.height : selection.maxY + gap
        let fits = container.isFlipped ? above >= 0 : above + size.height <= container.bounds.height
        let y = fits ? above : container.isFlipped ? selection.maxY + gap : selection.minY - gap - size.height
        let x = min(max(selection.minX, 4), container.bounds.width - size.width - 4)
        setFrameOrigin(NSPoint(x: x, y: y))
        isHidden = false
    }
}
