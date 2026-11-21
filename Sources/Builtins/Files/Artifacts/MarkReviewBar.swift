import AppKit
import DesignKit

/// The bar under a page's own bar while marks wait for the user's check, after the agent's turn handed them back. It
/// says how many there are and which one is shown, steps through them, shows the page as it was sent (Before, on a
/// canvas) and takes Done or Again for the one shown. The page keeps the marks (`MarkColumn`) and tells the bar where
/// it is (`review`); the bar's buttons act on the page.
@MainActor
final class MarkReviewBar {
    private(set) lazy var bar: Bar = {
        let icon = NSImageView(image: NSImage.symbol("checklist"))
        icon.contentTintColor = .systemOrange
        before.controlSize = .small
        before.font = .ui(TextSize.row)
        before.selectedSegment = 1
        before.setToolTip(String(localized: "The page as the mark was sent with it (or hold Space)"), forSegment: 0)
        before.target = self
        before.action = #selector(beforeChosen)
        let buttons: [NSView] = [
            IconButton(.symbol("chevron.left"), tip: String(localized: "Previous Mark")) { [weak self] in
                self?.run("step(-1)")
            },
            position,
            IconButton(.symbol("chevron.right"), tip: String(localized: "Next Mark")) { [weak self] in
                self?.run("step(1)")
            },
            before,
            TextButton(String(localized: "Again")) { [weak self] in self?.run("again()") },
            TextButton(String(localized: "Done")) { [weak self] in self?.run("finish()") }
        ]
        let made = Bar.content([icon, label], buttons, stretching: label)
        made.isHidden = true
        return made
    }()
    private let label = NSTextField.label("", font: .ui(TextSize.row))
    private let position = NSTextField.label("", font: .uiDigits(TextSize.row), color: .secondaryLabelColor)
    private let before = CapsuleSegments(labels: [String(localized: "Before"), String(localized: "After")])
    private let act: (String) -> Void

    /// `act` runs a call on the page's marks (`window.kelpMarks`).
    init(act: @escaping (String) -> Void) { self.act = act }

    /// Shows where the check is: `count` marks wait, `at` is shown, and whether Before shows (and can, on a canvas).
    func show(count: Int, at: Int, before shown: Bool, canBefore: Bool, who: String?) {
        _ = bar
        bar.isHidden = count == 0
        guard count > 0 else { return }
        let finished =
            who.map { String(localized: "\($0) finished its turn") }
            ?? String(localized: "The agent finished its turn")
        label.stringValue = finished + " · " + String(localized: "To check: \(count)")
        position.stringValue = String(localized: "\(at + 1) of \(count)")
        before.isHidden = !canBefore
        before.selectedSegment = shown ? 0 : 1
    }

    @objc private func beforeChosen() { run("showBefore(\(before.selectedSegment == 0))") }

    private func run(_ call: String) { act("window.kelpMarks?.\(call)") }
}
