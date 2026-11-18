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

    var body: some View {
        let mode = app.settings[SettingKeys.suggestions, language: language]
        let named = app.settings[SettingKeys.suggestionModel]
        let model = suggestions.model(named: named)
        VStack(alignment: .leading, spacing: Metrics.inset) {
            if mode == "cloud", let cloud = SuggestCloud(rawValue: app.settings[SettingKeys.suggestionCloud]) {
                cloudCard(cloud, named: named)
            } else if let model, mode == "off" {
                title(String(localized: "Code Suggestions"))
                Text("\(model.server) is running on this Mac with \(model.id).").foregroundStyle(.secondary)
                buttons(String(localized: "Turn On")) { app.settings.set(SettingKeys.suggestions, "local") }
            } else if let model {
                title(Suggestions.shortName(model.id))
                if let pause = suggestions.pause { Text(pause.reason).foregroundStyle(.secondary) }
                facts(String(localized: "This Mac · \(model.server)"))
                buttons(String(localized: "Turn Off"), prominent: false) {
                    app.settings.set(SettingKeys.suggestions, "off")
                }
            } else {
                title(String(localized: "No Model Found"))
                Text("Install Ollama, then download a model for code:").foregroundStyle(.secondary)
                Text(verbatim: "ollama pull qwen2.5-coder:1.5b-base").font(.uiMono(TextSize.caption))
                    .textSelection(.enabled)
                buttons(String(localized: "Try Again")) { Task { await suggestions.refresh() } }
            }
        }
        .font(.ui(TextSize.row))
        .padding(Metrics.inset)
        .frame(width: 300, alignment: .leading)
        .task { await suggestions.refresh() }
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
            buttons(String(localized: "Turn Off"), prominent: false) {
                app.settings.set(SettingKeys.suggestions, "off")
            }
        }
    }

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
