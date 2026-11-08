import AppKit

/// ⌘F over a terminal or a diff: floats in the top corner (what's under it doesn't move, so an agent's screen doesn't
/// reflow). Matches as you type; ↩ / ⇧↩ or ⌘G / ⇧⌘G step through them, Esc closes. The owner searches (`onSearch`) and
/// says what it found (`total`, `selected`).
@MainActor
public final class FindCard: NSView, NSSearchFieldDelegate {
    public let field = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    private lazy var steps = NSSegmentedControl.steps(
        previous: String(localized: "Previous Match (⇧⌘G)"), next: String(localized: "Next Match (⌘G)"),
        target: self, action: #selector(stepped))
    public var onSearch: ((String) -> Void)?
    public var onStep: ((_ next: Bool) -> Void)?
    public var onClose: (() -> Void)?
    private var pending: DispatchWorkItem?
    /// From the owner; -1 while it's still counting.
    public var total = -1 { didSet { updateCount() } }
    public var selected = -1 { didSet { updateCount() } }

    public init() {
        super.init(frame: .zero)
        field.placeholderString = String(localized: "Find")
        field.delegate = self
        field.controlSize = .small
        field.font = .ui(12)
        field.sendsSearchStringImmediately = true
        field.focusRingType = .none
        count.font = .uiDigits(11)
        count.textColor = .secondaryLabelColor
        let done = NSButton(title: String(localized: "Done"), target: self, action: #selector(close))
        done.controlSize = .small
        done.bezelStyle = .push
        let row = NSStackView(views: [field, count, steps, done])
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
        let card = FloatingCard(row, radius: Metrics.radiusMD)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor), card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.widthAnchor.constraint(equalToConstant: 190)
        ])
        count.setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    public func begin(_ needle: String?) {
        isHidden = false
        if let needle, !needle.isEmpty, needle != field.stringValue {
            field.stringValue = needle
            search()
        }
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func updateCount() {
        count.stringValue =
            field.stringValue.isEmpty
            ? ""
            : total == 0
                ? String(localized: "No matches")
                : total < 0
                    ? ""
                    : selected >= 0
                        ? String(localized: "\(selected + 1) of \(total)") : String(localized: "\(total) found")
        steps.isEnabled = total != 0
    }

    // One or two letters match half the scrollback: wait for a pause before searching for them.
    public func controlTextDidChange(_ notification: Notification) {
        pending?.cancel()
        guard field.stringValue.count < 3, !field.stringValue.isEmpty else {
            search()
            return
        }
        // on the main queue below
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.search() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
    private func search() {
        total = -1
        selected = -1
        onSearch?(field.stringValue)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(insertNewline(_:)):
            onStep?(!(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
            return true
        case #selector(cancelOperation(_:)):
            close()
            return true
        default: return false
        }
    }

    /// ⌘G / ⇧⌘G while typing (the field editor would swallow them otherwise).
    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !isHidden, let forward = event.findStep, (window?.firstResponder as? NSText)?.delegate === field
        else { return super.performKeyEquivalent(with: event) }
        onStep?(forward)
        return true
    }

    @objc private func stepped() { onStep?(steps.selectedSegment == 1) }
    @objc public func close() {
        pending?.cancel()
        isHidden = true
        onClose?()
    }
}

extension NSEvent {
    /// ⌘G → forward, ⇧⌘G → back, anything else nil. By key code, as a Russian layout sends another letter.
    public var findStep: Bool? {
        let mods = modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard type == .keyDown, keyCode == 5, mods.subtracting(.shift) == .command else { return nil }
        return !mods.contains(.shift)
    }
}
