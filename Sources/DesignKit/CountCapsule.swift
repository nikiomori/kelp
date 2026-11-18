import AppKit

/// A section's file count on a grey capsule, as in VS Code, because a bare "3" next to "+6 −2" ran into it. Every
/// list's section shows its count this way (Source Control, Skills & MCP, Databases). VoiceOver reads the capsule as
/// "3 items", because a bare "3" says nothing; text that isn't a number is read as it is.
public final class CountCapsule: NSView {
    private let field = NSTextField(labelWithString: "")
    public var text: String {
        get { field.stringValue }
        set {
            field.stringValue = newValue
            setAccessibilityLabel(Int(newValue).map { String(localized: "\($0) items") } ?? newValue)
        }
    }
    public init() {
        super.init(frame: .zero)
        field.font = .uiDigits(TextSize.micro, weight: .semibold)
        field.textColor = .secondaryLabelColor
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            field.centerYAnchor.constraint(equalTo: centerYAnchor), heightAnchor.constraint(equalToConstant: 16),
            widthAnchor.constraint(greaterThanOrEqualTo: heightAnchor)
        ])
        // VoiceOver reads the capsule with its label, not the digits inside it.
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        field.setAccessibilityElement(false)
    }
    public required init?(coder: NSCoder) { fatalError() }
    override public var wantsUpdateLayer: Bool { true }
    override public func updateLayer() {
        layer?.backgroundColor = NSColor.fillSelected.cgColor
        layer?.cornerRadius = bounds.height / 2
    }
    override public func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
}
