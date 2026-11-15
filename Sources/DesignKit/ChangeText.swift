import AppKit

extension NSAttributedString {
    /// "pending → cancelled": a value that changed, the old one struck out on the diff's red, the new one on its green;
    /// nil reads NULL.
    public static func change(from old: String?, to new: String?, font: NSFont) -> NSAttributedString {
        func part(_ value: String?, _ fill: NSColor, struck: Bool) -> NSAttributedString {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .backgroundColor: fill, .foregroundColor: NSColor.labelColor
            ]
            if struck { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            return NSAttributedString(
                string: value?.replacingOccurrences(of: "\n", with: "⏎") ?? "NULL", attributes: attributes)
        }
        let text = NSMutableAttributedString(attributedString: part(old, .diffRemovedWord, struck: true))
        text.append(
            NSAttributedString(string: " → ", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        text.append(part(new, .diffAddedWord, struck: false))
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        return text
    }
}
