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
        count.font = .uiDigits(11, weight: .medium)
        count.textColor = .secondaryLabelColor
        let s = NSStackView(views: [icon, count])
        s.spacing = 2
        s.translatesAutoresizingMaskIntoConstraints = false
        addSubview(s)
        NSLayoutConstraint.activate([s.leadingAnchor.constraint(equalTo: leadingAnchor), s.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     s.topAnchor.constraint(equalTo: topAnchor), s.bottomAnchor.constraint(equalTo: bottomAnchor)])
        s.setHuggingPriority(.required, for: .horizontal)   // an NSStackView keeps to its views only so; a view around one has no size of its own
        s.setClippingResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)   // read by its label: the tooltip, the whole list
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ symbol: String, count n: Int = 1) {
        icon.image = .symbol(symbol)
        count.isHidden = n < 2
        count.stringValue = "\(n)"
    }
}
