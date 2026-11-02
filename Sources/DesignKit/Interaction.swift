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
        wantsLayer = true
        guard !Motion.reduced, let layer, bounds.width > 0 else { return }
        let a = CABasicAnimation(keyPath: "transform")
        a.fromValue = NSValue(caTransform3D: aboutCentre(CATransform3DMakeRotation(angle, 0, 0, 1)))
        a.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        a.duration = Motion.base
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(a, forKey: "turn")
    }

    /// Where the view stands in its window: take it before a layout changes, for `slide(from:)` after.
    public var placeInWindow: NSPoint { convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil) }

    /// A view a layout moved seems to travel from where it stood (`placeInWindow`) instead of jumping there.
    public func slide(from place: NSPoint, duration: TimeInterval = Motion.appear) {
        let now = placeInWindow, dx = place.x - now.x, dy = place.y - now.y
        wantsLayer = true
        guard !Motion.reduced, let layer, abs(dx) + abs(dy) > 0.5 else { return }
        let a = CABasicAnimation(keyPath: "transform.translation")
        a.fromValue = NSValue(size: NSSize(width: dx, height: superview?.isFlipped == true ? -dy : dy))
        a.toValue = NSValue(size: .zero)
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(a, forKey: "slide")
    }

    /// Coming into view (what appears over content, not a row): it fades in, rising a little.
    public func comeIn() {
        guard !Motion.reduced, window != nil else { return }
        wantsLayer = true
        alphaValue = 0
        slide(from: NSPoint(x: placeInWindow.x, y: placeInWindow.y - Metrics.gapWide))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.appear
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    /// About to go in a change that can't animate it: a picture of the view stays where it stood, over `parent`, and
    /// fades. Call it before the view is removed.
    public func leaveGhost(in parent: NSView) {
        guard !Motion.reduced, window != nil, bounds.width > 0, bounds.height > 0,
              let picture = bitmapImageRepForCachingDisplay(in: bounds) else { return }
        cacheDisplay(in: bounds, to: picture)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(picture)
        let ghost = Ghost(image: image)
        ghost.frame = parent.convert(bounds, from: self)
        parent.addSubview(ghost)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.appear
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ghost.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { ghost.removeFromSuperview() }   // AppKit runs it on the main thread
        }
    }

    /// Something failed: the view shakes its head, as a password field does.
    public func shake() {
        wantsLayer = true
        guard !Motion.reduced, let layer else { return }
        let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
        a.values = [0, -5, 5, -3, 3, -1, 0]
        a.duration = Motion.press
        layer.add(a, forKey: "shake")
    }

    /// Work on its way through a control (a push, a pull): a soft shade runs up (`true`) or down its glyph, again and
    /// again. nil: it stops. Nothing under Reduce Motion: the words on the panel's button say it.
    public func flow(up: Bool?) {
        wantsLayer = true
        guard let layer else { return }
        guard let up, !Motion.reduced else { layer.mask = nil; return }
        let band = CAGradientLayer()
        band.frame = bounds.insetBy(dx: -40, dy: 0)   // the count beside the arrow may grow or go while it runs
        band.colors = [NSColor.black, .black.withAlphaComponent(0.3), .black].map(\.cgColor)
        // A gradient's y runs up the screen whichever way its view is flipped.
        band.startPoint = CGPoint(x: 0.5, y: up ? 0 : 1)
        band.endPoint = CGPoint(x: 0.5, y: up ? 1 : 0)
        let a = CABasicAnimation(keyPath: "locations")
        a.fromValue = [-0.5, -0.25, 0]
        a.toValue = [1, 1.25, 1.5]
        a.duration = Motion.pulse
        a.repeatCount = .infinity
        a.beginTime = Motion.beat(a.duration)
        band.add(a, forKey: "flow")
        layer.mask = band
    }

    /// `t` about the view's middle: a layer-backed view's anchor is its corner.
    private func aboutCentre(_ t: CATransform3D) -> CATransform3D {
        CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-bounds.midX, -bounds.midY, 0), t),
                            CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0))
    }
}

/// What `leaveGhost` leaves: only a picture, clicks go through it.
private final class Ghost: NSImageView {
    override func hitTest(_ p: NSPoint) -> NSView? { nil }
}

@MainActor
extension NSTableView {
    /// Where the rows on show stand, by a key that outlives a reload: for `settleRows` after it.
    public func rowPlaces(_ key: (Int) -> String?) -> [String: NSPoint] {
        var places: [String: NSPoint] = [:]
        enumerateAvailableRowViews { v, row in
            if let k = key(row) { places[k] = v.placeInWindow }
        }
        return places
    }

    /// After a reload: rows that stayed travel from where they stood, new ones fade in. More than a few coming or going
    /// is the list changing as a whole, not something happening: that just shows.
    public func settleRows(from places: [String: NSPoint], _ key: (Int) -> String?) {
        guard !places.isEmpty, !Motion.reduced, window?.isVisible == true else { return }
        layoutSubtreeIfNeeded()
        var rows: [(NSTableRowView, String)] = []
        enumerateAvailableRowViews { v, row in
            if let k = key(row) { rows.append((v, k)) }
        }
        let came = rows.filter { places[$0.1] == nil }, kept = Set(rows.map(\.1))
        guard came.count + places.keys.filter({ !kept.contains($0) }).count <= 3 else { return }
        for (row, k) in rows { if let place = places[k] { row.slide(from: place) } }
        for (row, _) in came {
            row.wantsLayer = true
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 0
            a.toValue = 1
            a.duration = Motion.appear
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            row.layer?.add(a, forKey: "arrive")
        }
    }
}
