import AppKit
import Testing

@testable import BuiltinDatabases
@testable import KelpKit

extension AppOfItsOwn {
    /// Appwrite is a URL and a key: its form starts with an empty endpoint (not "localhost"), has no port beside it,
    /// no SSH or SSL, and its note wraps inside the sheet instead of widening it.
    @Test func appwritesFormIsAnEndpointAndAKey() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let preset = try #require(EnginePreset.all.first { $0.engine == .appwrite })
        let sheet = DatabaseSheet(app: rig.app, worktreeId: rig.workspace.id)
        sheet.newOne(preset)
        let form = try #require(sheet.window.contentView)
        form.layoutSubtreeIfNeeded()
        func all(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + all($0) } }
        let views = all(form), fields = views.compactMap { $0 as? NSTextField }
        let typed = fields.filter { $0.isEditable && !$0.isHidden }
        let endpoint = try #require(typed.first { $0.placeholderString == "https://appwrite.example.com" })
        #expect(endpoint.stringValue.isEmpty)
        #expect(!(endpoint.superview is NSStackView), "a port sat beside it in a row")
        let titles = views.compactMap { ($0 as? NSButton)?.title }
        #expect(!titles.contains { $0.contains("SSH") || $0 == "SSL" }, "\(titles)")
        let hint = try #require(preset.hint), note = try #require(fields.first { $0.stringValue == hint })
        #expect(sheet.window.frame.width <= DatabaseSheet.width + 1)
        #expect(note.frame.width <= form.bounds.width && note.frame.height > 2 * (note.font?.pointSize ?? 11))
    }
}
