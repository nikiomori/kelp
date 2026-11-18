import AppKit
import Core
import DesignKit

/// One tab in a strip. It is an NSControl, not a plain view, because under a transparent title bar the window server
/// moves the window on a drag over anything but controls, whatever `mouseDownCanMoveWindow` says, so a dragged tab
/// would take the window with it.
@MainActor
final class TabButton: NSControl, NSDraggingSource {
    weak var strip: TabStrip?
    private(set) var item: TabStrip.Item?
    private(set) var selected = false
    var groupFocused = false { didSet { if groupFocused != oldValue { updateLook() } } }
    var stripDimmed = false { didSet { if stripDimmed != oldValue { updateLook() } } }
    /// The row of the tab's parts, which fades in a dimmed strip; the fill and the glow stay as they are.
    private weak var content: NSView?
    private let icon = NSImageView(), title = NSTextField(labelWithString: ""), close = PointerButton(frame: .zero),
        editedDot = NSImageView()
    /// The close button's tooltip. The strip sets it, with Close Tab's key as it stands.
    var closeTip: String? {
        get { close.toolTip }
        set { close.toolTip = newValue }
    }
    private let mark = StatusMark(size: 12)
    private let meter = ContextMeter()
    /// How full the context is, shown next to the ring once the ring is red. Before that the ring and its tooltip say
    /// it, and the strip stays quiet.
    private let full = NSTextField(labelWithString: "")
    /// What runs beside the tab's agent, whatever it's doing (a dev server), with the names in the tooltip.
    private let chip = Chip()
    private let edgeGlow = EdgeGlow(radius: Metrics.radiusSM, spread: 3, strength: 0.5)
    private var hover = false {
        didSet {
            if hover != oldValue { slot.crossfade() }   // the close button takes the icon's place in a fade, as a row's "+" comes in
            updateLook()
        }
    }
    private let slot = NSView()
    private var shownSlot: (edited: Bool, state: Bool)?
    private let row = NSStackView()
    /// The title keeps about twelve letters however many tabs there are (six when compact); the tabs that don't fit
    /// scroll and are in the ▾ menu.
    private lazy var titleMin = title.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
    private lazy var tall = heightAnchor.constraint(equalToConstant: 28)
    /// Settings › Appearance › Tab height: Compact.
    var low = false { didSet { tall.constant = low ? 24 : 28 } }
    private lazy var widest = widthAnchor.constraint(lessThanOrEqualToConstant: 300)
    private lazy var narrowest = widthAnchor.constraint(greaterThanOrEqualToConstant: 76)
    private lazy var comfortable = widthAnchor.constraint(greaterThanOrEqualToConstant: 110)
    /// Settings › Appearance › Tab width, compact: tabs of 60–160 pt with tighter insets that keep six letters; the
    /// marks and meter stay.
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
        title.font = .ui(TextSize.row)
        title.lineBreakMode = .byTruncatingTail
        close.image = .symbol("xmark", String(localized: "Close Tab"))
        close.toolTip = String(localized: "Close Tab")
        close.isBordered = false
        close.symbolConfiguration = .chrome(Metrics.iconTiny)
        close.wantsLayer = true
        close.contentTintColor = .secondaryLabelColor
        close.imagePosition = .imageOnly
        close.radius = nil   // a round 16 pt fill (the slot's size) under the pointer
        close.target = self
        close.action = #selector(closeTapped)
        // Unsaved changes: a dot where the close button goes (as in TextEdit's tabs); hovering shows the close button.
        editedDot.image = .symbol("circle.fill", String(localized: "Edited"))
        editedDot.symbolConfiguration = .chrome(Metrics.iconTiny)
        editedDot.contentTintColor = .labelColor
        // One slot at the start shows the agent's state while there is something to see, otherwise the tab's icon,
        // and on hover the close button.
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
        full.font = .uiDigits(TextSize.micro, weight: .semibold)
        for part in [slot, title, chip, meter, full] as [NSView] { row.addArrangedSubview(part) }
        applyWidth()
        pin(row)
        content = row
        pin(edgeGlow)   // over the row, as the pane's ring is over its content; clicks go through it
        NSLayoutConstraint.activate([
            tall, widest, narrowest,
            slot.widthAnchor.constraint(equalToConstant: 16), slot.heightAnchor.constraint(equalToConstant: 16)
        ])
        // The title's priority is below the strip's `fit` (245), so a squeezed tab truncates its title with "…" (the
        // row never clips it). The comfortable width sits lower still, so a short title gives up its spare room before
        // a long one loses letters.
        title.setContentCompressionResistancePriority(.init(240), for: .horizontal)
        comfortable.priority = .init(239)
        comfortable.isActive = true
        titleMin.priority = .init(999)   // over `fit`, so a tab at its minimum widens the strip, which scrolls
        titleMin.isActive = true
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        // VoiceOver hears a tab like NSTabView's (radio button, tab subrole). The close button only exists on hover, so
        // it is an action.
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

    /// Shows item `it`, and returns true when the tab's width may have changed (then the strip measures again).
    @discardableResult func set(_ it: TabStrip.Item, selected: Bool, groupFocused: Bool) -> Bool {
        let before = sizeKey
        item = it
        self.selected = selected
        self.groupFocused = groupFocused
        title.stringValue = it.title
        title.lineBreakMode = it.keepsEnd ? .byTruncatingMiddle : .byTruncatingTail
        if icon.image !== it.icon { icon.image = it.icon }
        mark.status = it.badge?.status
        mark.unread = it.badge?.unread ?? false
        mark.progress = it.badge?.progress
        mark.waitsForCommand = it.badge?.waitsFor ?? false
        meter.usage = it.badge?.meter
        let level = ContextMeter.level(it.badge?.meter)
        full.isHidden = level < 3
        full.stringValue = it.badge?.meter.map { "\(Int(Double($0.used) / Double(max($0.window, 1)) * 100))%" } ?? ""
        full.textColor = .textRed
        chip.isHidden = (it.badge?.background ?? 0) == 0
        chip.show("terminal", count: it.badge?.background ?? 0)
        chip.toolTip = it.card == nil ? it.badge?.backgroundTip : nil   // the card lists them
        chip.setAccessibilityLabel(it.badge?.backgroundTip)
        toolTip = it.card == nil ? it.toolTip ?? it.title : nil   // not both at once
        // VoiceOver hears the agent's state too ("Claude Code, Needs your input"), because on screen the state replaces
        // the icon.
        setAccessibilityLabel((it.badge?.status).map { "\(it.title), \($0.words)" } ?? it.title)
        setAccessibilityValue(selected)
        updateLook()
        return sizeKey != before
    }

    /// What the tab's width comes from: its title and weight, and which of chip, meter and percentage show.
    private var sizeKey: SizeKey {
        SizeKey(
            title: title.stringValue, font: title.font, chip: chip.isHidden ? 0 : item?.badge?.background ?? 0,
            meter: meter.isHidden, full: full.isHidden ? "" : full.stringValue)
    }
    private struct SizeKey: Equatable {
        let title: String, font: NSFont?, chip: Int, meter: Bool, full: String
    }

    /// Whether the slot shows the agent's state: working, asking, failed, or finished and not looked at. Then the state
    /// says more than the agent's icon.
    private var showsState: Bool {
        guard let status = item?.badge?.status else { return false }
        return [.working, .waiting, .error].contains(status) || (status == .done && item?.badge?.unread == true)
    }

    /// Whether the tab has something for you, so it stays bright when its pane fades.
    private var news: Bool { showsState && item?.badge?.status != .working }

    /// The title's colour when the agent asks, or failed and wasn't looked at. The tab also glows (`glow`), so the pane
    /// that calls for you stands out across the window, not only by its 12 pt mark.
    private var callText: NSColor? {
        switch item?.badge?.status {
        case .waiting?: .textOrange
        case .error? where item?.badge?.unread == true: .textRed
        default: nil
        }
    }

    func updateLook() {
        let edited = item?.edited == true
        // The icon, the edited dot and the agent's mark take each other's place in a fade, as the close button does.
        let shows = (edited, showsState)
        if let was = shownSlot, was != shows, window != nil { slot.crossfade() }
        shownSlot = shows
        close.isHidden = !hover
        editedDot.isHidden = hover || !edited
        icon.isHidden = hover || edited || showsState
        mark.alphaValue = hover || edited || !showsState ? 0 : 1   // StatusMark hides itself when there's no state
        let active = selected && groupFocused, call = callText
        title.textColor = call ?? (selected ? .labelColor : .secondaryLabelColor)
        // A tab finished and not looked at is marked by the weight of its title alone, as unread mail is.
        title.font = .ui(TextSize.row, weight: doneUnread ? .semibold : active || call != nil ? .medium : .regular)
        titleMin.constant = Self.minTitle(
            title.stringValue, font: title.font ?? .ui(TextSize.row), letters: compact ? 6 : 12)
        icon.contentTintColor = active ? .themeAccent : .secondaryLabelColor
        // The window has one plate, on the tab you're in; another pane's chosen tab stands out by its brighter title.
        let fill = active ? NSColor.fillSelected : hover ? .fillHover : nil
        fadeBackground(to: fill)   // the state's colour is in the glow and the title, not a fill under them
        // With Increase Contrast the capsule gets an edge, as the system's controls do; its state is in the mark's
        // shape already.
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

    /// The tab glows the way its pane does (GroupView's ring): orange and breathing while its agent asks, red when it
    /// failed unseen, and a faint glow in the text's colour when it finished unseen. A glow plus its edge line make it
    /// read as part of the pane.
    private var glow: NSColor? {
        switch item?.badge?.status {
        case .waiting?: .systemOrange
        case .error? where item?.badge?.unread == true: .systemRed
        case .done? where item?.badge?.unread == true: .labelColor
        default: item?.run
        }
    }
    /// Shows light along the inside of the capsule, like the pane's ring at a tab's size. Nothing outside the capsule
    /// is tinted, and the selected fill under the light stays as it is.
    private func showGlow() {
        edgeGlow.show(glow, breathing: item?.badge?.status == .waiting, faint: item?.badge?.status == .done)
    }

    private var doneUnread: Bool { item?.badge?.status == .done && item?.badge?.unread == true }

    private func applyWidth() {
        widest.constant = compact ? 160 : 300
        narrowest.constant = compact ? 60 : 76
        comfortable.constant = compact ? 60 : 110
        row.spacing = compact ? 4 : 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: compact ? 6 : 8, bottom: 0, right: compact ? 8 : 10)
    }

    /// How narrow the tab gets at the regular width. Automatic turns the strip compact once tabs this narrow no longer
    /// fit.
    var regularMinimum: CGFloat {
        let others = [chip, meter, full].filter { !$0.isHidden }.reduce(0) { $0 + $1.fittingSize.width + 6 }
        let text = Self.minTitle(title.stringValue, font: title.font ?? .ui(TextSize.row), letters: 12)
        return max(76, 8 + 16 + 6 + text + others + 10)
    }

    /// Returns the width of up to `letters` letters of `text` (all of a shorter text), so many tabs don't leave four
    /// letters of each.
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
        // A peeking sidebar or inspector lies over the tabs in the same window, and the tab's tracking area still
        // fires. The tab's card would then hang off that panel's row, and its Continue would type into this tab's
        // agent.
        guard window?.contentView?.hitTest(event.locationInWindow)?.isDescendant(of: self) == true else { return }
        hover = true
        if let key = item?.card { strip?.hoverCard?.hover(key, rect: bounds, in: self) }
    }
    override func mouseExited(with event: NSEvent) {
        hover = false
        if item?.card != nil { strip?.hoverCard?.hover(nil, rect: .zero, in: self) }
    }
    /// Updates the hover after the tab moved under, or out from under, a pointer that stayed still, because AppKit only
    /// notices when the pointer next moves.
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
