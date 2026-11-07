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

/// The sidebar's knob runs in the floater's margin, right of the cards, and stays an overlay whatever the system says.
@MainActor @Test func sidebarScrollerRunsBesideTheCards() {
    let s = SidebarScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
    let o = SidebarOutline()
    let col = NSTableColumn(identifier: .init("main"))
    col.resizingMask = .autoresizingMask
    o.addTableColumn(col)
    o.headerView = nil
    s.documentView = o
    s.scrollerStyle = .legacy
    s.contentInsets.right = 8
    s.scrollerInsets.right = -8
    s.tile()
    o.sizeToFit()
    #expect(s.scrollerStyle == .overlay)
    #expect(o.frame.width == 192)
    #expect(s.verticalScroller.map { $0.frame.maxX } == 200)
}
