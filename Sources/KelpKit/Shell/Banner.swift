import AppKit
import Core
import DesignKit

/// A short message in the top right corner of the editor area, under its tabs — errors, confirmations and (when
/// macOS's are off) what an agent did — that blocks nothing: not over the sidebar, the inspector or the line being
/// typed at the bottom of a terminal. On Liquid Glass (macOS 26; the popover material before). Up to three, the newest
/// on top; one under the pointer stays (and shows its ✕) until the pointer leaves.
@MainActor
package enum Banner {
    package enum Style { case info, error }
    /// The editor area's card, which banners sit in the corner of (EditorHost names it).
    static let anchor = NSUserInterfaceItemIdentifier("kelp.editorCard")
    private static var stack: NSStackView?
    private static let most = 3

    /// `action`: one button beside the text (e.g. "Open Settings"); the banner stays a little longer. `title`, `subtitle`
    /// and `icon`: what an agent's banner leads with (its name and what it did, where, its icon), the text under them.
    package static func show(_ text: String, style: Style = .info, action: (title: String, run: @MainActor () -> Void)? = nil,
                             title: String? = nil, subtitle: String? = nil, icon: NSImage? = nil) {
        guard let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }), let stack = stack(in: window) else { return }
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
        let card = BannerCard(text: text, style: style, title: title, subtitle: subtitle, icon: icon, action: action,
                              stays: fix?.blocking == true)   // git can't run at all: stays until it's closed
        stack.insertArrangedSubview(card, at: 0)
        while stack.arrangedSubviews.count > most, let oldest = stack.arrangedSubviews.last { oldest.removeFromSuperview() }
        card.appear()
        // VoiceOver says it too: the banner is out of the keyboard's way, so it would go unheard.
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: [title, text].compactMap { $0 }.joined(separator: ". "),
                                        .priority: (style == .error ? NSAccessibilityPriorityLevel.high : .medium).rawValue])
        if !card.stays { card.leave(after: action != nil ? 10 : style == .error ? 6 : 4) }
    }

    /// The column banners stack in, made once per window in the corner of the editor area (or of the window, without one).
    private static func stack(in window: NSWindow) -> NSStackView? {
        guard let content = window.contentView else { return nil }
        if let s = stack, s.window === window { return s }
        let s = NSStackView()
        s.orientation = .vertical
        s.alignment = .trailing
        s.spacing = Metrics.gapWide
        s.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(s)
        let card = find(anchor, in: content) ?? content
        NSLayoutConstraint.activate([
            // Under the tab strip, clear of the card's edge; never wider than the area leaves room for.
            s.topAnchor.constraint(equalTo: card.topAnchor, constant: card === content ? WindowBar.height + 8 : TabStrip.height + 8),
            s.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            s.widthAnchor.constraint(lessThanOrEqualTo: card.widthAnchor, constant: -24)
        ])
        stack = s
        return s
    }

    private static func find(_ id: NSUserInterfaceItemIdentifier, in v: NSView) -> NSView? {
        if v.identifier == id { return v }
        for sub in v.subviews { if let found = find(id, in: sub) { return found } }
        return nil
    }
}

/// One banner: the icon (an agent's, or the info / warning sign), what happened, where, the text, and its buttons.
@MainActor
private final class BannerCard: NSView {
    let stays: Bool
    private var hovering = false { didSet { close.alphaValue = hovering || stays ? 1 : 0 } }
    private var leaveAt: Date?
    private let close = IconButton(.symbol("xmark", String(localized: "Close")), tip: String(localized: "Close")) {}

    init(text: String, style: Banner.Style, title: String?, subtitle: String?, icon: NSImage?,
         action: (title: String, run: @MainActor () -> Void)?, stays: Bool) {
        self.stays = stays
        super.init(frame: .zero)
        let symbol = NSImageView(image: icon ?? .symbol(style == .error ? "exclamationmark.triangle.fill" : "info.circle.fill"))
        symbol.contentTintColor = style == .error ? .systemOrange : .secondaryLabelColor
        symbol.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([symbol.widthAnchor.constraint(equalToConstant: icon == nil ? 16 : 24),
                                     symbol.heightAnchor.constraint(equalToConstant: icon == nil ? 16 : 24)])
        var lines: [NSView] = []
        if let title {
            let t = NSTextField(wrappingLabelWithString: title)   // two lines: an agent's long name keeps the "finished" at its end
            t.font = .ui(13, weight: .semibold)
            t.maximumNumberOfLines = 2
            t.cell?.truncatesLastVisibleLine = true
            t.preferredMaxLayoutWidth = 252
            lines.append(t)
        }
        if let subtitle, !subtitle.isEmpty {
            let s = NSTextField(labelWithString: subtitle)
            s.font = .ui(11)
            s.textColor = .secondaryLabelColor
            s.lineBreakMode = .byTruncatingTail
            lines.append(s)
        }
        let body = NSTextField(wrappingLabelWithString: text)
        body.font = .ui(12)
        body.textColor = title == nil ? .labelColor : .secondaryLabelColor
        body.isSelectable = true
        body.maximumNumberOfLines = title == nil ? 0 : 3
        body.preferredMaxLayoutWidth = 252   // the card's 340 less its insets, the icon, the ✕ and the gaps between them
        lines.append(body)
        let words = NSStackView(views: lines)
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = Metrics.lineGap
        close.onClick = { [weak self] in self?.dismiss() }
        close.alphaValue = stays ? 1 : 0
        let top = NSStackView(views: [symbol, words, close])
        top.alignment = .top
        top.spacing = Metrics.gapWide
        var rows: [NSView] = [top]
        var buttons: NSStackView?
        if let action {
            let b = ClosureButton(title: action.title) { [weak self] in action.run(); self?.dismiss() }
            b.bezelStyle = .push
            b.controlSize = .small
            let row = NSStackView(views: [NSView(), b])
            buttons = row
            rows.append(row)
        }
        let column = NSStackView(views: rows)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Metrics.gapWide
        // Pinned, not the stack's edgeInsets: those give way to a long line, which then pushes the icon and the
        // button to the card's very edges.
        let padded = NSView()
        padded.pin(column, inset: NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 10))
        padded.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
        buttons?.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true   // the button at the right edge
        Self.ground(padded, in: self)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Liquid Glass where there is, the popover card before.
    private static func ground(_ content: NSView, in v: NSView) {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Metrics.radiusXL + 2
            glass.contentView = content
            v.pin(glass)
        } else {
            v.pin(FloatingCard(content, radius: Metrics.radiusLG))
        }
    }

    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) {
        hovering = false
        if let at = leaveAt, at < Date() { leave(after: 1.5) }   // its time came while it was read: a moment more, then away
    }

    /// In from the right as it fades in.
    func appear() {
        alphaValue = 0
        wantsLayer = true
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = Motion.reduced ? 0 : 16
        slide.toValue = 0
        slide.duration = Motion.duration(Motion.fast)
        slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(slide, forKey: "in")
        NSAnimationContext.runAnimationGroup { $0.duration = Motion.duration(Motion.fast); animator().alphaValue = 1 }
    }

    /// Fades out after `seconds`, unless the pointer is on it then.
    func leave(after seconds: TimeInterval) {
        let at = Date().addingTimeInterval(seconds)
        leaveAt = at
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, leaveAt == at, !hovering else { return }
            dismiss()
        }
    }

    func dismiss() {
        leaveAt = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = Motion.duration(Motion.slow); animator().alphaValue = 0 }) { [weak self] in
            MainActor.assumeIsolated { self?.removeFromSuperview() }   // AppKit: on main
        }
    }
}
