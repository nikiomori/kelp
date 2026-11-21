import AppKit

/// A choice of a few words in one capsule: the chosen word sits on a white raised capsule that slides to a new choice,
/// as the sidebar's chosen row is drawn. The system's segmented control draws every style of it as a rounded rectangle
/// now, where Kelp's controls taken whole are capsules. Each segment is as wide as its word; more room is shared in
/// proportion. It answers the pointer, a press, the arrows (with Full Keyboard Access) and VoiceOver as a radio group,
/// and grows with Text size. `SwiftUI` takes it through `Segments`.
@MainActor
public final class CapsuleSegments: NSControl {
    private var words: [String]
    private var fields: [NSTextField] = []
    private var segmentOn: [Bool] = []
    private var tips: [String?] = []
    /// A number after a segment's word, on an orange capsule: what waits for the user there (marks to check).
    private var counts: [Int?] = []
    private var countFields: [NSTextField] = []
    private var countPlates: [NSView] = []
    private let thumb = NSView(), hover = NSView()
    private var hovered: Int?, pressed: Int?
    private var watching: [NSObjectProtocol] = []
    /// The pointer's area: the only one taken down and put back, so the tool tips' own areas stay.
    private var tracking: NSTrackingArea?
    /// The segments as VoiceOver knows them, made once per set of words, so its cursor stays on the one chosen.
    private var choices: [Choice] = []

    public init(labels: [String], target: AnyObject? = nil, action: Selector? = nil) {
        words = labels
        super.init(frame: .zero)
        self.target = target
        self.action = action
        wantsLayer = true
        for part in [hover, thumb] {
            part.wantsLayer = true
            addSubview(part)
        }
        rebuild()
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
    }
    public convenience init() { self.init(labels: []) }
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    // MARK: What it says

    /// The chosen segment, -1 for none. Setting it slides the plate; it sends no action.
    public var selectedSegment = -1 {
        didSet {
            guard selectedSegment != oldValue else { return }
            restyle()
            placeThumb(animated: window != nil && oldValue >= 0)
            NSAccessibility.post(element: self, notification: .valueChanged)
            NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
        }
    }
    public var segmentCount: Int {
        get { words.count }
        set {
            words = Array(words.prefix(newValue)) + Array(repeating: "", count: max(0, newValue - words.count))
            rebuild()
        }
    }
    public func setLabel(_ label: String, forSegment index: Int) {
        guard words.indices.contains(index), words[index] != label else { return }
        words[index] = label
        fields[index].stringValue = label
        choices[index].setAccessibilityLabel(label)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
    public func label(forSegment index: Int) -> String? { words.indices.contains(index) ? words[index] : nil }
    public func setEnabled(_ on: Bool, forSegment index: Int) {
        guard segmentOn.indices.contains(index) else { return }
        segmentOn[index] = on
        restyle()
    }
    public func isEnabled(forSegment index: Int) -> Bool { segmentOn.indices.contains(index) && segmentOn[index] }
    public func setToolTip(_ tip: String?, forSegment index: Int) {
        guard tips.indices.contains(index) else { return }
        tips[index] = tip
        needsLayout = true
    }
    /// Shows `count` after segment `index`'s word on an orange capsule, or nothing when it is nil.
    public func setCount(_ count: Int?, forSegment index: Int) {
        guard counts.indices.contains(index), counts[index] != count else { return }
        counts[index] = count
        countFields[index].stringValue = count.map { $0 > 99 ? "99+" : "\($0)" } ?? ""
        countPlates[index].isHidden = count == nil
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
    override public var isEnabled: Bool { didSet { restyle() } }
    override public var controlSize: NSControl.ControlSize {
        didSet {
            restyle()
            invalidateIntrinsicContentSize()
        }
    }

    private func rebuild() {
        fields.forEach { $0.removeFromSuperview() }
        fields = words.map { word in
            let field = NSTextField(labelWithString: word)
            field.alignment = .center
            field.lineBreakMode = .byTruncatingTail
            addSubview(field)
            return field
        }
        countPlates.forEach { $0.removeFromSuperview() }
        counts = Array(repeating: nil, count: words.count)
        countPlates = words.map { _ in
            let plate = NSView()
            plate.wantsLayer = true
            plate.isHidden = true
            plate.appearance = NSAppearance(named: .aqua)   // dark digits on the orange in both looks
            addSubview(plate)
            return plate
        }
        countFields = countPlates.map { plate in
            let count = NSTextField(labelWithString: "")
            count.font = .uiDigits(TextSize.micro, weight: .semibold)
            count.alignment = .center
            plate.addSubview(count)
            return count
        }
        segmentOn = Array(repeating: true, count: words.count)
        tips = Array(repeating: nil, count: words.count)
        choices = words.enumerated().map { Choice(index: $0, label: $1, of: self) }
        if selectedSegment >= words.count { selectedSegment = -1 }
        light(nil)
        restyle()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    // MARK: Size and places

    private var small: Bool { controlSize == .small || controlSize == .mini }
    private var wordFont: NSFont { .ui(small ? TextSize.caption : TextSize.body) }
    private var chosenFont: NSFont { .ui(small ? TextSize.caption : TextSize.body, weight: .medium) }
    private var height: CGFloat { TextSize.of(small ? Metrics.segment.height : Metrics.row) }
    /// A word's own width with room on both sides, measured in the weight it has when chosen, so choosing doesn't move it.
    private var wants: [CGFloat] {
        words.indices.map { i in
            ceil((words[i] as NSString).size(withAttributes: [.font: chosenFont]).width) + 2 * Metrics.gapWide + 2
                + (counts.indices.contains(i) && counts[i] != nil ? countSize(i).width + Metrics.gapTight : 0)
        }
    }
    /// The size of segment `index`'s count capsule.
    private func countSize(_ index: Int) -> NSSize {
        let height = TextSize.of(Metrics.countCapsule - Metrics.lineGap)
        let digits = ceil(countFields[index].attributedStringValue.size().width) + 2 * TextSize.of(Metrics.gapTight)
        return NSSize(width: max(height, digits), height: height)
    }
    override public var intrinsicContentSize: NSSize {
        NSSize(width: wants.reduce(0, +) + 2 * Metrics.lineGap, height: height)
    }
    /// Each segment's place: its word's width, with what room there is beyond (or short of) them shared in proportion.
    func segmentRects() -> [NSRect] {
        let wants = self.wants, total = wants.reduce(0, +)
        guard total > 0 else { return [] }
        let share = (bounds.width - 2 * Metrics.lineGap) / total
        var x = Metrics.lineGap
        return wants.map { want in
            defer { x += want * share }
            return NSRect(x: x, y: Metrics.lineGap, width: want * share, height: bounds.height - 2 * Metrics.lineGap)
        }
    }
    override public func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        let rects = segmentRects()
        removeAllToolTips()
        for (index, field) in fields.enumerated() where rects.indices.contains(index) {
            let size = field.fittingSize
            let badge = counts[index] == nil ? NSSize.zero : countSize(index)
            let room = badge.width > 0 ? badge.width + Metrics.gapTight : 0
            field.frame = NSRect(
                x: rects[index].minX + Metrics.gapWide / 2, y: rects[index].midY - size.height / 2,
                width: rects[index].width - Metrics.gapWide - room, height: size.height)
            if badge.width > 0 {
                countPlates[index].frame = NSRect(
                    x: field.frame.maxX + Metrics.gapTight, y: rects[index].midY - badge.height / 2, width: badge.width,
                    height: badge.height)
                countPlates[index].layer?.cornerRadius = badge.height / 2
                let digits = countFields[index].fittingSize
                countFields[index].frame = NSRect(
                    x: 0, y: (badge.height - digits.height) / 2, width: badge.width, height: digits.height)
            }
            if let tip = tips[index] { addToolTip(rects[index], owner: tip as NSString, userData: nil) }
            choices[index].setAccessibilityFrameInParentSpace(rects[index])
        }
        placeThumb(animated: false)
        if let hovered, rects.indices.contains(hovered) { hover.frame = rects[hovered] }
    }
    private func placeThumb(animated: Bool) {
        let rects = segmentRects()
        thumb.isHidden = !rects.indices.contains(selectedSegment)
        guard rects.indices.contains(selectedSegment) else { return }
        let target = rects[selectedSegment]
        thumb.layer?.cornerRadius = target.height / 2
        hover.layer?.cornerRadius = target.height / 2
        guard animated, !Motion.reduced else { return thumb.frame = target }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.base
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            thumb.animator().frame = target
        }
    }

    // MARK: Look

    private func restyle() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
            key = window?.isKeyWindow ?? true, contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.fillHover.cgColor
            guard let plate = thumb.layer else { return }
            // As the sidebar's chosen row: white and lifted by a hairline shadow in light, lighter than the track in
            // dark; quieter while another window is in front.
            plate.backgroundColor = NSColor.white.withAlphaComponent(dark ? (key ? 0.2 : 0.1) : (key ? 1 : 0.6)).cgColor
            plate.shadowOpacity = !dark && key ? 1 : 0
            plate.shadowColor = NSColor.black.withAlphaComponent(0.18).cgColor
            plate.shadowRadius = 1
            plate.shadowOffset = CGSize(width: 0, height: -0.5)
            plate.borderWidth = contrast ? 1 : 0
            plate.borderColor = (dark ? NSColor.white : .black).withAlphaComponent(dark ? 0.35 : 0.25).cgColor
        }
        for plate in countPlates { plate.layer?.backgroundColor = NSColor.systemOrange.cgColor }
        for count in countFields { count.textColor = .labelColor }
        for (index, field) in fields.enumerated() {
            let chosen = index == selectedSegment, on = isEnabled && segmentOn[index]
            field.font = chosen ? chosenFont : wordFont
            field.textColor = !on ? .tertiaryLabelColor : chosen ? .labelColor : .secondaryLabelColor
            choices[index].setAccessibilityValue(chosen ? 1 : 0)
            choices[index].setAccessibilityEnabled(on)
        }
    }
    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }
    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        watching.forEach(NotificationCenter.default.removeObserver)
        watching = []
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            // Delivered on the main thread: the window posts it there.
            watching.append(
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.restyle() }   // queue .main: the observer runs there
                })
        }
        restyle()
        placeThumb(animated: false)
    }

    // MARK: Pointer

    private func segment(at point: NSPoint) -> Int? {
        segmentRects().firstIndex { $0.contains(point) }.flatMap { isEnabled && segmentOn[$0] ? $0 : nil }
    }
    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override public func mouseMoved(with event: NSEvent) {
        light(segment(at: convert(event.locationInWindow, from: nil)))
    }
    override public func mouseExited(with event: NSEvent) { light(nil) }
    /// Greys in the segment under the pointer (not the chosen one, which has its plate) and fades it out after.
    private func light(_ index: Int?) {
        let index = index == selectedSegment ? nil : index
        guard index != hovered else { return }
        hovered = index
        if let index, segmentRects().indices.contains(index) {
            hover.layer?.backgroundColor = nil
            hover.frame = segmentRects()[index]
            hover.fadeBackground(to: .fillHover)
        } else {
            hover.fadeBackground(to: nil)
        }
    }
    override public func mouseDown(with event: NSEvent) {
        guard let index = segment(at: convert(event.locationInWindow, from: nil)) else { return }
        pressed = index
        if index != selectedSegment {
            hovered = index
            hover.frame = segmentRects()[index]
            hover.fadeBackground(to: .fillSelected, held: true)
        }
    }
    override public func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        guard let pressed else { return }
        let index = segment(at: convert(event.locationInWindow, from: nil))
        light(nil)
        if index == pressed { choose(pressed) }
    }
    /// Picks `index` as a person did: the plate slides there and the action goes.
    func choose(_ index: Int) {
        guard index != selectedSegment, segmentOn.indices.contains(index), segmentOn[index], isEnabled else { return }
        selectedSegment = index
        sendAction(action, to: target)
    }

    // MARK: Keys

    override public var acceptsFirstResponder: Bool { isEnabled && NSApp.isFullKeyboardAccessEnabled }
    override public var focusRingMaskBounds: NSRect { bounds }
    override public func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
    override public func keyDown(with event: NSEvent) {
        let step: Int? =
            switch event.specialKey {
            case .leftArrow?: -1
            case .rightArrow?: 1
            default: nil
            }
        guard let step else { return super.keyDown(with: event) }
        var index = selectedSegment + step
        while segmentOn.indices.contains(index), !segmentOn[index] { index += step }
        if segmentOn.indices.contains(index) { choose(index) }
    }

    // MARK: VoiceOver

    override public func accessibilityValue() -> Any? { label(forSegment: selectedSegment) }
    override public func accessibilityChildren() -> [Any]? { choices }
    override public func accessibilitySelectedChildren() -> [Any]? {
        choices.indices.contains(selectedSegment) ? [choices[selectedSegment]] : []
    }
    /// One segment to VoiceOver: a radio button whose press chooses it.
    private final class Choice: NSAccessibilityElement {
        let index: Int
        weak var control: CapsuleSegments?
        init(index: Int, label: String, of control: CapsuleSegments) {
            self.index = index
            self.control = control
            super.init()
            setAccessibilityRole(.radioButton)
            setAccessibilityLabel(label)
            setAccessibilityParent(control)
        }
        override func accessibilityPerformPress() -> Bool {
            let control = self.control, index = self.index
            MainActor.assumeIsolated { control?.choose(index) }   // VoiceOver asks on the main thread
            return true
        }
    }
}
