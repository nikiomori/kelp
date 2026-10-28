import AppKit

/// A button that is an icon (and maybe a count): a 13 pt symbol in secondary grey on a 22 pt square that greys under the
/// pointer. The one icon button of the bars: a panel's header, a tab's toolbar, the sidebar's.
@MainActor
public final class IconButton: NSButton {
    private var handler: (() -> Void)?
    private var area: NSTrackingArea?
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }

    /// `image` named `tip` (its tooltip), calling `action`.
    public convenience init(_ image: NSImage?, tip: String, action: @escaping () -> Void) {
        self.init(image, tip: tip, target: nil, action: nil)
        handler = action
        target = self
        self.action = #selector(fire)
    }

    public convenience init(_ image: NSImage?, tip: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.image = image
        title = ""
        isBordered = false
        imagePosition = .imageLeading
        toolTip = tip
        setAccessibilityLabel(tip)
        contentTintColor = .secondaryLabelColor
        symbolConfiguration = .init(pointSize: Metrics.iconPoint, weight: .regular)
        font = .uiDigits(11, weight: .medium)
        self.target = target
        self.action = action
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @objc private func fire() { handler?() }

    override public var intrinsicContentSize: NSSize {
        let s = super.intrinsicContentSize
        return NSSize(width: max(Metrics.iconButton, s.width + (title.isEmpty ? 0 : 6)), height: Metrics.iconButton)
    }

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }
    override public func mouseEntered(with event: NSEvent) { hovering = true }
    override public func mouseExited(with event: NSEvent) { hovering = false }
    override public func viewDidMoveToWindow() { super.viewDidMoveToWindow(); hovering = false }

    override public func draw(_ dirtyRect: NSRect) {
        if hovering, isEnabled {
            NSColor.fillHover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: Metrics.radiusSM, yRadius: Metrics.radiusSM).fill()
        }
        super.draw(dirtyRect)
    }
}
