import Core
import EditorKit
import TestSupport
import Testing
import WorkbenchKit

@testable import BuiltinFiles
@testable import KelpKit

/// One at a time: applying settings sets what every editor reads (`CodeEditor.wrapLines`).
extension OneAtATime {
    /// A language's block beats the setting for all files, Kelp's own wrapping of prose comes after that, the rest follow the setting.
    @Test func aLanguagesBlockBeatsTheSettingForAllFiles() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let s = rig.app.settings
        s.apply([
            "editor.wordWrap": .bool(false), "[go]": .object(["editor.formatOnSave": .bool(true)]),
            "[markdown]": .object(["editor.tabSize": .double(2)])
        ])
        #expect(s.bool("editor.wordWrap", language: "markdown") == true)   // Kelp's default for prose
        #expect(s.bool("editor.wordWrap", language: "plaintext") == true)
        #expect(s.bool("editor.wordWrap", language: "swift") == false)
        #expect(s.bool("editor.formatOnSave", language: "go") == true)
        #expect(s.bool("editor.formatOnSave") != true)
        #expect(s.number("editor.tabSize", language: "markdown") == 2)
    }

    /// Settings' language picker writes the language's block even when it had nothing yet, and its reset empties it.
    @Test func thePickersValueGoesInTheLanguagesOwnBlock() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        defer { CodeEditor.wrapLines = false }
        let s = rig.app.settings
        s.apply(["editor.tabSize": .int(4)])
        s.setOwn("editor.tabSize", .int(2), language: "python")
        #expect(s.number("editor.tabSize", language: "python") == 2)
        #expect(s.number("editor.tabSize") == 4)
        #expect(s.languagesSet == ["python"])
        s.setOwn("editor.tabSize", nil, language: "python")
        #expect(s.values["[python]"] == nil)
        #expect(CodeEditor.languageIds.contains("python") && CodeEditor.languageIds.contains("markdown"))
    }

    /// Word Wrap in a Markdown file changes Markdown; in Swift, every file: each where it's read.
    @Test func aChangeGoesWhereTheValueIsRead() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
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

extension AppOfItsOwn {
    /// A project's .editorconfig comes before what the file does and the settings.
    @Test func aProjectsEditorconfigSetsAFilesIndentation() async throws {
        let rig = try await AppRig(files: [
            ".editorconfig": "root = true\n[*.txt]\nindent_style = tab\nindent_size = 8\n", "a.txt": "    x\n"
        ])
        defer { rig.done() }
        rig.app.worktrees = [rig.workspace]
        let tab = FileTab(uri: TabURI.file(rig.workspace.path + "/a.txt"), app: rig.app)
        await tab.loading?.value
        let e = try #require(tab.editor)
        #expect(try await waitFor(5) { !(e.tabWidth != 8) })
        #expect(e.tabWidth == 8)
    }
}

@MainActor @Test func rulersAreWhateverNumbersTheSettingHas() {
    #expect(FileRules.columns("80, 120") == [80, 120])
    #expect(FileRules.columns("  100") == [100])
    #expect(FileRules.columns("") == [] && FileRules.columns(nil) == [])
}
