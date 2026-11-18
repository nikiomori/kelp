import AppKit

/// A stack view on a fill: a band across a list, or a card in it. The fill is read in `updateLayer`, which AppKit calls
/// again on every light / dark change with the view's appearance current. A `cgColor` set once on the layer keeps the
/// colour of the appearance it was built in.
public final class FillStack: NSStackView {
    public var fill: NSColor = .clear {
        didSet {
            wantsLayer = true
            needsDisplay = true
        }
    }
    override public var wantsUpdateLayer: Bool { true }
    override public func updateLayer() { layer?.backgroundColor = fill.cgColor }
}
