import AppKit
import Core
import Foundation
import TestSupport
import Testing

@testable import KelpApp
@testable import KelpKit

extension AppOfItsOwn {
    /// ⌘P lists the files the Files panel was last told (the daemon's push) instead of asking git for them on every
    /// opening; a row's item is made only for what's shown.
    @Test func quickOpenTakesTheFilesThePanelWasTold() async throws {
        _ = NSApplication.shared
        let rig = try await AppRig(files: ["real.swift": "x\n"])
        defer { rig.done() }
        rig.app.land(FilesEvent(worktree: rig.workspace.id, paths: ["src/ghost.swift", "real.swift"]))
        let q = QuickOpen(app: rig.app)
        q.build()
        q.list(query: "")
        #expect(try await waitFor { q.files.paths.count == 2 })
        q.field.stringValue = "ghost"
        q.filter()
        await q.scoring?.value
        let shown = q.rows.compactMap { if case .item(let it) = $0 { it.detail } else { nil } }
        #expect(shown.contains("src/ghost.swift"))
    }
}
