import AppKit

/// What a panel or a tab shows instead of a list that has nothing, or couldn't load: one block in the middle of the
/// room under its bar, lifted 40 pt — an icon (28 pt light, tertiary), a title, a line of what to do, a command that
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
        icon.symbolConfiguration = .init(pointSize: 28, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        title.font = .ui(13, weight: .semibold)
        text.font = .ui(13)
        text.textColor = .secondaryLabelColor
        fix.font = .uiMono(11)
        fix.textColor = .secondaryLabelColor
        fix.isSelectable = true
        for l in [title, text, fix] { l.alignment = .center }
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
        for l in [title, text, fix] { l.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -2 * Metrics.inset - 8).isActive = true }
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Shows the block; nil `title` hides it. `symbol` is an SF Symbol's name.
    public func show(_ title: String?, symbol: String? = nil, text: String? = nil, fix: String? = nil, buttons: [NSButton] = []) {
        isHidden = title == nil
        guard let title else { return }
        self.title.stringValue = title
        self.text.stringValue = text ?? ""
        self.fix.stringValue = fix ?? ""
        icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        icon.isHidden = icon.image == nil
        self.text.isHidden = (text ?? "").isEmpty
        self.fix.isHidden = (fix ?? "").isEmpty
        self.buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for b in buttons {
            b.bezelStyle = .push
            self.buttons.addArrangedSubview(b)
        }
        self.buttons.isHidden = buttons.isEmpty
    }

    /// An error in the same place: what failed, what to do, the command that fixes it.
    public func showError(_ title: String, text: String?, fix: String? = nil, buttons: [NSButton] = []) {
        show(title, symbol: "exclamationmark.triangle", text: text, fix: fix, buttons: buttons)
    }

    /// Fills `area` under `top` (its bar), over whatever the area shows when it has something.
    public func place(in area: NSView, under top: NSView? = nil) {
        translatesAutoresizingMaskIntoConstraints = false
        area.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: top?.bottomAnchor ?? area.topAnchor), bottomAnchor.constraint(equalTo: area.bottomAnchor),
            leadingAnchor.constraint(equalTo: area.leadingAnchor), trailingAnchor.constraint(equalTo: area.trailingAnchor)
        ])
    }

    /// The same block as a web page, for a web view that has nothing to show (a page that didn't load, a notebook that
    /// can't be read): the title and a line under it, centred and lifted as the view is. Plain text; it's escaped here.
    public static func html(_ title: String, text: String) -> String {
        let esc = { (s: String) in s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        return "<html><head><meta name='color-scheme' content='light dark'></head><body style='margin:0;font:13px -apple-system;"
            + "color:-apple-system-secondary-label;display:flex;height:100vh;align-items:center;justify-content:center;text-align:center'>"
            + "<div style='margin:0 \(Int(Metrics.inset) + 4)px \(2 * Int(Metrics.emptyLift))px'>"
            + "<div style='font-weight:600;color:-apple-system-label;margin-bottom:\(Int(Metrics.gap))px'>\(esc(title))</div>\(esc(text))</div></body></html>"
    }

    /// Clicks go through where the block has nothing (the list under a hidden or transparent spot).
    override public func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === self ? nil : v
    }
}
