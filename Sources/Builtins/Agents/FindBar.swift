import AppKit
import DesignKit
import KelpKit

/// ⌘F over a terminal: floats in the top corner (the terminal doesn't resize, so an agent's screen doesn't reflow).
/// Matches as you type; ↩ / ⇧↩ or ⌘G / ⇧⌘G step through them, Esc closes.
@MainActor
final class FindBar: NSView, NSSearchFieldDelegate {
    let field = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    private lazy var steps = NSSegmentedControl.steps(previous: String(localized: "Previous Match (⇧⌘G)"), next: String(localized: "Next Match (⌘G)"),
                                                      target: self, action: #selector(stepped))
    var onSearch: ((String) -> Void)?
    var onStep: ((_ next: Bool) -> Void)?
    var onClose: (() -> Void)?
    private let pending = Debounce()
    /// From the terminal; -1 while it's still counting.
    var total = -1 { didSet { updateCount() } }
    var selected = -1 { didSet { updateCount() } }

    init() {
        super.init(frame: .zero)
        field.placeholderString = String(localized: "Find")
        field.delegate = self
        field.controlSize = .small
        field.font = .ui(12)
        field.sendsSearchStringImmediately = true; field.focusRingType = .none
        count.font = .uiDigits(11); count.textColor = .secondaryLabelColor
        let done = NSButton(title: String(localized: "Done"), target: self, action: #selector(close))
        done.controlSize = .small
        done.bezelStyle = .push
        let row = NSStackView(views: [field, count, steps, done]); row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
        pin(FloatingCard(row, radius: Metrics.radiusMD)); field.widthAnchor.constraint(equalToConstant: 190).isActive = true
        count.setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    func begin(_ needle: String?) {
        isHidden = false
        if let needle, !needle.isEmpty, needle != field.stringValue { field.stringValue = needle; search() }
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func updateCount() {
        count.stringValue = field.stringValue.isEmpty ? "" : total == 0 ? String(localized: "No matches")
            : total < 0 ? "" : selected >= 0 ? String(localized: "\(selected + 1) of \(total)") : String(localized: "\(total) found")
        steps.isEnabled = total != 0
    }

    // One or two letters match half the scrollback: wait for a pause before searching for them.
    func controlTextDidChange(_ n: Notification) {
        pending.cancel()
        guard field.stringValue.count < 3, !field.stringValue.isEmpty else { search(); return }
        pending.after(0.3) { [weak self] in self?.search() }
    }
    private func search() {
        total = -1
        selected = -1
        onSearch?(field.stringValue)
    }

    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(insertNewline(_:)): onStep?(!(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)); return true
        case #selector(cancelOperation(_:)): close(); return true
        default: return false
        }
    }

    /// ⌘G / ⇧⌘G while typing (the field editor would swallow them otherwise).
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard !isHidden, e.modifierFlags.contains(.command), e.charactersIgnoringModifiers?.lowercased() == "g",
              (window?.firstResponder as? NSText)?.delegate === field else { return super.performKeyEquivalent(with: e) }
        onStep?(!e.modifierFlags.contains(.shift)); return true
    }

    @objc private func stepped() { onStep?(steps.selectedSegment == 1) }
    @objc func close() {
        pending.cancel()
        isHidden = true
        onClose?()
    }
}
