import AppKit
import Core
import DesignKit
import KelpKit

/// Turn On in one step: a code model already on this Mac, else the one recommended for it downloaded through Ollama,
/// else Ollama itself installed with Homebrew in a terminal tab the person watches.
extension Suggestions {
    /// The model to suggest with: the 1.5B, which answers in about 0.2 s and, keeping only what it's sure of, is right
    /// as often as the 7B is (measured on Kelp's code). Both are Apache-2.0; the 3B is licensed for research only.
    nonisolated static func recommended() -> (id: String, size: String) { ("qwen2.5-coder:1.5b-base", "1 GB") }

    /// The model offered beside it where there's memory for it (32 GB): more often sure, about 0.9 s an answer.
    nonisolated static func larger(memory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> (
        id: String, size: String
    )? {
        memory >= 32 << 30 ? ("qwen2.5-coder:7b-base", "4.7 GB") : nil
    }

    func turnOn() async {
        setupError = nil
        needsOllama = nil
        await refresh()
        if models?.contains(where: \.fillsIn) == true { return enable(model: "") }
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
        guard needsOllama == .homebrew, let starter = app.workbench.starter else {
            if let page = URL(string: "https://ollama.com/download") { PreviewLinks.openOutside(page) }
            return
        }
        let app = app
        starter.run(
            command: "brew install --cask ollama-app && open -a Ollama", title: String(localized: "Install Ollama")
        ) { [weak self] made in
            track(owner: self, now: false) {
                app.session(made.id).map { $0.status == .exited } ?? true
            } changed: { [weak self] ended in
                if ended { Task { await self?.turnOn() } }
            }
        }
    }

    /// Suggestions on, from this Mac, with `model` (empty: the first that fills in code).
    func enable(model: String) {
        app.settings.set(SettingKeys.suggestionModel, model.isEmpty ? nil : model)
        app.settings.set(SettingKeys.suggestions, "local")
        problem = nil
    }

    /// Off, remembering where suggestions came from, so switching them on again goes back there.
    func turnOff() {
        let mode = app.settings[SettingKeys.suggestions]
        if mode != "off" { wereOn = mode }
        app.settings.set(SettingKeys.suggestions, "off")
    }

    /// On again from where they last came: the cloud, or else this Mac (Turn On's way).
    func switchOn() async {
        if wereOn == "cloud", let cloud = SuggestCloud(rawValue: app.settings[SettingKeys.suggestionCloud]) {
            return use(cloud)
        }
        await turnOn()
    }

    /// Suggestions from `cloud`, which asks for its key when it has none.
    func use(_ cloud: SuggestCloud) {
        app.settings.set(SettingKeys.suggestionCloud, cloud.rawValue)
        app.settings.set(SettingKeys.suggestions, "cloud")
        problem = nil
    }
}
