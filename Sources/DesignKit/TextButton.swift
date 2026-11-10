import AppKit

/// A button named in words in a bar inside the window (a tab's toolbar, the bar over a file, a diff's hunk line): the
/// quiet grey plate, darker under the pointer. One look for them all; a sheet, Settings and an empty state keep the
/// system's push button, and only the window's own bar has capsules.
public final class TextButton: PointerButton {
    public init(_ title: String, target: AnyObject? = nil, action: Selector? = nil) {
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        font = .ui(TextSize.row)
        padding = Metrics.gap
        restFill = .fillRest
        setContentHuggingPriority(.required, for: .horizontal)
        heightAnchor.constraint(equalToConstant: TextSize.of(Metrics.iconButton)).isActive = true
    }
    public convenience init(_ title: String, onClick: @escaping () -> Void) {
        self.init(title)
        self.onClick = onClick
    }
    required public init?(coder: NSCoder) { fatalError("not from a nib") }
}
