import AppKit
import Core
import DesignKit
import TestSupport
import Testing

@testable import BuiltinDatabases
@testable import KelpKit

extension AppOfItsOwn {
    /// Add Database closed (Cancel, or Add) while its check still waits for the server: the late answer lands nowhere,
    /// and the sheet isn't kept for it.
    @Test func aCheckThatAnswersAfterTheSheetClosedLandsNowhere() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        var sheet: DatabaseSheet? = DatabaseSheet(app: rig.app, worktreeId: rig.workspace.id)
        let db = DatabaseInfo(name: "x", engine: .postgres, host: "127.0.0.1", port: 1, database: "x")
        sheet?.openForm(DatabaseAddress(database: db))
        weak var form = sheet?.pane, closed = sheet
        func all(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + all($0) } }
        let fields = all(try #require(sheet?.window.contentView)).compactMap { $0 as? NSTextField }
        // Yielding (not sleeping) between looks, so the sheet goes while the check waits for its answer.
        for _ in 0..<10_000 where !fields.contains(where: { $0.stringValue.hasPrefix("Connecting") }) {
            await Task.yield()
        }
        #expect(fields.contains { $0.stringValue.hasPrefix("Connecting") })
        sheet = nil
        #expect(closed == nil)
        try await waitFor { form == nil }   // the answer came, and the form let go
    }

    /// The form's Agents control has five levels since See Structure: each is shown whole, none cut short.
    @Test func theFormShowsEveryAgentsLevelWhole() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let sheet = DatabaseSheet(app: rig.app, worktreeId: rig.workspace.id)
        sheet.openForm(DatabaseAddress(database: DatabaseInfo(name: "x", engine: .sqlite, path: "/tmp/x.sqlite")))
        sheet.window.contentView?.layoutSubtreeIfNeeded()
        func all(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + all($0) } }
        let content = try #require(sheet.window.contentView)
        let agents = try #require(
            all(content).compactMap { $0 as? CapsuleSegments }.first {
                $0.segmentCount == DatabaseInfo.Access.allCases.count
            })
        let labels = (0..<agents.segmentCount).compactMap { agents.label(forSegment: $0) }
        #expect(agents.frame.width >= CapsuleSegments(labels: labels, name: "").fittingSize.width)
    }
}
