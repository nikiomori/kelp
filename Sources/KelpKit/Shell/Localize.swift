import AppKit

/// Kelp in the user's language: English and Russian, from Resources/Localizable.xcstrings (compiled into the app's
/// Resources by scripts/strings.sh). Text written in code goes through `String(localized:)` and SwiftUI's string keys;
/// text that's data (menu titles, settings, panel and command names) is looked up by its English text when shown.
package func loc(_ english: String) -> String {
    Bundle.main.localizedString(forKey: english, value: english, table: nil)
}

@MainActor
enum Localize {
    /// The menu bar is built in English and shows the translation; a submenu keeps its English title as its
    /// identifier (Settings › Keyboard names items by command id or English path).
    static func menu(_ level: NSMenu) {
        for item in level.items where !item.isSeparatorItem {
            if item.identifier == nil { item.identifier = NSUserInterfaceItemIdentifier(item.title) }
            let indent = item.title.prefix { $0 == " " }   // the View menu's panel list is indented
            item.title = indent + loc(String(item.title.dropFirst(indent.count)))
            if let submenu = item.submenu, submenu !== NSApp.servicesMenu {
                submenu.title = loc(submenu.title)
                menu(submenu)
            }
        }
    }
}
