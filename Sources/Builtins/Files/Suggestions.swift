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

    /// What the status bar says: the model while it suggests, Off while a model could, No Model when none can; nothing
    /// while it's off and there's no model to turn on.
    static func label(mode: String, model: SuggestModel?, known: Bool, pause: SuggestionPause? = nil) -> String? {
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
        editor.onSuggestion = { [weak self] taken in self?.tally { taken ? ($0.taken += 1) : ($0.shown += 1) } }
        bar.onSuggestions = { [weak self] button in self?.showCard(from: button, language: language) }
        track(owner: owner) { [weak self, settings = app.settings] in
            State(
                mode: settings[SettingKeys.suggestions, language: language],
                named: settings[SettingKeys.suggestionModel], models: self?.models, pause: self?.pause)
        } changed: { [weak self, weak editor, weak bar] state in
            guard let self else { return }
            let on = state.mode != "off" && state.pause == nil && !Self.holdsSecrets(path)
            editor?.suggestionProvider = on ? editor.map { provider(for: $0, name: name) } : nil
            if on, let editor {
                ring.add(path: name, text: String(editor.text.prefix(SuggestionRing.width * 2)), from: 0)
                warm(editor, name: name, named: state.named)
            }
            bar?.show(
                suggestions: Self.label(
                    mode: state.mode, model: model(named: state.named), known: state.models != nil, pause: state.pause))
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
            let named = app.settings[SettingKeys.suggestionModel], start = Date()
            let ask = EditorSuggest(
                prefix: context.prefix, suffix: context.suffix, path: name, model: named.isEmpty ? nil : named,
                extra: ring.extra(for: name))
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

/// What the status bar's suggestions item opens: the model and how it does today, how to turn it on, or how to get a
/// model when there's none.
struct SuggestionsCard: View {
    let suggestions: Suggestions
    let language: String
    let close: () -> Void
    private var app: AppModel { suggestions.app }

    var body: some View {
        let mode = app.settings[SettingKeys.suggestions, language: language]
        let model = suggestions.model(named: app.settings[SettingKeys.suggestionModel])
        VStack(alignment: .leading, spacing: Metrics.inset) {
            if let model, mode == "off" {
                title(String(localized: "Code Suggestions"))
                Text("\(model.server) is running on this Mac with \(model.id).").foregroundStyle(.secondary)
                buttons(String(localized: "Turn On")) { app.settings.set(SettingKeys.suggestions, "local") }
            } else if let model {
                title(Suggestions.shortName(model.id))
                if let pause = suggestions.pause { Text(pause.reason).foregroundStyle(.secondary) }
                facts(model)
                buttons(String(localized: "Turn Off"), prominent: false) {
                    app.settings.set(SettingKeys.suggestions, "off")
                }
            } else {
                title(String(localized: "No Model Found"))
                Text("Install Ollama, then download a model for code:").foregroundStyle(.secondary)
                Text(verbatim: "ollama pull qwen2.5-coder:1.5b-base").font(.uiMono(TextSize.caption)).textSelection(
                    .enabled)
                buttons(String(localized: "Try Again")) { Task { await suggestions.refresh() } }
            }
        }
        .font(.ui(TextSize.row))
        .padding(Metrics.inset)
        .frame(width: 300, alignment: .leading)
        .task { await suggestions.refresh() }
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.ui(TextSize.heading, weight: .semibold)).lineLimit(1)
    }

    private func facts(_ model: SuggestModel) -> some View {
        let today = suggestions.today
        let taken =
            today.shown == 0
            ? String(localized: "None shown yet")
            : String(localized: "\(today.taken * 100 / today.shown)% · \(today.taken) of \(today.shown)")
        return VStack(spacing: Metrics.gap) {
            fact(String(localized: "Where"), String(localized: "This Mac · \(model.server)"))
            fact(String(localized: "Taken today"), taken)
            if let wait = today.typicalWait {
                fact(String(localized: "Typical wait"), String(localized: "\(Int(wait * 1000)) ms"))
            }
        }
    }

    private func fact(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }

    /// Settings…, then the card's one action: the default button when it's the step forward (Turn On, Try Again).
    private func buttons(_ main: String, prominent: Bool = true, _ action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button(String(localized: "Settings…")) {
                close()
                app.extensions.run(
                    "workbench.openSettings", ["section": .string("editor"), "group": .string("Code suggestions")])
            }
            if prominent {
                Button(main, action: action).keyboardShortcut(.defaultAction)
            } else {
                Button(main, action: action)
            }
        }
    }
}
