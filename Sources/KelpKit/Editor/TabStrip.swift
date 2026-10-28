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
    struct Item {
        let id: String
        var title: String
        let icon: NSImage?
        let status: AgentStatus?
        var unread = false
        let toolTip: String?
        var edited = false
        var meter: SessionContextWindow.Usage?
        var progress: Double?
        var waitsFor: String?
    }

    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onMenu: ((String) -> NSMenu?)?
    var onDropTab: ((String, Int) -> Void)?        // tab id, index in this strip
    var addMenu: (() -> NSMenu)?
    var onNewAgent: (() -> Void)?
    var onUnzoom: (() -> Void)?
    /// This group fills the editor area (⇧⌘↩); the button says so and brings the other panes back.
    var zoomed = false { didSet { unzoom.isHidden = !zoomed } }
    private let unzoom = NSButton()
    var focused = false { didSet { if focused != oldValue { buttons.forEach { $0.groupFocused = focused } } } }
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let overflow = NSButton()
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
        insertion.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
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
        unzoom.contentTintColor = .controlAccentColor; unzoom.symbolConfiguration = .init(pointSize: 11, weight: .medium)
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
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed; scroll.verticalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        let sep = NSBox(); sep.boxType = .separator
        for v in [scroll, adds, trailing, sep] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        addSubview(insertion)
        let lead = adds.leadingAnchor.constraint(equalTo: leadingAnchor); addLead = lead
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

    override func updateLayer() { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
    override var wantsUpdateLayer: Bool { true }

    func set(_ items: [Item], selected: String?) {
        // Reuse buttons by position: tabs change titles and status far more often than they move.
        while buttons.count > items.count { buttons.removeLast().removeFromSuperview() }
        while buttons.count < items.count {
            let b = TabButton()
            b.strip = self
            buttons.append(b)
            stack.addArrangedSubview(b)
        }
        for (b, it) in zip(buttons, items) { b.set(it, selected: it.id == selected, groupFocused: focused) }
        self.items = items; selectedId = selected
        needsLayout = true
        DispatchQueue.main.async { [weak self] in self?.revealSelected() }
    }

    override func layout() {
        // "+" right after the tabs while they fit (as in Safari), else at the end of the room they have.
        // Before super.layout(): set after it, the constant only took effect on the next pass, so a tab whose title
        // grew (a page finishing loading) stayed clipped until something else laid the strip out.
        let natural = stack.fittingSize.width
        let room = bounds.width - 6 - (overflow.superview?.fittingSize.width ?? 0) - 2 - adds.fittingSize.width
        let x = max(0, min(natural, room))
        if abs((addLead?.constant ?? 0) - x) > 0.5 { addLead?.constant = x }
        overflow.isHidden = natural <= room + 1
        super.layout()
    }

    /// Keeps the selected tab in view when the strip is scrolled or squeezed.
    private func revealSelected() {
        guard let i = items.firstIndex(where: { $0.id == selectedId }), buttons.indices.contains(i) else { return }
        layoutSubtreeIfNeeded()
        buttons[i].scrollToVisible(buttons[i].bounds.insetBy(dx: -24, dy: 0))
    }

    @objc private func unzoomTapped() { onUnzoom?() }
    /// The agent "+" would start first (nil: no agent CLI found, the button hides).
    func setNewAgent(icon: NSImage?, name: String) {
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
        insertion.frame = NSRect(x: x, y: 4, width: 2, height: bounds.height - 8); insertion.isHidden = false
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
/// A button in a capsule: a soft fill under the pointer, like the inspector's panel icons.
private final class CapsuleSegment: NSButton {
    private var hover = false { didSet { needsDisplay = true } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        title = ""
        imagePosition = .imageOnly
        isBordered = false
        wantsLayer = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(hover ? 0.08 : 0).cgColor }
    override func layout() { super.layout(); layer?.cornerRadius = bounds.height / 2 }
    override func mouseEntered(with e: NSEvent) { hover = true }
    override func mouseExited(with e: NSEvent) { hover = false }
}

private final class TabButton: NSControl, NSDraggingSource {
    weak var strip: TabStrip?
    private var item: TabStrip.Item?
    private var selected = false
    var groupFocused = false { didSet { updateLook() } }
    private let icon = NSImageView(), title = NSTextField(labelWithString: ""), close = NSButton(), editedDot = NSImageView()
    private let mark = StatusMark(size: 12)
    private let meter = ContextMeter()
    /// Next to the ring once it's orange: how full, in words a glance takes in without telling the colours apart.
    private let full = NSTextField(labelWithString: "")
    /// Its agent waits for a command it started: the command on a chip, a cyan line along the tab's top.
    private let chip = Chip(), light = CALayer()
    private var hover = false { didSet { updateLook() } }

    /// Like Safari and Xcode: the close button takes the icon's place on hover; the selected tab is a quiet fill.
    init() {
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 6
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        title.font = .systemFont(ofSize: 12); title.lineBreakMode = .byTruncatingTail
        close.image = .symbol("xmark", String(localized: "Close Tab"))
        close.toolTip = String(localized: "Close Tab (⌘W)")
        close.isBordered = false
        close.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        close.contentTintColor = .secondaryLabelColor
        close.target = self
        close.action = #selector(closeTapped)
        // Unsaved changes: a dot where the close button goes (as in TextEdit's tabs); hovering shows the close button.
        editedDot.image = .symbol("circle.fill", String(localized: "Edited")); editedDot.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        editedDot.contentTintColor = .labelColor
        // One slot at the start: the agent's state while there's something to see, else the tab's icon; the close button on hover.
        let slot = NSView()
        for v in [icon, mark, close, editedDot] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false; slot.addSubview(v)
            NSLayoutConstraint.activate([v.centerXAnchor.constraint(equalTo: slot.centerXAnchor), v.centerYAnchor.constraint(equalTo: slot.centerYAnchor)])
        }
        full.font = .uiDigits(10, weight: .semibold)
        chip.setContentCompressionResistancePriority(.init(200), for: .horizontal)   // gives way before the title, down to "…"
        let least = chip.widthAnchor.constraint(greaterThanOrEqualToConstant: 40); least.priority = .init(760)
        NSLayoutConstraint.activate([least, chip.widthAnchor.constraint(lessThanOrEqualToConstant: 90)])
        chip.icon.image = .symbol("apple.terminal")
        light.cornerRadius = 1
        layer?.addSublayer(light)
        let row = NSStackView(views: [slot, title, chip, meter, full])
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 10)
        pin(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            widthAnchor.constraint(lessThanOrEqualToConstant: 300), widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
            slot.widthAnchor.constraint(equalToConstant: 16), slot.heightAnchor.constraint(equalToConstant: 16)
        ])
        // Below the strip's `fit` (245): a squeezed tab truncates its title with "…" (the row never clips it).
        title.setContentCompressionResistancePriority(.init(240), for: .horizontal)
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
        meter.usage = it.meter
        let level = ContextMeter.level(it.meter)
        full.isHidden = level < 2
        full.stringValue = it.meter.map { "\(Int(Double($0.used) / Double(max($0.window, 1)) * 100))%" } ?? ""
        full.textColor = level == 3 ? .textRed : .textOrange
        chip.isHidden = it.waitsFor == nil; light.isHidden = it.waitsFor == nil
        chip.label.stringValue = it.waitsFor ?? ""
        chip.toolTip = it.waitsFor.map { String(localized: "Waits for its command:") + "\n" + $0 }
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

    /// It asks, or it failed and wasn't looked at: the whole capsule takes the colour, so the pane that calls for you
    /// reads across the window, not only by its 12 pt mark.
    private var call: (fill: NSColor, text: NSColor)? {
        switch item?.status {
        case .waiting?: (.systemOrange, .textOrange)
        case .error? where item?.unread == true: (.systemRed, .textRed)
        default: nil
        }
    }

    private func updateLook() {
        let edited = item?.edited == true
        close.isHidden = !hover; editedDot.isHidden = hover || !edited
        icon.isHidden = hover || edited || showsState
        mark.alphaValue = hover || edited || !showsState ? 0 : 1   // StatusMark hides itself when there's no state
        let active = selected && groupFocused, call = call
        title.textColor = call?.text ?? (selected ? .labelColor : .secondaryLabelColor)
        title.font = .systemFont(ofSize: 12, weight: active || call != nil ? .medium : .regular)
        icon.contentTintColor = active ? .controlAccentColor : .secondaryLabelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            light.backgroundColor = NSColor.systemCyan.cgColor
            if let call { layer?.backgroundColor = call.fill.withAlphaComponent(selected ? 0.24 : 0.16).cgColor; return }
            let fill = selected ? (groupFocused ? 0.12 : 0.07) : hover ? 0.05 : 0
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(fill).cgColor
        }
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
        let ends = max(layer?.cornerRadius ?? 6, 6)   // clear of the rounded ends
        light.frame = NSRect(x: ends, y: bounds.height - 2, width: max(0, bounds.width - 2 * ends), height: 2)
    }
    override func mouseEntered(with e: NSEvent) { hover = true }
    override func mouseExited(with e: NSEvent) { hover = false }
    override func mouseDown(with e: NSEvent) { if let id = item?.id { strip?.onSelect?(id) } }
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

/// A small ring: how full an agent's conversation is (gray, amber from 75 %, red from 90 %).
@MainActor
/// How full an agent's conversation is: nothing while there's room, then a ring that fills, yellow where answers may
/// start to slip, orange where it's time to compact or hand off, red just before the agent compacts by itself. Past
/// half a 200k window, or 200k tokens of a bigger one: long-context benchmarks slip by absolute tokens, so a 1M
/// window turns yellow at 200k, orange at 400k and red at 600k (a 200k one at 100k, 130k and 150k, under Claude Code's
/// own compaction).
final class ContextMeter: NSView {
    private let track = CAShapeLayer(), fill = CAShapeLayer()
    var usage: SessionContextWindow.Usage? { didSet { isHidden = Self.level(usage) == 0; update() } }
    /// 0 room, 1 yellow, 2 orange, 3 red.
    static func level(_ u: SessionContextWindow.Usage?) -> Int {
        guard let u, u.window > 0 else { return 0 }
        let w = Double(u.window), used = Double(u.used)
        return used >= min(0.75 * w, 600_000) ? 3 : used >= min(0.65 * w, 400_000) ? 2 : used >= min(0.5 * w, 200_000) ? 1 : 0
    }
    init() {
        super.init(frame: .zero)
        wantsLayer = true; isHidden = true
        let path = CGMutablePath()   // from the top, clockwise (the layer's y goes up)
        path.addArc(center: CGPoint(x: 6, y: 6), radius: 4.5, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for l in [track, fill] {
            l.path = path
            l.fillColor = nil
            l.lineWidth = 2
            layer?.addSublayer(l)
        }
        fill.lineCap = .round
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 12), heightAnchor.constraint(equalToConstant: 12)])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); update() }
    private func update() {
        guard let usage, usage.window > 0 else { return }
        let share = Double(usage.used) / Double(usage.window), level = Self.level(usage)
        toolTip = String(localized: "Context \(Int(share * 100)) % full: \(usage.used / 1000)k of \(usage.window / 1000)k tokens")
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.strokeColor = NSColor.tertiaryLabelColor.cgColor
            fill.strokeColor = [NSColor.secondaryLabelColor, .systemYellow, .systemOrange, .systemRed][level].cgColor
        }
        fill.strokeEnd = min(1, share)
    }
}

extension NSView {
    /// What it shows now, as an image (a dragged tab or pane).
    func snapshot() -> NSImage {
        let img = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) { cacheDisplay(in: bounds, to: rep); img.addRepresentation(rep) }
        return img
    }
}
