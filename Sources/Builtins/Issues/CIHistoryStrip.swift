import AppKit
import Core
import DesignKit
import KelpKit

/// A workflow's latest runs in a line, newest on the right, in the colours of their marks: whether it broke just now or has
/// been red for a while, without reading the list. A mark goes to its run. Hidden with nothing to compare.
@MainActor
final class CIHistoryStrip: NSView {
    var onPick: ((CIRuns.Run) -> Void)?
    private let marks = NSStackView()
    private let words = NSTextField(labelWithString: "")
    private var height: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        marks.spacing = Metrics.lineGap
        words.font = .uiDigits(TextSize.caption)
        words.textColor = .secondaryLabelColor
        words.lineBreakMode = .byTruncatingTail
        words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let line = NSStackView(views: [marks, NSView(), words])
        line.spacing = Metrics.gapWide
        pin(line, inset: NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.inset))
        height = heightAnchor.constraint(equalToConstant: 0)
        height?.isActive = true
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ history: CIRuns.History?) {
        let tall = history == nil ? 0 : TextSize.of(Metrics.row)
        if tall != height?.constant {   // it opens, the runs under it moving down, not jumping
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = window == nil ? 0 : Motion.duration(Motion.base)
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                height?.animator().constant = tall
                superview?.layoutSubtreeIfNeeded()
            }
        }
        guard let history else { return }
        marks.setViews(history.runs.map { r in HistoryMark(r) { [weak self] in self?.onPick?(r) } }, in: .leading)
        words.stringValue =
            history.lastGreen.map { green in
                green.number.map { String(localized: "green on #\($0)") }
                    ?? String(localized: "green \(CIRunLook.ago(green.began)) ago")
            } ?? (history.greenInARow > 1 ? String(localized: "\(history.greenInARow) green in a row") : "")
    }
}

/// One run: 8 × 12, in the colour of its mark.
@MainActor
private final class HistoryMark: PointerControl {
    private let color: NSColor, pick: @MainActor () -> Void

    init(_ run: CIRuns.Run, pick: @escaping @MainActor () -> Void) {
        color =
            switch (run.status, run.conclusion) {
            case ("completed", "success"?): .systemGreen
            case ("completed", "skipped"?), ("completed", "cancelled"?), ("completed", "neutral"?):
                .quaternaryLabelColor
            case ("completed", _): .systemRed
            default: .tertiaryLabelColor
            }
        self.pick = pick
        super.init(frame: .zero)
        layer?.cornerRadius = Metrics.lineGap
        let number = run.number.map { "#\($0) · " } ?? ""
        let said =
            number + CIRunLook.words(run.status, run.conclusion) + (run.timeWords(usual: nil).map { " · " + $0 } ?? "")
        toolTip = said
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(said)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Metrics.gapWide), heightAnchor.constraint(equalToConstant: 12)
        ])
        refreshPointer()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func clicked() { pick() }
    override func showPointer(hovering: Bool, pressed: Bool) {
        fadeBackground(
            to: pressed ? color.withAlphaComponent(0.5) : hovering ? color.withAlphaComponent(0.75) : color,
            held: pressed)
    }
}
