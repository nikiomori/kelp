import AppKit

/// A section's title over its rows, in a list's section row (`Metrics.rowSection`): 11 semibold, secondary, standing
/// on the row's bottom as Settings' titles do (`sectionHeading()`), so it reads with the rows under it. Only a section
/// that folds has a chevron before it; a count goes after it on its capsule, and `trailing` at the row's end. Every
/// AppKit list draws its headings with this one.
@MainActor
public final class SectionHeading: NSView {
    /// The chevron of a section that folds, which turns as it does.
    public let chevron: NSImageView?
    /// The fold VoiceOver's press does, for a section that folds (a click is the list's own).
    public var onPress: (() -> Void)?

    /// `open` is nil for a section that doesn't fold.
    public init(_ title: String, count: Int? = nil, open: Bool? = nil, trailing: [NSView] = []) {
        chevron = open.map { open in
            let view = NSImageView(image: .symbol(open ? "chevron.down" : "chevron.right"))
            view.symbolConfiguration = .chrome(Metrics.iconTiny)
            view.contentTintColor = .secondaryLabelColor
            return view
        }
        super.init(frame: .zero)
        let label = NSTextField.label(
            title, font: .ui(TextSize.caption, weight: .semibold), color: .secondaryLabelColor)
        var views: [NSView] = (chevron.map { [$0] } ?? []) + [label]
        if let count {
            let capsule = CountCapsule()
            capsule.text = count.formatted()
            views.append(capsule)
        }
        // The line's marks centre on the title; the line itself stands 4 pt over the row's bottom.
        let line = NSStackView(views: views + [NSView()] + trailing)
        line.spacing = Metrics.gap
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.inset),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.inset),
            line.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            line.topAnchor.constraint(greaterThanOrEqualTo: topAnchor)
        ])
        if let open {
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel(title)
            setAccessibilityHelp(open ? String(localized: "Collapse") : String(localized: "Expand"))
        }
    }
    public required init?(coder: NSCoder) { fatalError("not from a nib") }

    override public func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }
}
