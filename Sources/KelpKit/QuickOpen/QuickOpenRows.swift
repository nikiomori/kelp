// What the palette lists: its items, rows and a setting's choices, the commands run lately, and the bold in a title.
import AppKit
import Core
import DesignKit

extension QuickOpen {
    struct Item {
        let kind: String
        let icon: String
        let title: String
        let detail: String
        let action: () -> Void
        /// What ⇧↩ does: the same thing in a split to the right (files, agents, tabs).
        var split: (() -> Void)?
        /// The agent's session, whose state shows where the icon goes, as on its tab.
        var session: Session?
        /// For a setting with choices, its current value, shown on the right. Choosing the setting lists the choices
        /// here.
        var value: String?
        /// For one of those choices: the value it sets, whether it is in effect, and its theme's colors.
        var choice: JSONValue?
        var checked = false
        var image: NSImage?
        /// A command's shortcut, shown at the end of its title's line as in a menu.
        var key = ""
        /// Whether it was run from here lately, which puts it on top of ⇧⌘P's empty list, under Recently Used.
        var recent = false
        /// For a built-in's row, a view at its end, grey words there, and a monospaced title (`QuickItem`).
        var accessory: (@MainActor () -> NSView?)?
        var note = ""
        var mono = false
    }
    /// A setting's choices on screen: the setting's key, the saved value to go back to, whether moving the selection
    /// tries each choice on, and the query to return to.
    struct Choosing {
        let key: String
        let saved: JSONValue?
        let tries: Bool
        let query: String
    }
    /// A list row: a group's heading ("Files", "Agents"…) while searching, or an item.
    enum Row {
        case heading(String), item(Item)
        var isItem: Bool { if case .item = self { true } else { false } }
    }

    /// The item for a built-in's row, in group `kind` (a heading, or "" for a list of its own).
    static func item(_ row: QuickItem, kind: String = "") -> Item {
        Item(
            kind: kind, icon: row.icon, title: row.title, detail: row.detail, action: row.open, split: row.split,
            image: row.image, accessory: row.accessory, note: row.note, mono: row.mono)
    }

    static func group(_ it: Item) -> String {
        if it.recent { return "Recently Used" }
        return [
            "File": "Files", "Agent": "Chats", "Terminal": "Terminals", "Command": "Commands", "Setting": "Settings",
            "Group": "Groups",
            "Server": "Servers", "Tab": "Tabs"
        ][it.kind]
            ?? it.kind
    }

    /// The commands and settings run from the palette last, newest first. Five are kept, per Mac.
    static let usedKey = "quickOpen.recentCommands"
    static func usedID(_ it: Item) -> String { [it.kind, it.detail, it.title].joined(separator: " › ") }
    /// Returns the items of `pool` run lately that the menus still offer, in the order they were run.
    static func recentlyUsed(_ pool: [Item]) -> [Item] {
        (UserDefaults.standard.stringArray(forKey: usedKey) ?? []).compactMap { id in
            guard var it = pool.first(where: { usedID($0) == id }) else { return nil }
            it.recent = true
            return it
        }
    }
    static func remember(_ it: Item) {
        guard it.kind == "Command" || it.kind == "Setting" else { return }
        let defaults = UserDefaults.standard, id = usedID(it)
        defaults.set(
            Array(([id] + (defaults.stringArray(forKey: usedKey) ?? []).filter { $0 != id }).prefix(5)), forKey: usedKey
        )
    }
}

extension QuickOpen {
    /// Returns the title with what was typed in bold, each word of the query where it first occurs.
    /// A line of output is set monospaced (`mono`), a size smaller as code is in the chrome.
    static func highlighted(_ title: String, _ query: String, mono: Bool = false) -> NSAttributedString {
        let font = mono ? NSFont.uiMono(TextSize.row) : .ui(TextSize.body)
        let bold = mono ? NSFont.uiMono(TextSize.row, weight: .semibold) : .ui(TextSize.body, weight: .semibold)
        let text = NSMutableAttributedString(string: title, attributes: [.font: font])
        for word in query.split(separator: " ") where !word.isEmpty {
            let range = (title as NSString).range(of: String(word), options: .caseInsensitive)
            if range.location != NSNotFound { text.addAttribute(.font, value: bold, range: range) }
        }
        return text
    }
}
