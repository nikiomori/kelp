import Core
import DesignKit
import KelpKit
import SwiftUI

/// Every place gray text can come from, picked with one click: the code models on this Mac (and the one recommended
/// for it, to download), the cloud providers with their key typed in place, and a server of one's own. The status
/// bar's card and Settings › Editor show the same list.
struct SuggestionsList: View {
    let suggestions: Suggestions
    /// The list's text size: Settings' body, or a row's in the status bar's card, whose switches are small too.
    var size = TextSize.body
    private var switches: ControlSize { size < TextSize.body ? .small : .regular }
    @State private var key = ""
    private var app: AppModel { suggestions.app }

    var body: some View {
        let settings = app.settings, mode = settings[SettingKeys.suggestions]
        let named = settings[SettingKeys.suggestionModel],
            cloud = settings[SettingKeys.suggestionCloud]
        let local = (suggestions.models ?? []).filter(\.fillsIn), recommended = Suggestions.recommended()
        VStack(alignment: .leading, spacing: 2) {
            // On or off here; where from is the row picked below, and picking one turns them on.
            Toggle(
                String(localized: "Suggest code as you type"),
                isOn: Binding(
                    get: { mode != .off },
                    set: { on in
                        if on { Task { await suggestions.switchOn() } } else { suggestions.turnOff() }
                    })
            )
            .toggleStyle(.switch).controlSize(switches).padding(.horizontal, 6)
            nextEdit(on: mode != .off)
            heading(String(localized: "On This Mac"))
            ForEach(local, id: \.id) { model in
                let picked = mode == .local && (named == model.id || named.isEmpty && local.first == model)
                row(Suggestions.shortName(model.id), side: model.server, picked: picked) {
                    suggestions.enable(model: model.id)
                }
            }
            if !local.contains(where: { $0.id == recommended.id }) {
                get(recommended, note: String(localized: "recommended · \(recommended.size)"))
            }
            heading(String(localized: "Cloud"))
            ForEach([SuggestCloud.mercury, .codestral, .openai], id: \.self) { each in
                let picked = mode == .cloud && cloud == each
                row(
                    each == .openai ? String(localized: "Your Server") : Suggestions.cloudName(each, model: ""),
                    side: side(each), picked: picked
                ) { suggestions.use(each) }
                if picked { details(each) }
            }
        }
        .font(.ui(size))
        .task {
            if suggestions.models == nil { await suggestions.refresh() }
            for each in SuggestCloud.allCases where suggestions.keys[each] == nil { await suggestions.checkKey(each) }
        }
    }

    /// The next edit: its own switch under the main one, and what its model needs.
    @ViewBuilder private func nextEdit(on: Bool) -> some View {
        let wanted = app.settings[SettingKeys.nextEdit]
        Toggle(
            String(localized: "Predict the next edit"),
            isOn: Binding(get: { on && wanted }, set: { app.settings.set(SettingKeys.nextEdit, $0) })
        )
        .toggleStyle(.switch).controlSize(switches).padding(.horizontal, 6).padding(.top, Metrics.gap).disabled(!on)
        if on, wanted {
            HStack(spacing: Metrics.gap) {
                switch suggestions.nextEditSetup {
                case .starting:
                    ProgressView().controlSize(.mini)
                    Text(String(localized: "Getting Sweep Next-Edit ready (1.5 GB the first time)…"))
                case .needs:
                    Text(String(localized: "Needs llama.cpp"))
                    Spacer()
                    Button(String(localized: "Install")) { suggestions.installLlama() }
                case .failed:
                    Text(String(localized: "llama-server stopped"))
                    Spacer()
                    Button(String(localized: "Try Again")) { Task { await suggestions.startNextEdit() } }
                case nil:
                    Text(String(localized: "Sweep Next-Edit on this Mac · ⇥ goes to the edit, ⇥ takes it"))
                }
            }
            .font(.ui(TextSize.caption)).foregroundStyle(.secondary).controlSize(.small)
            .padding(.horizontal, 6).padding(.bottom, 2)
        }
    }

    private func side(_ cloud: SuggestCloud) -> String {
        let company = SuggestionsCard.company(cloud, app.settings[SettingKeys.suggestionURL])
        guard cloud != .openai else { return String(localized: "address, model, key") }
        return suggestions.keys[cloud] == true ? String(localized: "\(company) · key saved") : company
    }

    /// Under a picked cloud provider: its key when there's none (and the server's address and model for one's own).
    @ViewBuilder private func details(_ cloud: SuggestCloud) -> some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            if cloud == .openai {
                TextField(String(localized: "Server address"), text: setting(SettingKeys.suggestionURL))
                TextField(String(localized: "Model"), text: setting(SettingKeys.suggestionServerModel))
            }
            if suggestions.keys[cloud] != true {
                HStack(spacing: Metrics.gap) {
                    SecureField(String(localized: "Paste the key"), text: $key)
                    Button(String(localized: "Save Key")) {
                        let typed = key
                        key = ""
                        Task { await suggestions.saveKey(typed, for: cloud) }
                    }
                    .disabled(key.isEmpty)
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(.leading, 26).padding(.trailing, 6).padding(.bottom, 4)
    }

    private func setting(_ setting: Setting<String>) -> Binding<String> {
        Binding(get: { app.settings[setting] }, set: { app.settings.set(setting, $0.isEmpty ? nil : $0) })
    }

    /// A model to download through Ollama (Turn On's way when there's none yet).
    private func get(_ model: (id: String, size: String), note: String) -> some View {
        HStack(spacing: Metrics.gap) {
            Image(systemName: "arrow.down.circle").font(.symbol()).foregroundStyle(.secondary).frame(width: 14)
            Text(Suggestions.shortName(model.id)).lineLimit(1)
            Spacer()
            Text(note).foregroundStyle(.secondary).lineLimit(1)
            Button(String(localized: "Get")) {
                Task {
                    if suggestions.models?.isEmpty != false {
                        await suggestions.turnOn()
                    } else {
                        await suggestions.download(model.id)
                    }
                }
            }
            .disabled(suggestions.pull != nil)
        }
        .frame(minHeight: Metrics.row).padding(.horizontal, 6)
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.ui(TextSize.caption, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.top, Metrics.gap).padding(.horizontal, 6)
    }

    private func row(_ name: String, side: String, picked: Bool, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack(spacing: Metrics.gap) {
                Image(systemName: picked ? "largecircle.fill.circle" : "circle").font(.symbol())
                    .foregroundStyle(picked ? Color.accentColor : .secondary).frame(width: 14)
                Text(name).foregroundStyle(.primary)
                Spacer()
                Text(side).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(minHeight: Metrics.row).padding(.horizontal, 6).contentShape(Rectangle())
        }
        .buttonStyle(PointerButtonStyle())
    }
}
