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
    @State private var files = AgentManifest.load(dir: Paths.agents)
    /// The presets and ~/.kelp/agents, then the agents extensions add.
    private var agents: [AgentManifest] {
        (files + app.catalog.all.filter { a in !files.contains { $0.id == a.id } })
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    @State private var selection: String? = "claude"
    @State private var show = Show.all
    private enum Show: Int { case all, installed, available }
    @State private var command = ""
    @State private var args = ""
    @State private var env = ""
    /// The agent the fields hold: by the time they're saved another one may be selected.
    @State private var loaded: String?
    private enum LaunchField { case command, args, env }
    @FocusState private var field: LaunchField?
    @State private var versions: [String: (version: String?, latest: String?)] = [:]
    @State private var lacking: Set<String> = []   // npm, brew: not on this Mac

    private var updates: [AgentManifest] { agents.filter { newer(versions[$0.id]) } }
    /// "2.1.310" is newer than "2.1.304" (numbers, not text; a build ahead of npm isn't behind).
    private func newer(_ versionInfo: (version: String?, latest: String?)?) -> Bool {
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
                        .font(.ui(11)).foregroundStyle(Color.textOrange)
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
                        if let note = app.plans[a.id]?.note {
                            Text(" · " + note.text).foregroundStyle(Color(nsColor: note.color))
                        }
                    }.font(.ui(11))
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

    /// Found after its installer ended: offered in New Agent from now on.
    private func started(_ m: AgentManifest) -> some View {
        HStack {
            Label {
                status(String(localized: "\(m.name) is installed"), String(localized: "Offered in New Agent."))
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Spacer()
            Button("Start \(m.name)") {
                guard let editor = app.workbench.editor else {
                    Banner.show(String(localized: "Open a chat to start \(m.name) there."))
                    return
                }
                editor.newAgent(m.id)
                app.workbench.bringToFront()
            }
        }
    }

    private func status(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).fontWeight(.medium)
            Text(detail).font(.ui(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A command as it runs, to read or copy.
    private func commandLine(_ cmd: String) -> some View {
        HStack(alignment: .top) {
            Text(cmd).font(.uiMono(11)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cmd, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }.buttonStyle(PointerButtonStyle()).help("Copy")
        }
        .padding(Metrics.gapWide)
        .background(Color(nsColor: .fillRest), in: RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous))
    }

    @ViewBuilder private func versionRow(_ m: AgentManifest) -> some View {
        let versionInfo = versions[m.id]
        HStack {
            if let installed = versionInfo?.version {
                Text("Version \(installed)")
                    + Text(newer(versionInfo) ? String(localized: " · \(versionInfo?.latest ?? "") available") : "")
                    .foregroundColor(
                        .textOrange)
            } else if versions.isEmpty {
                Text("Checking…").foregroundStyle(.secondary)
            }
            Spacer()
            if let cmd = m.update {
                Button(newer(versionInfo) ? String(localized: "Update") : String(localized: "Check for Update")) {
                    run(cmd, String(localized: "Update \(m.name)"))
                }.help(cmd).disabled(versions.isEmpty)   // "Checking…" beside it
            }
        }
        // The agents of SSH projects run on their hosts: the same command there, one terminal per host.
        if let cmd = m.update, !hosts.isEmpty {
            HStack {
                let names = hosts.map(\.host).joined(separator: ", ")
                Text("SSH hosts: \(names)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).help(names)
                Spacer()
                Button("Update on Hosts") {
                    for h in hosts { run(cmd, String(localized: "Update \(m.name) on \(h.host)"), in: h.folder) }
                }.help(cmd)
            }
        }
    }

    /// How Kelp starts it: binary, arguments, environment (and a provider's variables).
    /// Bordered fields as wide as the card, as the text settings are bordered: an agent's environment lines are long.
    private func launch(_ m: AgentManifest) -> some View {
        Section {
            input("Command", $command, .command)
            input("Arguments", $args, .args, prompt: "space separated")
            input("Environment", $env, .env, prompt: "KEY=value, one per line", lines: 3...6)
            HStack {
                if !Self.presets(m.id).isEmpty {
                    Menu("Provider Presets") {
                        ForEach(Self.presets(m.id), id: \.0) { name, lines in Button(name) { addLines(lines) } }
                    }.fixedSize()
                }
                Spacer()
                Button("Reset to Default…") { reset(m) }
            }
        } header: {
            Text("Launch")
        } footer: {
            Text(
                "Values of *_KEY, *_TOKEN and *_SECRET are kept in your login keychain, not in the agent's file. Agents are JSON files in ~/.kelp/agents — add a file to add any CLI agent."
            )
            .font(.ui(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A bordered field beside its name, its text from the left: a form sets a field's text at its trailing end.
    private func input(
        _ title: LocalizedStringKey, _ text: Binding<String>, _ which: LaunchField, prompt: LocalizedStringKey? = nil,
        lines: ClosedRange<Int> = 1...1
    ) -> some View {
        LabeledContent(title) {
            TextField(
                "", text: text, prompt: prompt.map { Text($0) }, axis: lines.upperBound > 1 ? .vertical : .horizontal
            )
            .lineLimit(lines).textFieldStyle(.roundedBorder).multilineTextAlignment(.leading)
            .focused($field, equals: which).onSubmit(persist)
        }
    }

    /// One remote project's folder per host: a command run in it runs on that host, in its login shell.
    private var hosts: [(host: String, folder: String)] {
        var seen = Set<String>()
        return app.repos.compactMap { repo in
            RemoteHost.of(repo.path).flatMap { seen.insert($0.host).inserted ? ($0.host, repo.path) : nil }
        }
    }

    private func install(_ m: AgentManifest) {
        guard let editor = app.workbench.editor else {
            run(m.install ?? "", String(localized: "Install \(m.name)"))
            return
        }   // says what to do
        app.catalog.install(m, in: editor)
        app.workbench.bringToFront()
    }

    private func show(_ tab: String) {
        app.workbench.focus(session: tab)
        app.workbench.bringToFront()
    }

    /// The agent's own command, in a terminal in the workspace on screen, so what it does is in plain sight.
    private func run(_ cmd: String, _ title: String, in folder: String? = nil) {
        guard let editor = app.workbench.editor else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
            Banner.show(String(localized: "Open a chat to run it there — the command is on the clipboard: \(cmd)"))
            return
        }
        editor.run(command: cmd, title: title, cwd: folder)
        app.workbench.bringToFront()
    }

    private func loadVersions() async {
        // Quiet: a version beside each agent (npm offline, say); unknown versions just stay blank.
        let rows = await app.quiet(AgentsVersions(), timeout: 60) ?? []
        var byId: [String: (String?, String?)] = [:]
        for row in rows { byId[row.id] = (row.version, row.latest) }
        for a in agents where byId[a.id] == nil { byId[a.id] = (nil, nil) }
        versions = byId
        // What an installer runs with: without it, Install says what to get first. Not knowing, nothing is held back.
        if let found = await app.quiet(ProcessWhich(commands: ["npm", "brew"])) {
            lacking = Set(["npm", "brew"].filter { found[$0] == nil })
        }
    }

    /// Ways to run an agent through another provider, as environment variables its docs define.
    static func presets(_ agent: String) -> [(String, [String])] {
        switch agent {
        case "claude":
            [
                ("Anthropic API Key", ["ANTHROPIC_API_KEY="]),
                ("Amazon Bedrock", ["CLAUDE_CODE_USE_BEDROCK=1", "AWS_REGION=us-east-1", "AWS_PROFILE=default"]),
                (
                    "Google Vertex AI",
                    ["CLAUDE_CODE_USE_VERTEX=1", "CLOUD_ML_REGION=us-east5", "ANTHROPIC_VERTEX_PROJECT_ID="]
                ),
                ("Gateway (LiteLLM, Ollama…)", ["ANTHROPIC_BASE_URL=http://localhost:4000", "ANTHROPIC_AUTH_TOKEN="])
            ]
        case "codex":
            [
                ("OpenAI API Key", ["OPENAI_API_KEY="]),
                (
                    "OpenAI-compatible Endpoint (OpenRouter…)",
                    ["OPENAI_BASE_URL=https://openrouter.ai/api/v1", "OPENAI_API_KEY="]
                )
            ]
        case "gemini":
            [
                ("Gemini API Key", ["GEMINI_API_KEY="]),
                (
                    "Google Vertex AI",
                    ["GOOGLE_GENAI_USE_VERTEXAI=true", "GOOGLE_CLOUD_PROJECT=", "GOOGLE_CLOUD_LOCATION=us-central1"]
                )
            ]
        default: []
        }
    }
    private func addLines(_ lines: [String]) {
        var have = env.split(separator: "\n").map(String.init)
        for l in lines
        where !have.contains(where: { $0.hasPrefix(l.split(separator: "=").first.map { $0 + "=" } ?? l) }) {
            have.append(l)
        }
        env = have.joined(separator: "\n")
    }

    private var current: AgentManifest? { agents.first { $0.id == selection } }
    private static func envText(_ m: AgentManifest) -> String {
        m.env.map { "\($0)=\($1)" }.sorted().joined(separator: "\n")
    }
    private func load() {
        guard let agent = current else { return }
        loaded = agent.id
        command = agent.command
        args = agent.args.joined(separator: " ")
        env = Self.envText(agent)
    }
    private func reload() {
        files = AgentManifest.load(dir: Paths.agents)
        load()
    }

    private func reset(_ m: AgentManifest) {
        Task {
            let question = NSAlert(
                question: String(localized: "Reset how \(m.name) starts?"),
                detail: String(localized: "Its command, arguments and environment go back to Kelp's."),
                action: String(localized: "Reset"))
            guard await runSheet(question) == .alertFirstButtonReturn else { return }
            AgentManifest.resetOverride(id: m.id, dir: Paths.agents)
            reload()
        }
    }

    /// Only what changed: looking at an agent mustn't leave an override behind. The values go along now, since the fields
    /// may hold another agent by the time the keychain answers.
    private func persist() {
        guard let agent = agents.first(where: { $0.id == loaded }) else { return }
        guard command != agent.command || args != agent.args.joined(separator: " ") || env != Self.envText(agent) else {
            return
        }
        let (c, a, e) = (command, args, env)
        Task { await save(agent, command: c, args: a, env: e) }
    }

    /// A secret the keychain refused, or a file that couldn't be written, says why.
    private func save(_ agent: AgentManifest, command: String, args: String, env: String) async {
        var manifest = agent
        manifest.command = command
        manifest.args = args.split(separator: " ").map(String.init)
        var pairs = Dictionary(
            env.split(separator: "\n").compactMap { line -> (String, String)? in
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                return parts.count == 2
                    ? (String(parts[0]).trimmingCharacters(in: .whitespaces), String(parts[1])) : nil
            }, uniquingKeysWith: { $1 })
        // Secrets: the daemon puts them in the keychain; the file only says where they are.
        for (k, v) in pairs where AgentManifest.isSecret(k) && v != AgentManifest.keychainValue && !v.isEmpty {
            guard await app.call(AgentSetSecret(agent: manifest.id, key: k, value: v)) != nil else { return }
            pairs[k] = AgentManifest.keychainValue
        }
        for k in manifest.env.keys where pairs[k] == nil && manifest.env[k] == AgentManifest.keychainValue {
            await app.call(AgentSetSecret(agent: manifest.id, key: k))   // removed: forget it
        }
        manifest.env = pairs.filter { !$0.value.isEmpty }   // a preset's blank line until it's filled in
        do { try AgentManifest.saveOverride(manifest, dir: Paths.agents) } catch {
            Banner.show(
                String(localized: "Couldn't save \(manifest.name): \(error.localizedDescription)"), style: .error)
            return
        }
        files = AgentManifest.load(dir: Paths.agents)
        if field == nil { load() }   // a secret reads as the keychain's mark now; not under someone's typing
        app.agents = AgentManifest.load(dir: Paths.agents)
        app.availability.refresh(force: true)
    }
}
