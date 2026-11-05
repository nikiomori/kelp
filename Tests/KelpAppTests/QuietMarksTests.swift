import AppKit
import Core
import DesignKit
import Testing
@testable import KelpKit

/// A tab shows the context pie from yellow on; a tab's title keeps about twelve letters.
@MainActor @Test func tabsStayQuietUntilSomethingNeedsDoing() {
    let use = { (used: Int) in SessionContextWindow.Usage(used: used, window: 200_000) }
    #expect([90_000, 100_000, 150_000].map { ContextMeter.shows(use($0)) } == [false, true, true])
    let font = NSFont.ui(12), twelve = TabButton.minTitle(String(repeating: "n", count: 12), font: font)
    #expect(TabButton.minTitle("zsh", font: font) < twelve)
    #expect(TabButton.minTitle("Refactor the login screen", font: font) == twelve)
}
