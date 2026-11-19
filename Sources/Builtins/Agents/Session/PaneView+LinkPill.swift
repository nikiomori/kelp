import AppKit
import DesignKit

/// While ⌘ is held over a link or a path in the terminal, what ⌘-click opens, in a small plate at the terminal's
/// bottom-left, as Safari shows a link's address. It lets clicks through.
@MainActor
final class LinkPill: NSView {
    let label = NSTextField(labelWithString: "")

    /// Places the pill in `host`, at its leading edge, just above `bottom`'s top.
    init(in host: NSView, above bottom: NSView) {
        super.init(frame: .zero)
        label.font = .ui(TextSize.row)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle   // a path's file name and line are at its end
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let plate = NSView()
        plate.pin(
            label,
            inset: NSEdgeInsets(top: Metrics.lineGap, left: Metrics.gap, bottom: Metrics.lineGap, right: Metrics.gap))
        pin(FloatingCard(plate, radius: Metrics.radiusSM))   // a low hint, not a capsule control
        isHidden = true
        translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(self)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: Metrics.inset),   // as the cards over it
            bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -Metrics.inset),
            widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, multiplier: 0.6)   // the rest stays readable
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows `address`, fading in over `Motion.fast`; "" fades it out in two thirds of that.
    func show(_ address: String) {
        guard !address.isEmpty else {
            guard window != nil, !Motion.reduced else { return isHidden = true }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.fast * 2 / 3
                animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {   // AppKit ends the animation group on the main thread
                    if self?.alphaValue == 0 { self?.isHidden = true }
                }
            }
            return
        }
        label.stringValue = address
        fadeIn(Motion.fast)
    }
}
