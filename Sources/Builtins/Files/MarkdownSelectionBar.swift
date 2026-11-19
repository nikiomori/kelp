import AppKit
import DesignKit
import KelpKit

/// The few formatting buttons that float over a Markdown selection (as in Notion or Bear): bold, italic, code, link.
@MainActor
final class MarkdownSelectionBar: NSView {
    private let row = NSStackView()

    init(target: AnyObject, items: [(symbol: String, tip: String, action: Selector)]) {
        super.init(frame: .zero)
        for item in items {
            row.addArrangedSubview(MarkdownTab.toolButton(item.symbol, item.tip, item.action, target: target))
        }
        row.spacing = Metrics.iconGap
        // The buttons stand as far from the card's edge as from each other, as a segmented capsule's do.
        row.edgeInsets = NSEdgeInsets(
            top: Metrics.iconGap, left: Metrics.iconGap, bottom: Metrics.iconGap, right: Metrics.iconGap)
        let card = FloatingCard(row, radius: Metrics.radiusMD)   // popover material, like the other floating bars
        setFrameSize(card.fittingSize)
        card.frame = bounds
        card.autoresizingMask = [.width, .height]
        addSubview(card)
        isHidden = true
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(String(localized: "Format"))
    }

    required init?(coder: NSCoder) { nil }

    /// Shows the bar over `selection` (in `container`'s coordinates), or under it when there's no room above. The bar
    /// is kept inside the container's width.
    func show(over selection: NSRect, in container: NSView) {
        let size = frame.size, gap = Metrics.gap
        let above = container.isFlipped ? selection.minY - gap - size.height : selection.maxY + gap
        let fits = container.isFlipped ? above >= 0 : above + size.height <= container.bounds.height
        let originY = fits ? above : container.isFlipped ? selection.maxY + gap : selection.minY - gap - size.height
        let originX = min(max(selection.minX, 4), container.bounds.width - size.width - 4)
        setFrameOrigin(NSPoint(x: originX, y: originY))
        if isHidden { fadeIn() }   // it fades in over the text rather than popping up
    }
}
