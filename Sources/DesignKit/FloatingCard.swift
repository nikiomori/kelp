import AppKit

/// Something small that floats over a tab's content (the terminal's find bar, "Session ended", the Markdown selection
/// bar, the banner): the popover material on a continuous rounded rect, with a small shadow. `radius`: 8 for a control
/// strip, 10 for a card.
@MainActor
public final class FloatingCard: NSView {
    private let material = NSVisualEffectView()

    public init(_ content: NSView, radius: CGFloat = Metrics.radiusLG) {
        super.init(frame: .zero)
        material.material = .popover
        material.blendingMode = .withinWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = radius
        material.layer?.cornerCurve = .continuous
        material.layer?.masksToBounds = true
        let floatShadow = NSShadow()   // shadow-floating-sm: 0 2 6, black 20 %
        floatShadow.shadowBlurRadius = 6
        floatShadow.shadowOffset = NSSize(width: 0, height: -2)
        floatShadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
        shadow = floatShadow
        pin(material)
        material.pin(content)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Liquid Glass where there is (macOS 26), this card before. `glassRadius`: the glass's own, when it differs.
    public static func ground(_ content: NSView, radius: CGFloat, glassRadius: CGFloat? = nil) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = glassRadius ?? radius
            glass.contentView = content
            return glass
        }
        return FloatingCard(content, radius: radius)
    }
}
