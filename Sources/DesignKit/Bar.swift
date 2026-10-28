import AppKit

/// A bar over what a panel or a tab shows, with a hairline under it. `panel`: an inspector panel's header, 36 pt, what it
/// shows on the left (a title, a branch, a search field), icon buttons on the right with ⋯ last. `content`: a tab's
/// toolbar (diff, Markdown, notebook, browser), 32 pt, a little more room between its controls. Heights follow the
/// text size, as the rows do.
@MainActor
public final class Bar: NSView {
    /// The bar's controls, left to right; a flexible space sits between `leading` and `trailing`.
    public let stack: NSStackView

    public static func panel(_ leading: [NSView], _ trailing: [NSView] = []) -> Bar {
        Bar(leading, trailing, height: Metrics.panelHeader, gap: Metrics.gap, insets: (Metrics.inset, Metrics.insetTrailing))
    }
    public static func content(_ leading: [NSView], _ trailing: [NSView] = []) -> Bar {
        Bar(leading, trailing, height: Metrics.contentBar, gap: Metrics.gapWide, insets: (Metrics.inset, Metrics.inset))
    }

    private init(_ leading: [NSView], _ trailing: [NSView], height: CGFloat, gap: CGFloat, insets: (CGFloat, CGFloat)) {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        stack = NSStackView(views: leading + [spacer] + trailing)
        stack.spacing = gap
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: insets.0, bottom: 0, right: insets.1)
        // Icon buttons side by side: their 22 pt squares already hold them apart.
        for (a, b) in zip(stack.arrangedSubviews, stack.arrangedSubviews.dropFirst()) where a is IconButton && b is IconButton {
            stack.setCustomSpacing(Metrics.iconGap, after: a)
        }
        super.init(frame: .zero)
        let line = NSBox()
        line.boxType = .separator
        for v in [stack, line] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.heightAnchor.constraint(equalToConstant: TextSize.of(height)),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.topAnchor.constraint(equalTo: stack.bottomAnchor), line.heightAnchor.constraint(equalToConstant: 1),
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A bar's title words: semibold row text, the panel's name or what it lists.
    public static func title(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .ui(12, weight: .semibold)
        t.lineBreakMode = .byTruncatingTail
        t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return t
    }
}
