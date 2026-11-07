import Foundation
import Testing
import WorkbenchKit

private func twoPanes() throws -> (WorkspaceLayout, left: String, right: String, tabs: [String]) {
    var l = WorkspaceLayout()
    let a = l.add("file:///a"), left = try #require(l.focused)
    let b = l.add("file:///b")
    let right = l.newGroup(beside: left, vertical: true)
    let c = l.add("file:///c", to: right)
    return (l, left, right, [a.id, b.id, c.id])
}

@Test func tabsCycleAndWrapInTheFocusedGroup() throws {
    var (l, left, _, t) = try twoPanes()
    l.focused = left
    l.select(t[0])
    #expect(l.tab(cycling: 1) == t[1])
    #expect(l.tab(cycling: -1) == t[1])   // two tabs: either way round is the other one
    l.select(t[1])
    #expect(l.tab(cycling: 1) == t[0])   // wraps past the end
    #expect(l.tab(cycling: 5) == t[0])   // a long jump still lands inside the group
    #expect(WorkspaceLayout().tab(cycling: 1) == nil)
}

@Test func panesCycleAndWrapAndAloneThereIsNowhereToGo() throws {
    var (l, left, right, t) = try twoPanes()
    l.focused = left
    #expect(l.tabInGroup(cycling: 1) == l.groups[right]?.selectedTab?.id)
    l.focused = right
    #expect(l.tabInGroup(cycling: 1) == l.groups[left]?.selectedTab?.id)
    #expect(l.tabInGroup(cycling: -1) == l.groups[left]?.selectedTab?.id)
    var one = WorkspaceLayout()
    _ = one.add("file:///a")
    #expect(one.tabInGroup(cycling: 1) == nil)
    _ = t
}

/// Among panes side by side only the one you're in is being looked at; alone or zoomed, a pane is.
@Test func onlyTheFocusedPaneIsAttendedAmongSeveral() throws {
    var (l, left, right, _) = try twoPanes()
    l.focused = right
    #expect(l.attendedTabs(zoomed: nil).map(\.uri) == ["file:///c"])
    l.focused = left
    #expect(l.attendedTabs(zoomed: nil).map(\.uri) == ["file:///b"])
    #expect(l.attendedTabs(zoomed: right).map(\.uri) == ["file:///c"])
    var one = WorkspaceLayout()
    _ = one.add("file:///a")
    one.focused = nil
    #expect(one.attendedTabs(zoomed: nil).map(\.uri) == ["file:///a"])
    #expect(WorkspaceLayout().attendedTabs(zoomed: nil).isEmpty)
}

@Test func aFileOpenedAtAnotherLineIsTheSameTab() throws {
    let (l, _, _, t) = try twoPanes()
    #expect(l.fileTab(sameFileAs: "file:///b#L40")?.id == t[1])
    #expect(l.fileTab(sameFileAs: "file:///nope") == nil)
    #expect(l.fileTab(sameFileAs: "https://example.com/b") == nil)   // only files
}

@Test func theNearestPaneOnThatSideWins() {
    let me = CGRect(x: 100, y: 100, width: 100, height: 100)
    let panes = [
        "left": CGRect(x: 0, y: 100, width: 100, height: 100), "far": CGRect(x: -200, y: 100, width: 100, height: 100),
        "right": CGRect(x: 200, y: 100, width: 100, height: 100),
        "above": CGRect(x: 100, y: 200, width: 100, height: 100),
        "diagonal": CGRect(x: 200, y: 300, width: 100, height: 100)
    ]
    typealias Layout = WorkspaceLayout
    #expect(Layout.nearestPane(from: me, among: panes, toward: .minX) == "left")   // touching counts, the farther one doesn't
    #expect(Layout.nearestPane(from: me, among: panes, toward: .maxX) == "right")
    #expect(Layout.nearestPane(from: me, among: panes, toward: .maxY) == "above")   // y grows upward
    #expect(Layout.nearestPane(from: me, among: panes, toward: .minY) == nil)   // nothing below: the caller beeps
    #expect(
        Layout.nearestPane(
            from: me,
            among: [
                "a": CGRect(x: 300, y: 95, width: 10, height: 10), "b": CGRect(x: 300, y: 195, width: 10, height: 10)
            ],
            toward: .maxX) == "a")   // equal distance: stable
}
