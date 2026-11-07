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
        /// An agent's tab: the sidebar's card for it ("a:<session>") under the pointer, in place of the tooltip.
        var card: String?
        /// Its title ends with what tells it from a namesake ("README.md — docs"): it gives way in the middle, so that stays.
        var keepsEnd = false
    }

    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onMenu: ((String) -> NSMenu?)?
    var onDropTab: ((String, Int) -> Void)?   // tab id, index in this strip
    var addMenu: (() -> NSMenu)?
    var onNewAgent: (() -> Void)?
    var onUnzoom: (() -> Void)?
    /// Shows `Item.card` under a tab the pointer rests on.
    var hoverCard: HoverCard?
    /// This group fills the editor area (⇧⌘↩); the button says so and brings the other panes back.
    var zoomed = false {
        didSet {
            unzoom.isHidden = !zoomed
            measured = nil
        }
    }
    private let unzoom = PointerButton(frame: .zero)
    var focused = false { didSet { if focused != oldValue { buttons.forEach { $0.groupFocused = focused } } } }
    /// A pane without focus among several: its tabs fade with its content, all but those with news (`TabButton.news`).
    var dimmed = false {
        didSet {
            guard dimmed != oldValue else { return }
            buttons.forEach { $0.stripDimmed = dimmed }
            NSAnimationContext.runAnimationGroup { ctx in   // new agent and "+" fade with the pane's tabs
                ctx.duration = Motion.duration(Motion.fast)
                adds.animator().alphaValue = dimmed ? Metrics.tabDim : 1
            }
        }
    }
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private lazy var edgeMask: CAGradientLayer = {
        let gradient = CAGradientLayer()
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        return gradient
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
        overflow.symbolConfiguration = .chrome(Metrics.iconTiny)
        overflow.toolTip = String(localized: "All tabs in this group")
        overflow.target = self
        overflow.action = #selector(overflowTapped)
        overflow.isHidden = true
        unzoom.image = .symbol("arrow.down.right.and.arrow.up.left", String(localized: "Show All Panes"))
        unzoom.isBordered = false
        unzoom.contentTintColor = .themeAccent
        unzoom.symbolConfiguration = .chrome(Metrics.iconSmall)
        unzoom.toolTip = String(localized: "Show all panes (⇧⌘↩)")
        unzoom.target = self
        unzoom.action = #selector(unzoomTapped)
        unzoom.isHidden = true
        // The one way to add a tab, in each pane (like Safari's "+"); the empty workspace offers the same choices.
        add.image = .symbol("plus", String(localized: "New Tab"))
        add.contentTintColor = .secondaryLabelColor
        add.symbolConfiguration = .chrome()
        add.toolTip = String(localized: "New tab: an agent (⌥⌘T), a terminal (⌘T), a browser…")
        add.target = self
        add.action = #selector(addTapped)
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(stripScrolled), name: NSView.boundsDidChangeNotification,
            object: scroll.contentView)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        let sep = NSBox()
        sep.boxType = .separator
        for part in [scroll, adds, trailing, sep] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            addSubview(part)
        }
        addSubview(insertion)
        // Below the split view's holding (250), like `fit`: measured before the overflow button shows, it asked for 18 pt
        // more than the strip had, and the window widened to give them; now "+" gives way instead.
        let lead = adds.leadingAnchor.constraint(equalTo: leadingAnchor)
        lead.priority = .init(249)
        addLead = lead
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            scroll.trailingAnchor.constraint(equalTo: adds.leadingAnchor), lead,
            adds.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -2),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            adds.centerYAnchor.constraint(equalTo: centerYAnchor),
            overflow.widthAnchor.constraint(equalToConstant: 18), add.widthAnchor.constraint(equalToConstant: 24),
            add.heightAnchor.constraint(equalToConstant: 24),
            newAgent.widthAnchor.constraint(equalToConstant: 24), newAgent.heightAnchor.constraint(equalToConstant: 24),
            sep.leadingAnchor.constraint(equalTo: leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: trailingAnchor),
            sep.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        // Like Safari: tabs narrow (titles truncate, down to their minimum) before the strip has to scroll.
        // Below the split view's holding priority (250): a full strip must never move the divider.
        let fit = stack.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor)
        fit.priority = .init(245)
        fit.isActive = true
        // The stack's own hugging would beat `fit` and keep every title whole. Its clipping resistance stays above `fit`:
        // tabs at their minimum widen the stack (the strip scrolls) instead of running past its end, clipped.
        stack.setHuggingPriority(.init(200), for: .horizontal)
        stack.setClippingResistancePriority(.init(246), for: .horizontal)
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
        let places =
            moved && window != nil && items.contains { kept[$0.id] != nil }
            ? Dictionary(uniqueKeysWithValues: buttons.map { (ObjectIdentifier($0), $0.placeInWindow) }) : [:]
        for button in buttons where !next.contains(button) {
            if !places.isEmpty { button.leaveGhost(in: self) }
            button.removeFromSuperview()
        }
        for (index, button) in next.enumerated()
        where stack.arrangedSubviews.indices.contains(index) ? stack.arrangedSubviews[index] !== button : true {
            stack.insertArrangedSubview(button, at: index)
        }
        buttons = next
        for (button, item) in zip(buttons, items) {
            button.stripDimmed = dimmed
            button.set(item, selected: item.id == selected, groupFocused: focused)
        }
        self.items = items
        selectedId = selected
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
        let button = TabButton()
        button.strip = self
        return button
    }

    /// The tabs travel from where they stood, a new one fades in at its place. The next tab can come to rest under a
    /// pointer that closed the last: its ✕ is there for the next click, as in a browser.
    private func settle(from places: [ObjectIdentifier: NSPoint]) {
        layoutSubtreeIfNeeded()
        for button in buttons {
            if let place = places[ObjectIdentifier(button)] {
                button.slide(from: place, duration: Motion.base)
            } else if !Motion.reduced {
                button.alphaValue = 0
                NSAnimationContext.runAnimationGroup {
                    $0.duration = Motion.base
                    button.animator().alphaValue = 1
                }
            }
            button.followPointer()
        }
    }

    override func layout() {
        // "+" right after the tabs while they fit (as in Safari), else at the end of the room they have.
        // Before super.layout(): set after it, the constant only took effect on the next pass, so a tab whose title
        // grew (a page finishing loading) stayed clipped until something else laid the strip out.
        let sizes =
            measured ?? (stack.fittingSize.width, (overflow.superview?.fittingSize.width ?? 0) + adds.fittingSize.width)
        measured = sizes
        let natural = sizes.tabs, room = bounds.width - 6 - sizes.others - 2
        let offset = max(0, min(natural, room))
        if abs((addLead?.constant ?? 0) - offset) > 0.5 { addLead?.constant = offset }
        let fits = natural <= room + 1
        if overflow.isHidden != fits {
            overflow.isHidden = fits
            measured = nil
        }
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
        guard cutLeft || cutRight else {
            scroll.layer?.mask = nil
            return
        }
        let fade = 20 / max(scroll.bounds.width, 40)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edgeMask.frame = scroll.bounds
        edgeMask.colors = [
            cutLeft ? NSColor.clear.cgColor : NSColor.black.cgColor, NSColor.black.cgColor, NSColor.black.cgColor,
            cutRight ? NSColor.clear.cgColor : NSColor.black.cgColor
        ]
        edgeMask.locations = [0, NSNumber(value: fade), NSNumber(value: 1 - fade), 1]
        scroll.layer?.mask = edgeMask
        CATransaction.commit()
    }

    /// Keeps the selected tab in view when the strip is scrolled or squeezed.
    private func revealSelected() {
        guard let index = items.firstIndex(where: { $0.id == selectedId }), buttons.indices.contains(index) else {
            return
        }
        layoutSubtreeIfNeeded()
        buttons[index].scrollToVisible(buttons[index].bounds.insetBy(dx: -24, dy: 0))
    }

    @objc private func unzoomTapped() { onUnzoom?() }
    @objc private func stripScrolled() { fadeEdges() }
    /// The agent "+" would start first (nil: no agent CLI found, the button hides). Grey and faint at rest, no heavier than
    /// the "+" beside it, as a mark that isn't a state must be here; its colour comes under the pointer.
    func setNewAgent(icon: NSImage?, grey: NSImage?, name: String) {
        if newAgent.isHidden != (icon == nil) { measured = nil }
        newAgent.isHidden = icon == nil
        if let grey, faint?.of !== grey { faint = (grey, Self.faint(grey)) }
        newAgent.show(icon, atRest: grey == nil ? nil : faint?.image)
        newAgent.toolTip = String(localized: "New \(name) (⌥⌘T)")
        newAgent.setAccessibilityLabel(String(localized: "New \(name)"))
    }
    private var faint: (of: NSImage, image: NSImage)?
    /// `image` at the opacity of a secondary label.
    private static func faint(_ image: NSImage) -> NSImage {
        let img = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.55)
            return true
        }
        img.accessibilityDescription = image.accessibilityDescription
        return img
    }
    @objc private func newAgentTapped() { onNewAgent?() }
    @objc private func addTapped() {
        addMenu?().popUp(positioning: nil, at: NSPoint(x: 0, y: add.bounds.height + 4), in: add)
    }

    @objc private func overflowTapped() {
        let menu = NSMenu()
        for item in items {
            let menuItem = menu.add(item.title) { [weak self] in self?.onSelect?(item.id) }
            menuItem.image = item.icon
            menuItem.state = item.id == selectedId ? .on : .off
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: overflow.bounds.height + 4), in: overflow)
    }

    /// The empty strip: what the + offers.
    override func menu(for event: NSEvent) -> NSMenu? { addMenu?() }

    /// Double-click on the empty strip: new tab, like Safari's tab bar.
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2, let menu = addMenu?() else {
            super.mouseDown(with: event)
            return
        }
        menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
    }

    // MARK: drops between tabs
    private func index(at point: NSPoint) -> Int {
        let x = stack.convert(point, from: nil).x
        return buttons.firstIndex { $0.frame.midX > x } ?? buttons.count
    }
    private func showInsertion(_ position: Int) {
        let local = position < buttons.count ? buttons[position].frame.minX - 1 : (buttons.last?.frame.maxX ?? 6)
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
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.string(forType: .kelpTab) != nil else { return [] }
        showInsertion(index(at: sender.draggingLocation))
        return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { insertion.isHidden = true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        insertion.isHidden = true
        guard let id = sender.draggingPasteboard.string(forType: .kelpTab) else { return false }
        onDropTab?(id, index(at: sender.draggingLocation))
        return true
    }
}

@MainActor
/// A button in a capsule: a soft fill fades in under the pointer, darkens held, springs when clicked (`PointerButton`).
private final class CapsuleSegment: PointerButton {
    private var images: (pointed: NSImage?, atRest: NSImage?)?
    private var pointed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        imagePosition = .imageOnly
        radius = nil
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `image` under the pointer, `atRest` otherwise.
    func show(_ image: NSImage?, atRest: NSImage?) {
        images = (image, atRest)
        self.image = pointed ? image : atRest
    }
    private func follow(_ on: Bool) {
        pointed = on
        if let images { image = on ? images.pointed : images.atRest }
    }
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        follow(true)
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        follow(false)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        follow(false)
    }
}

extension NSView {
    /// What it shows now, as an image (a dragged tab or pane).
    func snapshot() -> NSImage {
        let img = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            img.addRepresentation(rep)
        }
        return img
    }
}
