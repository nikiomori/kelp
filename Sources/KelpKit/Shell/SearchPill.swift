// The window bar's search pill: Open Quickly as a place to click.
import AppKit
import Core
import DesignKit

/// Open Quickly as a place to click: it looks like a search field and opens the ⌘P palette (files, agents, commands).
@MainActor
final class SearchPill: PointerControl {
    private let glass = NSImageView(image: .symbol("magnifyingglass", ""))
    private let label = NSTextField(labelWithString: ""), key = NSTextField(labelWithString: "⌘P")
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
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 9, bottom: 0, right: 10)
        pin(row)
        toolTip = String(localized: "Open Quickly (⌘P)")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "Open Quickly"))
        track(owner: self) {
            app.themes.chromeText
        } changed: { [weak self] _ in
            self?.label.font = .ui(TextSize.row)
            self?.key.font = .ui(TextSize.caption)
            self?.needsLayout = true
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        // When room is short, show "Search" instead of "Files, a…". The room measured is the pill's own, so the choice
        // doesn't feed back on itself.
        let room = bounds.width - 19 - glass.frame.width - key.frame.width - 18
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
