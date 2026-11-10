import AppKit
import Testing

@testable import KelpKit

/// A peeking sidebar lies over the tabs in the same window, and a tab's tracking area fires under it: the tab isn't
/// hovered there (its agent card would hang off the panel's row). Where nothing covers it, it is.
@MainActor @Test func aTabUnderAPanelIsntHovered() throws {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
    window.contentView = content
    let tab = TabButton()
    tab.frame = NSRect(x: 0, y: 0, width: 200, height: 28)
    content.addSubview(tab)
    content.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)))   // the panel, over its left half
    func buttons(_ view: NSView) -> [NSButton] {
        view.subviews.flatMap { [$0 as? NSButton].compactMap { $0 } + buttons($0) }
    }
    // Shown only while the tab is hovered.
    let close = try #require(buttons(tab).first { $0.toolTip?.hasPrefix("Close Tab") == true })
    func event(_ type: NSEvent.EventType, _ x: CGFloat) throws -> NSEvent {
        try #require(
            NSEvent.enterExitEvent(
                with: type, location: tab.convert(NSPoint(x: x, y: 14), to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0,
                userData: nil))
    }
    func enter(_ x: CGFloat) throws { tab.mouseEntered(with: try event(.mouseEntered, x)) }
    tab.mouseExited(with: try event(.mouseExited, 150))   // as it starts: not hovered
    #expect(close.isHidden)
    try enter(50)
    #expect(close.isHidden)
    try enter(150)
    #expect(!close.isHidden)
}
