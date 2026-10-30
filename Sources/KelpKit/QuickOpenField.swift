import AppKit
import DesignKit

/// The palette's field, the top of the panel as Spotlight's is (no box of its own): in ⇧⌘P it starts with a purple
/// "Commands" capsule (`scope`), what's typed after it, so the two palettes — alike otherwise — tell apart at a glance.
@MainActor
final class PaletteField: NSSearchField {
    override static var cellClass: AnyClass? { get { Cell.self } set {} }
    private let token = Token()

    /// The token's word; nil: none.
    var scope: String? {
        didSet {
            guard scope != oldValue else { return }
            token.text = scope ?? ""
            token.isHidden = scope == nil
            (cell as? Cell)?.leading = scope == nil ? 0 : token.intrinsicContentSize.width + 6
            needsLayout = true
            // The open editor keeps the old text frame: open it again where the text starts now, the caret at the end.
            guard currentEditor() != nil else { return }
            window?.makeFirstResponder(nil)
            window?.makeFirstResponder(self)
            currentEditor()?.selectedRange = NSRange(location: (stringValue as NSString).length, length: 0)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBezeled = false
        isBordered = false
        drawsBackground = false
        token.isHidden = true
        token.setAccessibilityElement(false)   // the field's label says "Commands"
        addSubview(token)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard let c = cell as? Cell else { return }
        let after = c.searchButtonRect(forBounds: bounds).maxX + 2, size = token.intrinsicContentSize
        token.frame = NSRect(x: after, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
    }

    /// Its text starts after the token.
    final class Cell: NSSearchFieldCell {
        var leading: CGFloat = 0
        override func drawingRect(forBounds r: NSRect) -> NSRect {   // the placeholder's and the editor's frame
            var t = super.drawingRect(forBounds: r)
            t.origin.x += leading
            t.size.width -= leading
            return t
        }
    }

    /// A word on a faint purple capsule: the one colour in the palette, for the palette you're in.
    private final class Token: NSView {
        var text = "" { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
        private var words: NSAttributedString {
            NSAttributedString(string: text, attributes: [.font: NSFont.ui(13, weight: .medium), .foregroundColor: NSColor.textPurple])
        }
        override var intrinsicContentSize: NSSize { NSSize(width: ceil(words.size().width) + 20, height: 24) }
        override func draw(_ r: NSRect) {
            NSColor.systemPurple.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
            let s = words.size()
            words.draw(at: NSPoint(x: 10, y: ((bounds.height - s.height) / 2).rounded()))
        }
    }
}

/// The palette's list: its rows are `PaletteRowView`s. Asked of the table (NSTableView loads a row view by
/// `rowViewIdentifier` when its delegate doesn't give one), not of the delegate: that method would be one more of the
/// shell's `package` declarations.
@MainActor
final class PaletteTable: NSTableView {
    override func makeView(withIdentifier id: NSUserInterfaceItemIdentifier, owner: Any?) -> NSView? {
        id == NSTableView.rowViewIdentifier ? PaletteRowView() : super.makeView(withIdentifier: id, owner: owner)
    }
}

/// A palette row, as Spotlight's: the accent under the chosen one (the palette's list is chosen from even while the field
/// has the keyboard), the hover grey under the pointer, both on an 8 pt rounded rect inset from the sides.
@MainActor
final class PaletteRowView: NSTableRowView {
    private let hoverFill = CALayer()
    private var area: NSTrackingArea?
    private var hovering = false { didSet { if hovering != oldValue { showHover() } } }
    override var isEmphasized: Bool { get { true } set {} }
    override var isSelected: Bool { didSet { showHover() } }

    override func drawSelection(in r: NSRect) {
        NSColor.themeAccent.setFill()   // the selection colour turns grey in a panel that isn't key; Spotlight's stays blue
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: Metrics.radiusMD, yRadius: Metrics.radiusMD).fill()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }
    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }
    override func prepareForReuse() { super.prepareForReuse(); hovering = false }
    private func showHover() {
        wantsLayer = true
        if hoverFill.superlayer == nil {
            hoverFill.cornerRadius = Metrics.radiusMD
            hoverFill.cornerCurve = .continuous
            layer?.insertSublayer(hoverFill, at: 0)
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.duration(Motion.fast))
        hoverFill.frame = bounds.insetBy(dx: 2, dy: 1)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // A heading's row holds no PaletteCell: it chooses nothing, so it doesn't light up either.
            let item = subviews.contains { $0 is PaletteCell }
            hoverFill.backgroundColor = hovering && !isSelected && item ? NSColor.fillHover.cgColor : nil
        }
        CATransaction.commit()
    }
}

/// A palette row's content: on the accent its words and glyphs turn light, as a menu's do (the row says when).
@MainActor
final class PaletteCell: NSTableCellView {
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { apply(backgroundStyle, in: self) }
    }
    private func apply(_ style: NSView.BackgroundStyle, in v: NSView) {
        for sub in v.subviews {
            (sub as? NSControl)?.cell?.backgroundStyle = style
            if let i = sub as? NSImageView, i.image?.isTemplate == true {
                i.contentTintColor = style == .emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
            }
            apply(style, in: sub)
        }
    }
}

/// The keys a palette knows, under its list, each key on a small cap: "↩ Run    ⌫ Everything". Given as one line,
/// segments four spaces apart, the key before the first space of each (so a translation keeps the shape).
@MainActor
final class Keycaps: NSStackView {
    var stringValue = "" { didSet { if stringValue != oldValue { rebuild() } } }

    private func rebuild() {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        spacing = 14
        for segment in stringValue.components(separatedBy: "    ") where !segment.isEmpty {
            let parts = segment.split(separator: " ", maxSplits: 1).map(String.init)
            let cap = NSTextField(labelWithString: parts[0])
            cap.font = .ui(10, weight: .medium)
            cap.textColor = .secondaryLabelColor
            cap.alignment = .center
            let capBox = NSStackView(views: [cap])
            capBox.edgeInsets = NSEdgeInsets(top: 1, left: 5, bottom: 1, right: 5)
            capBox.wantsLayer = true
            capBox.layer?.cornerRadius = Metrics.radiusXS
            effectiveAppearance.performAsCurrentDrawingAppearance { capBox.layer?.backgroundColor = NSColor.fillSelected.cgColor }
            let word = NSTextField(labelWithString: parts.count > 1 ? parts[1] : "")
            word.font = .ui(11)
            word.textColor = .secondaryLabelColor
            let pair = NSStackView(views: [capBox, word])
            pair.spacing = 5
            addArrangedSubview(pair)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(stringValue)
    }
}
