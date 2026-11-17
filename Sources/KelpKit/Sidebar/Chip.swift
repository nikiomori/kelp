import AppKit
import DesignKit

/// What goes on beside an agent, shown after its name: a symbol, and a count from two on. It has no fill and no words,
/// so it takes only the room of its symbol, on a row or a tab, and the tooltip says the rest.
@MainActor
final class Chip: NSView {
    private let icon = NSImageView(), count = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        icon.symbolConfiguration = .chrome(Metrics.iconSmall)
        icon.contentTintColor = .secondaryLabelColor
        count.font = .uiDigits(TextSize.caption, weight: .medium)
        count.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [icon, count])
        stack.spacing = 2
        pin(stack)
        // An NSStackView keeps to the size of its views only with this, and a view around one has no size of its own.
        stack.setHuggingPriority(.required, for: .horizontal)
        stack.setClippingResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)   // VoiceOver reads its label, which is the tooltip with the whole list
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ symbol: String, count number: Int = 1) {
        icon.image = .symbol(symbol)
        if !count.isHidden, let old = Int(count.stringValue), number >= 2, old != number {
            count.roll(up: number > old)
        }
        count.isHidden = number < 2
        count.stringValue = "\(number)"
    }
}
