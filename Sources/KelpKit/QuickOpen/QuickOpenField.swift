import AppKit
import DesignKit

/// The palette's field, at the top of the panel as in Spotlight (with no box of its own). In ⇧⌘P it starts with a
/// purple "Commands" capsule (`scope`) followed by what is typed, so the two palettes, which look alike otherwise, can
/// be told apart at a glance.
@MainActor
final class PaletteField: NSSearchField {
    override static var cellClass: AnyClass? {
        get { Cell.self }
        set {}
    }
    private let token = Token()

    /// The word on the token, or nil for no token.
    var scope: String? {
        didSet {
            guard scope != oldValue else { return }
            token.text = scope ?? ""
            token.isHidden = scope == nil
            (cell as? Cell)?.leading = scope == nil ? 0 : token.intrinsicContentSize.width + 6
            needsLayout = true
            // The open editor keeps the old text frame, so open it again where the text starts now, with the caret at
            // the end.
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
        guard let searchCell = cell as? Cell else { return }
        let after = searchCell.searchButtonRect(forBounds: bounds).maxX + 2, size = token.intrinsicContentSize
        token.frame = NSRect(
            x: after, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
    }

    /// The field's cell, whose text starts after the token.
    final class Cell: NSSearchFieldCell {
        var leading: CGFloat = 0
        override func drawingRect(forBounds r: NSRect) -> NSRect {   // the placeholder's and the field editor's frame
            var rect = super.drawingRect(forBounds: r)
            rect.origin.x += leading
            rect.size.width -= leading
            return rect
        }
        // The editor goes where the search field's text is, after the magnifier. A field without a bezel got its whole
        // frame, so what was typed sat over the magnifier until a resize put it right.
        private func textRect(in controlView: NSView) -> NSRect {
            var rect = searchTextRect(forBounds: controlView.bounds)
            rect.origin.x += leading
            rect.size.width -= leading
            return rect
        }
        override func select(
            withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, start: Int, length: Int
        ) {
            super.select(
                withFrame: textRect(in: controlView), in: controlView, editor: editor,
                delegate: delegate, start: start, length: length)
        }
        override func edit(
            withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, event: NSEvent?
        ) {
            super.edit(
                withFrame: textRect(in: controlView), in: controlView, editor: editor,
                delegate: delegate, event: event)
        }
    }

    /// A word on a faint purple capsule. It is the one colour in the palette, and it says which palette you're in.
    private final class Token: NSView {
        var text = "" {
            didSet {
                invalidateIntrinsicContentSize()
                needsDisplay = true
            }
        }
        private var words: NSAttributedString {
            NSAttributedString(
                string: text,
                attributes: [.font: NSFont.ui(TextSize.body, weight: .medium), .foregroundColor: NSColor.textPurple])
        }
        override var intrinsicContentSize: NSSize { NSSize(width: ceil(words.size().width) + 20, height: 24) }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.fillTint(.systemPurple).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
            let size = words.size()
            words.draw(at: NSPoint(x: 10, y: ((bounds.height - size.height) / 2).rounded()))
        }
    }
}

/// The palette's list. Its rows look like Spotlight's: the accent under the chosen row (the list is chosen from even
/// while the field has the keyboard), and the hover grey under the pointer, both on an 8 pt rounded rect inset from
/// the sides. The row view comes from the table (NSTableView loads one by `rowViewIdentifier` when its delegate doesn't
/// give one), not from the delegate, because that method would be one more of the shell's `package` declarations.
@MainActor
final class PaletteTable: NSTableView {
    override func makeView(withIdentifier id: NSUserInterfaceItemIdentifier, owner: Any?) -> NSView? {
        guard id == NSTableView.rowViewIdentifier else { return super.makeView(withIdentifier: id, owner: owner) }
        // The selection colour turns grey in a panel that isn't key, but Spotlight's stays blue. A heading's row holds
        // no PaletteCell, because it chooses nothing, so it doesn't light up either.
        return ListRowView(inset: 2, radius: Metrics.radiusMD, selection: .themeAccent, tracking: .activeAlways) {
            $0.subviews.contains { $0 is PaletteCell }
        }
    }
}

/// A palette row's content. On the accent its words and glyphs turn light, as a menu's do (the row says when).
@MainActor
class PaletteCell: NSTableCellView {
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { apply(backgroundStyle, in: self) }
    }
    private func apply(_ style: NSView.BackgroundStyle, in view: NSView) {
        for sub in view.subviews {
            (sub as? NSControl)?.cell?.backgroundStyle = style
            if let image = sub as? NSImageView, image.image?.isTemplate == true {
                image.contentTintColor =
                    style == .emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
            }
            apply(style, in: sub)
        }
    }
}

/// The keys a palette knows, shown under its list with each key on a small cap: "↩ Run    ⌫ Everything". It is given
/// as one line, with segments four spaces apart and the key before the first space of each, so a translation keeps the
/// shape.
@MainActor
final class Keycaps: NSStackView {
    var stringValue = "" { didSet { if stringValue != oldValue { rebuild() } } }

    private func rebuild() {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        spacing = Metrics.inset
        for segment in stringValue.components(separatedBy: "    ") where !segment.isEmpty {
            let parts = segment.split(separator: " ", maxSplits: 1).map(String.init)
            let cap = NSTextField(labelWithString: parts[0])
            cap.font = .ui(TextSize.micro, weight: .medium)
            cap.textColor = .secondaryLabelColor
            cap.alignment = .center
            let capBox = NSStackView(views: [cap])
            capBox.edgeInsets = NSEdgeInsets(top: 1, left: 5, bottom: 1, right: 5)
            capBox.wantsLayer = true
            capBox.layer?.cornerRadius = Metrics.radiusXS
            effectiveAppearance.performAsCurrentDrawingAppearance {
                capBox.layer?.backgroundColor = NSColor.fillSelected.cgColor
            }
            let word = NSTextField(labelWithString: parts.count > 1 ? parts[1] : "")
            word.font = .ui(TextSize.caption)
            word.textColor = .secondaryLabelColor
            let pair = NSStackView(views: [capBox, word])
            pair.spacing = Metrics.gap
            addArrangedSubview(pair)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(stringValue)
    }
}
