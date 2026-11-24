import AppKit
import DesignKit

/// One count in the row above the projects ("2 working · 12m"). It is a button that goes to the next chat it counts,
/// and under the pointer it shows those chats (`SummaryCard`) and lights their rows. Its words shorten as room runs out
/// (`level`). For a few seconds after a chat gets into the count, it names that chat instead (`peek`).
@MainActor
final class SummarySegment: PointerControl {
    let kind: SummaryKind
    private let mark = StatusMark(size: 12)
    private let label = NSTextField(labelWithString: "")
    /// The word after a peek's name, such as "done". It stays whole while the name gives way.
    private let verb = NSTextField(labelWithString: "")
    private var words = [""]
    /// The number the words start with, as shown (nil while it peeks). A new number rolls in.
    private var counted: Int?
    /// How much to shorten the text: 0 keeps all of it, 1 leaves out the time, and 2 keeps only the number (or the
    /// clock).
    var level = 0 { didSet { if level != oldValue { show() } } }
    /// The chat that just got into the count, named for a moment: its name and what it did ("fix flaky test", "done").
    var peek: (name: String, verb: String)? {
        didSet { if peek?.name != oldValue?.name || peek?.verb != oldValue?.verb { show() } }
    }
    /// The room a long name has, so it ends in "…" rather than pushing Add Project away.
    private lazy var widest: NSLayoutConstraint = {
        let constraint = widthAnchor.constraint(lessThanOrEqualToConstant: 0)
        constraint.isActive = false
        return constraint
    }()
    private lazy var height = heightAnchor.constraint(equalToConstant: TextSize.of(22))
    var press: () -> Void = {}
    var hover: (Bool) -> Void = { _ in }

    init(_ kind: SummaryKind) {
        self.kind = kind
        super.init(frame: .zero)
        mark.status = kind == .working || kind == .quiet ? .working : .done
        mark.limited = kind == .limit
        mark.announces = false
        label.font = .uiDigits(TextSize.caption)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        verb.textColor = .secondaryLabelColor
        verb.setContentCompressionResistancePriority(.required, for: .horizontal)
        let content = NSStackView(views: [mark, label, verb])
        content.detachesHiddenViews = true
        content.spacing = Metrics.gap
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            height,
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.gap),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.gap),
            content.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Sets the sizes that follow Text size: the plate's height and rounding and the words' fonts.
    func restyle() {
        height.constant = TextSize.of(22)
        layer?.cornerRadius = TextSize.of(22) / 2
        verb.font = .ui(TextSize.caption)
        show()
    }

    func say(_ words: [String]) {
        self.words = words.isEmpty ? [""] : words
        show()
    }

    /// The segment's width at `level` (with a peeked name whole), so the row can pick what fits.
    func width(at level: Int) -> CGFloat {
        func wide(_ text: String, _ font: NSFont) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
        }
        let named = peek.map {
            wide($0.name, .ui(TextSize.caption, weight: .semibold)) + Metrics.gap + wide($0.verb, .ui(TextSize.caption))
        }
        let text = named ?? wide(words[min(level, words.count - 1)], .uiDigits(TextSize.caption))
        return 2 * Metrics.gap + 12 + Metrics.gap + text
    }

    /// Keeps the segment at most `room` wide, for a peek's long name. With nil it is as wide as its words.
    func fit(within room: CGFloat?) {
        widest.constant = room ?? 0
        widest.isActive = room != nil
    }

    private func show() {
        let text = peek?.name ?? words[min(level, words.count - 1)]
        let number = peek == nil ? Int(text.prefix { $0.isNumber }) : nil
        if let old = counted, let number, old != number { label.roll(up: number > old) }
        counted = number
        label.stringValue = text
        verb.stringValue = peek?.verb ?? ""
        verb.isHidden = peek == nil
        // A named chat is news, so it has the weight of news (600), and no plate: a fill would read as a button held.
        label.font = peek == nil ? .uiDigits(TextSize.caption) : .ui(TextSize.caption, weight: .semibold)
        label.textColor = peek == nil ? .secondaryLabelColor : .labelColor
        let said = peek.map { "\($0.name) \($0.verb)" } ?? words[0]
        setAccessibilityLabel(String(localized: "\(said). Show the next one."))
    }

    /// Glows briefly when a chat just got into the count, as the capsule glows for a new question. A finished chat
    /// doesn't: done is the quiet state, said by its name's weight alone.
    func flash() {
        guard !Motion.reduced, kind != .done else { return }
        alphaValue = 0.4
        NSAnimationContext.runAnimationGroup {
            $0.duration = Motion.flash
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
