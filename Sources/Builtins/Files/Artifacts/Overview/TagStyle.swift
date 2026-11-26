import AppKit
import Core
import DesignKit

/// How the user dressed a tag: an emoji or an SF Symbol in front of its name, and one of Finder's colours. A tag no one
/// dressed is grey. The styles are one list in the window's state (`UIState`), because they are the user's view and
/// not the pages': the pages keep only the tags' names.
struct TagStyle: Equatable, Sendable {
    var emoji: String?, symbol: String?, color: Color?

    /// Finder's tag colours.
    enum Color: String, CaseIterable, Sendable {
        case red, orange, yellow, green, blue, purple, gray
        var ns: NSColor {
            switch self {
            case .red: .systemRed
            case .orange: .systemOrange
            case .yellow: .systemYellow
            case .green: .systemGreen
            case .blue: .systemBlue
            case .purple: .systemPurple
            case .gray: .systemGray
            }
        }
        var title: String {
            switch self {
            case .red: String(localized: "Red")
            case .orange: String(localized: "Orange")
            case .yellow: String(localized: "Yellow")
            case .green: String(localized: "Green")
            case .blue: String(localized: "Blue")
            case .purple: String(localized: "Purple")
            case .gray: String(localized: "Gray")
            }
        }
    }

    /// The symbols a tag can wear, a short list so choosing one stays one look.
    static let symbols = [
        "star", "flag", "bookmark", "bolt", "lightbulb", "paintbrush", "magnifyingglass", "hammer", "checkmark.seal",
        "exclamationmark.triangle", "heart", "book"
    ]

    static let key = "artifacts.tagStyles"

    /// Reads the styles kept in the window's state: {tag: {emoji, symbol, color}}. A part that doesn't read is left
    /// out.
    static func read(_ value: JSONValue?) -> [String: TagStyle] {
        guard case .object(let tags)? = value else { return [:] }
        return tags.mapValues { style in
            TagStyle(
                emoji: style["emoji"]?.string, symbol: style["symbol"]?.string,
                color: style["color"]?.string.flatMap(Color.init))
        }
    }
    static func value(_ styles: [String: TagStyle]) -> JSONValue {
        .object(
            styles.mapValues { style in
                .object(
                    [("emoji", style.emoji), ("symbol", style.symbol), ("color", style.color?.rawValue)]
                        .reduce(into: [:]) { fields, part in if let v = part.1 { fields[part.0] = .string(v) } })
            })
    }
}

/// A tag on a card or a row: its emoji or symbol and name on a capsule of its colour, grey when it has none.
@MainActor
final class TagCapsule: NSView {
    private let tint: NSColor?

    init(_ tag: String, style: TagStyle?) {
        tint = style?.color?.ns
        super.init(frame: .zero)
        var views: [NSView] = []
        if let symbol = style?.symbol, style?.emoji == nil {
            let icon = NSImageView(image: .symbol(symbol))
            icon.symbolConfiguration = .chrome(Metrics.iconTiny)
            icon.contentTintColor = tint ?? .secondaryLabelColor
            views.append(icon)
        }
        let text = (style?.emoji.map { $0 + " " } ?? "") + tag
        let name = NSTextField.label(
            text, font: .ui(TextSize.micro, weight: .medium), color: tint ?? .secondaryLabelColor)
        name.lineBreakMode = .byTruncatingTail
        views.append(name)
        let row = NSStackView(views: views)
        row.spacing = Metrics.iconGap
        row.edgeInsets = NSEdgeInsets(
            top: 0, left: TextSize.of(Metrics.gap), bottom: 0, right: TextSize.of(Metrics.gap))
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: TextSize.of(Metrics.countCapsule))
        ])
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(String(localized: "Tag \(tag)"))
        toolTip = "#" + tag
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = (tint.map(NSColor.fillTint) ?? NSColor.fillSelected).cgColor
        layer?.cornerRadius = bounds.height / 2
    }
    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    /// A line of a page's tags, at most `most` of them and "+N" for the rest.
    static func line(_ tags: [String], styles: [String: TagStyle], most: Int = 2) -> NSStackView {
        var views: [NSView] = tags.prefix(most).map { TagCapsule($0, style: styles[$0]) }
        if tags.count > most {
            let more = "+\(tags.count - most)"
            views.append(NSTextField.label(more, font: .ui(TextSize.micro), color: .secondaryLabelColor))
        }
        let line = NSStackView(views: views)
        line.spacing = Metrics.gapTight
        return line
    }
}
