import AppKit
import Core
import DesignKit
import KelpKit

/// The branch's CI in a line under Commit. It shows the latest run of each workflow, a failure first with the job that
/// broke ("CI: Failed · test"; the step is in the tooltip). It is only the summary: a click opens the CI Runs panel,
/// which has the log and the actions.
final class CIStatusRow: PointerControl {
    private let text = NSTextField(labelWithString: ""), time = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private let line = NSStackView()

    init() {
        super.init(frame: .zero)
        layer?.cornerRadius = Metrics.radiusSM
        text.font = .ui(TextSize.row)
        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 1
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        time.font = .uiDigits(TextSize.caption)
        time.textColor = .secondaryLabelColor
        chevron.image = .symbol("chevron.right", "")
        chevron.symbolConfiguration = .chrome(Metrics.iconTiny)
        chevron.contentTintColor = .secondaryLabelColor
        line.spacing = 6
        line.alignment = .centerY
        pin(line, inset: NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `latest` holds one run per workflow, newest first. `failure` is where the failed one broke ("job › step"), once
    /// its jobs are read.
    func show(_ latest: [CIRuns.Run], failure: String?) {
        guard
            let run = latest.first(where: \.failed) ?? latest.first(where: { $0.status != "completed" }) ?? latest.first
        else {
            showLine(false)
            return
        }
        let failing = run.failed
        let name =
            latest.count > 1 && !failing && run.status == "completed"
            ? String(localized: "\(latest.count) workflows") : run.workflow
        let head = "\(name): \(CIRunLook.words(run.status, run.conclusion))"
        let job = failing ? failure?.components(separatedBy: " › ").first ?? "" : ""
        let one = NSMutableParagraphStyle()
        one.lineBreakMode = .byTruncatingTail
        let look: [NSAttributedString.Key: Any] = [.font: NSFont.ui(TextSize.row), .paragraphStyle: one]
        let headColor: NSColor = failing ? .labelColor : .secondaryLabelColor
        let headText = NSMutableAttributedString(
            string: head, attributes: look.merging([.foregroundColor: headColor]) { $1 })
        if !job.isEmpty {
            headText.append(
                NSAttributedString(
                    string: " · " + job,
                    attributes: look.merging([.foregroundColor: NSColor.secondaryLabelColor]) { $1 }))
        }
        text.attributedStringValue = headText
        time.stringValue = CIRunLook.ago(run.began)
        line.setViews([CIRunLook.mark(run.status, run.conclusion), text, NSView(), time, chevron], in: .leading)
        let place = failing ? failure ?? "" : ""
        toolTip =
            latest.map { "\($0.workflow): \(CIRunLook.words($0.status, $0.conclusion)) · \(CIRunLook.ago($0.began))" }
            .joined(separator: "\n") + (place.isEmpty ? "" : "\n" + place)
            + String(localized: "\n\nClick to open CI Runs") + "\n" + CIRunLook.clickTip(run.url)
        setAccessibilityLabel([head, place].filter { !$0.isEmpty }.joined(separator: ", "))
        showLine(true)
    }

    /// The line comes in and goes as `FailureBar` does: the changes under it slide down to make room and back up (in
    /// two thirds of the time), instead of jumping a line when gh answers.
    private func showLine(_ on: Bool) {
        guard isHidden == on else { return }
        crossfade()
        let host = window?.contentView
        host?.layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = host == nil ? 0 : Motion.duration(on ? Motion.base : Motion.fast)
            ctx.timingFunction = CAMediaTimingFunction(name: on ? .easeOut : .easeIn)
            ctx.allowsImplicitAnimation = true
            isHidden = !on
            host?.layoutSubtreeIfNeeded()
        }
    }

    // The row is one click target, labels included.
    override func hitTest(_ p: NSPoint) -> NSView? { super.hitTest(p) != nil ? self : nil }
}
