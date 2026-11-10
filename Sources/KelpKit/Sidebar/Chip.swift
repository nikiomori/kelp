import AppKit
import DesignKit

/// What goes on beside an agent, after its name: a symbol, and how many from two on. No fill and no words: it takes the
/// room of its symbol, on a row or a tab, and the tooltip says the rest.
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
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        stack.setHuggingPriority(.required, for: .horizontal)   // an NSStackView keeps to its views only so; a view around one has no size of its own
        stack.setClippingResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)   // read by its label: the tooltip, the whole list
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ symbol: String, count number: Int = 1) {
        icon.image = .symbol(symbol)
        count.isHidden = number < 2
        count.stringValue = "\(number)"
    }
}
