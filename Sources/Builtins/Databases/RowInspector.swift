import AppKit
import Core
import DesignKit
import KelpKit

/// One row, top to bottom, beside the grid (Space or ⌘I): a column's name and type over its value, JSON laid out to
/// read, long text whole; a foreign key a link to the row it refers to (`onFollow`).
@MainActor
final class RowInspector: NSObject {
    let view = NSView()
    private let stack = NSStackView()
    private let title = NSTextField(labelWithString: "")
    /// "users", "id", "17": open that table at that row.
    var onFollow: (String, String, String) -> Void = { _, _, _ in }
    var onClose: () -> Void = {}
    static let width: CGFloat = 260

    override init() {
        super.init()
        title.font = .ui(12, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        let close = IconButton(.symbol("xmark"), tip: String(localized: "Close")) { [weak self] in self?.onClose() }
        let bar = Bar.content([title], [close], stretching: title)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let flipped = FlippedView()
        flipped.pin(stack)
        scroll.documentView = flipped
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        let column = NSStackView(views: [bar, scroll])
        column.orientation = .vertical
        column.spacing = 0
        for v in [bar, scroll] { v.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        view.pin(column)
        view.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
    }

    func show(row: Int?, columns: [String], values: [String?], info: [String: DatabaseSchema.Column]) {
        for v in stack.arrangedSubviews { v.removeFromSuperview() }
        guard let row else {
            title.stringValue = String(localized: "No Row Selected")
            return
        }
        title.stringValue = String(localized: "Row \(row + 1)")
        for (i, name) in columns.enumerated() {
            let value = values.indices.contains(i) ? values[i] : nil
            stack.addArrangedSubview(cell(name, value, info[name]))
        }
    }

    private func cell(_ name: String, _ value: String?, _ column: DatabaseSchema.Column?) -> NSView {
        let head = NSTextField(
            labelWithString: [name, column?.type.lowercased()].compactMap { $0 }.joined(separator: " · "))
        head.font = .ui(10.5)
        head.textColor = .tertiaryLabelColor
        var parts: [NSView] = [head]
        if let ref = column?.references, let value, case let p = ref.split(separator: "."), p.count == 2 {
            let link = ClosureButton(title: "\(value) → \(p[0])") { [weak self] in
                self?.onFollow(String(p[0]), String(p[1]), value)
            }
            link.isBordered = false
            link.contentTintColor = .linkColor
            link.font = .ui(12)
            parts.append(link)
        } else {
            let text = NSTextField(wrappingLabelWithString: Self.readable(value))
            text.font = value.map { $0.first == "{" || $0.first == "[" } == true ? .uiMono(11) : .ui(12)
            text.textColor = value == nil ? .tertiaryLabelColor : .labelColor
            text.isSelectable = true
            text.preferredMaxLayoutWidth = Self.width - 2 * Metrics.inset
            parts.append(text)
        }
        let box = NSStackView(views: parts)
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = Metrics.lineGap
        box.edgeInsets = NSEdgeInsets(top: Metrics.gap, left: Metrics.inset, bottom: Metrics.gap, right: Metrics.inset)
        return box
    }

    /// NULL said so; JSON indented; the rest as it is.
    static func readable(_ value: String?) -> String {
        guard let value else { return "NULL" }
        guard value.first == "{" || value.first == "[" else { return value }
        do {
            let object = try JSONSerialization.jsonObject(with: Data(value.utf8))
            let data = try JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
        } catch { return value }
    }
}

/// Top-down, as a list reads.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
