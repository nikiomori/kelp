import AppKit
import Core
import DesignKit
import KelpKit

/// The branch's CI in a line under Commit: the latest run of each workflow, a failure first with the job that broke
/// ("CI: Failed · test"; the step is in the tooltip). Only the summary: a click opens the CI Runs panel, which has the log and the actions.
final class CIStatusRow: NSView {
    var onClick: (() -> Void)?
    private let text = NSTextField(labelWithString: ""), time = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private let line = NSStackView()
    private var hover = false

    init() {
        super.init(frame: .zero)
        text.font = .ui(12); text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 1
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        time.font = .ui(11); time.textColor = .tertiaryLabelColor
        chevron.image = .symbol("chevron.right", "")
        chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        chevron.contentTintColor = .tertiaryLabelColor
        line.spacing = 6; line.alignment = .centerY
        pin(line, inset: NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        setAccessibilityElement(true); setAccessibilityRole(.button)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `latest`: one run per workflow, newest first; `failure`: where the failed one broke ("job › step"), once its jobs are read.
    func show(_ latest: [CIRuns.Run], failure: String?) {
        guard let run = latest.first(where: \.failed) ?? latest.first(where: { $0.status != "completed" }) ?? latest.first else { isHidden = true; return }
        isHidden = false
        let failing = run.failed
        let name = latest.count > 1 && !failing && run.status == "completed" ? String(localized: "\(latest.count) workflows") : run.workflow
        let head = "\(name): \(CIRunLook.words(run.status, run.conclusion))"
        let job = failing ? failure?.components(separatedBy: " › ").first ?? "" : ""
        let one = NSMutableParagraphStyle()
        one.lineBreakMode = .byTruncatingTail
        let look: [NSAttributedString.Key: Any] = [.font: NSFont.ui(12), .paragraphStyle: one]
        let headColor: NSColor = failing ? .labelColor : .secondaryLabelColor
        let s = NSMutableAttributedString(string: head, attributes: look.merging([.foregroundColor: headColor]) { $1 })
        if !job.isEmpty { s.append(NSAttributedString(string: " · " + job, attributes: look.merging([.foregroundColor: NSColor.secondaryLabelColor]) { $1 })) }
        text.attributedStringValue = s
        time.stringValue = CIRunLook.ago(run.createdAt)
        line.setViews([CIRunLook.mark(run.status, run.conclusion), text, NSView(), time, chevron], in: .leading)
        let place = failing ? failure ?? "" : ""
        toolTip = latest.map { "\($0.workflow): \(CIRunLook.words($0.status, $0.conclusion)) · \(CIRunLook.ago($0.createdAt))" }
            .joined(separator: "\n") + (place.isEmpty ? "" : "\n" + place) + String(localized: "\n\nClick to open CI Runs")
        setAccessibilityLabel([head, place].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 6
        layer?.backgroundColor = (hover ? NSColor.quaternarySystemFill : .clear).cgColor
    }
    override func mouseEntered(with e: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hover = false; needsDisplay = true }
    override func hitTest(_ p: NSPoint) -> NSView? { super.hitTest(p) != nil ? self : nil }   // one target, labels included
    override func mouseDown(with e: NSEvent) {}   // the click is the row's, not the panel's
    override func mouseUp(with e: NSEvent) { if bounds.contains(convert(e.locationInWindow, from: nil)) { onClick?() } }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}
