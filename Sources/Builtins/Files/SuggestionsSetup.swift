import AppKit
import Core
import DesignKit
import KelpKit

/// Turn On in one step: a code model already on this Mac, else the one recommended for it downloaded through Ollama,
/// else Ollama itself installed with Homebrew in a terminal tab the person watches.
extension Suggestions {
    /// The model to suggest with: ByteDance's Seed-Coder 8B (MIT) where there's memory for it (32 GB), else
    /// qwen2.5-coder 1.5B (Apache-2.0). On Kelp's code Seed-Coder was sure in 59 % of the places against 41 %, right
    /// 61 % of the time exactly against 56 %, and answered in about 0.13 s; it beat qwen2.5-coder 7B and Mellum 4B.
    nonisolated static func recommended(memory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> (
        id: String, size: String
    ) {
        memory >= 32 << 30
            ? ("hf.co/mradermacher/Seed-Coder-8B-Base-GGUF:Q4_K_M", "5.1 GB") : ("qwen2.5-coder:1.5b-base", "1 GB")
    }

    func turnOn() async {
        setupError = nil
        needsOllama = nil
        await refresh()
        if let local = models?.filter(\.fillsIn), !local.isEmpty {
            return enable(model: local.contains { $0.id == Self.recommended().id } ? Self.recommended().id : "")
        }
        let found = await app.quiet(ProcessWhich(commands: ["ollama", "brew"])) ?? [:]
        let ollamaApp = SuggestionsCard.ollamaApp
        guard ollamaApp != nil || found["ollama"] != nil else {
            needsOllama = found["brew"] == nil ? .download : .homebrew
            return
        }
        if let ollamaApp, models?.isEmpty != false {   // not running: the download waits for it to listen
            NSWorkspace.shared.openApplication(at: ollamaApp, configuration: .init()) { _, _ in }
        }
        await download(Self.recommended().id)
    }

    /// Has Ollama download `model`, showing how far it has come; turns suggestions on with it when it's in.
    func download(_ model: String) async {
        setupError = nil
        pull = Pull(model: model)
        let (done, error) = await app.tryCall(EditorSuggestPull(model: model))
        let cancelled = pull?.cancelled == true
        pull = nil
        if done != nil {
            await refresh()
            enable(model: model)
        } else if !cancelled {
            setupError = error
        }
    }

    func cancelDownload() {
        pull?.cancelled = true
        Task { await app.call(EditorSuggestPullCancel()) }
    }

    func downloaded(_ progress: SuggestPullEvent) {
        guard pull?.model == progress.model else { return }
        pull?.completed = progress.completed
        pull?.total = progress.total
    }

    /// Installs Ollama's app with Homebrew in a terminal tab, then goes on with Turn On once the tab's command ends;
    /// without Homebrew, opens Ollama's download page.
    func installOllama() {
        guard needsOllama == .homebrew, app.workbench.starter != nil else {
            if let page = URL(string: "https://ollama.com/download") { PreviewLinks.openOutside(page) }
            return
        }
        runInTerminal("brew install --cask ollama-app && open -a Ollama", title: String(localized: "Install Ollama")) {
            [weak self] in await self?.turnOn()
        }
    }

    /// Runs `command` in a terminal tab the person watches, and `then` once it has ended.
    func runInTerminal(_ command: String, title: String, then: @escaping @MainActor () async -> Void) {
        let app = app
        app.workbench.starter?.run(command: command, title: title) { [weak self] made in
            track(owner: self, now: false) {
                app.session(made.id).map { $0.status == .exited } ?? true
            } changed: { ended in
                if ended { Task { await then() } }
            }
        }
    }

    /// Suggestions on, from this Mac, with `model` (empty: the first that fills in code).
    func enable(model: String) {
        app.settings.set(SettingKeys.suggestionModel, model.isEmpty ? nil : model)
        app.settings.set(SettingKeys.suggestions, .local)
        problem = nil
    }

    /// Off, remembering where suggestions came from, so switching them on again goes back there.
    func turnOff() {
        let mode = app.settings[SettingKeys.suggestions]
        if mode != .off { wereOn = mode }
        app.settings.set(SettingKeys.suggestions, .off)
    }

    /// On again from where they last came: the cloud, or else this Mac (Turn On's way).
    func switchOn() async {
        if wereOn == .cloud { return use(app.settings[SettingKeys.suggestionCloud]) }
        await turnOn()
    }

    /// Suggestions off in `language`'s files only, or back to the setting for all files.
    func set(on: Bool, in language: String) {
        app.settings.setOwn(SettingKeys.suggestions.key, on ? nil : SuggestMode.off.setting, language: language)
    }

    /// Suggestions from `cloud`, which asks for its key when it has none.
    func use(_ cloud: SuggestCloud) {
        app.settings.set(SettingKeys.suggestionCloud, cloud)
        app.settings.set(SettingKeys.suggestions, .cloud)
        problem = nil
    }
}
