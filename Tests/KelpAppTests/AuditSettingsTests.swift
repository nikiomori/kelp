import AppKit
import DesignKit
import Testing
import WorkbenchKit

@testable import KelpKit

/// Escape is written "esc", as the design system names it, wherever a shortcut is shown (menus, the palette, Settings ›
/// Keyboard).
@MainActor @Test func escapeIsShownInWords() {
    #expect(KeyBindings.display(KeySpec(key: "\u{1b}", mods: [])) == "esc")
    #expect(KeyBindings.display(KeySpec(key: "\u{1b}", mods: [.command])) == "⌘esc")
}

/// Settings › Keyboard: a shortcut set goes to settings.json's `keys` and over the menu, "" leaving the item without
/// one; set back to nil, the default returns. A command goes by its id, any other item by its English path.
@MainActor @Test func aShortcutSetInSettingsIsLaidOverTheMenu() {
    _ = NSApplication.shared   // a write without a daemon says so in a banner
    let settings = AppModel(builtins: []).settings
    func menu() -> (bar: NSMenu, save: NSMenuItem, copy: NSMenuItem) {
        let save = NSMenuItem(title: "Save All", action: #selector(AppDelegate.runCommand(_:)), keyEquivalent: "s")
        save.keyEquivalentModifierMask = [.option, .command]
        save.identifier = .init("editor.saveAll")
        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let edit = NSMenu(title: "Edit"), top = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""),
            bar = NSMenu()
        edit.items = [save, copy]
        top.submenu = edit
        bar.addItem(top)
        return (bar, save, copy)
    }
    KeyBindings.set("editor.saveAll", KeySpec("ctrl+shift+s"), in: settings)
    KeyBindings.set("Edit › Copy", KeySpec(key: "", mods: []), in: settings)
    #expect(KeyBindings.overrides(settings) == ["editor.saveAll": "ctrl+shift+s", "Edit › Copy": ""])
    let over = menu()
    KeyBindings.apply(to: over.bar, settings)
    #expect(over.save.keyEquivalent.lowercased() == "s" && over.save.keyEquivalentModifierMask == [.control, .shift])
    #expect(over.copy.keyEquivalent.isEmpty && over.copy.identifier?.rawValue == "Edit › Copy")
    KeyBindings.set("editor.saveAll", nil, in: settings)
    KeyBindings.set("Edit › Copy", nil, in: settings)
    #expect(KeyBindings.overrides(settings).isEmpty)
    let back = menu()
    KeyBindings.apply(to: back.bar, settings)
    #expect(back.save.keyEquivalent == "s" && back.save.keyEquivalentModifierMask == [.option, .command])
    #expect(back.copy.keyEquivalent == "c")
}

/// Send to Agent lists the agents by the names people see, with a number after one that comes again, never their ids.
@MainActor @Test func agentsWithOneNameAreToldApartByNumber() {
    #expect(
        FileActions.distinct(["Claude", "Codex", "Claude", "Claude"]) == ["Claude", "Codex", "Claude 2", "Claude 3"])
    #expect(FileActions.distinct(["Fix the login"]) == ["Fix the login"])
}

extension OneAtATime {
    /// A panel icon's count grows with Text size, as a section's count capsule does; a dot stays half its height.
    @Test func aPanelIconsCountGrowsWithTheText() {
        defer { TextSize.apply(nil) }
        func sizes() -> (count: NSSize, dot: NSSize) {
            let count = CountBadge(), dot = CountBadge()
            count.badge = PanelBadge(count: 3)
            dot.badge = PanelBadge(count: 0)
            return (count.intrinsicContentSize, dot.intrinsicContentSize)
        }
        let normal = sizes()
        TextSize.apply("larger")
        let grown = sizes()
        #expect(grown.count.height > normal.count.height && grown.count.width > normal.count.width)
        #expect(grown.dot.width == grown.dot.height / 2 && normal.dot.width == normal.dot.height / 2)
    }
}
