import AppKit
import KelpKit

/// The few formatting buttons that float over a Markdown selection (as in Notion or Bear): bold, italic, code, link.
@MainActor
final class MarkdownSelectionBar: NSView {
    private let row = NSStackView()

    init(target: AnyObject, items: [(symbol: String, tip: String, action: Selector)]) {
        super.init(frame: .zero)
        let back: NSView
        if #available(macOS 26, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = 9
            back = g
        } else {
            let v = NSVisualEffectView()
            v.material = .popover
            v.blendingMode = .withinWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.cornerRadius = 9
            v.layer?.masksToBounds = true
            back = v
        }
        back.frame = bounds; back.autoresizingMask = [.width, .height]
        addSubview(back)
        for i in items { row.addArrangedSubview(MarkdownTab.toolButton(i.symbol, i.tip, i.action, target: target)) }
        row.spacing = 0
        row.edgeInsets = NSEdgeInsets(top: 3, left: 5, bottom: 3, right: 5)
        row.frame = bounds; row.autoresizingMask = [.width, .height]
        addSubview(row)
        setFrameSize(row.fittingSize)
        shadow = NSShadow()
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
