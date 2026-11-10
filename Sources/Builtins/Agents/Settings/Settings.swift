import Agents
import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI

/// Settings › Agent Catalog: every agent Kelp knows, installed first. Its card: Install (its own installer in a terminal you
/// can watch, or what it needs first), the version (and a newer one, if published) and Update, and how it's launched:
/// binary, arguments, environment, saved like every other setting, on leaving the fields. Secrets in the environment go to
/// the login keychain. Reset deletes the override.
struct AgentsSettings: View {
    let app: AppModel
    init(app: AppModel) { self.app = app }
    @State var files = AgentManifest.load(dir: Paths.agents)
    /// The presets and ~/.kelp/agents, then the agents extensions add.
    var agents: [AgentManifest] {
        (files + app.catalog.all.filter { a in !files.contains { $0.id == a.id } })
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    @State var selection: String? = "claude"
    @State private var show = Show.all
    private enum Show: Int { case all, installed, available }
    @State var command = ""
    @State var args = ""
    @State var env = ""
    /// The agent the fields hold: by the time they're saved another one may be selected.
    @State var loaded: String?
    enum LaunchField { case command, args, env }
    @FocusState var field: LaunchField?
    @State var versions: [String: (version: String?, latest: String?)] = [:]
    @State var lacking: Set<String> = []   // npm, brew: not on this Mac

    private var updates: [AgentManifest] { agents.filter { newer(versions[$0.id]) } }
    /// "2.1.310" is newer than "2.1.304" (numbers, not text; a build ahead of npm isn't behind).
    func newer(_ versionInfo: (version: String?, latest: String?)?) -> Bool {
        guard let version = versionInfo?.version, let latest = versionInfo?.latest else { return false }
        return version.compare(latest, options: .numeric) == .orderedAscending
    }
    /// Found on this Mac: offered in New Agent.
    private func installed(_ m: AgentManifest) -> Bool {
        app.availability.ids.contains(m.id) || versions[m.id]?.version != nil
    }

    var body: some View {
        // Two grouped forms side by side, as every other page is one: the agents in a card on the left, the chosen one's on the
        // right. Settings' own search finds an agent by name and opens this page on it, so there's no second search field.
        GeometryReader { pane in
            HStack(alignment: .top, spacing: 0) {
                list.frame(width: min(Self.listWidth, pane.size.width * 0.4))
                Form { if let agent = current { card(agent) } }.formStyle(.grouped)
            }
        }
        .onChange(of: selection) { _, _ in
            persist()
            load()
        }
        .onChange(of: field) { _, now in if now == nil { persist() } }
        .onAppear {
            reveal()
            load()
        }
        .onDisappear(perform: persist)
        .task { await loadVersions() }
        .onChange(of: app.availability.ids) { _, _ in Task { await loadVersions() } }   // an install ended
    }

    /// The list's column, the form's margins included.
    private static let listWidth: CGFloat = 300

    /// What's on this Mac first; the rest under it, greyed, to install from the card.
    private var list: some View {
        let have = show == .available ? [] : agents.filter(installed)
        let rest = show == .installed ? [] : agents.filter { !installed($0) }
        // Every agent Kelp knows, on this Mac or not: one click to the ones there are to install. Over the list, not in a
        // card of its own: a box around one control.
        return VStack(alignment: .leading, spacing: 0) {
            Segments(
                labels: [String(localized: "All"), String(localized: "Installed"), String(localized: "Available")],
                selection: Binding {
                    show.rawValue
                } set: {
                    show = Show(rawValue: $0) ?? .all
                }
            )
            .padding([.horizontal, .top], Metrics.sheetInset)   // the grouped form's own margin
            catalogForm(have: have, rest: rest)
        }
    }

    private func catalogForm(have: [AgentManifest], rest: [AgentManifest]) -> some View {
        Form {
            if !have.isEmpty {
                Section {
                    ForEach(have, id: \.id) { row($0) }
                } header: {
                    Text("Installed \(have.count)")
                } footer: {
                    if !updates.isEmpty {
                        Text(
                            updates.count == 1
                                ? String(localized: "1 update available")
                                : String(localized: "\(updates.count) updates available")
                        )
                        .font(.ui(TextSize.caption)).foregroundStyle(Color.textOrange)
                    }
                }
            }
            if !rest.isEmpty { Section("Not Installed \(rest.count)") { ForEach(rest, id: \.id) { row($0) } } }
            if have.isEmpty && rest.isEmpty {
                Text(show == .installed ? "No agent is installed yet." : "Every agent Kelp knows is installed.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onKeyPress(.upArrow) { step(-1, in: have + rest) }
        .onKeyPress(.downArrow) { step(1, in: have + rest) }
    }

    /// ↑ and ↓ walk the list, as they did when it was a List.
    private func step(_ by: Int, in shown: [AgentManifest]) -> KeyPress.Result {
        guard let next = Self.neighbour(of: selection, by: by, in: shown.map(\.id)) else { return .ignored }
        selection = next
        return .handled
    }

    /// The id `by` places from `id` in the list as shown; none past either end, or when `id` isn't shown.
    static func neighbour(of id: String?, by: Int, in ids: [String]) -> String? {
        guard let index = ids.firstIndex(where: { $0 == id }), ids.indices.contains(index + by) else { return nil }
        return ids[index + by]
    }

    /// Opened from Settings' search on an agent's name: that agent.
    private func reveal() {
        guard let word = UserDefaults.standard.string(forKey: "settings.group"),
            let agent = agents.first(where: { $0.name == word })
        else { return }
        UserDefaults.standard.set("", forKey: "settings.group")
        selection = agent.id
    }

    private func row(_ a: AgentManifest) -> some View {
        let have = installed(a), on = a.id == selection
        var caption = String(localized: "Not installed")
        if have {
            caption = versions[a.id]?.version.map { "\($0) · \(a.command)" } ?? a.command
        } else if case .running? = app.availability.phases[a.id] {
            caption = String(localized: "Installing…")
        }
        return Button {
            selection = a.id
        } label: {
            HStack(spacing: Metrics.gapWide) {
                Image(nsImage: app.catalog.icon(a.id, size: Metrics.iconMenu) ?? NSImage()).resizable()
                    .frame(width: Metrics.iconMenu, height: Metrics.iconMenu).opacity(have ? 1 : 0.5)
                VStack(alignment: .leading, spacing: Metrics.lineGap) {
                    HStack(spacing: Metrics.gap) {
                        Text(a.name).foregroundStyle(have ? .primary : .secondary)
                        if updates.contains(where: { $0.id == a.id }) {
                            Circle().fill(Color.textOrange).frame(width: Metrics.gap, height: Metrics.gap).help(
                                "Update available")
                        }
                    }
                    HStack(spacing: 0) {
                        Text(caption).foregroundStyle(.secondary)
                        if let note = UsageView.plans(app)[a.id]?.note {
                            Text(" · " + note.text).foregroundStyle(Color(nsColor: note.color))
                        }
                    }.font(.ui(TextSize.caption))
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            // The chosen one tinted to just past its text: a form's rows take no list row background on macOS.
            .background {
                RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous)
                    .fill(on ? Color(nsColor: .fillTint(.controlAccentColor)) : .clear).padding(-Metrics.gap)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder private func card(_ m: AgentManifest) -> some View {
        Section {
            HStack(spacing: Metrics.inset) {
                // As tall as the name and the line under it.
                Image(nsImage: app.catalog.icon(m.id, size: Metrics.rowTwoLine) ?? NSImage()).resizable()
                    .frame(width: Metrics.rowTwoLine, height: Metrics.rowTwoLine)
                VStack(alignment: .leading, spacing: Metrics.lineGap) {
                    Text(m.name).font(.ui(15, weight: .semibold))
                    if let about = app.catalog.about(m.id) { Text(about).foregroundStyle(.secondary) }
                }
            }
            if installed(m) {
                if app.availability.phases[m.id] == .done { started(m) }
                versionRow(m)
            } else {
                installBox(m)
            }
        }
        if installed(m) { launch(m) }
    }

    /// Not on this Mac: its installer, what it needs first, the installer running, or ended without the agent found.
    @ViewBuilder private func installBox(_ m: AgentManifest) -> some View {
        switch app.availability.phases[m.id] {
        case .running(let tab)?:
            HStack {
                ProgressView().controlSize(.small)
                status(
                    String(localized: "Installing…"),
                    String(localized: "In the tab “Install \(m.name)”. This page updates when it ends."))
                Spacer()
                Button("Show Tab") { show(tab) }
            }
            if let cmd = m.install { commandLine(cmd) }
        case .notFound(let tab)?:
            Label {
                status(
                    String(localized: "The installer finished, but \(m.name) isn’t found yet"),
                    String(
                        localized: "Kelp asked your login shell for its PATH again and still didn’t see \(m.command). ")
                        + String(
                            localized:
                                "If the installer printed a line to add to your shell profile, add it, then check again."
                        ))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Show Tab") { show(tab) }
                Button("Check Again") { app.availability.refresh(force: true, rereadPath: true, expecting: [m.id]) }
            }
        default:
            if let cmd = m.install {
                let tool = m.installNeeds.flatMap { lacking.contains($0) ? $0 : nil }
                HStack {
                    if let tool {
                        status(String(localized: "Needs \(tool)"), String(localized: "\(tool) isn’t on this Mac."))
                    } else {
                        status(
                            String(localized: "Not installed"),
                            String(localized: "Runs its own installer in a terminal tab you can watch."))
                    }
                    Spacer()
                    Button("Install") { install(m) }.disabled(tool != nil).help(cmd)
                }
                if tool == "npm" {
                    Text("Install Node.js first, from nodejs.org or with Homebrew:").foregroundStyle(.secondary)
                    commandLine("brew install node")
                } else if tool != nil {
                    Text("Install Homebrew first, from brew.sh.").foregroundStyle(.secondary)
                }
                commandLine(cmd)
            } else {
                Text(
                    "Kelp has no installer for \(m.name). Install it as its docs say; it shows up here once \(m.command) is on your PATH."
                )
                .foregroundStyle(.secondary)
            }
        }
    }

}
