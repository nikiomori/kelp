import AppKit

/// A borderless button that answers the pointer as Kelp's controls do: under it a grey fill fades in (`fillHover`),
/// held it darkens (`fillSelected`), and a click dips and springs it back. For chips, badges, words and glyphs that act
/// (the branch chip, "+12 −3", Fetch, a tab's ✕); an icon alone is `IconButton`, which is one of these.
@MainActor
open class PointerButton: NSButton {
    private var area: NSTrackingArea?
    private var hovering = false { didSet { if hovering != oldValue { showFill() } } }
    private var pressed = false { didSet { if pressed != oldValue { showFill() } } }
    /// What a click does, in place of a target and action.
    public var onClick: (() -> Void)? { didSet { target = self; action = #selector(runClick) } }
    /// The fill's corner; nil: a capsule (half the height).
    public var radius: CGFloat? = Metrics.radiusSM { didSet { needsLayout = true } }
    /// Room left and right of the title or image, inside the fill.
    public var padding: CGFloat = 0 { didSet { invalidateIntrinsicContentSize() } }
    /// The fill it rests on (nil: none); hover and press go a step past it.
    public var restFill: NSColor? { didSet { showFill() } }
    /// A link (a port, "Open Source Control"): no fill; under the pointer its words are underlined, as links are.
    public var underlinesOnHover = false { didSet { showFill() } }

    override public init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        title = ""
        wantsLayer = true
        layer?.cornerCurve = .continuous
    }
    required public init?(coder: NSCoder) { fatalError() }

    /// A borderless button with `title` (or none) and `image` (or none), calling `action`.
    public convenience init(title: String = "", image: NSImage? = nil, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        self.image = image
        imagePosition = image == nil ? .noImage : title.isEmpty ? .imageOnly : .imageLeading
        onClick = action
        target = self   // a class's own initializer doesn't run its observers: onClick's didSet won't wire it here
        self.action = #selector(runClick)
    }

    @objc private func runClick() { onClick?() }

    /// The frame is the button: AppKit's alignment insets made it taller than its constraints (a 22 pt square drew its
    /// hover fill 22 × 26, the "+" of a sidebar row standing taller than the row's other marks).
    override open var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override open var intrinsicContentSize: NSSize {
        let s = super.intrinsicContentSize
        return NSSize(width: s.width + 2 * padding, height: s.height)
    }

    override open func layout() {
        super.layout()
        layer?.cornerRadius = radius ?? bounds.height / 2
    }

    override open func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }
    override open func mouseEntered(with event: NSEvent) { hovering = true }
    override open func mouseExited(with event: NSEvent) { hovering = false }
    override open func viewDidMoveToWindow() { super.viewDidMoveToWindow(); hovering = false; pressed = false }
    override open var isEnabled: Bool { didSet { showFill() } }

    /// AppKit says when the button is held down (and let go, or dragged off).
    override open func highlight(_ flag: Bool) {
        super.highlight(flag)
        pressed = flag
    }

    override open func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        pressBounce()
        return super.sendAction(action, to: target)
    }

    private func showFill() {
        guard !underlinesOnHover else {
            let words = NSMutableAttributedString(string: title, attributes: [.font: font ?? .ui(13), .foregroundColor: contentTintColor ?? .linkColor])
            if hovering && isEnabled {
                words.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: words.length))
            }
            attributedTitle = words
            return
        }
        // A step past what it rests on: a pill on the hover grey darkens under the pointer instead of staying as it was.
        let hover: NSColor = restFill == nil || restFill === NSColor.fillRest ? .fillHover : .fillSelected
        fadeBackground(to: !isEnabled ? restFill : pressed ? .fillSelected : hovering ? hover : restFill)
    }
    override open func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); showFill() }
}

/// A borderless pop-up (a panel's title words that pick what it lists): the hover grey fades in under the pointer, as a
/// `PointerButton`'s does; its menu answers the press.
@MainActor
open class PointerPopUpButton: NSPopUpButton {
    private var area: NSTrackingArea?
    private var hovering = false { didSet { if hovering != oldValue { fadeBackground(to: hovering && isEnabled ? .fillHover : nil) } } }

    override public init(frame: NSRect, pullsDown: Bool) {
        super.init(frame: frame, pullsDown: pullsDown)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = Metrics.radiusSM
        layer?.cornerCurve = .continuous
    }
    public convenience init() { self.init(frame: .zero, pullsDown: false) }
    required public init?(coder: NSCoder) { fatalError() }

    override open func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }
    override open func mouseEntered(with event: NSEvent) { hovering = true }
    override open func mouseExited(with event: NSEvent) { hovering = false }
    override open func viewDidMoveToWindow() { super.viewDidMoveToWindow(); hovering = false }
}

/// A custom clickable view (a pill, a capsule, a row drawn by hand) that answers the pointer like `PointerButton`:
/// `showPointer(hovering:pressed:)` fades a grey fill by default (override it for glass), and a click — down and up
/// inside — springs the view and calls `clicked()`, as a button fires on mouse-up.
@MainActor
open class PointerControl: NSControl {
    private var area: NSTrackingArea?
    public private(set) var hovering = false { didSet { if hovering != oldValue { refreshPointer() } } }
    public private(set) var pressed = false { didSet { if pressed != oldValue { refreshPointer() } } }
    /// The fill it rests on (nil: none); hover and press go a step past it.
    public var restFill: NSColor? { didSet { refreshPointer() } }

    override public init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
    }
    required public init?(coder: NSCoder) { fatalError() }

    /// What a click does.
    open func clicked() {}

    /// How it shows the pointer: a fill that fades, by default.
    open func showPointer(hovering: Bool, pressed: Bool) {
        fadeBackground(to: pressed ? .fillSelected : hovering ? .fillHover : restFill)
    }
    public func refreshPointer() { showPointer(hovering: hovering, pressed: pressed) }

    override open func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }
    override open func mouseEntered(with event: NSEvent) { hovering = true }
    override open func mouseExited(with event: NSEvent) { hovering = false }
    override open func viewDidMoveToWindow() { super.viewDidMoveToWindow(); hovering = false; pressed = false }
    override open func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshPointer() }
    override open var mouseDownCanMoveWindow: Bool { false }

    /// Held, it darkens; let go inside, it springs and acts; dragged off and let go, nothing happens.
    override open func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        while let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let inside = bounds.contains(convert(e.locationInWindow, from: nil))
            if e.type == .leftMouseDragged { pressed = inside; continue }
            pressed = false
            if inside {
                pressBounce()
                clicked()
            }
            return
        }
        pressed = false
    }

    override open func accessibilityPerformPress() -> Bool { clicked(); return true }
}
