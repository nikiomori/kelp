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

/// Send to Agent lists the agents by the names people see, with a number after one that comes again, never their ids.
@MainActor @Test func agentsWithOneNameAreToldApartByNumber() {
    #expect(
        FileActions.distinct(["Claude", "Codex", "Claude", "Claude"]) == ["Claude", "Codex", "Claude 2", "Claude 3"])
    #expect(FileActions.distinct(["Fix the login"]) == ["Fix the login"])
}

/// A panel icon's count grows with Text size, as a section's count capsule does; a dot stays half its height.
@MainActor @Test func aPanelIconsCountGrowsWithTheText() {
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
