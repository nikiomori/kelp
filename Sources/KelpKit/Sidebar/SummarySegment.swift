import AppKit
import DesignKit

/// One count in the row over the projects ("2 working · 12m"): a button that goes to the next chat it counts, and under
/// the pointer shows them (`SummaryCard`) and lights their rows. Its words shorten as room runs out (`level`); for a
/// few seconds after a chat gets here it names that chat instead (`peek`).
@MainActor
final class SummarySegment: PointerControl {
    let kind: SummaryKind
    private let mark = StatusMark(size: 12)
    private let label = NSTextField(labelWithString: "")
    /// After a peek's name, kept whole while the name gives way: "done".
    private let verb = NSTextField(labelWithString: "")
    private var words = [""]
    /// 0: all it says; 1: without the time; 2: the number (or the clock) alone.
    var level = 0 { didSet { if level != oldValue { show() } } }
    /// The chat that just got here, named for a moment: its name and what it did ("fix flaky test", "done").
    var peek: (name: String, verb: String)? {
        didSet { if peek?.name != oldValue?.name || peek?.verb != oldValue?.verb { show() } }
    }
    /// The room a long name has, so it ends in "…" rather than pushing Add Project away.
    private lazy var widest: NSLayoutConstraint = {
        let constraint = widthAnchor.constraint(lessThanOrEqualToConstant: 0)
        constraint.isActive = false
        return constraint
    }()
    var press: () -> Void = {}
    var hover: (Bool) -> Void = { _ in }

    init(_ kind: SummaryKind) {
        self.kind = kind
        super.init(frame: .zero)
        layer?.cornerRadius = TextSize.of(20) / 2
        mark.status = kind == .working || kind == .quiet ? .working : .done
        mark.limited = kind == .limit
        mark.announces = false
        label.font = .uiDigits(TextSize.caption)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        verb.font = .ui(TextSize.caption)
        verb.textColor = .secondaryLabelColor
        verb.setContentCompressionResistancePriority(.required, for: .horizontal)
        let content = NSStackView(views: [mark, label, verb])
        content.setCustomSpacing(3, after: label)
        content.detachesHiddenViews = true
        content.spacing = 4
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: TextSize.of(20)),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.gap),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.gap),
            content.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    func say(_ words: [String]) {
        self.words = words.isEmpty ? [""] : words
        show()
    }

    /// Its width at `level` (the name it peeks at, whole), for the row to pick what fits.
    func width(at level: Int) -> CGFloat {
        func wide(_ text: String, _ font: NSFont) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
        }
        let named = peek.map {
            wide($0.name, .ui(TextSize.caption, weight: .medium)) + 3 + wide($0.verb, .ui(TextSize.caption))
        }
        let text = named ?? wide(words[min(level, words.count - 1)], .uiDigits(TextSize.caption))
        return 2 * Metrics.gap + 12 + 4 + text
    }

    /// At most this wide (a peek's long name); nil: as wide as its words.
    func fit(within room: CGFloat?) {
        widest.constant = room ?? 0
        widest.isActive = room != nil
    }

    private func show() {
        label.stringValue = peek?.name ?? words[min(level, words.count - 1)]
        verb.stringValue = peek?.verb ?? ""
        verb.isHidden = peek == nil
        label.font = peek == nil ? .uiDigits(TextSize.caption) : .ui(TextSize.caption, weight: .medium)
        label.textColor = peek == nil ? .secondaryLabelColor : .labelColor
        restFill = peek == nil ? nil : .fillHover
        let said = peek.map { "\($0.name) \($0.verb)" } ?? words[0]
        setAccessibilityLabel(String(localized: "\(said). Show the next one."))
    }

    /// A chat just got here: a brief glow, as the capsule's for a new question.
    func flash() {
        guard !Motion.reduced else { return }
        alphaValue = 0.4
        NSAnimationContext.runAnimationGroup {
            $0.duration = Motion.appear
            animator().alphaValue = 1
        }
    }

    override func clicked() { press() }
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        hover(true)
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hover(false)
    }
}
