import AppKit
import Core
import DesignKit
import Foundation
import TestSupport
import Testing

@testable import BuiltinActivity
@testable import BuiltinAgents
@testable import KelpApp
@testable import KelpKit

/// The limit card under the sidebar opens by the hover card's rule: not the moment the pointer touches its row, at
/// once on a click, and a close puts it away.
@MainActor @Test func aLimitCardWaitsForThePointerToRest() async throws {
    let card = LimitCardHover()
    card.hover("claude", true)
    #expect(card.shown == nil)   // the pointer only touched the row
    #expect(try await waitFor { card.shown == "claude" })   // it rested there
    card.close()
    #expect(card.shown == nil)
    card.show("codex")   // a click
    #expect(card.shown == "codex")
    card.hover("codex", false)
    #expect(try await waitFor { card.shown == nil })   // the pointer left
}

extension AppOfItsOwn {
    /// A session's Stop in the Activity panel shows only while the pointer is over its row, as a row's actions do.
    @Test func activityStopShowsUnderThePointerOnly() async throws {
        let rig = try await AppRig()
        defer { rig.done() }
        defer { rig.app.latest(ActivityEvent.self).byKey[""] = nil }
        var session = Session(cwd: "/", command: "x", agent: "shell", status: .working)
        session.worktreeId = rig.workspace.id
        rig.app.sessions = [session]
        let vc = ActivityController(app: rig.app)
        rig.show(vc, 300, 400)
        let table = try #require(Self.tables(in: vc.view).first)
        rig.app.land(ActivityEvent(usage: [.init(session: session.id, cpu: 1, memory: 1000, processes: 2)]))
        #expect(try await waitFor { table.numberOfRows == 1 })
        let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let stop = try #require(Self.buttons(in: cell).first)
        #expect(stop.isHidden)
        try #require(cell as? Hoverable).setHover(true)
        #expect(!stop.isHidden)
        try #require(cell as? Hoverable).setHover(false)
        #expect(stop.isHidden)
    }

    private static func tables(in v: NSView) -> [NSTableView] {
        (v as? NSTableView).map { [$0] } ?? v.subviews.flatMap(tables)
    }
    private static func buttons(in v: NSView) -> [IconButton] {
        (v as? IconButton).map { [$0] } ?? v.subviews.flatMap(buttons)
    }
}
