import AppKit

/// A bar over what a panel or a tab shows, with a hairline under it. `panel`: an inspector panel's header, 36 pt, what it
/// shows on the left (a title, a branch, a search field), icon buttons on the right with ⋯ last. `content`: a tab's
/// toolbar (diff, Markdown, notebook, browser), 32 pt, a little more room between its controls. Heights follow the
/// text size, as the rows do. `foot`: under what a tab shows, 32 pt with the hairline over it.
@MainActor
public final class Bar: NSView {
    /// The bar's controls, left to right; a flexible space sits between `leading` and `trailing`.
    public let stack: NSStackView

    public static func panel(_ leading: [NSView], _ trailing: [NSView] = [], stretching: NSView? = nil) -> Bar {
        let bar = Bar(height: Metrics.panelHeader, gap: Metrics.gap, insets: (Metrics.inset, Metrics.insetTrailing))
        bar.set(leading, trailing, stretching: stretching)
        return bar
    }
    public static func content(_ leading: [NSView], _ trailing: [NSView] = [], stretching: NSView? = nil) -> Bar {
        let bar = Bar(height: Metrics.contentBar, gap: Metrics.gapWide, insets: (Metrics.inset, Metrics.inset))
        bar.sizesControls = true
        bar.set(leading, trailing, stretching: stretching)
        return bar
    }
    /// A tab's toolbar gives its system controls one size: a pop-up kept 13 pt at small size beside 11 pt buttons.
    private var sizesControls = false

    public static func foot(_ leading: [NSView], _ trailing: [NSView] = []) -> Bar {
        let bar = Bar(
            height: Metrics.contentBar, gap: Metrics.gapWide, insets: (Metrics.inset, Metrics.inset), lineOnTop: true)
        bar.set(leading, trailing)
        return bar
    }

    private init(height: CGFloat, gap: CGFloat, insets: (CGFloat, CGFloat), lineOnTop: Bool = false) {
        stack = NSStackView()
        stack.distribution = .fill
        stack.spacing = gap
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: insets.0, bottom: 0, right: insets.1)
        super.init(frame: .zero)
        let line = NSBox()
        line.boxType = .separator
        for view in [stack, line] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            stack.heightAnchor.constraint(equalToConstant: TextSize.of(height)),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        let (top, bottom): (NSView, NSView) = lineOnTop ? (line, stack) : (stack, line)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: topAnchor), bottom.topAnchor.constraint(equalTo: top.bottomAnchor),
            bottom.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    /// Puts these controls in the bar instead of the ones it had. The room left over goes to `stretching` (a search field,
    /// an address), else to a space between `leading` and `trailing`.
    public func set(_ leading: [NSView], _ trailing: [NSView] = [], stretching: NSView? = nil) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let flex = stretching ?? NSView()
        flex.setContentHuggingPriority(.init(1), for: .horizontal)
        for view in (stretching == nil ? leading + [flex] + trailing : leading + trailing) {
            stack.addArrangedSubview(view)
        }
        if sizesControls { (leading + trailing).forEach(Self.small) }
        // Icon buttons side by side: their 22 pt squares already hold them apart.
        for (left, right) in zip(stack.arrangedSubviews, stack.arrangedSubviews.dropFirst())
        where left is IconButton && right is IconButton {
            stack.setCustomSpacing(Metrics.iconGap, after: left)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Push buttons, pop-ups and segments as AppKit draws them, and those in a stack among them: small, in the chrome's
    /// 11 pt. Kelp's own (`PointerButton`, `PointerPopUpButton`) size themselves.
    private static func small(_ view: NSView) {
        if let stack = view as? NSStackView {
            stack.arrangedSubviews.forEach(small)
            return
        }
        let push =
            (view as? NSButton).map {
                !($0 is PointerButton) && !($0 is NSPopUpButton) && $0.isBordered && $0.bezelStyle == .push
            } ?? false
        let plain = [ObjectIdentifier(NSPopUpButton.self), ObjectIdentifier(NSSegmentedControl.self)].contains(
            ObjectIdentifier(type(of: view)))
        guard push || plain, let control = view as? NSControl else { return }
        control.controlSize = .small
        control.font = .ui(11)
    }

    /// A bar's title words: semibold row text, the panel's name or what it lists.
    public static func title(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .ui(12, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}
