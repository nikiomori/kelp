import AppKit

/// How a control answers the pointer: its fill fades in and out (not switched), a press dips it and lets it spring
/// back. Nothing moves under Reduce Motion; the fills still change, at once.
@MainActor
extension NSView {
    /// The layer's background becomes `color` (nil: none) over `Motion.fast`, from wherever it is now.
    public func fadeBackground(to color: NSColor?) {
        wantsLayer = true
        guard let layer else { return }
        var new: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance { new = color?.cgColor }
        let old = layer.presentation()?.backgroundColor ?? layer.backgroundColor
        layer.backgroundColor = new
        guard !Motion.reduced, old != new else { return }
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

    /// A press: the view dips to 90 % about its centre and springs back.
    public func pressBounce() {
        guard !Motion.reduced, let layer, bounds.width > 0 else { return }
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        func scaled(_ s: CGFloat) -> CATransform3D {   // a layer-backed view's anchor is its corner: scale about the middle
            CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-c.x, -c.y, 0), CATransform3DMakeScale(s, s, 1)),
                                CATransform3DMakeTranslation(c.x, c.y, 0))
        }
        let a = CAKeyframeAnimation(keyPath: "transform")
        a.values = [CATransform3DIdentity, scaled(0.9), scaled(1.03), CATransform3DIdentity].map { NSValue(caTransform3D: $0) }
        a.keyTimes = [0, 0.3, 0.7, 1]
        a.duration = Motion.appear
        a.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut),
                             CAMediaTimingFunction(name: .easeIn)]
        layer.add(a, forKey: "press")
    }
}
