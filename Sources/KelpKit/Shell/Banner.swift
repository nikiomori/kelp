import AppKit
import Core
import DesignKit

/// A short message in the top right corner of the editor area, under its tabs and the tab's own bar: errors,
/// confirmations and (when macOS notifications are off) what an agent did. It blocks nothing: it never covers the
/// sidebar, the inspector, a tab's buttons or the line being typed at the bottom of a terminal. It is drawn on Liquid
/// Glass (macOS 26, and the popover material before). Up to three show at once, the newest on top. A banner under the
/// pointer stays (and shows its ✕) until the pointer leaves.
@MainActor
package enum Banner {
    package enum Style { case info, error }
    /// The identifier of the editor area's card, in whose corner banners sit (EditorHost sets it).
    static let anchor = NSUserInterfaceItemIdentifier("kelp.editorCard")
    private static var stack: NSStackView?
    private static let most = 3

    /// Shows a banner. `action` adds one button beside the text (e.g. "Open Settings"), and the banner then stays a
    /// little longer. `title`, `subtitle` and `icon` are what an agent's banner leads with (its name and what it did,
    /// where, and its icon), with the text under them. `lasts` is the seconds on screen, when the action holds for a
    /// known time (an Undo the daemon keeps for a minute).
    package static func show(
        _ text: String, style: Style = .info, action: (title: String, run: @MainActor () -> Void)? = nil,
        title: String? = nil, subtitle: String? = nil, icon: NSImage? = nil, lasts: TimeInterval? = nil
    ) {
        guard let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }),
            let stack = stack(in: window)
        else { return }
        // A known error carries its fix, which is the command and a button that copies it.
        let fix = style == .error ? FixRecipes.fix(for: text) : nil
        var text = text, action = action
        if let fix {
            text += "\n" + String(localized: "Fix: \(fix.command)")
            if action == nil {
                action = (
                    String(localized: "Copy Fix"),
                    {
                        copyText(fix.command)
                    }
                )
            }
        }
        let card = BannerCard(
            text: text, style: style, title: title, subtitle: subtitle, icon: icon, action: action,
            stays: fix?.blocking == true)   // when git can't run at all, it stays until closed
        stack.rearrange { stack.insertArrangedSubview(card, at: 0) }
        card.appear()
        cards.dropFirst(most).forEach { $0.dismiss() }   // the oldest fades out, as one whose time came does
        // VoiceOver announces it too, because the banner is out of the keyboard's way and would go unheard.
        NSAccessibility.post(
            element: window, notification: .announcementRequested,
            userInfo: [
                .announcement: Self.spoken(text, title: title, style: style),
                .priority: (style == .error ? NSAccessibilityPriorityLevel.high : .medium).rawValue
            ])
        if !card.stays { card.leave(after: lasts ?? (action != nil ? 10 : style == .error ? 6 : 4)) }
    }

    /// What VoiceOver says for a banner. An error says that it is one, which sighted eyes read off its red sign.
    static func spoken(_ text: String, title: String?, style: Style) -> String {
        ([style == .error ? String(localized: "Error") : nil, title, text] as [String?]).compactMap(\.self)
            .joined(separator: ". ")
    }

    /// The column banners stack in. It is made once per window, in the corner of the editor area (or of the window,
    /// when there is no editor area).
    private static func stack(in window: NSWindow) -> NSStackView? {
        guard let content = window.contentView else { return nil }
        if let existing = stack, existing.window === window { return existing }
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .trailing
        column.spacing = Metrics.gapWide
        column.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)
        let card = find(anchor, in: content) ?? content
        NSLayoutConstraint.activate([
            // The column sits under the tab strip and the tab's bar (its Stage, Send to Agent…), clear of the card's
            // edge, and never wider than the area leaves room for.
            column.topAnchor.constraint(
                equalTo: card.topAnchor,
                constant: (card === content
                    ? WindowBar.height
                    : TabStrip.height(compact: false) + TextSize.of(Metrics.contentBar)) + Metrics.gapWide),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Metrics.inset),
            column.widthAnchor.constraint(lessThanOrEqualTo: card.widthAnchor, constant: -2 * Metrics.inset)
        ])
        stack = column
        return column
    }

    /// The banners on screen, the newest first. One already fading out isn't counted.
    private static var cards: [BannerCard] {
        (stack?.arrangedSubviews ?? []).compactMap { $0 as? BannerCard }.filter { !$0.leaving }
    }
    /// Whether a banner shows, which is when Dismiss Banner can be chosen.
    static var showing: Bool { !cards.isEmpty }
    /// Closes the newest banner, for the keyboard: a banner's ✕ shows only under the pointer, and one that stays until
    /// closed had no other way out.
    static func dismissTop() { cards.first?.dismiss() }

    private static func find(_ id: NSUserInterfaceItemIdentifier, in view: NSView) -> NSView? {
        if view.identifier == id { return view }
        for sub in view.subviews { if let found = find(id, in: sub) { return found } }
        return nil
    }
}

/// One banner: the icon (an agent's, or the info or warning sign), what happened and where, the text, and its buttons.
@MainActor
private final class BannerCard: NSView {
    let stays: Bool
    /// True once the banner is on its way out.
    private(set) var leaving = false
    private var hovering = false {
        didSet {
            let shown: CGFloat = hovering || stays ? 1 : 0
            NSAnimationContext.runAnimationGroup {
                $0.duration = Motion.duration(Motion.fast)
                close.animator().alphaValue = shown
            }
        }
    }
    private var leaveAt: Date?
    private let close = IconButton(.symbol("xmark", String(localized: "Close")), tip: String(localized: "Close")) {}

    init(
        text: String, style: Banner.Style, title: String?, subtitle: String?, icon: NSImage?,
        action: (title: String, run: @MainActor () -> Void)?, stays: Bool
    ) {
        self.stays = stays
        super.init(frame: .zero)
        let symbol = NSImageView(
            image: icon ?? .symbol(style == .error ? "exclamationmark.triangle.fill" : "info.circle.fill"))
        // What the user asked for failed, so the sign is red: orange stays for what waits for them.
        symbol.contentTintColor = style == .error ? .systemRed : .secondaryLabelColor
        symbol.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([
            symbol.widthAnchor.constraint(equalToConstant: icon == nil ? 16 : 24),
            symbol.heightAnchor.constraint(equalToConstant: icon == nil ? 16 : 24)
        ])
        var lines: [NSView] = []
        if let title {
            // two lines, so an agent's long name keeps the "finished" at its end
            let heading = NSTextField(wrappingLabelWithString: title)
            heading.font = .ui(TextSize.body, weight: .semibold)
            heading.maximumNumberOfLines = 2
            heading.cell?.truncatesLastVisibleLine = true
            heading.preferredMaxLayoutWidth = 252
            lines.append(heading)
        }
        if let subtitle, !subtitle.isEmpty {
            let place = NSTextField(labelWithString: subtitle)
            place.font = .ui(TextSize.caption)
            place.textColor = .secondaryLabelColor
            place.lineBreakMode = .byTruncatingTail
            lines.append(place)
        }
        let body = NSTextField(wrappingLabelWithString: text)
        body.font = .ui(TextSize.row)
        body.textColor = title == nil ? .labelColor : .secondaryLabelColor
        body.isSelectable = true
        body.maximumNumberOfLines = title == nil ? 0 : 3
        body.preferredMaxLayoutWidth = 252   // the card's 340 less its insets, the icon, the ✕ and the gaps between them
        body.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)   // keeps the words, not a sliver
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
            let button = ClosureButton(title: action.title) { [weak self] in
                action.run()
                self?.dismiss()
            }
            button.bezelStyle = .push
            button.controlSize = .small
            let row = NSStackView(views: [NSView(), button])
            buttons = row
            rows.append(row)
        }
        let column = NSStackView(views: rows)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Metrics.gapWide
        // The column is pinned with insets instead of using the stack's edgeInsets, because those give way to a long
        // line, which then pushes the icon and the button to the card's very edges.
        let padded = NSView()
        padded.pin(
            column,
            inset: NSEdgeInsets(
                top: Metrics.inset, left: Metrics.inset, bottom: Metrics.inset, right: Metrics.insetTrailing))
        // Every banner has one width, given up only to a narrower editor area. Otherwise a stack could squeeze a
        // banner down to its icon.
        let width = padded.widthAnchor.constraint(equalToConstant: 340)
        width.priority = .init(NSLayoutConstraint.Priority.required.rawValue - 1)
        NSLayoutConstraint.activate([width, padded.widthAnchor.constraint(lessThanOrEqualToConstant: 340)])
        buttons?.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true   // puts the button at the right edge
        pin(FloatingCard.ground(padded, radius: Metrics.radiusLG))
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        // When the banner's time came while it was being read, it stays a moment more, then goes.
        if let at = leaveAt, at < Date() { leave(after: Motion.linger) }
    }

    /// Slides the banner in from the right as it fades in, at the pace of whatever else comes over content
    /// (`Motion.appear`). At 120 ms it came quicker than it went and read as a flash.
    func appear() {
        alphaValue = 0
        wantsLayer = true
        if !Motion.reduced {
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = 16
            slide.toValue = 0
            slide.duration = Motion.appear
            slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer?.add(slide, forKey: "in")
        }
        NSAnimationContext.runAnimationGroup {
            $0.duration = Motion.duration(Motion.appear)
            $0.timingFunction = CAMediaTimingFunction(name: .easeOut)   // the same curve as the slide
            animator().alphaValue = 1
        }
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
        leaving = true
        leaveAt = nil
        NSAnimationContext.runAnimationGroup({
            $0.duration = Motion.duration(Motion.slow)
            animator().alphaValue = 0
        }) { [weak self] in
            MainActor.assumeIsolated {   // AppKit calls this on the main thread
                guard let self else { return }
                guard let stack = self.superview as? NSStackView else { return self.removeFromSuperview() }
                stack.rearrange { self.removeFromSuperview() }
            }
        }
    }
}

extension NSStackView {
    /// Runs `change`, which adds or removes banners. The other banners slide to their new places instead of jumping.
    fileprivate func rearrange(_ change: () -> Void) {
        let places = arrangedSubviews.map { ($0, $0.placeInWindow) }
        change()
        superview?.layoutSubtreeIfNeeded()
        for (view, place) in places where view.superview === self { view.slide(from: place, duration: Motion.fast) }
    }
}
