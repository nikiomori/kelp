import AppKit
import DesignKit

/// A tile that starts an agent: its icon, its name and how full its plan is (a bar and the share, with the reset in
/// the tooltip). The default agent's tile has an accent outline and its shortcut in the corner. It highlights on hover.
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

    /// The tile for the remaining agents, showing their first icons overlapping.
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

    /// Whether the tile keeps room under the name for a plan. While no agent on show has a plan, the tiles are only as
    /// tall as their names.
    var roomForPlan = true {
        didSet {
            bar.isHidden = !roomForPlan
            amount.isHidden = !roomForPlan
        }
    }

    /// Shows how full the agent's plan is, or nothing for a plan that is unused or not read.
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

/// A plan's used share as a thin bar in the plan's colour; a new share grows or shrinks the fill (`Motion.base`).
@MainActor
private final class PlanBar: NSView {
    private var used: Double = 0, color: NSColor = .secondaryLabelColor
    private let fill = CALayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(fill)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 56, height: 3) }
    func show(_ note: AgentNote?) {
        used = min(note?.used ?? 0, 1)
        color = note?.color ?? .secondaryLabelColor
        needsDisplay = true
        place(moving: window != nil)
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = bounds.height / 2
        layer?.backgroundColor = NSColor.fillSelected.cgColor   // drawing runs in the view's appearance
        fill.backgroundColor = color.cgColor
    }
    override func layout() {
        super.layout()
        place(moving: false)
    }
    private func place(moving: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // a layer of its own would ease these over 0.25 s
        fill.cornerRadius = bounds.height / 2
        fill.anchorPoint = .zero
        fill.position = .zero
        CATransaction.commit()
        fill.animate(
            "bounds", to: NSValue(rect: NSRect(x: 0, y: 0, width: bounds.width * used, height: bounds.height)),
            duration: moving ? Motion.base : 0)
    }
}
