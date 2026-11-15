import AppKit
import Core
import Foundation
import TestSupport
import Testing

@testable import BuiltinActivity
@testable import BuiltinFiles
@testable import BuiltinGit
@testable import KelpApp
@testable import KelpKit

/// A panel swapped out of the inspector, or under a collapsed one, rebuilds nothing on each change: what came meanwhile
/// shows, the latest of it, once the panel does.
@MainActor private func tables(in v: NSView) -> [NSTableView] {
    (v as? NSTableView).map { [$0] } ?? v.subviews.flatMap(tables)
}
@MainActor private func cell(_ table: NSTableView, _ row: Int) -> NSView? {
    table.view(atColumn: 0, row: row, makeIfNecessary: true)
}
/// Long enough for a change to reach a panel's `track` (the next turn of the main queue), had it been going to.
@MainActor private func settle() async throws { try await Task.sleep(for: .milliseconds(150)) }
/// Laid out and settled: the cells a row has now are the ones it keeps until it's drawn again.
@MainActor private func steady(_ table: NSTableView) async throws {
    try await settle()
    table.window?.layoutIfNeeded()
    for row in 0..<table.numberOfRows { _ = cell(table, row) }
}

extension AppOfItsOwn {
    @Test func artifactsOutOfTheWindowRebuildWhenBack() async throws {
        let rig = try await AppRig()
        defer { rig.done() }
        let wid = rig.workspace.id
        defer { rig.app.latest(ArtifactsEvent.self).byKey[wid] = nil }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 500), styleMask: [.titled], backing: .buffered,
            defer: true)
        let panel = ArtifactsPanel(app: rig.app)
        window.contentView?.addSubview(panel.view)
        panel.view.removeFromSuperview()   // another panel took its place
        let page = ArtifactItem(
            slug: "p", type: "page", title: "Plan", created: Date().timeIntervalSince1970, target: "/tmp/p.html")
        rig.app.land(ArtifactsEvent(worktree: wid, items: [page]))
        try await settle()
        #expect(panel.rows.isEmpty)
        window.contentView?.addSubview(panel.view)
        #expect(panel.rows.count == 2)   // its day's heading and the page
    }

    @Test func sourceControlUnderACollapsedInspectorAppliesGitWhenShown() async throws {
        let rig = try await AppRig()
        defer { rig.done() }
        let wid = rig.workspace.id
        try rig.write("f.txt", "b\n")
        let vc = SourceControlController(app: rig.app)
        rig.show(vc, 320, 700)
        vc.view.isHidden = true
        rig.app.watch(.git, wid)   // as the Files panel or a diff tab would
        defer { rig.app.unwatch(.git, wid) }
        #expect(try await waitFor(5) { rig.app.latest(GitEvent.self, wid)?.changes?.isEmpty == false })
        try await settle()
        #expect(vc.changes.isEmpty)
        vc.view.isHidden = false
        #expect(!vc.changes.isEmpty && vc.changes == rig.app.latest(GitEvent.self, wid)?.changes)   // at once
    }

    @Test func filesRedrawOnlyTheBadgesThatMovedAndNoneWhileHidden() async throws {
        let rig = try await AppRig()
        defer { rig.done() }
        let wid = rig.workspace.id
        defer {
            rig.app.latest(GitEvent.self).byKey[wid] = nil
            rig.app.latest(FilesEvent.self).byKey[wid] = nil
        }
        let panel = FilesPanel(app: rig.app)
        rig.show(panel, 300, 500)
        rig.app.land(FilesEvent(worktree: wid, paths: ["a.txt", "b.txt"], ignored: []))
        #expect(try await waitFor(5) { panel.outline.numberOfRows == 2 })
        try await steady(panel.outline)
        // A row's git letter: a row is drawn again in the cell it had (cells are used again), so it's read, not compared.
        @MainActor func letter(_ row: Int) -> String {
            let fields = cell(panel.outline, row)?.subviews.compactMap { $0 as? NSTextField } ?? []
            return fields.last?.stringValue ?? ""
        }
        let b = cell(panel.outline, 1)
        rig.app.land(GitEvent(worktree: wid, changes: [FileChange(path: "a.txt", index: ".", worktree: "M")]))
        #expect(try await waitFor(5) { letter(0) == "M" })
        #expect(cell(panel.outline, 1) === b && letter(1).isEmpty)   // its badge didn't change: not drawn again

        try await steady(panel.outline)
        panel.view.isHidden = true
        rig.app.land(GitEvent(worktree: wid, changes: [FileChange(path: "b.txt", index: ".", worktree: "M")]))
        try await settle()
        #expect(letter(0) == "M" && letter(1).isEmpty)   // hidden: nothing drawn
        panel.view.isHidden = false
        #expect(letter(0).isEmpty && letter(1) == "M")
    }

    @Test func activityRedrawsOnlyFiguresThatShowAChange() async throws {
        let rig = try await AppRig()
        defer { rig.done() }
        defer { rig.app.latest(ActivityEvent.self).byKey[""] = nil }
        var session = Session(cwd: "/", command: "x", agent: "shell", status: .working)
        session.worktreeId = rig.workspace.id
        rig.app.sessions = [session]
        let vc = ActivityController(app: rig.app)
        rig.show(vc, 300, 400)
        let table = try #require(tables(in: vc.view).first)
        func measured(_ cpu: Double) -> ActivityEvent {
            ActivityEvent(usage: [.init(session: session.id, cpu: cpu, memory: 1000, processes: 2)])
        }
        rig.app.land(measured(1.21))
        #expect(try await waitFor(5) { table.numberOfRows == 1 })
        try await steady(table)
        let row = cell(table, 0)
        rig.app.land(measured(1.23))   // still "1.2%"
        try await settle()
        #expect(cell(table, 0) === row)
        rig.app.land(measured(5))
        #expect(try await waitFor(5) { cell(table, 0) !== row })
    }
}
