// The window bar's search pill: Open Quickly as a place to click.
import AppKit
import Core
import DesignKit

/// Open Quickly as a place to click: it looks like a search field and opens the ⌘P palette (files, agents, commands).
@MainActor
final class SearchPill: PointerControl {
    private let glass = NSImageView(image: .symbol("magnifyingglass", ""))
    private let label = NSTextField(labelWithString: ""), key = NSTextField(labelWithString: "")
    private let full = String(localized: "Files, agents, commands"), short = String(localized: "Search")
    private let app: AppModel

    init(app: AppModel) {
        self.app = app
        super.init(frame: .zero)
        restFill = .fillRest   // a field's fill; a step darker under the pointer, and darker still while pressed
        glass.symbolConfiguration = .chrome(Metrics.iconSmall)
        glass.contentTintColor = .secondaryLabelColor
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        key.textColor = .tertiaryLabelColor
        let row = NSStackView(views: [glass, label, NSView(), key])
        row.spacing = Metrics.gap
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        pin(row)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "Open Quickly"))
        let height = heightAnchor.constraint(equalToConstant: TextSize.barCapsule)
        height.isActive = true
        track(owner: self) {
            app.themes.chromeText
        } changed: { [weak self] _ in
            height.constant = TextSize.barCapsule   // the capsule grows with its text
            self?.label.font = .ui(TextSize.row)
            self?.key.font = .ui(TextSize.caption)
            self?.needsLayout = true
        }
        // The key shown and the tooltip's are Open Quickly's as it stands, so one set in Settings › Keyboard shows
        // here at once, and a command left without a key shows none.
        track(owner: self) {
            app.extensions.keyText("files.quickOpen") ?? ""
        } changed: { [weak self] shortcut in
            self?.key.stringValue = shortcut
            self?.toolTip = app.extensions.hint(String(localized: "Open Quickly"), "files.quickOpen")
            self?.needsLayout = true
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        // When room is short, show "Search" instead of "Files, a…". The room measured is the pill's own, so the choice
        // doesn't feed back on itself.
        let room = bounds.width - 20 - glass.frame.width - key.frame.width - 3 * Metrics.gap
        let text =
            (full as NSString).size(withAttributes: [.font: label.font ?? .ui(TextSize.row)]).width <= room
            ? full : short
        if label.stringValue != text { label.stringValue = text }
    }
    /// The whole pill takes the click, because in the title bar its label would move the window instead.
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    /// The palettes grow out of the pill (QuickOpen.present).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { app.quickOpen.anchor = self }
    }
    override func clicked() { app.quickOpen.show(commandsOnly: false) }
}
