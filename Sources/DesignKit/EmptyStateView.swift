import AppKit

/// What a panel or a tab shows instead of a list that has nothing, or couldn't load: one block in the middle of the
/// room under its bar, lifted 40 pt — an icon (28 pt at the chrome's weight, tertiary), a title, a line of what to do, a command that
/// fixes it (selectable, monospaced) and at most a button or two. An error is the same block with a warning triangle.
@MainActor
public final class EmptyStateView: NSView {
    private let icon = NSImageView()
    private let title = NSTextField(wrappingLabelWithString: "")
    private let text = NSTextField(wrappingLabelWithString: "")
    private let fix = NSTextField(wrappingLabelWithString: "")
    private let buttons = NSStackView()
    private let stack = NSStackView()

    public init() {
        super.init(frame: .zero)
        icon.symbolConfiguration = .chrome(Metrics.iconEmpty)
        icon.contentTintColor = .tertiaryLabelColor
        title.font = .ui(TextSize.body, weight: .semibold)
        text.font = .ui(TextSize.body)
        text.textColor = .secondaryLabelColor
        fix.font = .uiMono(TextSize.caption)
        fix.textColor = .secondaryLabelColor
        fix.isSelectable = true
        for label in [title, text, fix] { label.alignment = .center }
        buttons.spacing = Metrics.gapWide
        stack.setViews([icon, title, text, fix, buttons], in: .center)
        stack.orientation = .vertical
        stack.spacing = Metrics.gapWide
        stack.setCustomSpacing(Metrics.gap, after: title)   // a title and its line read as one
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // Lifted over the middle while there's room; in a short area it slides down rather than past the top.
        let lifted = stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -Metrics.emptyLift)
        lifted.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor), lifted,
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -2 * Metrics.inset - 8),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: Metrics.inset)
        ])
        for label in [title, text, fix] {
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -2 * Metrics.inset - 8).isActive =
                true
        }
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Shows the block; nil `title` hides it. `symbol` is an SF Symbol's name.
    public func show(
        _ title: String?, symbol: String? = nil, text: String? = nil, fix: String? = nil, buttons: [NSButton] = []
    ) {
        let appearing = isHidden && title != nil
        isHidden = title == nil
        guard let title else { return }
        if appearing, !Motion.reduced {   // it fades in rather than flashing up over the list it replaces
            alphaValue = 0
            NSAnimationContext.runAnimationGroup {
                $0.duration = Motion.fast
                animator().alphaValue = 1
            }
        }
        self.title.stringValue = title
        self.text.stringValue = text ?? ""
        self.fix.stringValue = fix ?? ""
        // Kelp's own drawing where it has one (the checklist, CI's check), as the panel's icon is.
        icon.image = symbol.flatMap {
            Glyph.image($0, size: Metrics.iconEmpty + 4) ?? NSImage(systemSymbolName: $0, accessibilityDescription: nil)
        }
        icon.isHidden = icon.image == nil
        self.text.isHidden = (text ?? "").isEmpty
        self.fix.isHidden = (fix ?? "").isEmpty
        self.buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for button in buttons {
            button.bezelStyle = .push
            self.buttons.addArrangedSubview(button)
        }
        self.buttons.isHidden = buttons.isEmpty
    }

    /// An error in the same place: what failed, what to do, the command that fixes it.
    public func showError(_ title: String, text: String?, fix: String? = nil, buttons: [NSButton] = []) {
        show(title, symbol: "exclamationmark.triangle", text: text, fix: fix, buttons: buttons)
    }

    /// Fills `area` under `top` (its bar), over whatever the area shows when it has something.
    public func place(in area: NSView, under top: NSView? = nil) { pin(in: area, under: top) }

    /// The same block as a web page, for a web view that has nothing to show (a page that didn't load, a notebook that
    /// can't be read): the title and a line under it, centred and lifted as the view is. Plain text; it's escaped here.
    public static func html(_ title: String, text: String) -> String {
        let esc = { (raw: String) in
            raw.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        }
        return
            "<html><head><meta name='color-scheme' content='light dark'></head><body style='margin:0;font:13px -apple-system;"
            + "color:-apple-system-secondary-label;display:flex;height:100vh;align-items:center;justify-content:center;text-align:center'>"
            + "<div style='margin:0 \(Int(Metrics.inset) + 4)px \(2 * Int(Metrics.emptyLift))px'>"
            + "<div style='font-weight:600;color:-apple-system-label;margin-bottom:\(Int(Metrics.gap))px'>\(esc(title))</div>\(esc(text))</div></body></html>"
    }

    /// Clicks go through where the block has nothing (the list under a hidden or transparent spot).
    override public func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
