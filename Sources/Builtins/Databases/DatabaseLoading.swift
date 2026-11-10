import AppKit
import DesignKit
import KelpKit

/// "Connecting to webdb dev…": a spinning wheel over what it's waiting for, centred where the tab's content will be.
@MainActor
final class DatabaseLoading: NSView {
    private let wheel = NSProgressIndicator()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        wheel.style = .spinning
        wheel.controlSize = .regular
        wheel.isDisplayedWhenStopped = false
        title.font = .ui(TextSize.body, weight: .semibold)
        title.textColor = .secondaryLabelColor
        detail.font = .ui(TextSize.caption)
        detail.textColor = .tertiaryLabelColor
        detail.alignment = .center
        detail.preferredMaxLayoutWidth = 360
        let stack = NSStackView(views: [wheel, title, detail])
        stack.orientation = .vertical
        stack.spacing = Metrics.gapWide
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -Metrics.emptyLift)
        ])
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ title: String, detail: String) {
        self.title.stringValue = title
        self.detail.stringValue = detail
        isHidden = false
        alphaValue = 0
        wheel.startAnimation(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.fast
            animator().alphaValue = 1
        }
    }

    func hide() {
        wheel.stopAnimation(nil)
        isHidden = true
    }
}
