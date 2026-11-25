import AppKit
import DesignKit

/// Edit Tag…: the emoji or symbol in front of a tag and its colour, asked in a sheet. The emoji field takes one
/// character; Emoji & Symbols opens the system's picker into it.
@MainActor
enum TagEditor {
    /// Asks how `tag` looks. nil when the user cancels; a style with nothing in it makes the tag grey again.
    static func ask(_ tag: String, style: TagStyle?) async -> TagStyle? {
        let emoji = NSTextField()
        emoji.stringValue = style?.emoji ?? ""
        emoji.placeholderString = String(localized: "None")
        let picker = TextButton(
            String(localized: "Emoji & Symbols…"),
            onClick: {
                emoji.window?.makeFirstResponder(emoji)
                NSApp.orderFrontCharacterPalette(nil)
            })
        picker.setContentCompressionResistancePriority(.required, for: .horizontal)
        let emojiRow = NSStackView(views: [emoji, picker])
        emojiRow.spacing = Metrics.gapWide

        let symbol = NSPopUpButton()
        symbol.addItem(withTitle: String(localized: "None"))
        for name in TagStyle.symbols {
            symbol.addItem(withTitle: name)
            symbol.lastItem?.image = .symbol(name)
        }
        symbol.selectItem(withTitle: style?.symbol ?? String(localized: "None"))

        let color = NSPopUpButton()
        color.addItem(withTitle: String(localized: "None"))
        for c in TagStyle.Color.allCases {
            color.addItem(withTitle: c.title)
            color.lastItem?.image = swatch(c.ns)
            color.lastItem?.representedObject = c.rawValue
        }
        if let chosen = style?.color { color.selectItem(withTitle: chosen.title) }

        let alert = NSAlert()
        alert.messageText = String(localized: "Edit Tag “\(tag)”")
        alert.informativeText = String(localized: "How the tag looks on cards and rows. The pages keep only its name.")
        alert.accessoryView = SheetForm.grid([
            (String(localized: "Emoji"), emojiRow), (String(localized: "Symbol"), symbol),
            (String(localized: "Color"), color)
        ])
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard await runSheet(alert) == .alertFirstButtonReturn else { return nil }
        let typed = emoji.stringValue.trimmingCharacters(in: .whitespaces).first.map(String.init)
        return TagStyle(
            emoji: typed, symbol: symbol.indexOfSelectedItem > 0 ? symbol.titleOfSelectedItem : nil,
            color: (color.selectedItem?.representedObject as? String).flatMap(TagStyle.Color.init))
    }

    /// A round swatch of `color` for its menu item.
    private static func swatch(_ color: NSColor) -> NSImage {
        let side = Metrics.iconSmall
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }
}
