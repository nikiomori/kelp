import AppKit

/// How a control answers the pointer: its fill fades in and out (not switched), held it darkens in the first frame, and
/// a click dips it and lets it spring back. Nothing moves under Reduce Motion; the fills still change, at once.
@MainActor
extension NSView {
    /// `updateTrackingAreas`' body: `old` goes and a new area over the visible rect takes its place, reporting enter and exit.
    public func retracked(_ old: NSTrackingArea?, _ active: NSTrackingArea.Options) -> NSTrackingArea {
        if let old { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .inVisibleRect, active], owner: self)
        addTrackingArea(area)
        return area
    }

    /// The layer's background becomes `color` (nil: none) over `Motion.fast`, from wherever it is now. `held`: a press,
    /// which shows at once: faded, a quick click would be over before it was seen.
    public func fadeBackground(to color: NSColor?, held: Bool = false) {
        wantsLayer = true
        guard let layer else { return }
        var new: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance { new = color?.cgColor }
        layer.animate("backgroundColor", to: new, duration: held ? 0 : Motion.fast)
        if held { layer.removeAnimation(forKey: "backgroundColor") }
    }

    /// What the view shows next fades in over what it showed (call it right before swapping its content).
    public func crossfade(_ duration: TimeInterval = Motion.fast) {
        guard !Motion.reduced else { return }
        wantsLayer = true
        let transition = CATransition()
        transition.type = .fade
        transition.duration = duration
        layer?.add(transition, forKey: "crossfade")
    }

    /// A click: the view dips about its centre by `Motion.pressDip` and springs back, a little past where it was.
    public func pressBounce() {
        guard !Motion.reduced, let layer, bounds.width > 0 else { return }
        func scaled(_ scale: CGFloat) -> CATransform3D { aboutCentre(CATransform3DMakeScale(scale, scale, 1)) }
        let dip = Motion.pressDip(bounds.size)
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = [CATransform3DIdentity, scaled(dip), scaled(1 + (1 - dip) * 0.3), CATransform3DIdentity].map
        {
            NSValue(caTransform3D: $0)
        }
        animation.keyTimes = [0, 0.3, 0.7, 1]
        animation.duration = Motion.press
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeIn)
        ]
        layer.add(animation, forKey: "press")
    }

    /// A turn: the view starts `angle` radians round from how it's drawn (counter-clockwise) and comes back, so a
    /// chevron just changed from ⌄ to › seems to turn there, as a disclosure triangle does.
    public func turn(from angle: CGFloat) {
        wantsLayer = true
        guard !Motion.reduced, let layer, bounds.width > 0 else { return }
        // The click's spring is on the same transform: its tail popped after the turn.
        layer.removeAnimation(forKey: "press")
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: aboutCentre(CATransform3DMakeRotation(angle, 0, 0, 1)))
        animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        animation.duration = Motion.base
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "turn")
    }

    /// Where the view stands in its window: take it before a layout changes, for `slide(from:)` after.
    public var placeInWindow: NSPoint { convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil) }

    /// A view a layout moved seems to travel from where it stood (`placeInWindow`) instead of jumping there.
    public func slide(from place: NSPoint, duration: TimeInterval = Motion.appear) {
        let now = placeInWindow, dx = place.x - now.x, dy = place.y - now.y
        wantsLayer = true
        guard !Motion.reduced, let layer, abs(dx) + abs(dy) > 0.5 else { return }
        let animation = CABasicAnimation(keyPath: "transform.translation")
        animation.fromValue = NSValue(size: NSSize(width: dx, height: superview?.isFlipped == true ? -dy : dy))
        animation.toValue = NSValue(size: .zero)
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "slide")
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
            let picture = bitmapImageRepForCachingDisplay(in: bounds)
        else { return }
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
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, -5, 5, -3, 3, -1, 0]
        animation.duration = Motion.press
        layer.add(animation, forKey: "shake")
    }

    /// Work on its way through a control (a push, a pull): a soft shade runs up (`true`) or down its glyph, again and
    /// again. nil: it stops. Nothing under Reduce Motion: the words on the panel's button say it.
    public func flow(up: Bool?) {
        wantsLayer = true
        guard let layer else { return }
        guard let up, !Motion.reduced else {
            layer.mask = nil
            return
        }
        let band = CAGradientLayer()
        band.frame = bounds.insetBy(dx: -40, dy: 0)   // the count beside the arrow may grow or go while it runs
        band.colors = [NSColor.black, .black.withAlphaComponent(0.3), .black].map(\.cgColor)
        // A gradient's y runs up the screen whichever way its view is flipped.
        band.startPoint = CGPoint(x: 0.5, y: up ? 0 : 1)
        band.endPoint = CGPoint(x: 0.5, y: up ? 1 : 0)
        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [-0.5, -0.25, 0]
        animation.toValue = [1, 1.25, 1.5]
        animation.duration = Motion.pulse
        animation.repeatCount = .infinity
        animation.beginTime = Motion.beat(animation.duration)
        band.add(animation, forKey: "flow")
        layer.mask = band
    }

    /// `transform` about the view's middle: a layer-backed view's anchor is its corner.
    private func aboutCentre(_ transform: CATransform3D) -> CATransform3D {
        CATransform3DConcat(
            CATransform3DConcat(CATransform3DMakeTranslation(-bounds.midX, -bounds.midY, 0), transform),
            CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0))
    }
}

@MainActor
extension CALayer {
    /// `keyPath` takes `value` now and is seen to go there from wherever it showed, over `duration`; at once under
    /// Reduce Motion. No implicit action: a bare layer's own 0.25 s one showed the old value again after the fade. A
    /// colour's nil is clear; another value nil before comes in where it's going.
    public func animate(
        _ keyPath: String, to value: Any?, duration: TimeInterval = Motion.fast,
        timing: CAMediaTimingFunctionName = .easeOut
    ) {
        let none: Any? = keyPath.hasSuffix("Color") ? NSColor.clear.cgColor : value
        let old = presentation()?.value(forKeyPath: keyPath) ?? self.value(forKeyPath: keyPath) ?? none
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setValue(value, forKeyPath: keyPath)
        CATransaction.commit()
        let new = value ?? none
        guard !Motion.reduced, duration > 0, old.map({ ($0 as AnyObject).isEqual(new) }) != true else { return }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = old
        animation.toValue = new
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: timing)
        add(animation, forKey: keyPath)
    }
}

/// What `leaveGhost` leaves: only a picture, clicks go through it.
private final class Ghost: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
extension NSTableView {
    /// A panel's list: one column as wide as the table (an outline's own), no header, no fill; in `scroll`, which
    /// gets a vertical scroller and no fill either.
    @discardableResult
    public func plainList(_ column: String, in scroll: NSScrollView = NSScrollView()) -> NSScrollView {
        let col = NSTableColumn(identifier: .init(column))
        col.resizingMask = .autoresizingMask
        addTableColumn(col)
        (self as? NSOutlineView)?.outlineTableColumn = col
        // The column is the panel's width and stays it: an outline otherwise widens it to its longest row whenever one
        // opens, and the rows' right-hand ends (a run's time) go past the panel's edge.
        (self as? NSOutlineView)?.autoresizesOutlineColumn = false
        headerView = nil
        style = .plain
        backgroundColor = .clear
        scroll.documentView = self
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    /// Where the rows on show stand, by a key that outlives a reload: for `settleRows` after it.
    public func rowPlaces(_ key: (Int) -> String?) -> [String: NSPoint] {
        var places: [String: NSPoint] = [:]
        enumerateAvailableRowViews { rowView, row in
            if let rowKey = key(row) { places[rowKey] = rowView.placeInWindow }
        }
        return places
    }

    /// After a reload: rows that stayed travel from where they stood, new ones fade in. More than a few coming or going
    /// is the list changing as a whole, not something happening: that just shows.
    public func settleRows(from places: [String: NSPoint], _ key: (Int) -> String?) {
        guard !places.isEmpty, !Motion.reduced, window?.isVisible == true else { return }
        layoutSubtreeIfNeeded()
        var rows: [(NSTableRowView, String)] = []
        enumerateAvailableRowViews { rowView, row in
            if let rowKey = key(row) { rows.append((rowView, rowKey)) }
        }
        let came = rows.filter { places[$0.1] == nil }, kept = Set(rows.map(\.1))
        guard came.count + places.keys.filter({ !kept.contains($0) }).count <= 3 else { return }
        for (row, rowKey) in rows { if let place = places[rowKey] { row.slide(from: place) } }
        for (row, _) in came {
            row.wantsLayer = true
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 0
            animation.toValue = 1
            animation.duration = Motion.appear
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            row.layer?.add(animation, forKey: "arrive")
        }
    }
}
