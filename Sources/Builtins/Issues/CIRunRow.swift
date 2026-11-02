import AppKit
import Core
import DesignKit
import KelpKit

extension CIRuns.Run {
    /// How long it took, in the words its state needs: "6m 42s", "queued 1m 20s". Nil: the forge didn't say.
    var timeWords: String? {
        guard let s = seconds() else { return nil }
        let span = ciSpan(s)
        switch (status, conclusion) {
        case ("completed", "cancelled"?): return String(localized: "cancelled \(span)")
        case ("completed", _), ("in_progress", _): return span
        case ("waiting", _): return String(localized: "waiting \(span)")
        default: return String(localized: "queued \(span)")
        }
    }
}

/// "6m 42s", "1h 31m": two parts at most, the way Kelp says a span.
func ciSpan(_ seconds: Double) -> String { shortSpan(seconds, units: 2, smallest: .second) }

/// A run's second line. What the run is sits on the left and gives way first; how long and when stand in their own columns on
/// the right, the length a shade brighter, so a list of runs reads down its edge.
@MainActor
final class CIRunMeta: NSView {
    /// "When" keeps its width, so the lengths beside it stand in a column. Under `narrow`, the attempt shrinks to "↻ 2".
    private static let whenColumn: CGFloat = 26, narrow: CGFloat = 216
    private let attempt: AttemptChip?

    /// `extras`: what tells this run from its neighbours, after the number and commit (its workflow, its event).
    init(_ r: CIRuns.Run, extras: [String]) {
        attempt = r.attempt.flatMap { $0 > 1 ? AttemptChip($0) : nil }
        super.init(frame: .zero)
        let who = NSTextField(labelWithAttributedString: Self.who(r, extras))
        who.maximumNumberOfLines = 1
        who.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        who.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let time = NSTextField(labelWithString: r.timeWords ?? "")
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
        let look: [NSAttributedString.Key: Any] = [.font: NSFont.uiDigits(11), .foregroundColor: NSColor.secondaryLabelColor,
                                                   .paragraphStyle: one]
        let s = NSMutableAttributedString()
        if let n = r.number { s.append(NSAttributedString(string: "#\(n)", attributes: look)) }
        if let sha = r.shortSHA {
            s.append(NSAttributedString(string: s.length > 0 ? " " : "", attributes: look))
            s.append(NSAttributedString(string: sha, attributes: look.merging([.font: NSFont.uiMono(11)]) { $1 }))
        }
        if !extras.isEmpty { s.append(NSAttributedString(string: (s.length > 0 ? " · " : "") + extras.joined(separator: " · "), attributes: look)) }
        return s
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
