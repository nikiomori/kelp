import AppKit
import Core
import Foundation
import TestSupport
import Testing
import WorkbenchKit
@testable import KelpApp
@testable import KelpKit

/// A workspace's layout has one owner whether or not its editor area is loaded (`Workbench.layouts`): what's done to a
/// workspace off screen lands there, and is saved.

@MainActor @Test func aTabOpenedInAWorkspaceNotLoadedLandsInItsLayoutOnce() {
    let app = AppModel(builtins: Builtins.all), host = EditorHost(app: app)
    host.openInBackground("file:///tmp/a.txt", workspace: "w")
    host.openInBackground("file:///tmp/b.txt", workspace: "w")
    host.openInBackground("file:///tmp/a.txt", workspace: "w")   // already open: brought to the front, not added again
    let layout = app.workbench.layouts["w"]
    #expect(layout.allTabs.map(\.uri) == ["file:///tmp/a.txt", "file:///tmp/b.txt"])
    #expect(layout.focusedGroup?.selectedTab?.uri == "file:///tmp/a.txt")
    #expect(WorkspaceLayout.load("w", from: app.uiState).allTabs.isEmpty)   // saved after a pause
    app.workbench.layouts.save()
    #expect(WorkspaceLayout.load("w", from: app.uiState).allTabs.count == 2)
}

/// A chat moved to another screen leaves this one's tabs, as a loaded area's would.
@MainActor @Test func aChatMovedAwayLeavesAWorkspaceNotLoaded() {
    let app = AppModel(builtins: Builtins.all), host = EditorHost(app: app)
    var saved = WorkspaceLayout()
    saved.add("session:gone")
    saved.add("file:///tmp/kept.txt")
    saved.save("w", to: app.uiState)
    host.chatsLeft("w")
    #expect(app.workbench.layouts["w"].allTabs.map(\.uri) == ["file:///tmp/kept.txt"])
}

/// A chat closed from its row on a screen that isn't loaded: its tab goes from the layout, and ⇧⌘T can bring it back.
@MainActor @Test func aChatClosedOnAScreenNotLoadedLeavesItsLayout() async throws {
    let app = AppModel(builtins: Builtins.all), host = EditorHost(app: app)
    app.extensions.reload()   // the session tabs' provider ends a session never shown
    app.workbench.layouts["w"].add("session:s1")
    app.workbench.layouts["w"].add("file:///tmp/kept.txt")
    host.closeChat("s1", workspace: "w")
    #expect(try await waitFor(5) { app.workbench.layouts["w"].tab(uri: "session:s1") == nil })
    #expect(app.workbench.layouts["w"].allTabs.map(\.uri) == ["file:///tmp/kept.txt"])
    #expect(app.workbench.closedTabs.all.first?.uri == "session:s1")
}

/// A loaded area that isn't on screen follows its layout when it changes elsewhere: the tab is drawn, and one whose
/// URI changed under it (a restarted session) is built again for the new one.
@MainActor @Test func aLoadedAreaFollowsItsLayoutChangedElsewhere() async throws {
    let app = AppModel(builtins: Builtins.all), host = EditorHost(app: app)
    let area = EditorArea(app: app, workspaceId: "w")
    _ = area.view
    host.openInBackground("file:///tmp/a.txt", workspace: "w")
    #expect(try await waitFor(5) { !area.groupViews.isEmpty })
    let tab = try #require(area.layout.tab(uri: "file:///tmp/a.txt"))
    area.contents[tab.id] = UnavailableTab(uri: tab.uri, app: app)
    host.replaceInBackground("file:///tmp/a.txt", with: "file:///tmp/b.txt", workspace: "w")
    #expect(try await waitFor(5) { area.contents[tab.id]?.uri != "file:///tmp/a.txt" })
    #expect(area.layout.tab(uri: "file:///tmp/b.txt")?.id == tab.id)
}
