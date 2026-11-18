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

@Test func theStatusBarNamesTheModelOrSaysWhyThereIsNone() {
    let qwen = SuggestModel(id: "qwen2.5-coder:1.5b-base", server: "Ollama", fillsIn: true)
    func status(_ change: (inout SuggestionStatus.Inputs) -> Void) -> SuggestionStatus? {
        var inputs = SuggestionStatus.Inputs(mode: "local", everywhere: "local", model: qwen)
        change(&inputs)
        return SuggestionStatus.of(inputs)
    }
    let cases: [(SuggestionStatus?, String?, Bool)] = [
        (status { _ in }, "qwen2.5-coder:1.5b-base", false),
        (status { $0.loading = true }, "qwen2.5-coder:1.5b-base · Loading…", false),
        (status { $0.problem = .noServer }, "Ollama Isn't Running", true),
        (status { $0.problem = .noModel }, "No Code Model", true),
        (status { $0.model = nil }, "No Code Model", true),
        (
            status {
                $0.model = nil
                $0.known = false
            }, nil, false
        ),   // not asked yet: quiet
        (status { $0.pause = .lowPower }, "Paused: Low Power", false),
        (status { $0.secret = true }, "Off in This File", false),
        (status { $0.mode = "off" }, "Off in This File", false),   // off for this language only
        (
            status {
                $0.mode = "off"
                $0.everywhere = "off"
            }, "Suggestions Off", false
        ),
        (
            status {
                $0.mode = "off"
                $0.everywhere = "off"
                $0.model = nil
            }, nil, false
        ),
        // A cloud model is named as one, whatever runs on this Mac and however warm it is.
        (
            status {
                $0.mode = "cloud"
                $0.cloud = ("Codestral", true)
                $0.pause = .hot
            }, "Cloud · Codestral", false
        ),
        (
            status {
                $0.mode = "cloud"
                $0.cloud = ("Codestral", false)
            }, "Cloud: No Key", true
        ),
        (
            status {
                $0.mode = "cloud"
                $0.cloud = ("Codestral", true)
                $0.problem = .keyRejected
            },
            "Codestral: Key Rejected", true
        ),
        (
            status {
                $0.mode = "cloud"
                $0.cloud = ("Codestral", true)
                $0.problem = .notAnswering
            },
            "Codestral Isn't Answering", true
        )
    ]
    for (got, text, needsYou) in cases {
        #expect(got?.text == text)
        #expect((got?.needsYou ?? false) == needsYou)
    }
    #expect(Suggestions.shortName("hf.co/mradermacher/Seed-Coder-8B-Base-GGUF:Q4_K_M") == "Seed-Coder-8B-Base")
    #expect(Suggestions.shortName("qwen2.5-coder:1.5b-base") == "qwen2.5-coder:1.5b-base")
    #expect(Suggestions.shortName("starcoder2:latest") == "starcoder2")
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

@Test func theLargerModelIsOfferedWhereThereIsMemoryForIt() {
    #expect(Suggestions.recommended().id == "qwen2.5-coder:1.5b-base")
    #expect(Suggestions.larger(memory: 16 << 30) == nil)
    #expect(Suggestions.larger(memory: 32 << 30)?.id == "hf.co/mradermacher/Seed-Coder-8B-Base-GGUF:Q4_K_M")
}
