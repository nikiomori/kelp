import Core
import Foundation
import TestSupport
import Testing
import WorkbenchKit

@testable import BuiltinFiles
@testable import EditorKit
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

    /// The status bar's card turns suggestions off in one language's files and back to the setting for all.
    @Test func suggestionsGoOffInOneLanguageAndBackOn() {
        _ = testHome
        let app = AppModel(builtins: Builtins.all)
        let s = app.settings
        s.apply(["editor.suggestions": .string("local")])
        Suggestions.of(app).set(on: false, in: "markdown")
        #expect(s[SettingKeys.suggestions, language: "markdown"] == .off)
        #expect(s[SettingKeys.suggestions, language: "swift"] == .local && s[SettingKeys.suggestions] == .local)
        Suggestions.of(app).set(on: true, in: "markdown")
        #expect(s[SettingKeys.suggestions, language: "markdown"] == .local)
        #expect(s.values["[markdown]"] == nil)   // nothing of its own left
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
        #expect(try await waitFor { e.tabWidth == 8 })
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
    ("/p/keyboard.swift", false), ("/p/.npmrc", true), ("/p/.pypirc", true), ("/p/prod.tfvars", true),
    ("/home/me/.git-credentials", true), ("/p/secrets.yaml", true), ("/p/cert.pfx", true),
    ("/p/secretsauce.swift", false)
])
func noModelIsShownAFileOfSecrets(path: String, secret: Bool) {
    #expect(Suggestions.holdsSecrets(path) == secret)
}

@Test func theStatusBarNamesTheModelOrSaysWhyThereIsNone() {
    let qwen = SuggestModel(id: "qwen2.5-coder:1.5b-base", server: "Ollama", fillsIn: true)
    func status(_ change: (inout SuggestionStatus.Inputs) -> Void) -> SuggestionStatus? {
        var inputs = SuggestionStatus.Inputs(mode: .local, everywhere: .local, model: qwen)
        change(&inputs)
        return SuggestionStatus.of(inputs)
    }
    let cases: [(SuggestionStatus?, String?, Bool)] = [
        (status { _ in }, "qwen2.5-coder:1.5b-base", false),
        (status { $0.loading = true }, "qwen2.5-coder:1.5b-base · Loading…", false),
        (status { $0.editOffered = true }, "qwen2.5-coder:1.5b-base · Edit Below", false),
        (
            status {
                $0.editOffered = true
                $0.problem = .noServer
            }, "Ollama Isn’t Running", true
        ),   // what needs you comes first
        (status { $0.problem = .noServer }, "Ollama Isn’t Running", true),
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
        (status { $0.mode = .off }, "Off in This File", false),   // off for this language only
        (
            status {
                $0.mode = .off
                $0.everywhere = .off
            }, "Suggestions Off", false
        ),
        (
            status {
                $0.mode = .off
                $0.everywhere = .off
                $0.model = nil
            }, nil, false
        ),
        // A cloud model is named as one, whatever runs on this Mac and however warm it is.
        (
            status {
                $0.mode = .cloud
                $0.cloud = ("Codestral", true)
                $0.pause = .hot
            }, "Cloud · Codestral", false
        ),
        (
            status {
                $0.mode = .cloud
                $0.cloud = ("Codestral", false)
            }, "Cloud: No Key", true
        ),
        (
            status {
                $0.mode = .cloud
                $0.cloud = ("Codestral", true)
                $0.problem = .keyRejected
            },
            "Codestral: Key Rejected", true
        ),
        (
            status {
                $0.mode = .cloud
                $0.cloud = ("Codestral", true)
                $0.problem = .notAnswering
            },
            "Codestral Isn’t Answering", true
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

@Test func theModelRecommendedFitsTheMacsMemory() {
    #expect(Suggestions.recommended(memory: 16 << 30).id == "qwen2.5-coder:1.5b-base")
    #expect(Suggestions.recommended(memory: 32 << 30).id == "hf.co/mradermacher/Seed-Coder-8B-Base-GGUF:Q4_K_M")
}

@Test func aQuickModelIsAskedSoonerAndTheBatteryAsksLess() {
    #expect(Suggestions.pause(battery: false, typicalWait: 0.13) == .milliseconds(75))
    #expect(Suggestions.pause(battery: false, typicalWait: 0.6) == .milliseconds(150))
    #expect(Suggestions.pause(battery: false, typicalWait: nil) == .milliseconds(150))   // not timed yet
    #expect(Suggestions.pause(battery: true, typicalWait: 0.13) == .milliseconds(300))
}

@Test func theNextEditIsAskedWithTheEditsOldestFirstAndTheLatestLast() {
    let ask = NextEdit.Ask(
        earlier: [.init(old: "a", new: "A")], latest: .init(old: "b", new: "B"), original: "b", current: "B",
        firstLine: 0)
    let request = Suggestions.request(ask, path: "Sources/X.swift")
    #expect(request.changes == [NextEditChange(old: "a", new: "A"), NextEditChange(old: "b", new: "B")])
    #expect(request.path == "Sources/X.swift" && request.original == "b" && request.current == "B")
}

/// A cloud provider is asked for its own model, never this Mac's; only a server of one's own names one.
@Test(
    arguments: [
        (nil, "qwen2.5-coder:1.5b-base"), (SuggestCloud.mercury, nil), (.codestral, nil), (.openai, "qwen2.5-coder-7b")
    ] as [(SuggestCloud?, String?)])
func aCloudProviderIsntAskedForThisMacsModel(cloud: SuggestCloud?, model: String?) {
    #expect(Suggestions.model(for: cloud, local: "qwen2.5-coder:1.5b-base", server: "qwen2.5-coder-7b") == model)
}

/// The next edit's model follows its setting, whoever changed it: on starts it (here no daemon answers, so the start
/// fails at once), off stops it.
@MainActor @Test func theNextEditsModelFollowsItsSetting() async throws {
    _ = testHome
    let app = AppModel(builtins: [])
    let suggestions = Suggestions.of(app)
    // Settings read after the part was made, with the next edit on: Kelp opening, which starts nothing.
    app.settings.apply(["editor.suggestions": .string("local"), "editor.nextEdit": .bool(true)])
    app.settings.loaded = true   // as `load` does once the daemon answered
    try await waitFor { suggestions.settingsWereRead }
    await Task {}.value   // a start it began would have run by now, on the main actor before this
    #expect(suggestions.nextEditSetup == nil)
    app.settings.apply(["editor.suggestions": .string("local"), "editor.nextEdit": .bool(false)])
    await Task {}.value   // `track` looks again on the main queue's next turn: let it see the switch off
    app.settings.apply(["editor.suggestions": .string("local"), "editor.nextEdit": .bool(true)])   // as the daemon's echo
    try await waitFor { suggestions.nextEditSetup == .failed }
    app.settings.apply(["editor.suggestions": .string("local"), "editor.nextEdit": .bool(false)])
    try await waitFor { suggestions.nextEditSetup == nil }
}

/// Where suggestions come from is one of three words: one it doesn't know (a typo in settings.json) reads as off.
@Test(arguments: [
    (JSONValue.string("cloud"), SuggestMode.cloud), (.string("local"), .local), (.string("clod"), .off),
    (.bool(true), .off)
])
func aSuggestionModeItDoesntKnowReadsAsOff(stored: JSONValue, mode: SuggestMode) {
    #expect(SettingKeys.suggestions.read(stored) == mode)
}
