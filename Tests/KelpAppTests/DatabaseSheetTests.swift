import AppKit
import Core
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
}
