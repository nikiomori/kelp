import Agents
import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI

/// The Settings › Agent Catalog page: every agent Kelp knows, installed agents first. The selected agent's card holds
/// Install (the agent's own installer in a terminal you can watch, or what it needs first), the version (and a newer
/// one, if published) with Update, and how the agent is launched. The launch fields (binary, arguments, environment)
/// are saved like every other setting when you leave them. Secrets in the environment go to the login keychain, and
/// Reset deletes the override.
struct AgentsSettings: View {
    let app: AppModel
    init(app: AppModel) { self.app = app }
    @State var files = AgentManifest.load(dir: Paths.agents)
    /// The agents from the presets and ~/.kelp/agents, plus the agents that extensions add, sorted by name.
    var agents: [AgentManifest] {
        (files + app.catalog.all.filter { a in !files.contains { $0.id == a.id } })
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    @State var selection: String? = Session.claudeAgent
    @State private var show = Show.all
    private enum Show: Int { case all, installed, available }
    @State var command = ""
    @State var args = ""
    @State var env = ""
    /// The agent whose launch settings the fields hold, because by the time they are saved another agent may be
    /// selected.
    @State var loaded: String?
    enum LaunchField { case command, args, env }
    @FocusState var field: LaunchField?
    @State var versions: [String: (version: String?, latest: String?)] = [:]
    @State var lacking: Set<String> = []   // the installer tools (npm, brew) that aren't on this Mac

    private var updates: [AgentManifest] { agents.filter { newer(versions[$0.id]) } }
    /// True when the latest version is newer than the installed one, compared as numbers, not text ("2.1.310" is newer
    /// than "2.1.304"). A build ahead of npm doesn't count as behind.
    func newer(_ versionInfo: (version: String?, latest: String?)?) -> Bool {
        guard let version = versionInfo?.version, let latest = versionInfo?.latest else { return false }
        return version.compare(latest, options: .numeric) == .orderedAscending
    }
    /// True when the agent is found on this Mac, which means New Agent offers it.
    private func installed(_ manifest: AgentManifest) -> Bool {
        app.availability.ids.contains(manifest.id) || versions[manifest.id]?.version != nil
    }

    var body: some View {
        // Two grouped forms side by side, since every other page is one grouped form. The agents sit in a card on the
        // left, and the chosen agent's card is on the right. Settings' own search finds an agent by name and opens this
        // page on it, so there is no second search field.
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

    /// The agent list: the agents on this Mac first, and the rest under them, greyed, to install from the card.
    private var list: some View {
        let have = show == .available ? [] : agents.filter(installed)
        let rest = show == .installed ? [] : agents.filter { !installed($0) }
        // The segments show every agent Kelp knows, on this Mac or not, and one click shows the ones there are to
        // install. They sit over the list rather than in a card of their own, which would be a box around one control.
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
                EmptyState(
                    show == .installed
                        ? String(localized: "No agent is installed yet.")
                        : String(localized: "Every agent Kelp knows is installed."), symbol: "sparkles", lifted: false)
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

    /// Returns the id `by` places away from `id` in the list as shown; nil past either end, or when `id` isn't shown.
    static func neighbour(of id: String?, by: Int, in ids: [String]) -> String? {
        guard let index = ids.firstIndex(where: { $0 == id }), ids.indices.contains(index + by) else { return nil }
        return ids[index + by]
    }

    /// When Settings' search opened this page on an agent's name, selects that agent.
    private func reveal() {
        guard let word = UserDefaults.standard.string(forKey: "settings.group"),
            let agent = agents.first(where: { $0.name == word })
        else { return }
        UserDefaults.standard.set("", forKey: "settings.group")
        selection = agent.id
    }

    private func row(_ manifest: AgentManifest) -> some View {
        let have = installed(manifest), on = manifest.id == selection
        var caption = String(localized: "Not installed")
        if have {
            caption =
                versions[manifest.id]?.version.map { "\($0) · \(manifest.command)" } ?? manifest.command
        } else if case .running? = app.availability.phases[manifest.id] {
            caption = String(localized: "Installing…")
        }
        return Button {
            selection = manifest.id
        } label: {
            HStack(spacing: Metrics.gapWide) {
                Image(nsImage: app.catalog.icon(manifest.id, size: Metrics.iconMenu) ?? NSImage()).resizable()
                    .frame(width: Metrics.iconMenu, height: Metrics.iconMenu).opacity(have ? 1 : 0.5)
                VStack(alignment: .leading, spacing: Metrics.lineGap) {
                    HStack(spacing: Metrics.gap) {
                        Text(manifest.name).foregroundStyle(have ? .primary : .secondary)
                        if updates.contains(where: { $0.id == manifest.id }) {
                            // An update is news, which has no colour: orange is for what waits for the user.
                            Circle().fill(Color.secondary).frame(width: Metrics.gap, height: Metrics.gap).help(
                                "Update available"
                            ).accessibilityLabel("Update available")
                        }
                    }
                    HStack(spacing: 0) {
                        Text(caption).foregroundStyle(.secondary)
                        if let note = UsageView.notes(app)[manifest.id] {
                            Text(" · " + note.text).foregroundStyle(Color(nsColor: note.color))
                        }
                    }.font(.ui(TextSize.caption))
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            // The chosen row is tinted to just past its text, because a form's rows take no list row background on
            // macOS.
            .background {
                RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous)
                    .fill(on ? Color(nsColor: .fillTint(.controlAccentColor)) : .clear).padding(-Metrics.gap)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder private func card(_ manifest: AgentManifest) -> some View {
        Section {
            HStack(spacing: Metrics.inset) {
                // The icon is as tall as the name and the line under it.
                Image(nsImage: app.catalog.icon(manifest.id, size: Metrics.rowTwoLine) ?? NSImage()).resizable()
                    .frame(width: Metrics.rowTwoLine, height: Metrics.rowTwoLine)
                VStack(alignment: .leading, spacing: Metrics.lineGap) {
                    Text(manifest.name).font(.ui(TextSize.heading, weight: .semibold))
                    if let about = app.catalog.about(manifest.id) { Text(about).foregroundStyle(.secondary) }
                }
            }
            if installed(manifest) {
                if app.availability.phases[manifest.id] == .done { started(manifest) }
                versionRow(manifest)
            } else {
                installBox(manifest)
            }
        }
        if installed(manifest) { launch(manifest) }
    }

    /// The install box for an agent that isn't on this Mac. It shows the agent's installer, what it needs first, the
    /// installer running, or that the installer ended without the agent being found.
    @ViewBuilder private func installBox(_ manifest: AgentManifest) -> some View {
        switch app.availability.phases[manifest.id] {
        case .running(let tab)?:
            HStack {
                ProgressView().controlSize(.small)
                status(
                    String(localized: "Installing…"),
                    String(localized: "In the tab “Install \(manifest.name)”. This page updates when it ends."))
                Spacer()
                Button("Show Tab") { show(tab) }
            }
            if let cmd = manifest.install { commandLine(cmd) }
        case .notFound(let tab)?:
            Label {
                status(
                    String(localized: "The installer finished, but \(manifest.name) isn’t found yet"),
                    String(
                        localized:
                            "Kelp asked your login shell for its PATH again and still didn’t see \(manifest.command). "
                    )
                        + String(
                            localized:
                                "If the installer printed a line to add to your shell profile, add it, then check again."
                        ))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(nsColor: .systemRed))
            }
            HStack {
                Spacer()
                Button("Show Tab") { show(tab) }
                Button("Check Again") {
                    app.availability.refresh(force: true, rereadPath: true, expecting: [manifest.id])
                }
            }
        default:
            if let cmd = manifest.install {
                let tool = manifest.installNeeds.flatMap { lacking.contains($0) ? $0 : nil }
                HStack {
                    if let tool {
                        status(String(localized: "Needs \(tool)"), String(localized: "\(tool) isn’t on this Mac."))
                    } else {
                        status(
                            String(localized: "Not installed"),
                            String(localized: "Runs its own installer in a terminal tab you can watch."))
                    }
                    Spacer()
                    Button("Install") { install(manifest) }.disabled(tool != nil).help(cmd)
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
                    "Kelp has no installer for \(manifest.name). Install it as its docs say; it shows up here once \(manifest.command) is on your PATH."
                )
                .foregroundStyle(.secondary)
            }
        }
    }

}
