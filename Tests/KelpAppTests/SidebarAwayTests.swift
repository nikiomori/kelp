import AppKit
import Core
import DesignKit
import TestSupport
import Testing
import WorkbenchKit

@testable import KelpApp
@testable import KelpKit

/// With the strip's tests: a sidebar put away to the window's edge kept another test's strip from showing.
extension StripPlaceTests {
    /// The sidebar button (⌘0) puts the sidebar away into its floater, which comes in at the window's left edge, as
    /// Dia's does, and brings it back to its column: hidden and auto-hide are one state (decision 109). The traffic
    /// lights go and come with it; its toggle stays, and nothing in the bar moves while it slides in.
    @Test func theSidebarButtonHidesTheSidebarToItsEdge() async throws {
        _ = testHome
        let app = AppModel(builtins: Builtins.all), main = MainWindowController(app: app)
        let split = try #require(main.window?.contentView?.subviews.first { !($0 is Backdrop) })
        let was = app.settings[SettingKeys.sidebarAutoHide]
        defer { app.settings.set(SettingKeys.sidebarAutoHide, was) }
        if was { main.toggleSidebarPanel() }
        main.left.item.isCollapsed = false   // open, whatever this Mac's tests left in the split's autosave
        #expect(try await waitFor(5) { main.sidebar.view.isDescendant(of: split) })
        main.toggleSidebarPanel()
        #expect(try await waitFor(5) { !main.sidebar.view.isDescendant(of: split) })   // in its floater, at the edge
        #expect(app.settings[SettingKeys.sidebarAutoHide])
        // The traffic lights went with it; its toggle stays, at the window's edge where they stood.
        let close = try #require(main.window?.standardWindowButton(.closeButton))
        #expect(try await waitFor(5) { close.isHidden && !main.sidebarToggle.isHidden })
        #expect(
            try await waitFor(5) {
                main.window?.contentView?.layoutSubtreeIfNeeded()
                return main.sidebarToggle.frame.minX < close.frame.maxX   // at the edge, once its move is over
            })
        let name = main.bar.context.convert(main.bar.context.bounds, to: nil).minX
        // Sliding in at the edge brings the lights on it, and moves nothing in the bar.
        main.peek(main.left)
        #expect(try await waitFor(5) { !close.isHidden && close.alphaValue == 1 })
        main.window?.contentView?.layoutSubtreeIfNeeded()
        #expect(main.bar.context.convert(main.bar.context.bounds, to: nil).minX == name)
        main.stopPeek()
        #expect(try await waitFor(5) { close.isHidden })
        main.toggleSidebarPanel()
        #expect(try await waitFor(5) { main.sidebar.view.isDescendant(of: split) })
        #expect(!app.settings[SettingKeys.sidebarAutoHide])
        #expect(try await waitFor(5) { !close.isHidden && !main.sidebarToggle.isHidden })
        #expect(
            try await waitFor(5) {
                main.window?.contentView?.layoutSubtreeIfNeeded()
                return main.sidebarToggle.frame.minX > close.frame.maxX   // back after the lights
            })
    }
}
