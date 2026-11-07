import AppKit
import Core
import DesignKit
import KelpKit

extension CIRuns.Run {
    /// How long it took, in the words its state needs: "6m 42s", "3m 12s of ~15m", "queued 1m 20s". `usual`: what this
    /// workflow takes, which says "about", not a countdown: green runs of one project differ by a factor of four.
    /// Nil: the forge didn't say.
    func timeWords(usual: Double?) -> String? {
        guard let s = seconds() else { return nil }
        let span = ciSpan(s)
        switch (status, conclusion) {
        case ("completed", "cancelled"?): return String(localized: "cancelled \(span)")
        case ("completed", _): return span
        case ("in_progress", _): return usual.map { String(localized: "\(span) of ~\(shortSpan($0))") } ?? span
        case ("waiting", _): return String(localized: "waiting \(span)")
        default: return String(localized: "queued \(span)")
        }
    }
}

/// "6m 42s", "1h 31m": two parts at most, the way Kelp says a span.
func ciSpan(_ seconds: Double) -> String { shortSpan(seconds, units: 2, smallest: .second) }

/// What's still going counts up on screen, without asking the forge: seconds pass by themselves, from when it began. Runs only
/// while the panel shows, for labels still in a window.
@MainActor
final class CIClock {
    private struct Hand {
        weak var label: NSTextField?
        let text: @MainActor () -> String?
    }
    private var hands: [Hand] = [], timer: Timer?

    func follow(_ label: NSTextField, _ text: @escaping @MainActor () -> String?) {
        hands.append(Hand(label: label, text: text))
        start()
    }

    func start() {
        guard timer == nil, !hands.isEmpty else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }   // a timer on the main run loop calls back on the main thread
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func clear() { hands = [] }

    private func tick() {
        hands.removeAll { $0.label?.window == nil }
        for h in hands { if let t = h.text() { h.label?.stringValue = t } }
        if hands.isEmpty { stop() }
    }
}

/// A run's second line. What the run is sits on the left and gives way first; how long and when stand in their own columns on
/// the right, the length a shade brighter, so a list of runs reads down its edge.
@MainActor
final class CIRunMeta: NSView {
    /// "When" keeps its width, so the lengths beside it stand in a column. Under `narrow`, the attempt shrinks to "↻ 2".
    private static let whenColumn: CGFloat = 26, narrow: CGFloat = 216
    private let attempt: AttemptChip?

    /// `extras`: what tells this run from its neighbours, after the number and commit (its workflow, its event).
    init(_ r: CIRuns.Run, extras: [String], usual: Double?, clock: CIClock) {
        attempt = r.attempt.flatMap { $0 > 1 ? AttemptChip($0) : nil }
        super.init(frame: .zero)
        let who = NSTextField(labelWithAttributedString: Self.who(r, extras))
        who.maximumNumberOfLines = 1
        who.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        who.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let time = NSTextField(labelWithString: r.timeWords(usual: usual) ?? "")
        if !r.finished { clock.follow(time) { r.timeWords(usual: usual) } }
        time.font = .uiDigits(11)
        time.textColor = .labelColor
        // A run still going has no "when" yet: its time is now.
        let ago = NSTextField(labelWithString: r.finished ? CIRunLook.ago(r.began) : "")
        ago.font = .uiDigits(11)
        ago.textColor = .secondaryLabelColor
        ago.alignment = .right
        ago.widthAnchor.constraint(greaterThanOrEqualToConstant: TextSize.of(Self.whenColumn)).isActive = true
        let line = NSStackView(views: [who] + (attempt.map { [$0] } ?? []) + [NSView(), time, ago])
        line.spacing = Metrics.gapWide
        line.setCustomSpacing(Metrics.gap, after: who)
        for v in [time, ago] as [NSView] { v.setContentCompressionResistancePriority(.required, for: .horizontal) }
        pin(line)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        attempt?.compact = bounds.width < TextSize.of(Self.narrow)   // the time stays whole
    }

    /// "#67 2f2111f", the commit in the face of code.
    private static func who(_ r: CIRuns.Run, _ extras: [String]) -> NSAttributedString {
        let one = NSMutableParagraphStyle()
        one.lineBreakMode = .byTruncatingTail
        let look: [NSAttributedString.Key: Any] = [
            .font: NSFont.uiDigits(11), .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: one
        ]
        let s = NSMutableAttributedString()
        if let n = r.number { s.append(NSAttributedString(string: "#\(n)", attributes: look)) }
        if let sha = r.shortSHA {
            s.append(NSAttributedString(string: s.length > 0 ? " " : "", attributes: look))
            s.append(NSAttributedString(string: sha, attributes: look.merging([.font: NSFont.uiMono(11)]) { $1 }))
        }
        if !extras.isEmpty {
            s.append(
                NSAttributedString(
                    string: (s.length > 0 ? " · " : "") + extras.joined(separator: " · "), attributes: look))
        }
        return s
    }
}

/// The panel's rows of one line.
@MainActor
enum CIRow {
    /// "8 steps passed  2m 04s": a chevron opens them.
    static func fold(_ f: CIRuns.StepRow) -> NSView {
        let n = f.steps.count
        switch f {
        case .passed:
            let seconds = f.steps.compactMap { $0.seconds() }.reduce(0, +),
                done = String(localized: "\(n) steps passed")
            return line(
                CIRunLook.mark("completed", "success"), done, font: .ui(11), color: .secondaryLabelColor,
                right: ciSpan(seconds)
            ).cell
        case .skipped:
            let skipped = String(localized: "\(n) steps skipped")
            return line(
                CIRunLook.mark("completed", "skipped"), skipped, font: .ui(11), color: .tertiaryLabelColor, right: nil
            ).cell
        case .upcoming, .one:
            let left = String(localized: "\(n) steps to go")
            return line(CIRunLook.mark("queued", nil), left, font: .ui(11), color: .tertiaryLabelColor, right: nil).cell
        }
    }

    /// Mark, name, and on the right a number, whose label comes back for what counts up.
    static func line(_ mark: NSView, _ name: String, font: NSFont, color: NSColor, right: String?) -> (
        cell: NSView, time: NSTextField?
    ) {
        let t = NSTextField(labelWithString: name)
        t.font = font
        t.textColor = color
        t.lineBreakMode = .byTruncatingTail
        t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        guard let right else { return (row([mark, t]), nil) }
        let n = NSTextField(labelWithString: right)
        n.font = .uiDigits(11)
        n.textColor = .secondaryLabelColor
        return (row([mark, t, NSView(), n]), n)
    }

    static func row(_ views: [NSView]) -> NSView {
        let r = NSStackView(views: views)
        r.spacing = 6
        r.alignment = .centerY
        let cell = NSTableCellView()
        r.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(r)
        NSLayoutConstraint.activate([
            r.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            r.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            r.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}

/// "attempt 2": only from the second try on.
@MainActor
private final class AttemptChip: PointerControl {
    private let label = NSTextField(labelWithString: "")
    private let n: Int
    var compact = false { didSet { if compact != oldValue { show() } } }

    init(_ n: Int) {
        self.n = n
        super.init(frame: .zero)
        restFill = .fillHover
        layer?.cornerRadius = Metrics.radiusXS
        isEnabled = false
        toolTip = String(localized: "Attempt \(n) of this run")
        label.font = .ui(10, weight: .medium)
        label.textColor = .secondaryLabelColor
        pin(label, inset: NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4))
        setContentCompressionResistancePriority(.required, for: .horizontal)
        show()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }

    private func show() { label.stringValue = compact ? "↻ \(n)" : String(localized: "attempt \(n)") }
}
