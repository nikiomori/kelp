import AppKit
import Core
import DesignKit
import TestSupport
import Testing
import WorkbenchKit

@testable import KelpApp
@testable import KelpKit

extension OneAtATime {
    /// The sidebar button (⌘0) puts the sidebar away into its floater, which comes in at the window's left edge, as
    /// Dia's does, and brings it back to its column: hidden and auto-hide are one state (decision 109). The traffic
    /// lights and the toggle go and come with it.
    @Test func theSidebarButtonHidesTheSidebarToItsEdge() async throws {
        _ = testHome
        Motion.pinned = true
        defer { Motion.pinned = nil }
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
        // The traffic lights and the toggle went with it, and come back over it while it slides in at the edge.
        let close = try #require(main.window?.standardWindowButton(.closeButton))
        #expect(try await waitFor(5) { close.isHidden && main.sidebarToggle.isHidden })
        main.peek(main.left)
        #expect(try await waitFor(5) { !close.isHidden && close.alphaValue == 1 && !main.sidebarToggle.isHidden })
        main.stopPeek()
        #expect(try await waitFor(5) { close.isHidden })
        main.toggleSidebarPanel()
        #expect(try await waitFor(5) { main.sidebar.view.isDescendant(of: split) })
        #expect(!app.settings[SettingKeys.sidebarAutoHide])
        #expect(try await waitFor(5) { !close.isHidden && !main.sidebarToggle.isHidden })
    }
}
