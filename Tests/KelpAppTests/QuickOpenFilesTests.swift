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

extension AppOfItsOwn {
    /// ⌘P lists the lines open terminals printed with what's typed, under their own heading after its own matches: one
    /// row per terminal, its newest such line in the monospaced face, and how many more lines have it. Fewer than three
    /// characters look in no output.
    @Test func quickOpenListsLinesTerminalsPrinted() async throws {
        _ = NSApplication.shared
        let rig = try await AppRig(files: ["migrate.ts": "x\n"])
        defer { rig.done() }
        let printed = "printf 'npm run migrate\\nError: migrate failed\\n'; cat"
        let s = try await rig.client.call(SessionCreate(worktreeId: rig.workspace.id, command: printed))
        rig.app.sessions = [s]
        rig.app.extensions.reload()   // the built-ins' contributions, Agents' lines of output among them
        #expect(try await waitFor { try await rig.client.call(SessionRead(id: s.id)).contains("failed") })
        let q = QuickOpen(app: rig.app)
        q.build()
        q.list(query: "")
        #expect(try await waitFor { q.files.paths.count == 1 })
        func search(_ text: String) async -> [QuickOpen.Row] {
            q.field.stringValue = text
            q.filter()
            await q.scoring?.value
            return q.rows
        }
        let rows = await search("migrate")
        let headings = rows.compactMap { if case .heading(let text) = $0 { text } else { nil } }
        #expect(headings == ["Files", "In Terminal Output"])
        guard case .item(let line)? = rows.last else {
            Issue.record("no line of output")
            return
        }
        #expect(line.title == "Error: migrate failed" && line.mono && line.note.contains("1"))
        #expect(!(await search("mi")).contains { if case .heading("In Terminal Output") = $0 { true } else { false } })
    }
}
