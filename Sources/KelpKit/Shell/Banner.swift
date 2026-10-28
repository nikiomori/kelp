import AppKit
import Core
import DesignKit

/// A short message over the bottom of the window — errors and confirmations that shouldn't block anything.
@MainActor
package enum Banner {
    package enum Style { case info, error }
    private static var current: NSView?
    private static var shown = 0   // which banner is up: a fade that ends after a newer one came leaves that one

    /// `action`: one button beside the text (e.g. "Open Settings"); the banner stays a little longer.
    package static func show(_ text: String, style: Style = .info, action: (title: String, run: @MainActor () -> Void)? = nil) {
        guard let content = (NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible })?.contentView else { return }
        // A known error carries its fix: the command, and a button that copies it.
        let fix = style == .error ? FixRecipes.fix(for: text) : nil
        var text = text, action = action
        if let fix {
            text += "\n" + String(localized: "Fix: \(fix.command)")
            if action == nil {
                action = (String(localized: "Copy Fix"), {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(fix.command, forType: .string)
                })
            }
        }
        current?.removeFromSuperview()
        let icon = NSImageView(image: .symbol(style == .error ? "exclamationmark.triangle.fill" : "info.circle.fill"))
        icon.contentTintColor = style == .error ? .systemOrange : .secondaryLabelColor
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .ui(12)
        label.isSelectable = true
        label.preferredMaxLayoutWidth = 460
        let row = NSStackView(views: [icon, label])
        row.spacing = Metrics.gapWide
        row.alignment = .top
        if let action {
            let b = ClosureButton(title: action.title) { action.run(); current?.removeFromSuperview() }
            b.bezelStyle = .push
            b.controlSize = .small
            row.alignment = .centerY
            row.addArrangedSubview(b)
        }
        row.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 14)
        let fx = FloatingCard(row)
        fx.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(fx)
        let bottom = fx.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: Motion.reduced ? -24 : -14)
        NSLayoutConstraint.activate([
            fx.centerXAnchor.constraint(equalTo: content.centerXAnchor), bottom,
            fx.widthAnchor.constraint(lessThanOrEqualToConstant: 520)
        ])
        content.layoutSubtreeIfNeeded()
        current = fx
        shown += 1
        // VoiceOver says it too: the banner is out of the keyboard's way, so it would go unheard.
        NSAccessibility.post(element: content, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: (style == .error ? NSAccessibilityPriorityLevel.high : .medium).rawValue])
        fx.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in   // it rises into place as it fades in
            ctx.duration = Motion.duration(Motion.fast)
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fx.animator().alphaValue = 1
            bottom.animator().constant = -24
        }
        if fix?.blocking == true {   // git can't run at all: stays until it's closed
            row.addArrangedSubview(IconButton(.symbol("xmark"), tip: String(localized: "Close")) { current?.removeFromSuperview() })
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (action != nil ? 10 : style == .error ? 6 : 3)) { [weak fx] in
            guard let fx else { return }
            let id = shown
            NSAnimationContext.runAnimationGroup({ $0.duration = Motion.duration(Motion.slow); fx.animator().alphaValue = 0 }) {
                MainActor.assumeIsolated {   // AppKit: on main
                    if shown == id { current?.removeFromSuperview() }
                }
            }
        }
    }
}
