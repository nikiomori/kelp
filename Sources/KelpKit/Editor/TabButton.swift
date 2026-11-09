import AppKit
import Core
import DesignKit

/// An NSControl, not a plain view: under a transparent title bar the window server moves the window on a drag over
/// anything but controls, whatever `mouseDownCanMoveWindow` says, so a dragged tab would take the window with it.
@MainActor
final class TabButton: NSControl, NSDraggingSource {
    weak var strip: TabStrip?
    private var item: TabStrip.Item?
    private var selected = false
    var groupFocused = false { didSet { if groupFocused != oldValue { updateLook() } } }
    var stripDimmed = false { didSet { if stripDimmed != oldValue { updateLook() } } }
    /// The row of what it shows, which fades in a dimmed strip; the fill and the glow stay as they are.
    private weak var content: NSView?
    private let icon = NSImageView(), title = NSTextField(labelWithString: ""), close = PointerButton(frame: .zero),
        editedDot = NSImageView()
    private let mark = StatusMark(size: 12)
    private let meter = ContextMeter()
    /// Next to the ring once it's red: how full. Before that the ring and its tooltip say it, the strip stays quiet.
    private let full = NSTextField(labelWithString: "")
    /// What runs beside its agent, whatever it's doing (a dev server): by name in the tooltip.
    private let chip = Chip()
    private let edgeGlow = EdgeGlow(radius: Metrics.radiusSM, spread: 3, strength: 0.5)
    private var hover = false {
        didSet {
            if hover != oldValue { slot.crossfade() }   // the close button takes the icon's place in a fade, as a row's "+" comes in
            updateLook()
        }
    }
    private let slot = NSView()
    private let row = NSStackView()
    /// The title keeps about twelve letters however many tabs there are (six when compact); the rest scroll and are in
    /// the ▾ menu.
    private lazy var titleMin = title.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
    private lazy var tall = heightAnchor.constraint(equalToConstant: 28)
    /// Settings › Appearance › Tab height: Compact.
    var low = false { didSet { tall.constant = low ? 24 : 28 } }
    private lazy var widest = widthAnchor.constraint(lessThanOrEqualToConstant: 300)
    private lazy var narrowest = widthAnchor.constraint(greaterThanOrEqualToConstant: 76)
    private lazy var comfortable = widthAnchor.constraint(greaterThanOrEqualToConstant: 110)
    /// Settings › Appearance › Tab width: 60–160 pt, tighter insets, six letters kept; its marks and meter stay.
    var compact = false {
        didSet {
            guard compact != oldValue else { return }
            applyWidth()
            updateLook()
        }
    }

    /// Like Safari and Xcode: the close button takes the icon's place on hover; the selected tab is a quiet fill.
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Metrics.radiusSM
        icon.symbolConfiguration = .chrome(Metrics.iconSmall)
        title.font = .ui(12)
        title.lineBreakMode = .byTruncatingTail
        close.image = .symbol("xmark", String(localized: "Close Tab"))
        close.toolTip = String(localized: "Close Tab (⌘W)")
        close.isBordered = false
        close.symbolConfiguration = .chrome(Metrics.iconTiny)
        close.wantsLayer = true
        close.contentTintColor = .secondaryLabelColor
        close.imagePosition = .imageOnly
        close.radius = nil   // a round fill under the pointer, the slot's 16 pt
        close.target = self
        close.action = #selector(closeTapped)
        // Unsaved changes: a dot where the close button goes (as in TextEdit's tabs); hovering shows the close button.
        editedDot.image = .symbol("circle.fill", String(localized: "Edited"))
        editedDot.symbolConfiguration = .chrome(Metrics.iconTiny)
        editedDot.contentTintColor = .labelColor
        // One slot at the start: the agent's state while there's something to see, else the tab's icon; the close button on hover.
        for part in [icon, mark, close, editedDot] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            slot.addSubview(part)
            NSLayoutConstraint.activate([
                part.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
                part.centerYAnchor.constraint(equalTo: slot.centerYAnchor)
            ])
        }
        NSLayoutConstraint.activate([
            close.widthAnchor.constraint(equalToConstant: 16), close.heightAnchor.constraint(equalToConstant: 16)
        ])
        full.font = .uiDigits(10, weight: .semibold)
        for part in [slot, title, chip, meter, full] as [NSView] { row.addArrangedSubview(part) }
        applyWidth()
        pin(row)
        content = row
        pin(edgeGlow)   // over the row, as the pane's ring is over its content; clicks go through it
        NSLayoutConstraint.activate([
            tall, widest, narrowest,
            slot.widthAnchor.constraint(equalToConstant: 16), slot.heightAnchor.constraint(equalToConstant: 16)
        ])
        // Below the strip's `fit` (245): a squeezed tab truncates its title with "…" (the row never clips it). Under that
        // again its comfortable width: a short title gives up its air before a long one loses letters.
        title.setContentCompressionResistancePriority(.init(240), for: .horizontal)
        comfortable.priority = .init(239)
        comfortable.isActive = true
        titleMin.priority = .init(999)   // over the strip's `fit`: a tab at it widens the strip, which scrolls
        titleMin.isActive = true
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        // VoiceOver: a tab like NSTabView's (radio button, tab subrole); the close button only exists on hover, so it's an action.
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilitySubrole(.init(rawValue: "AXTabButton"))   // kAXTabButtonSubrole
        title.setAccessibilityElement(false)
        icon.setAccessibilityElement(false)
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: String(localized: "Close Tab")) { [weak self] in
                MainActor.assumeIsolated { self?.closeTapped() }
                return true   // accessibility actions come on main
            }
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ it: TabStrip.Item, selected: Bool, groupFocused: Bool) {
        item = it
        self.selected = selected
        self.groupFocused = groupFocused
        title.stringValue = it.title
        title.lineBreakMode = it.keepsEnd ? .byTruncatingMiddle : .byTruncatingTail
        if icon.image !== it.icon { icon.image = it.icon }
        mark.status = it.status
        mark.unread = it.unread
        mark.progress = it.progress
        mark.waitsForCommand = it.waitsFor
        meter.usage = it.meter
        let level = ContextMeter.level(it.meter)
        full.isHidden = level < 3
        full.stringValue = it.meter.map { "\(Int(Double($0.used) / Double(max($0.window, 1)) * 100))%" } ?? ""
        full.textColor = .textRed
        chip.isHidden = it.background == 0
        chip.show("apple.terminal", count: it.background)
        chip.toolTip = it.card == nil ? it.backgroundTip : nil   // the card lists them
        chip.setAccessibilityLabel(it.backgroundTip)
        toolTip = it.card == nil ? it.toolTip ?? it.title : nil   // not both at once
        // VoiceOver hears the agent's state too ("Claude Code, Needs your input"): on screen it replaces the icon.
        setAccessibilityLabel(it.status.map { "\(it.title), \($0.words)" } ?? it.title)
        setAccessibilityValue(selected)
        updateLook()
    }

    /// Working, asking, failed, or finished and not looked at: the state says more than the agent's icon.
    private var showsState: Bool {
        guard let status = item?.status else { return false }
        return [.working, .waiting, .error].contains(status) || (status == .done && item?.unread == true)
    }

    /// There's something here for you: it stays bright when its pane fades.
    private var news: Bool { showsState && item?.status != .working }

    /// It asks, or it failed and wasn't looked at: its title takes the colour (and the tab glows, `glow`), so the pane
    /// that calls for you reads across the window, not only by its 12 pt mark.
    private var callText: NSColor? {
        switch item?.status {
        case .waiting?: .textOrange
        case .error? where item?.unread == true: .textRed
        default: nil
        }
    }

    func updateLook() {
        let edited = item?.edited == true
        close.isHidden = !hover
        editedDot.isHidden = hover || !edited
        icon.isHidden = hover || edited || showsState
        mark.alphaValue = hover || edited || !showsState ? 0 : 1   // StatusMark hides itself when there's no state
        let active = selected && groupFocused, call = callText
        title.textColor = call ?? (selected ? .labelColor : .secondaryLabelColor)
        // Finished and not looked at: told by its title's weight alone, as unread mail is.
        title.font = .ui(12, weight: doneUnread ? .semibold : active || call != nil ? .medium : .regular)
        titleMin.constant = Self.minTitle(title.stringValue, font: title.font ?? .ui(12), letters: compact ? 6 : 12)
        icon.contentTintColor = active ? .themeAccent : .secondaryLabelColor
        // One plate in the window, on the tab you're in; a pane's chosen tab elsewhere is told by its brighter title.
        let fill = active ? NSColor.fillSelected : hover ? .fillHover : nil
        fadeBackground(to: fill)   // the state's colour is in the glow and the title, not a fill under them
        // Increase Contrast: the capsule gets an edge, as the system's controls do; its state is in the mark's shape already.
        layer?.borderWidth = NSColor.increaseContrast ? 1 : 0
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.borderColor = NSColor.separatorColor.cgColor }
        fadeContent(to: stripDimmed && !hover && !news ? Metrics.tabDim : 1)
        showGlow()
    }

    private func fadeContent(to alpha: CGFloat) {
        guard let content, content.alphaValue != alpha else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.duration(Motion.fast)
            content.animator().alphaValue = alpha
        }
    }

    /// The tab glows as its pane does (GroupView's ring): orange and breathing while its agent asks, red when it failed
    /// unseen, a faint glow in the text's colour when it finished unseen. A glow and its edge line: it reads as the pane's.
    private var glow: NSColor? {
        switch item?.status {
        case .waiting?: .systemOrange
        case .error? where item?.unread == true: .systemRed
        case .done? where item?.unread == true: .labelColor
        default: item?.run
        }
    }
    /// Light along the inside of the capsule, the pane's anatomy at a tab's size: nothing outside it is tinted, and the
    /// selected fill under it stays as it is.
    private func showGlow() {
        edgeGlow.show(glow, breathing: item?.status == .waiting, faint: item?.status == .done)
    }

    private var doneUnread: Bool { item?.status == .done && item?.unread == true }

    private func applyWidth() {
        widest.constant = compact ? 160 : 300
        narrowest.constant = compact ? 60 : 76
        comfortable.constant = compact ? 60 : 110
        row.spacing = compact ? 4 : 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: compact ? 6 : 8, bottom: 0, right: compact ? 8 : 10)
    }

    /// How narrow it gets at the regular width: Automatic turns the strip compact once these no longer fit.
    var regularMinimum: CGFloat {
        let others = [chip, meter, full].filter { !$0.isHidden }.reduce(0) { $0 + $1.fittingSize.width + 6 }
        let text = Self.minTitle(title.stringValue, font: title.font ?? .ui(12), letters: 12)
        return max(76, 8 + 16 + 6 + text + others + 10)
    }

    /// Up to `letters` letters of `text` (all of a shorter one), so many tabs don't leave four letters of each.
    static func minTitle(_ text: String, font: NSFont, letters: Int = 12) -> CGFloat {
        let most = NSAttributedString(string: String(repeating: "n", count: letters), attributes: [.font: font]).size()
            .width
        return ceil(min(most, NSAttributedString(string: text, attributes: [.font: font]).size().width))
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLook()
    }
    /// The whole tab takes the click, label and icon included: in the title bar they would move the window instead.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit.isDescendant(of: close) ? hit : self
    }
    override var mouseDownCanMoveWindow: Bool { false }
    /// A capsule on macOS 26+, like the system's own controls there (search fields, buttons, Safari's tabs).
    override func layout() {
        super.layout()
        if #available(macOS 26, *) { layer?.cornerRadius = bounds.height / 2 }
        edgeGlow.radius = layer?.cornerRadius ?? Metrics.radiusSM   // the glow follows the capsule
    }
    override func mouseEntered(with event: NSEvent) {
        hover = true
        if let key = item?.card { strip?.hoverCard?.hover(key, rect: bounds, in: self) }
    }
    override func mouseExited(with event: NSEvent) {
        hover = false
        if item?.card != nil { strip?.hoverCard?.hover(nil, rect: .zero, in: self) }
    }
    /// Moved under or from under a pointer that stayed still: AppKit says so only when it next moves.
    func followPointer() {
        guard let window else { return }
        hover = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
    override func mouseDown(with event: NSEvent) {
        strip?.hoverCard?.close()
        if let id = item?.id { strip?.onSelect?(id) }
    }
    override func mouseUp(with event: NSEvent) { pressBounce() }   // a click springs as every control's does; a drag never comes here
    override func accessibilityPerformPress() -> Bool {
        if let id = item?.id { strip?.onSelect?(id) }
        return true
    }
    override func otherMouseUp(with event: NSEvent) { closeTapped() }
    override func menu(for event: NSEvent) -> NSMenu? {
        strip?.hoverCard?.close()
        return item.flatMap { strip?.onMenu?($0.id) }
    }
    @objc private func closeTapped() { if let id = item?.id { strip?.onClose?(id) } }

    override func mouseDragged(with event: NSEvent) {
        guard let id = item?.id else { return }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(id, forType: .kelpTab)
        let dragItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        dragItem.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }
    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
        -> NSDragOperation
    { .move }
}
