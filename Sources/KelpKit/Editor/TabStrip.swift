import AppKit
import Core
import DesignKit

extension NSPasteboard.PasteboardType { static let kelpTab = NSPasteboard.PasteboardType("dev.kelp.tab") }

/// A group's tab strip: icon, title, agent status, close on hover; drag to reorder, move to another group, or split.
/// The top panes' strips make the window's second row, under the window bar, level with the sidebar's search and the
/// inspector's panel icons.
@MainActor
final class TabStrip: NSView {
    /// Room around the tabs: they don't run into the strip's edges or the pane dividers.
    static let height: CGFloat = 40
    struct Item: Equatable {
        let id: String
        var title: String
        var icon: NSImage?
        let status: AgentStatus?
        var unread = false
        let toolTip: String?
        var edited = false
        var meter: SessionContextWindow.Usage?
        var progress: Double?
        var background = 0
        var backgroundTip: String?
        var waitsFor = false
        /// A run's colour (the Run menu's): its tab glows so, steady, below any call for attention.
        var run: NSColor?
    }

    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onMenu: ((String) -> NSMenu?)?
    var onDropTab: ((String, Int) -> Void)?        // tab id, index in this strip
    var addMenu: (() -> NSMenu)?
    var onNewAgent: (() -> Void)?
    var onUnzoom: (() -> Void)?
    /// This group fills the editor area (⇧⌘↩); the button says so and brings the other panes back.
    var zoomed = false { didSet { unzoom.isHidden = !zoomed; measured = nil } }
    private let unzoom = PointerButton(frame: .zero)
    var focused = false { didSet { if focused != oldValue { buttons.forEach { $0.groupFocused = focused } } } }
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private lazy var edgeMask: CAGradientLayer = {
        let g = CAGradientLayer()
        g.startPoint = CGPoint(x: 0, y: 0.5); g.endPoint = CGPoint(x: 1, y: 0.5)
        return g
    }()
    private let overflow = PointerButton(frame: .zero)
    private let add = CapsuleSegment()
    /// The default agent, one click away beside "+" (no list to pick from); the two share one capsule.
    private let newAgent = CapsuleSegment()
    private let adds = CapsuleStack()
    private var items: [Item] = []
    private var selectedId: String?
    private var buttons: [TabButton] = []
    private let insertion = NSView()
    /// "+" follows the last tab (set in layout); with the strip full, it stays at the right end.
    private var addLead: NSLayoutConstraint?
    private var laidOutWidth: CGFloat = 0
    /// How wide the tabs and the buttons beside them want to be: the same at any width of the strip, and asking takes a
    /// layout pass, for each step of a panel sliding by.
    private var measured: (tabs: CGFloat, others: CGFloat)?
    private var revealing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel(String(localized: "Tabs"))
        stack.orientation = .horizontal
        stack.spacing = 1
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 6)
        insertion.wantsLayer = true
        insertion.layer?.backgroundColor = NSColor.themeAccent.cgColor
        insertion.isHidden = true
        // Too many tabs to fit: the strip scrolls (trackpad / wheel) and the chevron lists them all, like Safari.
        overflow.image = .symbol("chevron.down", String(localized: "All Tabs"))
        overflow.isBordered = false
        overflow.contentTintColor = .secondaryLabelColor
        overflow.symbolConfiguration = .init(pointSize: 10, weight: .semibold); overflow.toolTip = String(localized: "All tabs in this group")
        overflow.target = self
        overflow.action = #selector(overflowTapped)
        overflow.isHidden = true
        unzoom.image = .symbol("arrow.down.right.and.arrow.up.left", String(localized: "Show All Panes")); unzoom.isBordered = false
        unzoom.contentTintColor = .themeAccent; unzoom.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        unzoom.toolTip = String(localized: "Show all panes (⇧⌘↩)")
        unzoom.target = self
        unzoom.action = #selector(unzoomTapped)
        unzoom.isHidden = true
        // The one way to add a tab, in each pane (like Safari's "+"); the empty workspace offers the same choices.
        add.image = .symbol("plus", String(localized: "New Tab")); add.contentTintColor = .secondaryLabelColor
        add.symbolConfiguration = .init(pointSize: 12, weight: .medium); add.toolTip = String(localized: "New tab: an agent (⌥⌘T), a terminal (⌘T), a browser…")
        add.target = self; add.action = #selector(addTapped)
        newAgent.imageScaling = .scaleNone
        newAgent.target = self
        newAgent.action = #selector(newAgentTapped)
        newAgent.isHidden = true
        adds.setViews([newAgent, add], in: .leading)
        adds.spacing = 0
        adds.detachesHiddenViews = true
        adds.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        let trailing = NSStackView(views: [unzoom, overflow])
        trailing.spacing = 6
        trailing.detachesHiddenViews = true
        scroll.documentView = stack
        scroll.wantsLayer = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(stripScrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed; scroll.verticalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        let sep = NSBox(); sep.boxType = .separator
        for v in [scroll, adds, trailing, sep] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        addSubview(insertion)
        // Below the split view's holding (250), like `fit`: measured before the overflow button shows, it asked for 18 pt
        // more than the strip had, and the window widened to give them; now "+" gives way instead.
        let lead = adds.leadingAnchor.constraint(equalTo: leadingAnchor)
        lead.priority = .init(249)
        addLead = lead
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            scroll.trailingAnchor.constraint(equalTo: adds.leadingAnchor), lead,
            adds.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -2),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), stack.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor), adds.centerYAnchor.constraint(equalTo: centerYAnchor),
            overflow.widthAnchor.constraint(equalToConstant: 18), add.widthAnchor.constraint(equalToConstant: 24),
            add.heightAnchor.constraint(equalToConstant: 24),
            newAgent.widthAnchor.constraint(equalToConstant: 24), newAgent.heightAnchor.constraint(equalToConstant: 24),
            sep.leadingAnchor.constraint(equalTo: leadingAnchor), sep.trailingAnchor.constraint(equalTo: trailingAnchor),
            sep.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        // Like Safari: tabs narrow (titles truncate, down to their minimum) before the strip has to scroll.
        // Below the split view's holding priority (250): a full strip must never move the divider.
        let fit = stack.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor)
        fit.priority = .init(245)
        fit.isActive = true
        // The stack's own hugging would beat `fit` and keep every title whole. Its clipping resistance stays above `fit`:
        // tabs at their minimum widen the stack (the strip scrolls) instead of running past its end, clipped.
        stack.setHuggingPriority(.init(200), for: .horizontal); stack.setClippingResistancePriority(.init(246), for: .horizontal)
        registerForDraggedTypes([.kelpTab])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The card's colour, which the strip stands on.
    var fill: NSColor? { didSet { needsDisplay = true } }
    override func updateLayer() { layer?.backgroundColor = (fill ?? .windowBackgroundColor).cgColor }
    override var wantsUpdateLayer: Bool { true }

    func set(_ items: [Item], selected: String?) {
        guard items != self.items || selected != selectedId else { return }   // any session's change comes here, for every pane
        measured = nil
        // A button stays with its tab: closing, opening or moving one moves only that, and the rest slide.
        let kept = Dictionary(zip(self.items.map(\.id), buttons)) { first, _ in first }
        let next = items.map { kept[$0.id] ?? newButton() }
        let moved = next != buttons
        // Nothing in common: another workspace's tabs, which simply show.
        let places = moved && window != nil && items.contains { kept[$0.id] != nil }
            ? Dictionary(uniqueKeysWithValues: buttons.map { (ObjectIdentifier($0), $0.placeInWindow) }) : [:]
        for b in buttons where !next.contains(b) {
            if !places.isEmpty { b.leaveGhost(in: self) }
            b.removeFromSuperview()
        }
        for (i, b) in next.enumerated() where stack.arrangedSubviews.indices.contains(i) ? stack.arrangedSubviews[i] !== b : true {
            stack.insertArrangedSubview(b, at: i)
        }
        buttons = next
        for (b, it) in zip(buttons, items) { b.set(it, selected: it.id == selected, groupFocused: focused) }
        self.items = items; selectedId = selected
        needsLayout = true
        if !places.isEmpty { settle(from: places) }
        revealSoon()
    }

    /// The titles' font changed: the tabs take it, and their widths with it.
    func restyle() {
        buttons.forEach { $0.restyle() }
        measured = nil
        needsLayout = true
    }

    /// Next turn of the run loop, once however often it's asked.
    private func revealSoon() {
        guard !revealing else { return }
        revealing = true
        DispatchQueue.main.async { [weak self] in
            self?.revealing = false
            self?.revealSelected()
        }
    }

    private func newButton() -> TabButton {
        let b = TabButton()
        b.strip = self
        return b
    }

    /// The tabs travel from where they stood, a new one fades in at its place. The next tab can come to rest under a
    /// pointer that closed the last: its ✕ is there for the next click, as in a browser.
    private func settle(from places: [ObjectIdentifier: NSPoint]) {
        layoutSubtreeIfNeeded()
        for b in buttons {
            if let place = places[ObjectIdentifier(b)] {
                b.slide(from: place, duration: Motion.base)
            } else if !Motion.reduced {
                b.alphaValue = 0
                NSAnimationContext.runAnimationGroup { $0.duration = Motion.base; b.animator().alphaValue = 1 }
            }
            b.followPointer()
        }
    }

    override func layout() {
        // "+" right after the tabs while they fit (as in Safari), else at the end of the room they have.
        // Before super.layout(): set after it, the constant only took effect on the next pass, so a tab whose title
        // grew (a page finishing loading) stayed clipped until something else laid the strip out.
        let sizes = measured ?? (stack.fittingSize.width, (overflow.superview?.fittingSize.width ?? 0) + adds.fittingSize.width)
        measured = sizes
        let natural = sizes.tabs, room = bounds.width - 6 - sizes.others - 2
        let x = max(0, min(natural, room))
        if abs((addLead?.constant ?? 0) - x) > 0.5 { addLead?.constant = x }
        let fits = natural <= room + 1
        if overflow.isHidden != fits { overflow.isHidden = fits; measured = nil }
        super.layout()
        fadeEdges()
        // Squeezed (a narrower window, the inspector opening): the chosen tab is scrolled back into view.
        if bounds.width != laidOutWidth {
            laidOutWidth = bounds.width
            revealSoon()
        }
    }

    /// Tabs cut by the strip's ends fade out there, so a cut one reads as "more this way", not as a broken tab.
    private func fadeEdges() {
        let clip = scroll.contentView.bounds
        let cutLeft = clip.minX > 0.5, cutRight = clip.maxX < stack.frame.maxX - 0.5
        guard cutLeft || cutRight else { scroll.layer?.mask = nil; return }
        let fade = 20 / max(scroll.bounds.width, 40)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        edgeMask.frame = scroll.bounds
        edgeMask.colors = [cutLeft ? NSColor.clear.cgColor : NSColor.black.cgColor, NSColor.black.cgColor, NSColor.black.cgColor,
                           cutRight ? NSColor.clear.cgColor : NSColor.black.cgColor]
        edgeMask.locations = [0, NSNumber(value: fade), NSNumber(value: 1 - fade), 1]
        scroll.layer?.mask = edgeMask
        CATransaction.commit()
    }

    /// Keeps the selected tab in view when the strip is scrolled or squeezed.
    private func revealSelected() {
        guard let i = items.firstIndex(where: { $0.id == selectedId }), buttons.indices.contains(i) else { return }
        layoutSubtreeIfNeeded()
        buttons[i].scrollToVisible(buttons[i].bounds.insetBy(dx: -24, dy: 0))
    }

    @objc private func unzoomTapped() { onUnzoom?() }
    @objc private func stripScrolled() { fadeEdges() }
    /// The agent "+" would start first (nil: no agent CLI found, the button hides).
    func setNewAgent(icon: NSImage?, name: String) {
        if newAgent.isHidden != (icon == nil) { measured = nil }
        newAgent.isHidden = icon == nil
        newAgent.image = icon
        newAgent.toolTip = String(localized: "New \(name) (⌥⌘T)"); newAgent.setAccessibilityLabel(String(localized: "New \(name)"))
    }
    @objc private func newAgentTapped() { onNewAgent?() }
    @objc private func addTapped() { addMenu?().popUp(positioning: nil, at: NSPoint(x: 0, y: add.bounds.height + 4), in: add) }

    @objc private func overflowTapped() {
        let m = NSMenu()
        for it in items {
            let i = m.add(it.title) { [weak self] in self?.onSelect?(it.id) }
            i.image = it.icon; i.state = it.id == selectedId ? .on : .off
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: overflow.bounds.height + 4), in: overflow)
    }

    /// The empty strip: what the + offers.
    override func menu(for event: NSEvent) -> NSMenu? { addMenu?() }

    /// Double-click on the empty strip: new tab, like Safari's tab bar.
    override func mouseDown(with e: NSEvent) {
        guard e.clickCount == 2, let m = addMenu?() else { super.mouseDown(with: e); return }
        m.popUp(positioning: nil, at: convert(e.locationInWindow, from: nil), in: self)
    }

    // MARK: drops between tabs
    private func index(at p: NSPoint) -> Int {
        let x = stack.convert(p, from: nil).x
        return buttons.firstIndex { $0.frame.midX > x } ?? buttons.count
    }
    private func showInsertion(_ i: Int) {
        let local = i < buttons.count ? buttons[i].frame.minX - 1 : (buttons.last?.frame.maxX ?? 6)
        let x = convert(NSPoint(x: local, y: 0), from: stack).x
        let frame = NSRect(x: x, y: 4, width: 2, height: bounds.height - 8)
        if insertion.isHidden {   // it comes in where it's needed, then glides from gap to gap
            insertion.frame = frame
            insertion.isHidden = false
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.duration(Motion.fast)
                insertion.animator().frame = frame
            }
        }
    }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { draggingUpdated(s) }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation {
        guard s.draggingPasteboard.string(forType: .kelpTab) != nil else { return [] }
        showInsertion(index(at: s.draggingLocation)); return .move
    }
    override func draggingExited(_ s: NSDraggingInfo?) { insertion.isHidden = true }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        insertion.isHidden = true
        guard let id = s.draggingPasteboard.string(forType: .kelpTab) else { return false }
        onDropTab?(id, index(at: s.draggingLocation)); return true
    }
}

/// An NSControl, not a plain view: under a transparent title bar the window server moves the window on a drag over
/// anything but controls, whatever `mouseDownCanMoveWindow` says, so a dragged tab would take the window with it.
@MainActor
/// A button in a capsule: a soft fill fades in under the pointer, darkens held, springs when clicked (`PointerButton`).
private final class CapsuleSegment: PointerButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        imagePosition = .imageOnly
        radius = nil
    }
    required init?(coder: NSCoder) { fatalError() }
}

private final class TabButton: NSControl, NSDraggingSource {
    weak var strip: TabStrip?
    private var item: TabStrip.Item?
    private var selected = false
    var groupFocused = false { didSet { if groupFocused != oldValue { updateLook() } } }
    private let icon = NSImageView(), title = NSTextField(labelWithString: ""), close = PointerButton(frame: .zero), editedDot = NSImageView()
    private let mark = StatusMark(size: 12)
    private let meter = ContextMeter()
    /// Next to the ring once it's orange: how full, in words a glance takes in without telling the colours apart.
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

    /// Like Safari and Xcode: the close button takes the icon's place on hover; the selected tab is a quiet fill.
    init() {
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = Metrics.radiusSM
        icon.symbolConfiguration = .init(pointSize: 11, weight: Metrics.iconWeight)
        title.font = .ui(12); title.lineBreakMode = .byTruncatingTail
        close.image = .symbol("xmark", String(localized: "Close Tab"))
        close.toolTip = String(localized: "Close Tab (⌘W)")
        close.isBordered = false
        close.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        close.wantsLayer = true
        close.contentTintColor = .secondaryLabelColor
        close.imagePosition = .imageOnly
        close.radius = nil   // a round fill under the pointer, the slot's 16 pt
        close.target = self
        close.action = #selector(closeTapped)
        // Unsaved changes: a dot where the close button goes (as in TextEdit's tabs); hovering shows the close button.
        editedDot.image = .symbol("circle.fill", String(localized: "Edited")); editedDot.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        editedDot.contentTintColor = .labelColor
        // One slot at the start: the agent's state while there's something to see, else the tab's icon; the close button on hover.
        for v in [icon, mark, close, editedDot] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false; slot.addSubview(v)
            NSLayoutConstraint.activate([v.centerXAnchor.constraint(equalTo: slot.centerXAnchor), v.centerYAnchor.constraint(equalTo: slot.centerYAnchor)])
        }
        NSLayoutConstraint.activate([close.widthAnchor.constraint(equalToConstant: 16), close.heightAnchor.constraint(equalToConstant: 16)])
        full.font = .uiDigits(10, weight: .semibold)
        let row = NSStackView(views: [slot, title, chip, meter, full])
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 10)
        pin(row)
        pin(edgeGlow)   // over the row, as the pane's ring is over its content; clicks go through it
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            widthAnchor.constraint(lessThanOrEqualToConstant: 300), widthAnchor.constraint(greaterThanOrEqualToConstant: 76),
            slot.widthAnchor.constraint(equalToConstant: 16), slot.heightAnchor.constraint(equalToConstant: 16)
        ])
        // Below the strip's `fit` (245): a squeezed tab truncates its title with "…" (the row never clips it). Under that
        // again its comfortable width: a short title gives up its air before a long one loses letters.
        title.setContentCompressionResistancePriority(.init(240), for: .horizontal)
        let comfortable = widthAnchor.constraint(greaterThanOrEqualToConstant: 110)
        comfortable.priority = .init(239)
        comfortable.isActive = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        // VoiceOver: a tab like NSTabView's (radio button, tab subrole); the close button only exists on hover, so it's an action.
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilitySubrole(.init(rawValue: "AXTabButton"))   // kAXTabButtonSubrole
        title.setAccessibilityElement(false); icon.setAccessibilityElement(false)
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: String(localized: "Close Tab")) { [weak self] in
            MainActor.assumeIsolated { self?.closeTapped() }; return true   // accessibility actions come on main
        }])
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ it: TabStrip.Item, selected: Bool, groupFocused: Bool) {
        item = it
        self.selected = selected
        self.groupFocused = groupFocused
        title.stringValue = it.title
        icon.image = it.icon
        mark.status = it.status
        mark.unread = it.unread
        mark.progress = it.progress
        mark.waitsForCommand = it.waitsFor
        meter.usage = it.meter
        let level = ContextMeter.level(it.meter)
        full.isHidden = level < 2
        full.stringValue = it.meter.map { "\(Int(Double($0.used) / Double(max($0.window, 1)) * 100))%" } ?? ""
        full.textColor = level == 3 ? .textRed : .textOrange
        chip.isHidden = it.background == 0
        chip.show("apple.terminal", count: it.background)
        chip.toolTip = it.backgroundTip
        chip.setAccessibilityLabel(chip.toolTip)
        toolTip = it.toolTip ?? it.title
        // VoiceOver hears the agent's state too ("Claude Code, Needs your input"): on screen it replaces the icon.
        setAccessibilityLabel(it.status.map { "\(it.title), \($0.words)" } ?? it.title); setAccessibilityValue(selected)
        updateLook()
    }

    /// Working, asking, failed, or finished and not looked at: the state says more than the agent's icon.
    private var showsState: Bool {
        guard let s = item?.status else { return false }
        return [.working, .waiting, .error].contains(s) || (s == .done && item?.unread == true)
    }

    /// It asks, or it failed and wasn't looked at: its title takes the colour (and the tab glows, `glow`), so the pane
    /// that calls for you reads across the window, not only by its 12 pt mark.
    private var callText: NSColor? {
        switch item?.status {
        case .waiting?: .textOrange
        case .error? where item?.unread == true: .textRed
        default: nil
        }
    }

    func restyle() { updateLook() }

    private func updateLook() {
        let edited = item?.edited == true
        close.isHidden = !hover; editedDot.isHidden = hover || !edited
        icon.isHidden = hover || edited || showsState
        mark.alphaValue = hover || edited || !showsState ? 0 : 1   // StatusMark hides itself when there's no state
        let active = selected && groupFocused, call = callText
        title.textColor = call ?? (selected ? .labelColor : .secondaryLabelColor)
        title.font = .ui(12, weight: active || call != nil ? .medium : .regular)
        icon.contentTintColor = active ? .themeAccent : .secondaryLabelColor
        // Chosen in the group you're in, chosen in another one (or under the pointer), nothing; faded, not switched.
        let fill = selected && groupFocused ? NSColor.fillSelected : selected || hover ? .fillHover : nil
        fadeBackground(to: fill)   // the state's colour is in the glow and the title, not a fill under them
        showGlow()
    }

    /// The tab glows as its pane does (GroupView's ring): orange and breathing while its agent asks, red when it failed
    /// unseen; light that calls for you, and nothing else of an agent's. A glow, not a line or a fill: it reads as the pane's.
    private var glow: NSColor? {
        switch item?.status {
        case .waiting?: .systemOrange
        case .error? where item?.unread == true: .systemRed
        default: item?.run
        }
    }
    /// Light along the inside of the capsule, the pane's anatomy at a tab's size: nothing outside it is tinted, and the
    /// selected fill under it stays as it is.
    private func showGlow() {
        edgeGlow.show(glow, breathing: item?.status == .waiting)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateLook() }
    /// The whole tab takes the click, label and icon included: in the title bar they would move the window instead.
    override func hitTest(_ p: NSPoint) -> NSView? {
        guard let v = super.hitTest(p) else { return nil }
        return v.isDescendant(of: close) ? v : self
    }
    override var mouseDownCanMoveWindow: Bool { false }
    /// A capsule on macOS 26+, like the system's own controls there (search fields, buttons, Safari's tabs).
    override func layout() {
        super.layout()
        if #available(macOS 26, *) { layer?.cornerRadius = bounds.height / 2 }
        edgeGlow.radius = layer?.cornerRadius ?? Metrics.radiusSM   // the glow follows the capsule
    }
    override func mouseEntered(with e: NSEvent) { hover = true }
    override func mouseExited(with e: NSEvent) { hover = false }
    /// Moved under or from under a pointer that stayed still: AppKit says so only when it next moves.
    func followPointer() {
        guard let window else { return }
        hover = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
    override func mouseDown(with e: NSEvent) {
        if let id = item?.id { strip?.onSelect?(id) }
    }
    override func mouseUp(with e: NSEvent) { pressBounce() }   // a click springs as every control's does; a drag never comes here
    override func accessibilityPerformPress() -> Bool { if let id = item?.id { strip?.onSelect?(id) }; return true }
    override func otherMouseUp(with e: NSEvent) { closeTapped() }
    override func menu(for event: NSEvent) -> NSMenu? { item.flatMap { strip?.onMenu?($0.id) } }
    @objc private func closeTapped() { if let id = item?.id { strip?.onClose?(id) } }

    override func mouseDragged(with e: NSEvent) {
        guard let id = item?.id else { return }
        let p = NSPasteboardItem(); p.setString(id, forType: .kelpTab)
        let d = NSDraggingItem(pasteboardWriter: p); d.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [d], event: e, source: self)
    }
    nonisolated func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { .move }
}

extension NSView {
    /// What it shows now, as an image (a dragged tab or pane).
    func snapshot() -> NSImage {
        let img = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) { cacheDisplay(in: bounds, to: rep); img.addRepresentation(rep) }
        return img
    }
}
