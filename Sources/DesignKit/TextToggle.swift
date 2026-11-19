import AppKit

/// An option named in a character or two ("Aa", ".*"), filled while on: a search's options.
public final class TextToggle: PointerButton {
    public var isOn = false { didSet { restFill = isOn ? .fillSelected : nil } }

    public init(_ title: String, tip: String, action: @escaping () -> Void) {
        super.init(frame: .zero)
        self.title = title
        font = .uiMono(TextSize.caption)
        toolTip = tip
        setAccessibilityLabel(tip)
        onClick = action
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        // A square that grows with Text size, as its letters and the icon buttons beside it do.
        let side = TextSize.of(Metrics.iconButton)
        widthAnchor.constraint(equalToConstant: side).isActive = true
        heightAnchor.constraint(equalToConstant: side).isActive = true
    }
    required public init?(coder: NSCoder) { fatalError("not from a nib") }
}
