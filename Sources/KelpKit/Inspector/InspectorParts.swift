// The inspector's parts: its view, the icon row's capsule, a panel's icon and count, a SwiftUI panel's host.
import AppKit
import Core
import DesignKit
import SwiftUI

/// The inspector's view: a right-click on the icon row's band opens the row's menu.
final class InspectorView: NSView {
    var rowMenu: ((NSEvent) -> NSMenu?)?
    /// On screen: in a window and not collapsed (a collapsed split view item is hidden).
    var onShow: (() -> Void)?
    /// After a resize: how many icons fit.
    var onLayout: (() -> Void)?
    override func layout() {
        super.layout()
        onLayout?()
    }
    override func menu(for e: NSEvent) -> NSMenu? { rowMenu?(e) }
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
    /// macOS 26: the row in a glass capsule (the capsule's own fill off); earlier, the row's soft fill alone.
    static func glass(around row: CapsuleStack) -> NSView {
        guard #available(macOS 26, *) else { return row }
        let capsule = NSGlassEffectView()
        capsule.cornerRadius = Metrics.segmentCapsule / 2
        row.filled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        capsule.contentView = row
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: capsule.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: capsule.trailingAnchor),
            row.topAnchor.constraint(equalTo: capsule.topAnchor),
            row.bottomAnchor.constraint(equalTo: capsule.bottomAnchor)
        ])
        return capsule
    }
}

/// A soft capsule behind a row of icons: the inspector's panels, a pane's new-agent and "+" buttons.
final class CapsuleStack: NSStackView {
    /// Off inside glass, which is the capsule then.
    var filled = true { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = filled ? NSColor.fillRest.cgColor : nil }
    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
}

/// A panel's icon, a segment of the capsule: a click shows the panel, a drag moves the icon along the row (`moved`
/// with the pointer's x in the row, `dropped` on release). The shown panel's icon sits on the grey of a chosen row.
final class PanelIcon: NSButton {
    var moved: ((CGFloat) -> Void)?
    var dropped: (() -> Void)?
    var contextMenu: ((NSEvent) -> NSMenu?)?
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
        // Chosen is one grey everywhere (sidebar rows, tabs, Settings), in glass too: a white bubble said it a second way.
        fadeBackground(to: on || isHighlighted ? .fillSelected : hover ? .fillHover : nil, held: isHighlighted)   // held, it darkens
        contentTintColor = on ? .labelColor : .secondaryLabelColor
    }
    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
    /// The frame is the pill: AppKit's alignment insets made Files' 29 pt tall where the others are 24 (as PointerButton).
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    /// The count badge sits over the pill's corner; a button clips to its rounded layer (and sets this back to true on display).
    override var clipsToBounds: Bool {
        get { false }
        set {}
    }
    override func mouseEntered(with e: NSEvent) { hover = true }
    override func mouseExited(with e: NSEvent) { hover = false }

    override func menu(for e: NSEvent) -> NSMenu? { contextMenu?(e) }

    override func mouseDown(with e: NSEvent) {
        if e.modifierFlags.contains(.control), let shown = menu(for: e) {
            return NSMenu.popUpContextMenu(shown, with: e, for: self)
        }
        guard let window, let row = superview else { return super.mouseDown(with: e) }
        isHighlighted = true
        defer { isHighlighted = false }
        var dragging = false, at = e.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            at = next.locationInWindow
            if next.type == .leftMouseUp { break }
            guard dragging || abs(at.x - e.locationInWindow.x) > 3 else { continue }
            dragging = true
            isHighlighted = false
            moved?(row.convert(at, from: nil).x)
        }
        if dragging {
            dropped?()
        } else if bounds.contains(convert(at, from: nil)) {
            pressBounce()
            sendAction(action, to: target)
        }
    }
}

/// A panel's mark on its icon (`PanelBadge`): a grey capsule with the number, or a dot; red for a failure.
final class CountBadge: NSView {
    var badge: PanelBadge? {
        didSet {
            guard badge != oldValue else { return }
            isHidden = badge == nil
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    private var text: NSAttributedString? {
        guard let count = badge?.count, count > 0 else { return nil }
        return NSAttributedString(
            string: count > 99 ? "99+" : "\(count)",
            attributes: [.font: NSFont.uiDigits(10, weight: .semibold), .foregroundColor: NSColor.white])
    }
    init() {
        super.init(frame: .zero)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize {
        guard let label = text else { return NSSize(width: 7, height: 14) }   // a dot, centred where the number's capsule would be
        return NSSize(width: max(14, ceil(label.size().width) + 7), height: 14)
    }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }   // clicks go to the icon
    override func draw(_ r: NSRect) {
        (badge?.alert == true ? NSColor.systemRed : NSColor.systemGray).setFill()
        guard let label = text else { return NSBezierPath(ovalIn: NSRect(x: 0, y: 3, width: 7, height: 7)).fill() }
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let size = label.size()
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

/// SwiftUI panel in an AppKit host.
@MainActor
func hosting<V: View>(_ v: V) -> NSViewController {
    // Filling the panel from the top: content shorter than the panel would otherwise float in its middle.
    let host = NSHostingController(rootView: v.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
    host.sizingOptions = []   // a panel fills the space it's given; it must never resize the window to its ideal size
    return host
}
