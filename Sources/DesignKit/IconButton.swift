import AppKit

/// A button that is an icon (and maybe a count): a 13 pt medium symbol in secondary grey on a 22 pt square. Under the
/// pointer the square greys in (it fades), pressed it darkens, and a click dips and springs it back (`PointerButton`).
/// The one icon button of the bars: a panel's header, a tab's toolbar, the sidebar's.
@MainActor
public final class IconButton: PointerButton {
    /// `image` named `tip` (its tooltip), calling `action`.
    public convenience init(_ image: NSImage?, tip: String, action: @escaping () -> Void) {
        self.init(image, tip: tip, target: nil, action: nil)
        onClick = action
    }

    public convenience init(_ image: NSImage?, tip: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.image = image
        imagePosition = .imageLeading
        toolTip = tip
        setAccessibilityLabel(tip)
        contentTintColor = .secondaryLabelColor
        symbolConfiguration = .init(pointSize: Metrics.iconPoint, weight: Metrics.iconWeight)
        font = .uiDigits(11, weight: .medium)
        self.target = target
        self.action = action
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    override public var intrinsicContentSize: NSSize {
        let s = super.intrinsicContentSize
        return NSSize(width: max(Metrics.iconButton, s.width + (title.isEmpty ? 0 : 6)), height: Metrics.iconButton)
    }
}
