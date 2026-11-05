import AppKit

/// State as light along the inside of an edge (an agent asks, failed, waits for its command): a soft glow inward (and a
/// hairline, where there's room for one), the shadow of a frame drawn just outside and clipped to the rounded bounds. The
/// pane's ring and a tab's are this one view, at their own corner and spread; nothing outside the edge is tinted, and
/// clicks go through.
@MainActor
public final class EdgeGlow: NSView {
    private let frameLayer = CAShapeLayer()
    private var color: NSColor?
    private var breathing = false
    private var faint = false
    private let hairline: Bool
    /// The corner it follows (a tab's capsule changes it as it lays out).
    public var radius: CGFloat { didSet { layer?.cornerRadius = radius; needsLayout = true } }

    /// `spread`: how far the light reaches in, `strength` its opacity at the edge (a pane 14 and 0.6; a tab, 28 pt tall,
    /// 3 and 0.5, so its middle stays the tab's own colour). `hairline` off: light only, no line along the edge (a tab: a
    /// lined tab read as more chosen than the chosen one).
    public init(radius: CGFloat, spread: CGFloat, strength: Float = 0.6, hairline: Bool = true) {
        self.radius = radius
        self.hairline = hairline
        super.init(frame: .zero)
        wantsLayer = true; isHidden = true
        layer?.masksToBounds = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = hairline ? 1 : 0
        frameLayer.fillRule = .evenOdd
        frameLayer.shadowOffset = .zero
        frameLayer.shadowRadius = spread
        frameLayer.shadowOpacity = strength
        layer?.addSublayer(frameLayer)
        followReduceMotion(#selector(motionChanged))
        // A pane's ring lights a screenful: with nobody at the window it holds still.
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(motionChanged), name: name, object: nil)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override public func hitTest(_ p: NSPoint) -> NSView? { nil }

    /// Fades in and out, and eases into and out of breathing, rather than switching at once. nil: none. `faint`: half
    /// the light, for what's there to notice and not to answer.
    public func show(_ color: NSColor?, breathing: Bool, faint: Bool = false) {
        guard color != self.color || breathing != self.breathing || faint != self.faint else { return }   // every tab's every refresh comes here
        self.color = color
        self.breathing = breathing
        self.faint = faint
        guard let color else {
            // Keeps its colour and breathing while it fades; hidden at the end unless it was called back meanwhile.
            NSAnimationContext.runAnimationGroup({ $0.duration = Motion.duration(Motion.disappear); animator().alphaValue = 0 }) { [weak self] in
                MainActor.assumeIsolated {  // AppKit runs the completion on the main thread
                    guard let self, self.color == nil else { return }
                    self.isHidden = true
                    self.frameLayer.removeAllAnimations()
                }
            }
            return
        }
        if isHidden { alphaValue = 0; isHidden = false }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.duration(Motion.appear)
            ctx.allowsImplicitAnimation = true
            animator().alphaValue = 1
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let light = color.withAlphaComponent(faint ? 0.5 : 1).cgColor
                layer?.borderColor = color.withAlphaComponent(faint ? 0.25 : 0.5).cgColor
                frameLayer.fillColor = light; frameLayer.shadowColor = light
            }
        }
        breathe(breathes)
    }

    private var breathes: Bool { color != nil && breathing && !Motion.reduced && NSApplication.shared.isActive }
    @objc private func motionChanged() { breathe(breathes) }

    private func breathe(_ on: Bool) {
        let breathingNow = frameLayer.animation(forKey: "breathe") != nil
        guard on != breathingNow else { return }
        let opacity = frameLayer.presentation()?.opacity ?? 1
        frameLayer.removeAnimation(forKey: "breathe")
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = opacity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        if on {
            a.fromValue = 1
            a.toValue = 0.35
            a.duration = Motion.breathe
            a.autoreverses = true
            a.repeatCount = .infinity
            a.beginTime = Motion.beat(2 * a.duration)
            a.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)   // no faster than it shows
            frameLayer.add(a, forKey: "breathe")
        } else {
            a.toValue = 1   // back to full from wherever the breath was
            a.duration = Motion.appear
            frameLayer.add(a, forKey: "settle")
        }
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let color, !isHidden {
            self.color = nil   // the same colour, resolved anew
            show(color, breathing: breathing, faint: faint)
        }
    }

    override public func layout() {
        super.layout()
        // Given as the shadow's path, the shadow isn't worked out from the layer's pixels offscreen on every frame of the
        // breathing animation.
        guard bounds.width > 0, bounds.height > 0 else { return }
        let path = Self.frame(around: bounds, radius: min(radius, bounds.height / 2, bounds.width / 2))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.frame = bounds
        frameLayer.path = path
        frameLayer.shadowPath = path
        CATransaction.commit()
    }

    /// A band just outside `b`, its rounded inner edge wound against the outer one (mirrored), so the hole stays a hole
    /// under the non-zero rule a shadow path is filled with.
    static func frame(around b: CGRect, radius r: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addRect(b.insetBy(dx: -40, dy: -40))
        let mirror = CGAffineTransform(translationX: 2 * b.midX, y: 0).scaledBy(x: -1, y: 1)
        path.addPath(CGPath(roundedRect: b, cornerWidth: r, cornerHeight: r, transform: nil), transform: mirror)
        return path
    }
}
