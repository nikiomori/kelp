import AppKit

/// How a control answers the pointer. Its fill fades in and out rather than switching, when held it darkens in the
/// first frame, and a click dips it and lets it spring back. Nothing moves under Reduce Motion, but the fills still
/// change, at once.
@MainActor
extension NSView {
    /// The body of `updateTrackingAreas`: `old` goes, and a new area over the visible rect takes its place, reporting
    /// enter and exit.
    public func retracked(_ old: NSTrackingArea?, _ active: NSTrackingArea.Options) -> NSTrackingArea {
        if let old { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .inVisibleRect, active], owner: self)
        addTrackingArea(area)
        return area
    }

    /// Fades the layer's background to `color` (nil for none) over `Motion.fast`, from wherever it is now. `held` is a
    /// press, which shows at once, because faded, a quick click would be over before it was seen.
    public func fadeBackground(to color: NSColor?, held: Bool = false) {
        wantsLayer = true
        guard let layer else { return }
        var new: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance { new = color?.cgColor }
        layer.animate("backgroundColor", to: new, duration: held ? 0 : Motion.fast)
        if held { layer.removeAnimation(forKey: "backgroundColor") }
    }

    /// Fades what the view shows next in over what it showed. Call it right before swapping its content.
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
        // The click's spring is on the same transform, and its tail popped after the turn, so it's removed.
        layer.removeAnimation(forKey: "press")
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: aboutCentre(CATransform3DMakeRotation(angle, 0, 0, 1)))
        animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        animation.duration = Motion.fold
        animation.timingFunction = Motion.soft
        layer.add(animation, forKey: "turn")
    }

    /// Shows the view, fading in from what shows now: from nothing if it was hidden, or from wherever a fade out had
    /// got to if not.
    public func fadeIn(_ duration: TimeInterval = Motion.fast) {
        wantsLayer = true
        let from = isHidden ? 0 : layer?.presentation()?.opacity ?? Float(alphaValue)
        isHidden = false
        alphaValue = 1
        guard !Motion.reduced, window != nil, from < 1, let layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = 1
        fade.duration = duration
        layer.add(fade, forKey: "opacity")
    }

    /// Hides the view, fading it out over `duration` (at once off screen or under Reduce Motion), unless `back` says
    /// at the end that it was shown again meanwhile.
    public func fadeOut(
        _ duration: TimeInterval = Motion.fast, timing: CAMediaTimingFunction? = CAMediaTimingFunction(name: .easeIn),
        unless back: @escaping @MainActor () -> Bool
    ) {
        guard window != nil, !Motion.reduced else { return isHidden = true }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = timing
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {   // AppKit ends the group on the main thread
                guard let self, !back() else { return }
                self.isHidden = true
                self.alphaValue = 1
            }
        }
    }

    /// Where the view stands in its window. Take it before a layout changes, for `slide(from:)` after.
    public var placeInWindow: NSPoint { convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil) }

    /// Makes a view that a layout moved seem to travel from where it stood (`placeInWindow`) instead of jumping there.
    public func slide(from place: NSPoint, duration: TimeInterval = Motion.appear) {
        let now = placeInWindow, dx = place.x - now.x, dy = place.y - now.y
        wantsLayer = true
        guard !Motion.reduced, let layer, abs(dx) + abs(dy) > 0.5 else { return }
        let animation = CABasicAnimation(keyPath: "transform.translation")
        animation.fromValue = NSValue(size: NSSize(width: dx, height: superview?.isFlipped == true ? -dy : dy))
        animation.toValue = NSValue(size: .zero)
        animation.duration = duration
        animation.timingFunction = Motion.soft
        layer.add(animation, forKey: "slide")
    }

    /// Brings the view into view, for what appears over content, not a row. It fades in, rising a little.
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

    /// For a view about to go in a change that can't animate it. A picture of the view stays where it stood, over
    /// `parent`, and fades over `duration`, drifting `drift` points up the screen (down when negative). Call it before
    /// the view is removed or redrawn. A row comes in over `appear` and goes over `base`, about two thirds of it.
    public func leaveGhost(in parent: NSView, duration: TimeInterval = Motion.base, drift: CGFloat = 0) {
        guard !Motion.reduced, window != nil, bounds.width > 0, bounds.height > 0,
            let picture = bitmapImageRepForCachingDisplay(in: bounds)
        else { return }
        cacheDisplay(in: bounds, to: picture)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(picture)
        let ghost = Ghost(image: image)
        ghost.frame = parent.convert(bounds, from: self)
        ghost.wantsLayer = true
        parent.addSubview(ghost)
        if drift != 0, let layer = ghost.layer {
            let move = CABasicAnimation(keyPath: "transform.translation.y")
            move.toValue = parent.isFlipped ? -drift : drift   // a flipped view's layer is flipped, so its y runs down
            move.duration = duration
            move.timingFunction = Motion.soft
            move.fillMode = .forwards
            move.isRemovedOnCompletion = false
            layer.add(move, forKey: "drift")
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ghost.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { ghost.removeFromSuperview() }   // AppKit runs it on the main thread
        }
    }

    /// For a number on show that changed. The old number drifts off and fades while the new one comes in from the
    /// other side, up the screen when it grew (`up`) and down when it fell, as the system's numeric text does. Call it
    /// right before setting the new number, on a view showing only the number, so its words or its capsule stay put.
    public func roll(up: Bool) {
        guard !Motion.reduced, window != nil, let parent = superview, bounds.height > 0 else { return }
        let shift = bounds.height / 2 * (up ? 1 : -1)
        leaveGhost(in: parent, duration: Motion.fast, drift: shift)   // what leaves goes in two thirds of the time
        slide(from: NSPoint(x: placeInWindow.x, y: placeInWindow.y - shift), duration: Motion.base)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Motion.base
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(fade, forKey: "roll")
    }

    /// When something failed, the view shakes its head, as a password field does.
    public func shake() {
        wantsLayer = true
        guard !Motion.reduced, let layer else { return }
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, -5, 5, -3, 3, -1, 0]
        animation.duration = Motion.press
        layer.add(animation, forKey: "shake")
    }

    /// Shows work on its way through a control (a push, a pull): a soft shade runs up (`true`) or down its glyph, again
    /// and again, and nil stops it. Nothing runs under Reduce Motion, because the words on the panel's button say it;
    /// switched while it runs, the shade stops or starts.
    public func flow(up: Bool?) {
        wantsLayer = true
        guard let layer else { return }
        if up != nil, layer.value(forKey: "flowFollows") == nil {
            layer.setValue(true, forKey: "flowFollows")
            followReduceMotion(#selector(flowMotionChanged))
        }
        layer.setValue(up, forKey: "flowUp")   // what `flowMotionChanged` carries on with
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

    @objc private func flowMotionChanged() { flow(up: layer?.value(forKey: "flowUp") as? Bool) }

    /// `transform` about the view's middle, because a layer-backed view's anchor is its corner.
    func aboutCentre(_ transform: CATransform3D) -> CATransform3D {
        CATransform3DConcat(
            CATransform3DConcat(CATransform3DMakeTranslation(-bounds.midX, -bounds.midY, 0), transform),
            CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0))
    }
}

@MainActor
extension CALayer {
    /// Sets `keyPath` to `value` now, and shows it going there from wherever it showed, over `duration`, or at once
    /// under Reduce Motion. There's no implicit action, because a bare layer's own 0.25 s one showed the old value
    /// again after the fade. A colour's nil is clear; a value that was nil before comes in where it's going.
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

/// What `leaveGhost` leaves: only a picture, and clicks go through it.
private final class Ghost: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
extension NSTableView {
    /// Makes this a panel's list: one column as wide as the table (an outline's own column), no header and no fill, in
    /// `scroll`, which gets a vertical scroller and no fill either. A cell spans the row, so a row's content starts at
    /// a panel's inset from the list's own edge, under its header's first item; the table's default spacing between
    /// cells would move it 8.5 pt further in on both sides.
    @discardableResult
    public func plainList(_ column: String, in scroll: NSScrollView = NSScrollView()) -> NSScrollView {
        let col = NSTableColumn(identifier: .init(column))
        col.resizingMask = .autoresizingMask
        addTableColumn(col)
        (self as? NSOutlineView)?.outlineTableColumn = col
        // The column is the panel's width and stays it. Otherwise an outline widens it to its longest row whenever one
        // opens, and the rows' right-hand ends (a run's time) go past the panel's edge.
        (self as? NSOutlineView)?.autoresizesOutlineColumn = false
        headerView = nil
        style = .plain
        intercellSpacing = .zero
        backgroundColor = .clear
        scroll.documentView = self
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    /// Where the rows on show stand, by a key that outlives a reload, for `settleRows` after it.
    public func rowPlaces(_ key: (Int) -> String?) -> [String: NSPoint] {
        var places: [String: NSPoint] = [:]
        enumerateAvailableRowViews { rowView, row in
            if let rowKey = key(row) { places[rowKey] = rowView.placeInWindow }
        }
        return places
    }

    /// After a reload, rows that stayed travel from where they stood, and new ones fade in. More than a few coming or
    /// going means the list changed as a whole, not that something happened, so then it just shows. A caller that
    /// knows which rows are new says so in `new`; otherwise they are counted among the rows on screen, where a row
    /// pushed out of sight counts as gone.
    public func settleRows(from places: [String: NSPoint], _ key: (Int) -> String?, new: Set<String>? = nil) {
        guard !places.isEmpty, !Motion.reduced, window?.isVisible == true else { return }
        layoutSubtreeIfNeeded()
        var rows: [(NSTableRowView, String)] = []
        enumerateAvailableRowViews { rowView, row in
            if let rowKey = key(row) { rows.append((rowView, rowKey)) }
        }
        let came = rows.filter { new?.contains($0.1) ?? (places[$0.1] == nil) }, kept = Set(rows.map(\.1))
        guard new != nil || came.count + places.keys.filter({ !kept.contains($0) }).count <= 3 else { return }
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

    /// True when a refresh that adds `came` rows and drops `gone` is one to show moving: a few rows, in a list on
    /// screen that had rows, with motion on. More is the list changing as a whole, which just shows.
    public func movesFor(came: Int, gone: Int, from places: [String: NSPoint]) -> Bool {
        came + gone <= 3 && !places.isEmpty && !Motion.reduced && window?.isVisible == true
    }

    /// Reloads the list after a refresh, with the motion a small change gets: a row that goes leaves a picture that
    /// fades where it stood, the rows that stay travel to where they stand now, and a new one fades in. Call it with
    /// the new rows in the model and the old ones still on screen: `places` is `rowPlaces` from before the model
    /// changed, `came` and `gone` are the keys the refresh added and dropped, and `reload` reloads the list and puts
    /// back what it keeps (the open folds, the picked row).
    public func reloadSettling(
        from places: [String: NSPoint], came: Set<String>, gone: Set<String>, _ key: (Int) -> String?,
        reload: () -> Void
    ) {
        let moves = movesFor(came: came.count, gone: gone.count, from: places)
        if moves, let over = enclosingScrollView {
            for place in gone.compactMap({ places[$0] }) {
                // What leaves goes in less time than what comes takes.
                rowView(atRow: row(at: convert(place, from: nil)), makeIfNecessary: false)?
                    .leaveGhost(in: over, duration: Motion.base)
            }
        }
        reload()
        if moves { settleRows(from: places, key, new: came) }
    }
}

extension NSEvent {
    /// Whether this is a click with exactly `keys` held, as the design system reads them: ⌘ alone does the same thing
    /// in another place, ⌥ alone another action of the same place, ⇧ beside.
    public func isClick(with keys: NSEvent.ModifierFlags) -> Bool {
        [.leftMouseDown, .leftMouseUp].contains(type)
            && modifierFlags.intersection([.command, .shift, .option, .control]) == keys
    }
}
