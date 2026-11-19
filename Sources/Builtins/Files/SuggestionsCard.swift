import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI

/// What the status bar's suggestions item opens: the model and how it does today, how to turn it on, how to get a
/// model when there's none, or a key when a cloud one has none.
struct SuggestionsCard: View {
    let suggestions: Suggestions
    let language: String
    let close: () -> Void
    private var app: AppModel { suggestions.app }

    /// Whether the card shows every model to pick from (Other Models…).
    @State private var listing = false

    var body: some View {
        let mode = app.settings[SettingKeys.suggestions, language: language]
        let named = app.settings[SettingKeys.suggestionModel]
        let model = suggestions.model(named: named)
        VStack(alignment: .leading, spacing: Metrics.inset) {
            if listing {
                title(String(localized: "Code Suggestions"))
                SuggestionsList(suggestions: suggestions)
                buttons(String(localized: "Done")) { listing = false }
            } else if let pull = suggestions.pull {
                pullCard(pull)
            } else if let setup = suggestions.needsOllama {
                ollamaCard(setup)
            } else if let error = suggestions.setupError {
                title(String(localized: "Couldn't Get the Model"))
                Text(error).foregroundStyle(.secondary)
                otherModels()
                buttons(String(localized: "Try Again")) { Task { await suggestions.turnOn() } }
            } else if mode != .off, let problem = suggestions.problem, problem != .keyMissing,
                let status = suggestions.status(language: language, secret: false), status.needsYou
            {
                problemCard(problem, title: status.text, named: named)
            } else if mode == .off, app.settings[SettingKeys.suggestions] != .off {
                title(String(localized: "Off in \(LanguageName.of(language)) Files"))
                Text("Suggestions are on in other files.").foregroundStyle(.secondary)
                buttons(String(localized: "Turn On in \(LanguageName.of(language)) Files")) {
                    suggestions.set(on: true, in: language)
                }
            } else if mode == .cloud {
                let cloud = app.settings[SettingKeys.suggestionCloud]
                cloudCard(cloud, named: app.settings[SettingKeys.suggestionServerModel])
            } else if let model, mode != .off {
                title(Suggestions.shortName(model.id))
                if let pause = suggestions.pause { Text(pause.reason).foregroundStyle(.secondary) }
                facts(String(localized: "This Mac · \(model.server)"))
                otherModels()
                offHere()
                buttons(String(localized: "Turn Off"), prominent: false) {
                    suggestions.turnOff()
                }
            } else {
                offCard(model)
            }
        }
        .font(.ui(TextSize.row))
        .padding(Metrics.inset)
        .frame(width: 320, alignment: .leading)
        .task { await suggestions.refresh() }
    }

    /// Off, or on with no model yet: one button that gets it going.
    @ViewBuilder private func offCard(_ model: SuggestModel?) -> some View {
        let recommended = Suggestions.recommended()
        title(String(localized: "Code Suggestions"))
        Text("Gray text as you type, from a model on this Mac. Your code stays on it.").foregroundStyle(.secondary)
        if model == nil {
            Text("Kelp gets \(Suggestions.shortName(recommended.id)) (\(recommended.size)) through Ollama.")
                .foregroundStyle(.secondary)
        }
        otherModels()
        buttons(String(localized: "Turn On")) { Task { await suggestions.turnOn() } }
    }

    private func pullCard(_ pull: Suggestions.Pull) -> some View {
        let bytes = { (count: Int) in ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file) }
        return Group {
            title(String(localized: "Getting \(Suggestions.shortName(pull.model))"))
            Text("Ollama downloads it into its own folder.").foregroundStyle(.secondary)
            ProgressView(value: Double(pull.completed), total: Double(max(pull.total, 1)))
            Text(pull.total == 0 ? String(localized: "Starting…") : "\(bytes(pull.completed)) / \(bytes(pull.total))")
                .font(.ui(TextSize.caption)).monospacedDigit().foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { suggestions.cancelDownload() }
            }
        }
    }

    @ViewBuilder private func ollamaCard(_ setup: Suggestions.OllamaSetup) -> some View {
        title(String(localized: "Ollama Runs the Model"))
        Text(
            setup == .homebrew
                ? String(
                    localized: "Ollama runs code models on this Mac. Kelp installs it with Homebrew in a terminal tab.")
                : String(localized: "Ollama runs code models on this Mac. Download it, then Turn On again.")
        ).foregroundStyle(.secondary)
        otherModels()
        buttons(setup == .homebrew ? String(localized: "Install Ollama") : String(localized: "Download Ollama")) {
            close()
            suggestions.installOllama()
        }
    }

    /// Off for this file's language only, the rest going on as they are.
    private func offHere() -> some View {
        Button(String(localized: "Turn Off in \(LanguageName.of(language)) Files")) {
            suggestions.set(on: false, in: language)
        }
        .buttonStyle(.link)
    }

    /// Every model to pick from, the cloud's too.
    private func otherModels() -> some View {
        Button(String(localized: "Other Models…")) { listing = true }.buttonStyle(.link)
    }

    @ViewBuilder private func cloudCard(_ cloud: SuggestCloud, named: String) -> some View {
        let name = Suggestions.cloudName(cloud, model: named)
        if suggestions.keys[cloud] == false {
            title(String(localized: "\(name) Needs a Key"))
            Text("The code around the cursor goes to \(Self.company(cloud, app.settings[SettingKeys.suggestionURL])).")
                .foregroundStyle(.secondary)
            buttons(String(localized: "Add Key…")) { addKey(cloud) }
        } else {
            title(name)
            facts(String(localized: "Cloud · \(Self.company(cloud, app.settings[SettingKeys.suggestionURL]))"))
            Button(String(localized: "Change Key…")) { addKey(cloud) }.buttonStyle(.link)
            offHere()
            buttons(String(localized: "Turn Off"), prominent: false) {
                suggestions.turnOff()
            }
        }
    }

    /// Why nothing comes, and the one button that fixes it.
    @ViewBuilder private func problemCard(_ problem: SuggestProblem, title text: String, named: String) -> some View {
        let cloud =
            app.settings[SettingKeys.suggestions, language: language] == .cloud
            ? app.settings[SettingKeys.suggestionCloud] : nil
        title(text)
        switch problem {
        case .noServer:
            Text("Nothing answers where Ollama, LM Studio or llama-server listen on this Mac.").foregroundStyle(
                .secondary)
            if let ollama = Self.ollamaApp {
                buttons(String(localized: "Open Ollama")) {
                    NSWorkspace.shared.openApplication(at: ollama, configuration: .init()) { _, _ in }
                    close()
                    Task { await suggestions.retry() }
                }
            } else {
                retry()
            }
        case .noModel:
            Text("No server on this Mac has a model that fills in code. Download one:").foregroundStyle(.secondary)
            Text(verbatim: "ollama pull qwen2.5-coder:1.5b-base").font(.uiMono(TextSize.caption)).textSelection(
                .enabled)
            retry()
        case .modelMissing:
            Text(
                cloud == .openai
                    ? String(localized: "The server needs an address and a code model Kelp knows (Qwen2.5-Coder…).")
                    : String(localized: "No server on this Mac has \(named). Pick another model, or download it.")
            ).foregroundStyle(.secondary)
            retry()
        case .keyRejected:
            if let cloud {
                let company = Self.company(cloud, app.settings[SettingKeys.suggestionURL])
                Text(
                    cloud == .codestral
                        ? String(
                            localized: "Mistral didn't take the key. A free key works only at codestral.mistral.ai.")
                        : String(localized: "\(company) didn't take the key.")
                ).foregroundStyle(.secondary)
                buttons(String(localized: "Change Key…")) { addKey(cloud) }
            }
        case .notAnswering:
            Text("No answer came in 8 seconds, or there's no connection.").foregroundStyle(.secondary)
            retry()
        case .failed, .keyMissing:
            Text("The server answered with an error.").foregroundStyle(.secondary)
            retry()
        }
    }

    private func retry() -> some View {
        buttons(String(localized: "Try Again")) { Task { await suggestions.retry() } }
    }

    /// Ollama's app, when it's installed where apps go.
    static var ollamaApp: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.electron.ollama") }

    /// Who the code goes to: the company, or the server's host.
    static func company(_ cloud: SuggestCloud, _ url: String) -> String {
        switch cloud {
        case .mercury: "Inception"
        case .codestral: "Mistral"
        case .openai: URL(string: url)?.host ?? String(localized: "the server")
        }
    }

    private func addKey(_ cloud: SuggestCloud) {
        close()   // the sheet goes on the window, which the popover would cover
        Task { await suggestions.askForKey(cloud) }
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.ui(TextSize.heading, weight: .semibold)).lineLimit(1)
    }

    private func facts(_ place: String) -> some View {
        let today = suggestions.today
        let taken =
            today.shown == 0
            ? String(localized: "None shown yet")
            : String(localized: "\(today.taken * 100 / today.shown)% · \(today.taken) of \(today.shown)")
        return VStack(spacing: Metrics.gap) {
            fact(String(localized: "Where"), place)
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
