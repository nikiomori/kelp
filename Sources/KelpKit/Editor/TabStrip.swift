import AppKit
import Core
import DesignKit

/// A group's tab strip: icon, title, agent status, close on hover; drag to reorder, move to another group, or split.
/// The top panes' strips make the window's second row, under the window bar, level with the sidebar's search and the
/// inspector's panel icons.
@MainActor
final class TabStrip: NSView {
    /// Room around the tabs: they don't run into the strip's edges or the pane dividers. The sidebar's and inspector's
    /// band in the same row is as tall.
    static func height(compact: Bool) -> CGFloat { compact ? 32 : 40 }
    @MainActor static func height(_ settings: SettingsStore) -> CGFloat {
        height(compact: settings[SettingKeys.tabHeight] == "compact")
    }
    /// Settings › Appearance › Tab height: Compact, 24 pt tabs in a 32 pt strip.
    var low = false {
        didSet {
            guard low != oldValue else { return }
            tall.constant = Self.height(compact: low)
            addHeights.forEach { $0.constant = low ? 20 : 24 }
            buttons.forEach { $0.low = low }
            measured = nil
            needsLayout = true
        }
    }
    private lazy var tall = heightAnchor.constraint(equalToConstant: Self.height(compact: false))
    private lazy var addHeights = [
        add.heightAnchor.constraint(equalToConstant: 24), newAgent.heightAnchor.constraint(equalToConstant: 24)
    ]

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
    let stack = NSStackView()
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
    var buttons: [TabButton] = []
    let insertion = NSView()
    /// "+" follows the last tab (set in layout); with the strip full, it stays at the right end.
    private var addLead: NSLayoutConstraint?
    private var laidOutWidth: CGFloat = 0
    /// How wide the tabs and the buttons beside them want to be: the same at any width of the strip, and asking takes a
    /// layout pass, for each step of a panel sliding by.
    private var measured: (tabs: CGFloat, others: CGFloat, regular: CGFloat)?
    /// Settings › Appearance › Tab width: "regular", "compact", or "auto": regular while the tabs fit at their
    /// narrowest, compact once they would scroll.
    var tabWidth = "auto" {
        didSet {
            guard tabWidth != oldValue else { return }
            measured = nil
            needsLayout = true
        }
    }
    private var compact = false
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
            tall,
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
            newAgent.widthAnchor.constraint(equalToConstant: 24),
            sep.leadingAnchor.constraint(equalTo: leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: trailingAnchor),
            sep.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        NSLayoutConstraint.activate(addHeights)
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
        buttons.forEach { $0.updateLook() }
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
        button.compact = compact
        button.low = low
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
                    $0.timingFunction = CAMediaTimingFunction(name: .easeOut)   // as its neighbours slide
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
        var sizes = measured ?? measure()
        var room = bounds.width - 6 - sizes.others - 2
        // The chevron's room counts as the tabs': showing it mustn't turn them back to regular.
        let squeezed = sizes.regular > room + (overflow.isHidden ? 0 : overflow.fittingSize.width + 6)
        let compact = tabWidth == "compact" || tabWidth == "auto" && squeezed
        if compact != self.compact {
            self.compact = compact
            buttons.forEach { $0.compact = compact }
            sizes = measure()
            room = bounds.width - 6 - sizes.others - 2
        }
        measured = sizes
        let natural = sizes.tabs
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

    private func measure() -> (tabs: CGFloat, others: CGFloat, regular: CGFloat) {
        let gaps = CGFloat(max(buttons.count - 1, 0)) * stack.spacing + stack.edgeInsets.left + stack.edgeInsets.right
        return (
            stack.fittingSize.width, (overflow.superview?.fittingSize.width ?? 0) + adds.fittingSize.width,
            buttons.reduce(gaps) { $0 + $1.regularMinimum }
        )
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
}
