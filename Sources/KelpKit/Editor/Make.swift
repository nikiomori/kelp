import AppKit
import DesignKit

/// The pages an agent can be asked to make (Make, on the start page and in the "+" menu). Each starts the default agent
/// with a line that sends it to `kelp artifact guide`, for the user to finish with what to make.
enum Make {
    struct Kind: Sendable {
        let id: String, title: String, symbol: String, help: String
    }

    static let kinds = [
        Kind(id: "doc", title: String(localized: "Doc"), symbol: "doc.text", help: String(localized: "A page to read and keep")),
        Kind(id: "review", title: String(localized: "Review"), symbol: "checklist", help: String(localized: "Choices you answer on the page")),
        Kind(id: "slides", title: String(localized: "Slides"), symbol: "play.rectangle", help: String(localized: "A deck to present")),
        Kind(id: "design", title: String(localized: "Design"), symbol: "square.grid.2x2", help: String(localized: "Screens side by side")),
        Kind(id: "dashboard", title: String(localized: "Dashboard"), symbol: "chart.bar", help: String(localized: "Numbers at a glance"))
    ]

    /// What the agent gets; the user writes what it's about after it. In English: it's the agent's instruction.
    static func line(_ k: Kind) -> String { "Make a \(k.id) (kelp artifact guide \(k.id)): " }

    /// The kinds as menu items, after a "Make" heading: each starts `start` with its line.
    @MainActor static func addItems(to m: NSMenu, start: @escaping @MainActor (String) -> Void) {
        m.addItem(.sectionHeader(title: String(localized: "Make")))
        for k in kinds {
            m.add(k.title, symbol: k.symbol) { start(line(k)) }.toolTip = k.help
        }
    }
}

/// Make on the start page: a row of grey tiles, a symbol in each and its name under it.
@MainActor
final class MakeTiles: NSStackView {
    init(pick: @escaping (Make.Kind) -> Void) {
        super.init(frame: .zero)
        distribution = .fillEqually
        spacing = Metrics.gapWide
        setViews(Make.kinds.map { k in MakeTile(k) { pick(k) } }, in: .leading)
    }
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
private final class MakeTile: NSView {
    private let box = NSView()
    private let action: () -> Void
    private var hover = false, area: NSTrackingArea?

    init(_ k: Make.Kind, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        box.wantsLayer = true
        box.layer?.cornerRadius = Metrics.radiusLG; box.layer?.cornerCurve = .continuous
        let icon = NSImageView(image: .symbol(k.symbol))
        icon.symbolConfiguration = .init(pointSize: 17, weight: Metrics.iconWeight)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(icon)
        let name = NSTextField(labelWithString: k.title)
        name.font = .ui(12); name.alignment = .center
        name.lineBreakMode = .byTruncatingTail
        let col = NSStackView(views: [box, name])
        col.orientation = .vertical; col.spacing = Metrics.gap
        pin(col)
        NSLayoutConstraint.activate([icon.centerXAnchor.constraint(equalTo: box.centerXAnchor), icon.centerYAnchor.constraint(equalTo: box.centerYAnchor),
                                     box.heightAnchor.constraint(equalToConstant: 56), box.widthAnchor.constraint(equalTo: col.widthAnchor),
                                     name.widthAnchor.constraint(lessThanOrEqualTo: col.widthAnchor)])
        toolTip = k.help
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "Make a \(k.title)")); setAccessibilityHelp(k.help)
        rest()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func rest() { box.fadeBackground(to: hover ? .fillHover : .fillRest) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); rest() }
    override func updateTrackingAreas() { super.updateTrackingAreas(); area = retracked(area, .activeInActiveApp) }
    override func mouseEntered(with e: NSEvent) { hover = true; rest() }
    override func mouseExited(with e: NSEvent) { hover = false; rest() }
    override func mouseDown(with e: NSEvent) { box.fadeBackground(to: .fillSelected, held: true) }
    override func mouseUp(with e: NSEvent) {
        rest()
        if bounds.contains(convert(e.locationInWindow, from: nil)) { box.pressBounce(); action() }
    }
    override func accessibilityPerformPress() -> Bool { action(); return true }
}
