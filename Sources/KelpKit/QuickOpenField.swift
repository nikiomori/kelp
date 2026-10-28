import AppKit
import DesignKit

/// The palette's field: in ⇧⌘P it starts with a "Commands ›" token (`scope`), what's typed after it, so the two
/// palettes tell apart at a glance.
@MainActor
final class PaletteField: NSSearchField {
    override static var cellClass: AnyClass? { get { Cell.self } set {} }
    private let token = Token()

    /// The token's word; nil: none.
    var scope: String? {
        didSet {
            guard scope != oldValue else { return }
            token.text = (scope ?? "") + " ›"
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

    /// A word on a faint purple capsule.
    private final class Token: NSView {
        var text = "" { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
        private var words: NSAttributedString {
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.textPurple])
        }
        override var intrinsicContentSize: NSSize { NSSize(width: ceil(words.size().width) + 14, height: 20) }
        override func draw(_ r: NSRect) {
            NSColor.systemPurple.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
            let s = words.size()
            words.draw(at: NSPoint(x: 7, y: ((bounds.height - s.height) / 2).rounded()))
        }
    }
}
