import AppKit
import TestSupport
import Testing

/// A window a test shows is on screen for AppKit but never seen (TestSupportC/unseen.c): the window server draws it
/// see-through, while the code reads back the alpha it set.
@MainActor @Test func aWindowATestShowsIsNeverSeen() async throws {
    _ = NSApplication.shared   // windows go on screen only in an app
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.titled], backing: .buffered,
        defer: true)   // made in the window server only as it goes on screen, with the alpha AppKit reads then
    window.isReleasedWhenClosed = false
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    window.alphaValue = 0.5
    #expect(window.isVisible && window.alphaValue == 0.5)
    func drawn() -> Double? {   // what the window server has, once AppKit has put the window on screen
        let all = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let mine = all.first { $0[kCGWindowNumber as String] as? Int == window.windowNumber }
        return mine?[kCGWindowAlpha as String] as? Double
    }
    #expect(try await waitFor { drawn() != nil })
    #expect(drawn() == 0)
}
