// The inspector's parts: its view, the icon row's capsule, a panel's icon with its count, and the host of a SwiftUI
// panel.
import AppKit
import Core
import DesignKit
import SwiftUI

/// The inspector's view; a right-click on the band of the icon row opens the row's menu.
final class InspectorView: NSView {
    var rowMenu: ((NSEvent) -> NSMenu?)?
    /// Runs when the view comes on screen: in a window and not collapsed (a collapsed split view item is hidden).
    var onShow: (() -> Void)?
    /// Runs after each layout, to work out how many icons fit.
    var onLayout: (() -> Void)?
    override func layout() {
        super.layout()
        onLayout?()
    }
    override func menu(for event: NSEvent) -> NSMenu? { rowMenu?(event) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onShow?()
    }
    override func viewDidUnhide() {
        super.viewDidUnhide()
        onShow?()
    }
}

extension InspectorController {
    /// On macOS 26, puts the row on a glass capsule (with the capsule's own fill off); before that, the row has only
    /// its soft fill. The glass sits behind the row, not around it, because as the glass's content the row was clipped
    /// to the glass, and a column's count badges were clipped with it.
    static func glass(around row: CapsuleStack) -> NSView {
        guard #available(macOS 26, *) else { return row }
        let bar = NSView(), capsule = NSGlassEffectView()
        capsule.cornerRadius = Metrics.segmentCapsule / 2
        row.filled = false
        for v in [capsule, row] {
            v.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
                v.topAnchor.constraint(equalTo: bar.topAnchor),
                v.bottomAnchor.constraint(equalTo: bar.bottomAnchor)
            ])
        }
        return bar
    }
}

/// A soft capsule behind a row of icons: the inspector's panel icons, or a pane's new-agent and "+" buttons.
final class CapsuleStack: NSStackView {
    /// Whether the capsule draws its fill. It is off inside glass, because the glass is then the capsule.
    var filled = true { didSet { needsDisplay = true } }
    /// The icon shown on the chosen grey. One pill sits under the icons and moves from one to the next (with the
    /// `Motion.soft` curve), as a segmented control's pill does on macOS 26. nil means none is chosen (a pane's
    /// buttons).
    var chosen: NSView? {
        didSet {
            guard chosen !== oldValue else { return }
            // The pill is a layer of its own. The layer is asked for here, never in layout, because a pane's capsule
            // (nothing chosen) lost its round ends when layout gave it a new layer after rounding the old one.
            wantsLayer = true
            place(moving: oldValue?.superview === self && window != nil)
        }
    }
    private let pill = CALayer()
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = filled ? NSColor.fillRest.cgColor : nil
        pill.backgroundColor = NSColor.fillSelected.cgColor   // drawing runs in the view's appearance
    }
    private func place(moving: Bool) {
        guard let layer, chosen != nil || pill.superlayer != nil else { return }   // a pane's buttons have no pill
        if pill.superlayer !== layer { layer.insertSublayer(pill, at: 0) }
        let frame = chosen.flatMap { $0.superview === self && !$0.isHidden ? $0.frame : nil }
        let from = pill.isHidden ? nil : pill.presentation()?.frame ?? pill.frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.isHidden = frame == nil
        if let frame, pill.frame != frame {   // a layout during a move lets the move go on
            pill.frame = frame
            pill.cornerRadius = min(frame.width, frame.height) / 2
        }
        CATransaction.commit()
        guard moving, let from, let frame, from != frame, !Motion.reduced else { return }
        for (key, old, new) in [
            ("position", NSValue(point: NSPoint(x: from.midX, y: from.midY)), NSValue(point: pill.position)),
            ("bounds", NSValue(rect: NSRect(origin: .zero, size: from.size)), NSValue(rect: pill.bounds))
        ] {
            let move = CABasicAnimation(keyPath: key)
            move.fromValue = old
            move.toValue = new
            move.duration = Motion.base
            move.timingFunction = Motion.soft
            pill.add(move, forKey: key)
        }
    }
    /// The capsule doesn't clip, so a column's count badges can hang past its edge (`PanelIcon` lets them out of the
    /// icon).
    override var clipsToBounds: Bool {
        get { false }
        set {}
    }
    override func layout() {
        super.layout()
        place(moving: false)
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2   // a row or a column
    }
}

/// A panel's icon, one segment of the capsule. A click shows the panel, and a drag moves the icon along the row
/// (`moved` gets the pointer's point in the row, `dropped` runs on release). The shown panel's icon sits on the same
/// grey as a chosen row.
final class PanelIcon: NSButton {
    var moved: ((NSPoint) -> Void)?
    var dropped: (() -> Void)?
    var contextMenu: ((NSEvent) -> NSMenu?)?
    /// Runs when the pointer rests on the icon a moment (the » opens its menu without a click).
    var rested: (() -> Void)?
    private let resting = Debounce()
    private var held: (menu: NSMenu, area: NSRect, leftAt: Date?)?
    private var hover = false { didSet { needsDisplay = true } }

    convenience init(_ symbol: String, _ label: String) {
        self.init(frame: .zero)
        image = .symbol(symbol, label)
        imagePosition = .imageOnly
        title = ""
        toolTip = label
        isBordered = false
        setButtonType(.pushOnPushOff)
        wantsLayer = true
        symbolConfiguration = .chrome(Metrics.segmentPoint)
        imageScaling = .scaleProportionallyDown
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let on = state == .on
        // Chosen is one grey everywhere (sidebar rows, tabs, Settings), in glass too, because a white bubble said it a
        // second way. The capsule draws that grey under the chosen icon (`CapsuleStack.chosen`) so it can move. A held
        // icon darkens.
        fadeBackground(to: isHighlighted ? .fillSelected : hover && !on ? .fillHover : nil, held: isHighlighted)
        contentTintColor = on ? .labelColor : .secondaryLabelColor
    }
    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
    /// The frame is the pill, with no alignment insets. AppKit's insets made the Files icon 29 pt tall where the others
    /// are 24 (PointerButton does the same).
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    /// The count badge sits over the pill's corner, so the icon doesn't clip. A button clips to its rounded layer (and
    /// sets this back to true on display).
    override var clipsToBounds: Bool {
        get { false }
        set {}
    }
    override func mouseEntered(with event: NSEvent) {
        hover = true
        guard let rested else { return }
        resting.after(Motion.base) { rested() }   // passing over doesn't open it
    }
    override func mouseExited(with event: NSEvent) {
        hover = false
        resting.cancel()
    }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?(event) }

    /// Pops `menu` up under the icon. With `closingWhenLeft`, the menu closes a moment after the pointer is off both
    /// the icon and the menu. Menu tracking delivers no mouse-exited, so a timer on the tracking run loop checks while
    /// the menu is open.
    func popUp(_ menu: NSMenu, closingWhenLeft: Bool) {
        let at = NSPoint(x: 0, y: bounds.height + 4)
        guard closingWhenLeft, let window else {
            menu.popUp(positioning: nil, at: at, in: self)
            return refreshHover()
        }
        let icon = window.convertToScreen(convert(bounds, to: nil)), size = menu.size
        let below = NSRect(x: icon.minX, y: icon.minY - 4 - size.height, width: size.width, height: size.height + 4)
        held = (menu, icon.union(below), nil)
        let watch = Timer(timeInterval: Motion.stagger, repeats: true) { [weak self] _ in
            // Timer on the main run loop: it fires on the main thread.
            MainActor.assumeIsolated { self?.checkHeld() }
        }
        RunLoop.main.add(watch, forMode: .eventTracking)
        menu.popUp(positioning: nil, at: at, in: self)
        refreshHover()
        watch.invalidate()
        held = nil
    }

    private func checkHeld() {
        guard let view = held else { return }
        // When macOS moved the menu to fit the screen, the pointer still counts as on it while one of its items is lit.
        if view.area.contains(NSEvent.mouseLocation) || view.menu.highlightedItem != nil {
            held?.leftAt = nil
        } else if let left = view.leftAt {
            if Date().timeIntervalSince(left) >= Motion.hoverClose { view.menu.cancelTracking() }
        } else {
            held?.leftAt = Date()
        }
    }

    /// Sets the hover grey from where the pointer is now, because the menu's tracking swallowed mouse-exited.
    private func refreshHover() {
        guard let window else { return }
        hover = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        resting.cancel()
        if event.modifierFlags.contains(.control), let shown = menu(for: event) {
            return NSMenu.popUpContextMenu(shown, with: event, for: self)
        }
        guard let window, let row = superview else { return super.mouseDown(with: event) }
        isHighlighted = true
        defer { isHighlighted = false }
        var dragging = false, at = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            at = next.locationInWindow
            if next.type == .leftMouseUp { break }
            guard dragging || hypot(at.x - event.locationInWindow.x, at.y - event.locationInWindow.y) > 3 else {
                continue
            }
            dragging = true
            isHighlighted = false
            moved?(row.convert(at, from: nil))
        }
        if dragging {
            dropped?()
        } else if bounds.contains(convert(at, from: nil)) {
            pressBounce()
            sendAction(action, to: target)
        }
    }
}

/// A panel's mark on its icon (`PanelBadge`): a grey capsule with the number, or a dot, and red for a failure. A new
/// number rolls in (`roll`) while the capsule stays in place.
final class CountBadge: NSView {
    private let digits = NSTextField(labelWithString: "")
    var badge: PanelBadge? {
        didSet {
            guard badge != oldValue else { return }
            let old = Self.number(oldValue), new = Self.number(badge)
            if let old, let new, old != new, !isHidden { digits.roll(up: new > old) }
            if oldValue == nil { fadeIn() } else if badge == nil { isHidden = true }
            digits.stringValue = new.map { $0 > 99 ? "99+" : "\($0)" } ?? ""
            digits.isHidden = new == nil
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    private static func number(_ badge: PanelBadge?) -> Int? { badge.flatMap { $0.count > 0 ? $0.count : nil } }
    init() {
        super.init(frame: .zero)
        isHidden = true
        digits.font = .uiDigits(TextSize.micro, weight: .semibold)
        digits.textColor = .white
        digits.alignment = .center
        digits.translatesAutoresizingMaskIntoConstraints = false
        addSubview(digits)
        NSLayoutConstraint.activate([
            digits.centerXAnchor.constraint(equalTo: centerXAnchor),
            digits.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize {
        // With no number, the badge is a dot, centred where the number's capsule would be.
        guard Self.number(badge) != nil else { return NSSize(width: 7, height: 14) }
        return NSSize(width: max(14, ceil(digits.attributedStringValue.size().width) + 7), height: 14)
    }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }   // clicks go to the icon
    override func draw(_ dirtyRect: NSRect) {
        (badge?.alert == true ? NSColor.systemRed : NSColor.systemGray).setFill()
        guard Self.number(badge) != nil else {
            return NSBezierPath(ovalIn: NSRect(x: 0, y: 3, width: 7, height: 7)).fill()
        }
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

/// Hosts a SwiftUI panel in an AppKit view controller.
@MainActor
func hosting<V: View>(_ view: V) -> NSViewController {
    // The view fills the panel from the top, because content shorter than the panel would otherwise float in its
    // middle.
    let host = NSHostingController(rootView: view.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
    host.sizingOptions = []   // a panel fills the space it's given; it must never resize the window to its ideal size
    return host
}
