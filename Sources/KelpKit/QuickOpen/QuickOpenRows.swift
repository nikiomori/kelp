// What the palette lists: its items, rows and a setting's choices, the commands run lately, a title's bold.
import AppKit
import Core
import DesignKit
import WorkbenchKit

extension QuickOpen {
    struct Item {
        let kind: String
        let icon: String
        let title: String
        let detail: String
        let action: () -> Void
        /// ⇧↩: the same thing in a split to the right (files, agents, tabs).
        var split: (() -> Void)?
        /// An agent's: its state where the icon goes, as on its tab.
        var session: Session?
        /// A setting with choices: its value now, on the right; choosing it lists the choices here.
        var value: String?
        /// One of those choices: the value it sets, whether it's in effect, and its theme's colors.
        var choice: JSONValue?
        var checked = false
        var image: NSImage?
        /// A file's path, ready for fuzzy matching.
        var fuzzy: ProjectFiles.FuzzyPath?
        /// A command's shortcut, at the end of its title's line as in a menu.
        var key = ""
        /// Run from here lately: on top of ⇧⌘P's empty list, under Recently Used.
        var recent = false
    }
    /// A setting's choices on screen: the key, the value to go back to, whether moving tries them on, the query to return to.
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

    static func group(_ it: Item) -> String {
        if it.recent { return "Recently Used" }
        return [
            "File": "Files", "Agent": "Chats", "Terminal": "Terminals", "Command": "Commands", "Setting": "Settings",
            "Group": "Groups",
            "Server": "Servers", "Tab": "Tabs"
        ][it.kind]
            ?? it.kind
    }

    /// The commands and settings run from the palette last, newest first; kept per Mac, five of them.
    static let usedKey = "quickOpen.recentCommands"
    static func usedID(_ it: Item) -> String { [it.kind, it.detail, it.title].joined(separator: " › ") }
    /// Of `pool`, the ones run lately that the menus still offer, in the order they were run.
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
    /// The title with what was typed in bold: each word of the query where it first occurs.
    static func highlighted(_ title: String, _ query: String) -> NSAttributedString {
        let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.ui(TextSize.body)])
        for word in query.split(separator: " ") where !word.isEmpty {
            let range = (title as NSString).range(of: String(word), options: .caseInsensitive)
            if range.location != NSNotFound {
                text.addAttribute(.font, value: NSFont.ui(TextSize.body, weight: .semibold), range: range)
            }
        }
        return text
    }
}
