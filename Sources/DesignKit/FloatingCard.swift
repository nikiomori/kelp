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
        let s = NSShadow()   // shadow-floating-sm: 0 2 6, black 20 %
        s.shadowBlurRadius = 6
        s.shadowOffset = NSSize(width: 0, height: -2)
        s.shadowColor = NSColor.black.withAlphaComponent(0.2)
        shadow = s
        for (outer, inner) in [(self, material), (material, content)] as [(NSView, NSView)] {
            inner.translatesAutoresizingMaskIntoConstraints = false
            outer.addSubview(inner)
            NSLayoutConstraint.activate([
                inner.topAnchor.constraint(equalTo: outer.topAnchor), inner.bottomAnchor.constraint(equalTo: outer.bottomAnchor),
                inner.leadingAnchor.constraint(equalTo: outer.leadingAnchor), inner.trailingAnchor.constraint(equalTo: outer.trailingAnchor)
            ])
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}
