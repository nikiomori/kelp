import AppKit

/// How a control answers the pointer: its fill fades in and out (not switched), held it darkens in the first frame, and
/// a click dips it and lets it spring back. Nothing moves under Reduce Motion; the fills still change, at once.
@MainActor
extension NSView {
    /// The layer's background becomes `color` (nil: none) over `Motion.fast`, from wherever it is now. `held`: a press,
    /// which shows at once: faded, a quick click would be over before it was seen.
    public func fadeBackground(to color: NSColor?, held: Bool = false) {
        wantsLayer = true
        guard let layer else { return }
        var new: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance { new = color?.cgColor }
        let old = layer.presentation()?.backgroundColor ?? layer.backgroundColor
        layer.backgroundColor = new
        if held { layer.removeAnimation(forKey: "fade") }
        guard !held, !Motion.reduced, old != new else { return }
        let a = CABasicAnimation(keyPath: "backgroundColor")
        a.fromValue = old ?? NSColor.clear.cgColor
        a.toValue = new ?? NSColor.clear.cgColor
        a.duration = Motion.fast
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(a, forKey: "fade")
    }

    /// What the view shows next fades in over what it showed (call it right before swapping its content).
    public func crossfade(_ duration: TimeInterval = Motion.fast) {
        guard !Motion.reduced else { return }
        wantsLayer = true
        let t = CATransition()
        t.type = .fade
        t.duration = duration
        layer?.add(t, forKey: "crossfade")
    }

    /// A click: the view dips about its centre by `Motion.pressDip` and springs back, a little past where it was.
    public func pressBounce() {
        guard !Motion.reduced, let layer, bounds.width > 0 else { return }
        func scaled(_ s: CGFloat) -> CATransform3D { aboutCentre(CATransform3DMakeScale(s, s, 1)) }
        let dip = Motion.pressDip(bounds.size)
        let a = CAKeyframeAnimation(keyPath: "transform")
        a.values = [CATransform3DIdentity, scaled(dip), scaled(1 + (1 - dip) * 0.3), CATransform3DIdentity].map { NSValue(caTransform3D: $0) }
        a.keyTimes = [0, 0.3, 0.7, 1]
        a.duration = Motion.press
        a.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut),
                             CAMediaTimingFunction(name: .easeIn)]
        layer.add(a, forKey: "press")
    }

    /// A turn: the view starts `angle` radians round from how it's drawn (counter-clockwise) and comes back, so a
    /// chevron just changed from ⌄ to › seems to turn there, as a disclosure triangle does.
    public func turn(from angle: CGFloat) {
        guard !Motion.reduced, let layer, bounds.width > 0 else { return }
        let a = CABasicAnimation(keyPath: "transform")
        a.fromValue = NSValue(caTransform3D: aboutCentre(CATransform3DMakeRotation(angle, 0, 0, 1)))
        a.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        a.duration = Motion.base
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(a, forKey: "turn")
    }

    /// `t` about the view's middle: a layer-backed view's anchor is its corner.
    private func aboutCentre(_ t: CATransform3D) -> CATransform3D {
        CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-bounds.midX, -bounds.midY, 0), t),
                            CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0))
    }
}
