import AppKit

/// An option named in a character or two ("Aa", ".*"), filled while on: a search's options.
public final class TextToggle: PointerButton {
    public var isOn = false {
        didSet {
            restFill = isOn ? .fillSelected : nil
            setAccessibilityValue(isOn)   // VoiceOver hears on or off, not only the fill
        }
    }

    public init(_ title: String, tip: String, action: @escaping () -> Void) {
        super.init(frame: .zero)
        self.title = title
        font = .uiMono(TextSize.caption)
        toolTip = tip
        setAccessibilityLabel(tip)
        setAccessibilityRole(.checkBox)
        setAccessibilityValue(false)
        onClick = action
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        widthAnchor.constraint(equalToConstant: Metrics.iconButton).isActive = true
        heightAnchor.constraint(equalToConstant: Metrics.iconButton).isActive = true
    }
    required public init?(coder: NSCoder) { fatalError("not from a nib") }
}
