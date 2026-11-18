import Core
import EditorKit
import Foundation
import TestSupport
import Testing
import WorkbenchKit

@testable import BuiltinFiles
@testable import KelpApp
@testable import KelpKit

/// One at a time: applying settings sets what every editor reads (`CodeEditor.current`).
extension OneAtATime {
    /// A language's block beats the setting for all files, Kelp's own wrapping of prose comes after that, the rest follow the setting.
    @Test func aLanguagesBlockBeatsTheSettingForAllFiles() {
        _ = testHome
        let app = AppModel(builtins: Builtins.all)
        let s = app.settings
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
    @Test func thePickersValueGoesInTheLanguagesOwnBlock() {
        _ = testHome
        let app = AppModel(builtins: Builtins.all)
        defer { CodeEditor.set(\.wrapLines, false) }
        let s = app.settings
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
    @Test func aChangeGoesWhereTheValueIsRead() {
        _ = testHome
        let app = AppModel(builtins: Builtins.all)
        defer { CodeEditor.set(\.wrapLines, false) }
        let s = app.settings
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

@Test(arguments: [
    ("/p/.env", true), ("/p/.env.local", true), ("/home/me/.ssh/id_ed25519", true), ("/p/server.pem", true),
    ("/p/tls.key", true), ("/p/.netrc", true), ("/p/main.swift", false), ("/p/environment.ts", false),
    ("/p/keyboard.swift", false)
])
func noModelIsShownAFileOfSecrets(path: String, secret: Bool) {
    #expect(Suggestions.holdsSecrets(path) == secret)
}

@MainActor @Test func theStatusBarNamesTheModelOrSaysWhyThereIsNone() {
    let qwen = SuggestModel(id: "qwen2.5-coder:1.5b-base", server: "Ollama", fillsIn: true)
    #expect(Suggestions.label(mode: "local", model: qwen, known: true) == "qwen2.5-coder:1.5b-base")
    #expect(Suggestions.label(mode: "off", model: qwen, known: true) == "Suggestions Off")
    #expect(Suggestions.label(mode: "off", model: nil, known: true) == nil)   // nothing to turn on: quiet
    #expect(Suggestions.label(mode: "local", model: nil, known: true) == "No Model")
    #expect(Suggestions.label(mode: "local", model: nil, known: false) == nil)   // not asked yet
    #expect(Suggestions.shortName("hf.co/bartowski/zeta-2-GGUF:Q4_K_M") == "zeta-2-GGUF:Q4_K_M")
    #expect(Suggestions.shortName("starcoder2:latest") == "starcoder2")
    #expect(Suggestions.label(mode: "local", model: qwen, known: true, pause: .lowPower) == "Paused: Low Power")
    #expect(Suggestions.label(mode: "off", model: qwen, known: true, pause: .hot) == "Suggestions Off")
}

@Test(
    arguments: [
        (false, ProcessInfo.ThermalState.nominal, nil), (false, .fair, nil), (false, .serious, .hot),
        (false, .critical, .hot),
        (true, .nominal, .lowPower), (true, .critical, .lowPower)
    ] as [(Bool, ProcessInfo.ThermalState, SuggestionPause?)])
func aModelOnThisMacWaitsWhileItSavesPowerOrRunsHot(
    lowPower: Bool, thermal: ProcessInfo.ThermalState, pause: SuggestionPause?
) {
    #expect(SuggestionPause.of(lowPower: lowPower, thermal: thermal) == pause)
}

@Test func theRingKeepsTheNewestPiecesOfOtherFilesWithinItsBudget() {
    var ring = SuggestionRing()
    ring.add(path: "Item.swift", text: "struct Item {\n    var price: Int\n}", from: 0)
    ring.add(path: "Cart.swift", line: 9, before: "a\nb\nlet x = ", after: " 1\nc\nd")
    #expect(ring.chunks.last?.text == "a\nb\nlet x =  1\nc\nd")   // the cursor's line whole, and the lines around it
    #expect(ring.chunks.last?.lines == 7..<12)
    #expect(ring.extra(for: "Cart.swift").map(\.path) == ["Item.swift"])   // never the file being filled in
    #expect(ring.extra(for: "Other.swift").map(\.path) == ["Item.swift", "Cart.swift"])   // newest nearest
    ring.add(path: "Item.swift", text: "struct Item {}", from: 1)   // overlaps the old start: replaces it
    #expect(ring.chunks.map(\.path) == ["Cart.swift", "Item.swift"])
    for n in 0..<20 { ring.add(path: "f\(n).swift", text: String(repeating: "x", count: 1000), from: 0) }
    #expect(ring.chunks.count == SuggestionRing.most)
    #expect(ring.extra(for: "z.swift").count == SuggestionRing.budget / 1000)
    ring.add(path: "blank.swift", text: "  \n ", from: 0)
    #expect(!ring.chunks.contains { $0.path == "blank.swift" })
}
