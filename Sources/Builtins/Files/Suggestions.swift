import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import SwiftUI

/// The app's side of the editor's gray text: which models the servers on this Mac offer, how often a suggestion was
/// taken today and how long one takes, and what each file's status bar says about it. From a model on this Mac the
/// code stays on it; from a cloud provider (`SuggestMode.cloud`) the code around the cursor goes to that provider, and
/// never a file of secrets (`holdsSecrets`).
@MainActor @Observable
final class Suggestions {
    static func of(_ app: AppModel) -> Suggestions { app.part { Suggestions(app) } }
    @ObservationIgnored unowned let app: AppModel
    private init(_ app: AppModel) {
        self.app = app
        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification]
        {
            watching.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.pause = SuggestionPause.now }   // queue: .main delivers here
                })
        }
        followNextEdit()
    }
    @ObservationIgnored private var watching: [any NSObjectProtocol] = []
    /// Why the model on this Mac isn't asked now, if it isn't.
    private(set) var pause = SuggestionPause.now
    @ObservationIgnored private var warmed = Date.distantPast

    /// What the servers offer, in the order the daemon picks one; nil until asked.
    private(set) var models: [SuggestModel]?
    /// Why the last ask brought nothing, until one brings something; and whether one has waited past a second.
    var problem: SuggestProblem?
    private(set) var loading = false
    /// Turn On's way to a model: one Ollama is downloading, what it still needs, or why it stopped.
    var pull: Pull?
    var needsOllama: OllamaSetup?
    /// Where suggestions came from before they were switched off.
    @ObservationIgnored var wereOn: SuggestMode?
    var setupError: String?
    /// Turn On is finding or getting a model.
    @ObservationIgnored var turningOn = false
    /// The next edit's llama-server: starting (the first time, downloading its model), or what it needs.
    var nextEditSetup: NextEditSetup?
    enum NextEditSetup: Equatable { case starting, needs(OllamaSetup), failed }

    struct Pull: Equatable {
        let model: String
        var completed = 0, total = 0
        var cancelled = false
    }

    /// No Ollama on this Mac: whether Homebrew can install it in a terminal tab, or the person downloads it.
    enum OllamaSetup: Equatable { case homebrew, download }
    @ObservationIgnored private var asking = false
    private(set) var today = Tally()

    struct Tally: Equatable {
        var day = Calendar.current.startOfDay(for: Date())
        var shown = 0, taken = 0
        /// The latest answers' waits, in seconds.
        var waits: [Double] = []
        var typicalWait: Double? { waits.isEmpty ? nil : waits.sorted()[waits.count / 2] }
    }

    /// What a file's status bar says, for its language; `secret` for a file no model is shown.
    func status(language: String?, secret: Bool, editOffered: Bool = false) -> SuggestionStatus? {
        let settings = app.settings, mode = settings[SettingKeys.suggestions, language: language]
        let named = settings[SettingKeys.suggestionModel], server = settings[SettingKeys.suggestionServerModel]
        let cloud = mode == .cloud ? settings[SettingKeys.suggestionCloud] : nil
        return SuggestionStatus.of(
            .init(
                mode: mode, everywhere: settings[SettingKeys.suggestions], secret: secret, model: model(named: named),
                known: models != nil, pause: pause, cloud: cloud.map { (Self.cloudName($0, model: server), keys[$0]) },
                problem: problem, loading: loading, editOffered: editOffered))
    }

    /// Forgets the last problem and looks for models again (Try Again, a key saved, a model picked).
    func retry() async {
        problem = nil
        warmed = .distantPast
        await refresh()
    }

    func refresh() async {
        guard !asking else { return }
        asking = true
        defer { asking = false }
        models = await app.quiet(EditorSuggestModels()) ?? []
    }

    /// The model the editor asks: the one named in Settings, else the first that fills in code.
    func model(named: String) -> SuggestModel? {
        named.isEmpty ? models?.first(where: \.fillsIn) : models?.first { $0.id == named }
    }

    private func tally(_ change: (inout Tally) -> Void) {
        if today.day != Calendar.current.startOfDay(for: Date()) { today = Tally() }
        change(&today)
    }

    /// Whether a key is saved for each cloud provider, once asked.
    private(set) var keys: [SuggestCloud: Bool] = [:]

    func checkKey(_ cloud: SuggestCloud) async {
        if let saved = await app.quiet(EditorSuggestKey(cloud: cloud)) { keys[cloud] = saved }
    }

    /// Asks for `cloud`'s key in a sheet and saves it in the login keychain (through the daemon).
    func askForKey(_ cloud: SuggestCloud) async {
        guard
            let key = await askSecret(
                String(localized: "API Key for \(Self.cloudName(cloud, model: ""))"),
                detail: String(localized: "It's stored in your login keychain, not in settings.json."),
                action: String(localized: "Save"), placeholder: String(localized: "Paste the key")),
            !key.isEmpty
        else { return }
        await saveKey(key, for: cloud)
    }

    func saveKey(_ key: String, for cloud: SuggestCloud) async {
        if let saved = await app.call(EditorSuggestKey(cloud: cloud, key: key)) {
            keys[cloud] = saved
            problem = nil
        }
    }

    /// A cloud provider's name as the status bar and the card say it: the service, or the model on a server of one's
    /// own.
    static func cloudName(_ cloud: SuggestCloud, model: String) -> String {
        switch cloud {
        case .mercury: "Mercury Edit 2"
        case .codestral: "Codestral"
        case .openai: if model.isEmpty { String(localized: "OpenAI-compatible server") } else { shortName(model) }
        }
    }

    /// How long typing pauses before a model is asked: 75 ms when its answers come in under a quarter of a second, so
    /// the gray text follows soon after a pause; 150 ms otherwise; 300 ms on the battery, to ask it less.
    nonisolated static func pause(battery: Bool, typicalWait: Double?) -> Duration {
        if battery { return .milliseconds(300) }
        return .milliseconds((typicalWait ?? 1) < 0.25 ? 75 : 150)
    }

    /// "hf.co/mradermacher/Seed-Coder-8B-Base-GGUF:Q4_K_M" → "Seed-Coder-8B-Base"; "qwen2.5-coder:latest" →
    /// "qwen2.5-coder"; "qwen2.5-coder:1.5b-base" stays.
    nonisolated static func shortName(_ id: String) -> String {
        var name = id.split(separator: "/").last.map(String.init) ?? id
        if name.hasSuffix(":latest") { name.removeLast(":latest".count) }
        // A Hugging Face build's file kind and quantization ("-GGUF:Q4_K_M") say nothing about the model.
        if let colon = name.lastIndex(of: ":"), name[name.index(after: colon)...].hasPrefix("Q") {
            name = String(name[..<colon])
        }
        if name.lowercased().hasSuffix("-gguf") { name.removeLast(5) }
        return name
    }

    /// Whether a file's name says it holds keys or passwords, whose text no model is shown.
    nonisolated static func holdsSecrets(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        return name.hasPrefix(".env") || name.hasPrefix("id_") || name.hasPrefix("secrets.")
            || [".pem", ".key", ".p12", ".pfx", ".tfvars"].contains { name.hasSuffix($0) }
            || [".netrc", "credentials", ".npmrc", ".pypirc", ".git-credentials"].contains(name)
    }

    private struct State: Equatable {
        var mode: SuggestMode, everywhere: SuggestMode, named: String, models: [SuggestModel]?, pause: SuggestionPause?
        var cloud: SuggestCloud?, hasKey: Bool?, problem: SuggestProblem?, loading: Bool, nextEdit: Bool
    }

    /// Gives a file's editor gray text from `editor.suggest` while the setting is on (never in a file of secrets), and
    /// keeps its status bar saying which model suggests.
    func attach(
        to editor: CodeEditor, bar: EditorStatusBar, path: String, root: String, owner: AnyObject
    ) {
        let language = editor.languageId
        // The model is told the file's path in its project, as its training data named files.
        let name = Paths.relative(path, to: root) ?? (path as NSString).lastPathComponent
        if models == nil { Task { await refresh() } }
        editor.onSuggestion = { [weak self] taken in
            self?.tally { tally in
                if taken { tally.taken += 1 } else { tally.shown += 1 }
            }
        }
        bar.onSuggestions = { [weak self] button in self?.showCard(from: button, language: language) }
        editor.onNextEdit = { [weak self, weak bar] offered in
            bar?.show(suggestions: self?.status(language: language, secret: false, editOffered: offered))
        }
        track(owner: owner) { [weak self, settings = app.settings] in
            State(
                mode: settings[SettingKeys.suggestions, language: language],
                everywhere: settings[SettingKeys.suggestions], named: settings[SettingKeys.suggestionModel],
                models: self?.models, pause: self?.pause,
                cloud: settings[SettingKeys.suggestionCloud],
                hasKey: self?.keys[settings[SettingKeys.suggestionCloud]],
                problem: self?.problem, loading: self?.loading ?? false, nextEdit: settings[SettingKeys.nextEdit])
        } changed: { [weak self, weak editor, weak bar] state in
            guard let self else { return }
            // A cloud model keeps on through low power and heat: they're this Mac's, and it runs elsewhere.
            let cloud = state.mode == .cloud ? state.cloud : nil
            let on = (state.mode == .local && state.pause == nil || cloud != nil) && !Self.holdsSecrets(path)
            editor?.suggestionProvider = on ? editor.map { provider(for: $0, name: name) } : nil
            // The next edit's model is this Mac's, whichever gray text comes from: it rests through low power and heat.
            editor?.nextEditProvider = on && state.nextEdit && state.pause == nil ? nextEditProvider(name: name) : nil
            if let cloud, state.hasKey == nil { Task { await checkKey(cloud) } }
            if on, cloud == nil, let editor { warm(editor, name: name, named: state.named) }
            bar?.show(suggestions: status(language: language, secret: Self.holdsSecrets(path)))
        }
    }

    /// Has the model read a file just opened, so the first suggestion in it doesn't wait for the model to load. At most
    /// once a minute: a model that was asked since stays loaded for minutes.
    private func warm(_ editor: CodeEditor, name: String, named: String) {
        guard Date().timeIntervalSince(warmed) > 60 else { return }
        warmed = Date()
        let ask = EditorSuggest(
            prefix: "", suffix: String(editor.text.prefix(2000)), path: name, model: named.isEmpty ? nil : named,
            warm: true)
        Task { [app, weak self] in
            // A server that's down shows at once, before any typing.
            if let answer = await app.quiet(ask) { self?.problem = answer.problem }
        }
    }

    private func provider(for editor: CodeEditor, name: String) -> (InlineSuggestion.Context) async -> String? {
        let app = app
        return { [weak self, weak editor] context in
            // Kelp in the background asks nothing; on the battery, typing pauses longer before the next ask.
            guard NSApp.isActive else { return nil }
            editor?.suggestionDelay = Self.pause(
                battery: SuggestionPause.onBattery, typicalWait: self?.today.typicalWait)
            guard let self else { return nil }
            let settings = app.settings, start = Date()
            let cloud =
                settings[SettingKeys.suggestions, language: editor?.languageId] == .cloud
                ? settings[SettingKeys.suggestionCloud] : nil
            let url = settings[SettingKeys.suggestionURL]
            let model = Self.model(
                for: cloud, local: settings[SettingKeys.suggestionModel],
                server: settings[SettingKeys.suggestionServerModel])
            let ask = EditorSuggest(
                prefix: context.prefix, suffix: context.suffix, path: name, model: model, cloud: cloud,
                url: cloud == nil || cloud == .mercury || url.isEmpty ? nil : url)
            let slow = whileSlow { [weak self] in self?.loading = true }   // the model is loading: say so past a second
            let answer = await app.quiet(ask, timeout: EditorSuggest.timeout ?? 10)
            slow.cancel()
            loading = false
            guard let answer, !Task.isCancelled else { return nil }   // a newer edit asked instead
            problem = answer.problem
            if answer.text != nil {
                tally { $0.waits = Array(($0.waits + [Date().timeIntervalSince(start)]).suffix(50)) }
            }
            return answer.text
        }
    }

    /// The model the editor names for `cloud`: this Mac's, or a server of one's own's; none for a cloud provider, which
    /// is asked for its own.
    nonisolated static func model(for cloud: SuggestCloud?, local: String, server: String) -> String? {
        let named =
            switch cloud {
            case nil: local
            case .openai: server
            case .mercury, .codestral: ""
            }
        return named.isEmpty ? nil : named
    }

    private func showCard(from button: NSView, language: String) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: SuggestionsCard(suggestions: self, language: language) { popover.close() })
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}
