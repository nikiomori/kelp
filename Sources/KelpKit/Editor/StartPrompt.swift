import AppKit
import DesignKit

/// The empty workspace's field for the first task: it grows with the text up to six lines and then scrolls, ↩ starts the
/// agent and ⇧↩ goes to a new line.
@MainActor
final class StartPrompt: NSView, NSTextViewDelegate {
    private static let mostLines: CGFloat = 6
    private let text = Text(usingTextLayoutManager: false)   // TextKit 1: on macOS 26 a default one leaves `usedRect` empty
    private let scroll = NSScrollView()
    private let hint = NSTextField(labelWithString: "")
    private lazy var height = scroll.heightAnchor.constraint(equalToConstant: 20)
    var onReturn: ((String) -> Void)?
    /// What's typed, as it changes.
    var onChange: ((String) -> Void)?

    var value: String {
        get { text.string }
        set {
            text.string = newValue
            changed()
        }
    }

    init(placeholder: String, accessibilityLabel: String) {
        super.init(frame: .zero)
        let font = NSFont.ui(14)
        text.font = font
        text.isRichText = false
        text.allowsUndo = true
        text.drawsBackground = false
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.delegate = self
        text.setAccessibilityLabel(accessibilityLabel)
        scroll.documentView = text
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        hint.stringValue = placeholder
        hint.font = font
        hint.textColor = .placeholderTextColor
        hint.lineBreakMode = .byTruncatingTail
        pin(scroll)
        hint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hint)
        NSLayoutConstraint.activate([
            height, hint.leadingAnchor.constraint(equalTo: leadingAnchor), hint.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            hint.topAnchor.constraint(equalTo: topAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// The text's width said outright: left to follow the view, its container can stay at the zero it was made with, and
    /// then every character takes a row.
    override func layout() {
        super.layout()
        text.frame.size.width = bounds.width
        text.textContainer?.size = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)
        fit()
    }

    /// The caret at the end, after what's there.
    func focus() {
        window?.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
    }

    func textDidChange(_ notification: Notification) { changed() }

    private func changed() {
        hint.isHidden = !text.string.isEmpty
        onChange?(text.string)
        fit()
    }

    private func fit() {
        guard let lm = text.layoutManager, let tc = text.textContainer, let font = text.font else { return }
        lm.ensureLayout(for: tc)
        let line = lm.defaultLineHeight(for: font), rows = text.string.utf16.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
        let used = max(lm.usedRect(for: tc).height, CGFloat(rows) * line)   // the lines typed, however it's laid out
        height.constant = min(ceil(used), ceil(line * Self.mostLines))
    }

    func textView(_ view: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard sel == #selector(NSResponder.insertNewline(_:)) else { return false }
        if text.shiftHeld { view.insertNewlineIgnoringFieldEditor(nil) } else { onReturn?(view.string) }
        return true
    }

    /// Return and ⇧Return reach the delegate as one command: the key says which.
    private final class Text: NSTextView {
        var shiftHeld = false
        override func keyDown(with event: NSEvent) {
            shiftHeld = event.modifierFlags.contains(.shift)
            super.keyDown(with: event)
        }
    }
}
