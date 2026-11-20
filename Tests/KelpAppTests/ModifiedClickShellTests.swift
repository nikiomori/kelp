import AppKit
import Core
import Foundation
import TestSupport
import Testing
import WorkbenchKit

@testable import KelpKit

/// A tab with nothing in it, which closes when asked.
@MainActor private final class PlainTab: TabContent {
    let uri: String
    let view = NSView()
    var title: String { uri }
    var icon: NSImage? { nil }
    init(_ uri: String) { self.uri = uri }
    func focus() {}
    func close() async -> Bool { true }
}

extension OneAtATime {
    /// A click on a tab's ✕ closes that tab; with ⌥ held it closes the pane's other tabs, as in Safari.
    @Test func optionClickOnATabsCloseButtonClosesTheOthers() async throws {
        _ = testHome
        let plain = Builtin("test.plain", "Plain", "", icon: "doc") { _ in
            Contributions(tabs: [TabProvider(schemes: ["plain"]) { PlainTab($0) }])
        }
        let app = AppModel(builtins: [plain])
        app.extensions.reload()
        var layout = WorkspaceLayout()
        for name in ["a", "b", "c", "d"] { layout.add("plain:" + name) }
        app.workbench.layouts["w"] = layout
        let area = EditorArea(app: app, workspaceId: "w")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered,
            defer: true)   // never shown
        window.contentView?.addSubview(area.view)
        area.render()
        let strip = try #require(area.groupViews.values.first?.strip)
        func uris() -> [String] { area.layout.allTabs.map(\.uri) }
        func button(_ uri: String) throws -> TabButton {
            let id = try #require(area.layout.allTabs.first { $0.uri == uri }?.id)
            return try #require(strip.buttons.first { $0.item?.id == id })
        }

        try button("plain:a").clickClose(with: [])
        #expect(try await waitFor(5) { uris() == ["plain:b", "plain:c", "plain:d"] })
        try button("plain:c").clickClose(with: .option)
        #expect(try await waitFor(5) { uris() == ["plain:c"] })
    }

    /// In Quick Open a click only selects a row, and with ⇧ it opens the row beside, as ⇧↩ does. A row with nothing
    /// to open beside stays as it is.
    @Test func shiftClickInQuickOpenOpensTheRowBeside() throws {
        _ = testHome
        _ = NSApplication.shared
        let palette = QuickOpen(app: AppModel(builtins: []))
        palette.build()
        var ran: [String] = []
        palette.setRows(
            [
                .init(
                    kind: "File", icon: "doc", title: "a.swift", detail: "", action: { ran.append("open a") },
                    split: { ran.append("beside a") }),
                .init(kind: "File", icon: "doc", title: "b.swift", detail: "", action: { ran.append("open b") })
            ], grouped: false)
        palette.table.selectRowIndexes([0], byExtendingSelection: false)
        palette.click(with: [])
        #expect(ran.isEmpty)
        palette.click(with: .shift)
        #expect(ran == ["beside a"])
        palette.table.selectRowIndexes([1], byExtendingSelection: false)
        palette.click(with: .shift)
        #expect(ran == ["beside a"])
    }
}

/// An agent's menu item gets a stand-in that shows while ⌘ is held and starts it in a new group, as a ⌘-click does.
/// An item with a key gets none: macOS doesn't count a key's ⌘ when it swaps two items, so the stand-in would show
/// instead of the item.
@MainActor @Test func anAgentsMenuItemHasANewGroupStandInWhileCommandIsHeld() throws {
    _ = NSApplication.shared
    var ran: [String] = []
    for key in ["", "t"] {
        let menu = NSMenu()
        let item = menu.add("Claude Code", key: key) { ran.append("here") }
        let alternate = menu.addNewGroupAlternate(of: item, agent: "Claude Code", column: 0) { ran.append("new group") }
        guard key.isEmpty else {
            #expect(alternate == nil && menu.items.count == 1)
            continue
        }
        let new = try #require(alternate)
        #expect(menu.items.map(\.title) == ["Claude Code", "Claude Code in New Group\t⌘-click"])
        #expect(new.isAlternate && new.keyEquivalentModifierMask == .command && item.keyEquivalentModifierMask == [])
        menu.performActionForItem(at: 1)
    }
    #expect(ran == ["new group"])
}
