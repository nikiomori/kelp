import Core
import EditorKit
import Testing
@testable import KelpKit

/// One at a time: applying settings sets what every editor reads (`CodeEditor.wrapLines`).
extension OneAtATime {
    /// A language's block beats the setting for all files, Kelp's own wrapping of prose comes after that, the rest follow the setting.
    @Test func aLanguagesBlockBeatsTheSettingForAllFiles() async throws {
        let rig = try await AppRig(files: [:]); defer { rig.done() }
        let s = rig.app.settings
        s.apply(["editor.wordWrap": .bool(false), "[go]": .object(["editor.formatOnSave": .bool(true)]), "[markdown]": .object(["editor.tabSize": .double(2)])])
        #expect(s.bool("editor.wordWrap", language: "markdown") == true)     // Kelp's default for prose
        #expect(s.bool("editor.wordWrap", language: "plaintext") == true)
        #expect(s.bool("editor.wordWrap", language: "swift") == false)
        #expect(s.bool("editor.formatOnSave", language: "go") == true)
        #expect(s.bool("editor.formatOnSave") != true)
        #expect(s.number("editor.tabSize", language: "markdown") == 2)
    }

    /// Word Wrap in a Markdown file changes Markdown; in Swift, every file: each where it's read.
    @Test func aChangeGoesWhereTheValueIsRead() async throws {
        let rig = try await AppRig(files: [:]); defer { rig.done() }
        defer { CodeEditor.wrapLines = false }
        let s = rig.app.settings
        s.apply(["editor.wordWrap": .bool(false)])
        s.set("editor.wordWrap", .bool(false), language: "markdown")
        #expect(s.bool("editor.wordWrap", language: "markdown") == false)
        #expect(s.bool("editor.wordWrap") == false)
        s.set("editor.wordWrap", .bool(true), language: "swift")
        #expect(s.bool("editor.wordWrap") == true)
        #expect(s.bool("editor.wordWrap", language: "markdown") == false)   // still its own
    }
}
