import AppKit
import DesignKit

/// An agent to start, as a tile: its icon, its name and how full its plan is (a bar and the share, the reset in the
/// tip). The default agent's has the accent's outline and its shortcut in the corner. Highlights on hover.
@MainActor
final class AgentTile: PointerControl {
    private let isDefault: Bool
    private let name: String
    private let bar = PlanBar()
    private let amount = NSTextField(labelWithString: " ")

    convenience init(image: NSImage?, title: String, key: String?, isDefault: Bool, action: @escaping () -> Void) {
        let icon = NSImageView(image: image ?? NSImage())
        icon.symbolConfiguration = .chrome(Metrics.iconMenu)
        icon.contentTintColor = .secondaryLabelColor   // symbols only; real icons keep their colors
        self.init(icon: icon, title: title, key: key, isDefault: isDefault, action: action)
    }

    /// The tile for the rest: their first icons overlapping.
    convenience init(stack images: [NSImage?], title: String, action: @escaping () -> Void) {
        let icons = NSStackView(views: images.map { NSImageView(image: $0 ?? NSImage()) })
        icons.spacing = -4
        self.init(icon: icons, title: title, key: nil, isDefault: false, action: action)
    }

    private init(icon: NSView, title: String, key: String?, isDefault: Bool, action: @escaping () -> Void) {
        self.isDefault = isDefault
        name = title
        super.init(frame: .zero)
        onClick = action
        restFill = .fillRest
        let label = NSTextField(labelWithString: title)
        label.font = .ui(TextSize.row)
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .center
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        amount.font = .uiDigits(TextSize.caption)
        amount.textColor = .secondaryLabelColor
        bar.alphaValue = 0
        amount.alphaValue = 0
        let column = NSStackView(views: [icon, label, bar, amount])
        column.detachesHiddenViews = true
        column.orientation = .vertical
        column.spacing = Metrics.gap
        column.setCustomSpacing(Metrics.iconGap, after: bar)
        column.edgeInsets = NSEdgeInsets(
            top: Metrics.inset, left: Metrics.gapWide, bottom: Metrics.gapWide, right: Metrics.gapWide)
        pin(column)
        NSLayoutConstraint.activate([
            icon.heightAnchor.constraint(equalToConstant: Metrics.iconEmpty),
            label.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor, constant: -2 * Metrics.gapWide)
        ])
        if icon is NSImageView { icon.widthAnchor.constraint(equalToConstant: Metrics.iconEmpty).isActive = true }
        if let key {
            let keyLabel = NSTextField(labelWithString: key)
            keyLabel.font = .ui(TextSize.micro)
            keyLabel.textColor = .secondaryLabelColor
            keyLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(keyLabel)
            NSLayoutConstraint.activate([
                keyLabel.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.gap),
                keyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.gapWide)
            ])
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Room under the name for a plan: while no agent on show has one, the tiles are only as tall as their names.
    var roomForPlan = true {
        didSet {
            bar.isHidden = !roomForPlan
            amount.isHidden = !roomForPlan
        }
    }

    /// How full the agent's plan is; nothing for a plan unused or not read.
    func show(_ note: AgentNote?) {
        bar.show(note)
        amount.stringValue = note?.amount ?? " "
        amount.textColor = note?.color ?? .secondaryLabelColor
        bar.alphaValue = note == nil ? 0 : 1
        amount.alphaValue = bar.alphaValue
        toolTip = note?.tip
        setAccessibilityLabel([name, note?.text].compactMap { $0 }.joined(separator: ", "))
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = Metrics.radiusXL
        layer?.cornerCurve = .continuous
        layer?.borderWidth = isDefault ? 1.5 : 1
        layer?.borderColor = (isDefault ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
    }

}

/// A plan's share as a thin bar, in the plan's colour.
@MainActor
private final class PlanBar: NSView {
    private var used: Double = 0, color: NSColor = .secondaryLabelColor
    override var intrinsicContentSize: NSSize { NSSize(width: 56, height: 3) }
    func show(_ note: AgentNote?) {
        used = min(note?.used ?? 0, 1)
        color = note?.color ?? .secondaryLabelColor
        needsDisplay = true
    }
    override func draw(_ dirty: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.fillSelected.setFill()
        track.fill()
        let fill = NSRect(x: 0, y: 0, width: bounds.width * used, height: bounds.height)
        color.setFill()
        NSBezierPath(roundedRect: fill, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}
