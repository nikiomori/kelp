import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import SwiftUI

/// The app's side of the editor's gray text: which models the servers on this Mac offer, how often a suggestion was
/// taken today and how long one takes, and what each file's status bar says about it. Nothing leaves this Mac.
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
    }
    @ObservationIgnored private var watching: [any NSObjectProtocol] = []
    /// Why the model on this Mac isn't asked now, if it isn't.
    private(set) var pause = SuggestionPause.now
    @ObservationIgnored private var warmed = Date.distantPast
    /// Code from the files lately open or edited, which goes with each suggestion asked in another file.
    @ObservationIgnored private var ring = SuggestionRing()

    /// What the servers offer, in the order the daemon picks one; nil until asked.
    private(set) var models: [SuggestModel]?
    @ObservationIgnored private var asking = false
    private(set) var today = Tally()

    struct Tally: Equatable {
        var day = Calendar.current.startOfDay(for: Date())
        var shown = 0, taken = 0
        /// The latest answers' waits, in seconds.
        var waits: [Double] = []
        var typicalWait: Double? { waits.isEmpty ? nil : waits.sorted()[waits.count / 2] }
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
        if let saved = await app.call(EditorSuggestKey(cloud: cloud, key: key)) { keys[cloud] = saved }
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

    /// What the status bar says: the model while it suggests (a cloud one named as such), Off while a model could, No
    /// Model or No Key when none can; nothing while it's off and there's no model to turn on.
    static func label(
        mode: String, model: SuggestModel?, known: Bool, pause: SuggestionPause? = nil,
        cloud: (name: String, hasKey: Bool?)? = nil
    ) -> String? {
        if mode == "cloud", let cloud {
            return cloud.hasKey == false
                ? String(localized: "Cloud: No Key") : String(localized: "Cloud · \(cloud.name)")
        }
        if mode == "off" { return model == nil ? nil : String(localized: "Suggestions Off") }
        guard let model else { return known ? String(localized: "No Model") : nil }
        return pause?.title ?? shortName(model.id)
    }

    /// "hf.co/bartowski/zeta-2-GGUF:Q4_K_M" → "zeta-2-GGUF:Q4_K_M"; "qwen2.5-coder:latest" → "qwen2.5-coder".
    static func shortName(_ id: String) -> String {
        let name = id.split(separator: "/").last.map(String.init) ?? id
        return name.hasSuffix(":latest") ? String(name.dropLast(":latest".count)) : name
    }

    /// Whether a file's name says it holds keys or passwords, whose text no model is shown.
    nonisolated static func holdsSecrets(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        return name.hasPrefix(".env") || name.hasPrefix("id_") || name.hasSuffix(".pem") || name.hasSuffix(".key")
            || name.hasSuffix(".p12") || name == ".netrc" || name == "credentials"
    }

    private struct State: Equatable {
        var mode: String, named: String, models: [SuggestModel]?, pause: SuggestionPause?
        var cloud: SuggestCloud?, hasKey: Bool?
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
        track(owner: owner) { [weak self, settings = app.settings] in
            State(
                mode: settings[SettingKeys.suggestions, language: language],
                named: settings[SettingKeys.suggestionModel], models: self?.models, pause: self?.pause,
                cloud: SuggestCloud(rawValue: settings[SettingKeys.suggestionCloud]),
                hasKey: SuggestCloud(rawValue: settings[SettingKeys.suggestionCloud]).flatMap { self?.keys[$0] })
        } changed: { [weak self, weak editor, weak bar] state in
            guard let self else { return }
            // A cloud model keeps on through low power and heat: they're this Mac's, and it runs elsewhere.
            let cloud = state.mode == "cloud" ? state.cloud : nil
            let on = (state.mode == "local" && state.pause == nil || cloud != nil) && !Self.holdsSecrets(path)
            editor?.suggestionProvider = on ? editor.map { provider(for: $0, name: name) } : nil
            if let cloud, state.hasKey == nil { Task { await checkKey(cloud) } }
            if on, let editor {
                ring.add(path: name, text: String(editor.text.prefix(SuggestionRing.width * 2)), from: 0)
                if cloud == nil { warm(editor, name: name, named: state.named) }
            }
            bar?.show(
                suggestions: Self.label(
                    mode: state.mode, model: model(named: state.named), known: state.models != nil, pause: state.pause,
                    cloud: cloud.map { (Self.cloudName($0, model: state.named), state.hasKey) }))
        }
    }

    /// Has the model read a file just opened, so the first suggestion in it doesn't wait for the model to load. At most
    /// once a minute: a model that was asked since stays loaded for minutes.
    private func warm(_ editor: CodeEditor, name: String, named: String) {
        guard Date().timeIntervalSince(warmed) > 60 else { return }
        warmed = Date()
        let ask = EditorSuggest(
            prefix: "", suffix: String(editor.text.prefix(2000)), path: name, model: named.isEmpty ? nil : named,
            warm: true, extra: ring.extra(for: name))
        Task { [app] in _ = await app.quiet(ask) }
    }

    private func provider(for editor: CodeEditor, name: String) -> (InlineSuggestion.Context) async -> String? {
        let app = app
        return { [weak self, weak editor] context in
            // Kelp in the background asks nothing; on the battery, typing pauses longer before the next ask.
            guard NSApp.isActive else { return nil }
            editor?.suggestionDelay = .milliseconds(SuggestionPause.onBattery ? 300 : 150)
            guard let self else { return nil }
            let settings = app.settings, named = settings[SettingKeys.suggestionModel], start = Date()
            let cloud =
                settings[SettingKeys.suggestions, language: editor?.languageId] == "cloud"
                ? SuggestCloud(rawValue: settings[SettingKeys.suggestionCloud]) : nil
            let url = settings[SettingKeys.suggestionURL]
            let ask = EditorSuggest(
                prefix: context.prefix, suffix: context.suffix, path: name, model: named.isEmpty ? nil : named,
                extra: ring.extra(for: name), cloud: cloud, url: cloud == nil || url.isEmpty ? nil : url)
            // These lines go with the next suggestion asked in another file.
            ring.add(path: name, line: (editor?.cursor?.line ?? 1) - 1, before: context.prefix, after: context.suffix)
            let answer = await app.quiet(ask, timeout: EditorSuggest.timeout ?? 10) ?? nil
            if answer != nil {
                tally { $0.waits = Array(($0.waits + [Date().timeIntervalSince(start)]).suffix(50)) }
            }
            return answer
        }
    }

    private func showCard(from button: NSView, language: String) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: SuggestionsCard(suggestions: self, language: language) { popover.close() })
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}
