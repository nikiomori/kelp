import AppKit

/// ⌘F over a terminal, a diff or code: floats in the top corner (what's under it doesn't move, so an agent's screen
/// doesn't reflow). Matches as you type; ↩ / ⇧↩ or ⌘G / ⇧⌘G step through them, Esc closes. The owner searches
/// (`onSearch`) and says what it found (`total`, `selected`, or `show(count:canStep:)`); its own controls go in the slots
/// (`leading`, `trailing` beside the field, `below` it: the editor's options and its Replace row).
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
    /// ⌥↩ in the field (the editor: a cursor on every match); unset, ⌥↩ steps as ↩ does.
    public var onSelectAll: (() -> Void)?
    /// The field's width: a Replace field below matches it.
    public static let fieldWidth: CGFloat = 190
    private var pending: DispatchWorkItem?
    /// From the owner; -1 while it's still counting.
    public var total = -1 { didSet { updateCount() } }
    public var selected = -1 { didSet { updateCount() } }

    public init(leading: [NSView] = [], trailing: [NSView] = [], below: NSView? = nil) {
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
        let row = NSStackView(views: leading + [field, count] + trailing + [steps, done])
        row.spacing = Metrics.gap
        let rows = NSStackView(views: [row] + (below.map { [$0] } ?? []))
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = Metrics.gap
        rows.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
        let card = FloatingCard(rows, radius: Metrics.radiusMD)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor), card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.widthAnchor.constraint(equalToConstant: Self.fieldWidth)
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

    /// What an owner that counts its own way found: "2 of 7+", "Not a valid pattern".
    public func show(count text: String, canStep: Bool) {
        count.stringValue = text
        steps.isEnabled = canStep
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
            let mods = NSApp.currentEvent?.modifierFlags ?? []
            if mods.contains(.option), let onSelectAll { onSelectAll() } else { onStep?(!mods.contains(.shift)) }
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
