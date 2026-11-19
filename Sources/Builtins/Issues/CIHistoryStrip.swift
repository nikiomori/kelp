import AppKit
import Core
import DesignKit
import KelpKit

/// A workflow's latest runs in a line, newest on the right, in the colours of their marks. It shows whether the
/// workflow broke just now or has been red for a while, without reading the list. A mark goes to its run. The strip is
/// hidden when there is nothing to compare.
@MainActor
final class CIHistoryStrip: NSView {
    var onPick: ((CIRuns.Run) -> Void)?
    private let marks = NSStackView()
    private let words = NSTextField(labelWithString: "")
    private let line = NSStackView()
    private var height: NSLayoutConstraint?
    /// "green on #177", and "#177" for a panel too narrow for the words; the tooltip keeps the words.
    private var whole = "", short: String?, wholeWidth: CGFloat = 0

    init() {
        super.init(frame: .zero)
        marks.spacing = Metrics.lineGap
        words.font = .uiDigits(TextSize.caption)
        words.textColor = .secondaryLabelColor
        words.lineBreakMode = .byTruncatingTail
        words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        line.setViews([marks, NSView(), words], in: .leading)
        line.spacing = Metrics.gapWide
        pin(line, inset: NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.inset))
        height = heightAnchor.constraint(equalToConstant: 0)
        height?.isActive = true
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ history: CIRuns.History?) {
        let tall = history == nil ? 0 : TextSize.of(Metrics.row)
        if tall != height?.constant {   // it opens, so the runs under it move down rather than jump
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
        whole =
            history.lastGreen.map { green in
                green.number.map { String(localized: "green on #\($0)") }
                    ?? String(localized: "green \(CIRunLook.ago(green.began)) ago")
            } ?? (history.greenInARow > 1 ? String(localized: "\(history.greenInARow) green in a row") : "")
        short = history.lastGreen?.number.map { "#\($0)" }
        let probe = NSTextField(labelWithString: whole)
        probe.font = words.font
        wholeWidth = probe.fittingSize.width
        words.toolTip = whole.isEmpty ? nil : whole
        needsLayout = true   // layout picks which of the two fits
    }

    override func layout() {
        super.layout()
        let fits = line.fittingSize.width - words.fittingSize.width + wholeWidth <= line.bounds.width
        let text = fits ? whole : short ?? whole
        if words.stringValue != text { words.stringValue = text }
    }
}

/// One run's mark, 8 × 12, in the colour of the run's mark: a passed run grey, as CI's mark in the sidebar is, and only
/// a failed one red.
@MainActor
private final class HistoryMark: PointerControl {
    private let color: NSColor

    init(_ run: CIRuns.Run, pick: @escaping () -> Void) {
        color =
            switch (run.status, run.conclusion) {
            case ("completed", "success"?): .secondaryLabelColor
            case ("completed", "skipped"?), ("completed", "cancelled"?), ("completed", "neutral"?):
                .quaternaryLabelColor
            case ("completed", _): .systemRed
            default: .tertiaryLabelColor
            }
        super.init(frame: .zero)
        onClick = pick
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

    override func showPointer(hovering: Bool, pressed: Bool) {
        fadeBackground(
            to: pressed ? color.withAlphaComponent(0.5) : hovering ? color.withAlphaComponent(0.75) : color,
            held: pressed)
    }
}
