import AppKit
import SwiftUI
import Core
import Agents
import DesignKit
import KelpKit

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
    @State private var query = ""
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
    private func newer(_ v: (version: String?, latest: String?)?) -> Bool {
        guard let a = v?.version, let b = v?.latest else { return false }
        return a.compare(b, options: .numeric) == .orderedAscending
    }
    /// Found on this Mac: offered in New Agent.
    private func installed(_ m: AgentManifest) -> Bool { app.availability.ids.contains(m.id) || versions[m.id]?.version != nil }

    var body: some View {
        GeometryReader { pane in HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Search agents", text: $query, prompt: Text("Search agents")).textFieldStyle(.roundedBorder).labelsHidden()
                // Every agent Kelp knows, on this Mac or not: one click to the ones there are to install.
                ColumnSegments(labels: [String(localized: "All"), String(localized: "Installed"), String(localized: "Available")],
                               selection: Binding { show.rawValue } set: { show = Show(rawValue: $0) ?? .all })
                // What's on this Mac first; the rest under it, greyed, to install from the card.
                List(selection: $selection) {
                    let shown = agents.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
                    let have = show == .available ? [] : shown.filter(installed)
                    if !have.isEmpty { Section("Installed \(have.count)") { ForEach(have, id: \.id) { row($0) } } }
                    let rest = show == .installed ? [] : shown.filter { !installed($0) }
                    if !rest.isEmpty { Section("Not Installed \(rest.count)") { ForEach(rest, id: \.id) { row($0) } } }
                    if have.isEmpty && rest.isEmpty {
                        let empty: LocalizedStringKey = show == .installed ? "No agent is installed yet." : "Every agent Kelp knows is installed."
                        Text(!query.isEmpty ? "No agents match “\(query)”." : empty).foregroundStyle(.secondary)
                    }
                }
                if !updates.isEmpty {
                    Text(updates.count == 1 ? String(localized: "1 update available") : String(localized: "\(updates.count) updates available"))
                        .font(.caption).foregroundStyle(Color.textOrange)
                }
            }
            .frame(width: min(250, pane.size.width * 0.4))
            ScrollView {
                if let m = current { card(m).padding(.trailing, 4) }
            }
        } }
        .padding(16)
        .onChange(of: selection) { _, _ in persist(); load() }
        .onChange(of: field) { _, now in if now == nil { persist() } }
        .onAppear { load() }
        .onDisappear(perform: persist)
        .task { await loadVersions() }
        .onChange(of: app.availability.ids) { _, _ in Task { await loadVersions() } }   // an install ended
    }

    private func row(_ a: AgentManifest) -> some View {
        let have = installed(a)
        var caption = String(localized: "Not installed")
        if have { caption = versions[a.id]?.version.map { "\($0) · \(a.command)" } ?? a.command }
        else if case .running? = app.availability.phases[a.id] { caption = String(localized: "Installing…") }
        return HStack(spacing: 8) {
            Image(nsImage: app.catalog.icon(a.id, size: 18) ?? NSImage()).resizable().frame(width: 18, height: 18).opacity(have ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(a.name).foregroundStyle(have ? .primary : .secondary)
                    if updates.contains(where: { $0.id == a.id }) { Circle().fill(.orange).frame(width: 6, height: 6).help("Update available") }
                }
                HStack(spacing: 0) {
                    Text(caption).foregroundStyle(.secondary)
                    if let n = app.plans[a.id]?.note { Text(" · " + n.text).foregroundStyle(Color(nsColor: n.color)) }
                }.font(.caption)
            }
        }.tag(Optional(a.id))
    }

    @ViewBuilder private func card(_ m: AgentManifest) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: app.catalog.icon(m.id, size: 32) ?? NSImage()).resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.name).font(.title3.weight(.semibold))
                    if let about = app.catalog.about(m.id) { Text(about).foregroundStyle(.secondary) }
                }
            }
            if installed(m) {
                if app.availability.phases[m.id] == .done { started(m) }
                versionRow(m)
                Divider()
                launch(m)
            } else { installBox(m) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Not on this Mac: its installer, what it needs first, the installer running, or ended without the agent found.
    @ViewBuilder private func installBox(_ m: AgentManifest) -> some View {
        switch app.availability.phases[m.id] {
        case .running(let tab)?:
            HStack {
                ProgressView().controlSize(.small)
                status(String(localized: "Installing…"), String(localized: "In the tab “Install \(m.name)”. This page updates when it ends."))
                Spacer()
                Button("Show Tab") { show(tab) }
            }
            if let cmd = m.install { commandLine(cmd) }
        case .notFound(let tab)?:
            Label {
                status(String(localized: "The installer finished, but \(m.name) isn’t found yet"),
                       String(localized: "Kelp asked your login shell for its PATH again and still didn’t see \(m.command). ")
                        + String(localized: "If the installer printed a line to add to your shell profile, add it, then check again."))
            } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Show Tab") { show(tab) }
                Button("Check Again") { app.availability.refresh(force: true, rereadPath: true, expecting: [m.id]) }
            }
        default:
            if let cmd = m.install {
                let tool = m.installNeeds.flatMap { lacking.contains($0) ? $0 : nil }
                HStack {
                    if let tool { status(String(localized: "Needs \(tool)"), String(localized: "\(tool) isn’t on this Mac.")) }
                    else { status(String(localized: "Not installed"), String(localized: "Runs its own installer in a terminal tab you can watch.")) }
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
                Text("Kelp has no installer for \(m.name). Install it as its docs say; it shows up here once \(m.command) is on your PATH.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Found after its installer ended: offered in New Agent from now on.
    private func started(_ m: AgentManifest) -> some View {
        HStack {
            Label { status(String(localized: "\(m.name) is installed"), String(localized: "Offered in New Agent.")) } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Spacer()
            Button("Start \(m.name)") {
                guard let e = app.workbench.editor else { Banner.show(String(localized: "Open a chat to start \(m.name) there.")); return }
                e.newAgent(m.id)
                app.workbench.bringToFront()
            }
        }
    }

    private func status(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).fontWeight(.medium)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A command as it runs, to read or copy.
    private func commandLine(_ cmd: String) -> some View {
        HStack(alignment: .top) {
            Text(cmd).font(.system(.caption, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cmd, forType: .string) } label: {
                Image(systemName: "doc.on.doc")
            }.buttonStyle(PointerButtonStyle()).help("Copy")
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Metrics.radiusSM))
    }

    @ViewBuilder private func versionRow(_ m: AgentManifest) -> some View {
        let v = versions[m.id]
        HStack {
            if let installed = v?.version {
                Text("Version \(installed)") + Text(newer(v) ? String(localized: " · \(v?.latest ?? "") available") : "").foregroundColor(.textOrange)
            } else if versions.isEmpty { Text("Checking…").foregroundStyle(.secondary) }
            Spacer()
            if let cmd = m.update {
                Button(newer(v) ? String(localized: "Update") : String(localized: "Check for Update")) {
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
                Button("Update on Hosts") { for h in hosts { run(cmd, String(localized: "Update \(m.name) on \(h.host)"), in: h.folder) } }.help(cmd)
            }
        }
    }

    /// How Kelp starts it: binary, arguments, environment (and a provider's variables).
    @ViewBuilder private func launch(_ m: AgentManifest) -> some View {
        Text("Launch").font(.ui(13, weight: .semibold))
        Form {
            TextField("Command", text: $command).focused($field, equals: .command).onSubmit(persist)
            TextField("Arguments", text: $args, prompt: Text("space separated")).focused($field, equals: .args).onSubmit(persist)
            TextField("Environment", text: $env, prompt: Text("KEY=value, one per line"), axis: .vertical).lineLimit(3...6).focused($field, equals: .env)
            if !Self.presets(m.id).isEmpty {
                Menu("Provider Presets") {
                    ForEach(Self.presets(m.id), id: \.0) { name, lines in Button(name) { addLines(lines) } }
                }.fixedSize()
            }
            Button("Reset to Default…") { reset(m) }
        }
        .formStyle(.columns)   // already inside Settings' grouped section: a second card in it would nest boxes
        Text("Values of *_KEY, *_TOKEN and *_SECRET are kept in your login keychain, not in the agent's file. Agents are JSON files in ~/.kelp/agents — add a file to add any CLI agent.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    /// One remote project's folder per host: a command run in it runs on that host, in its login shell.
    private var hosts: [(host: String, folder: String)] {
        var seen = Set<String>()
        return app.repos.compactMap { r in RemoteHost.of(r.path).flatMap { seen.insert($0.host).inserted ? ($0.host, r.path) : nil } }
    }

    private func install(_ m: AgentManifest) {
        guard let e = app.workbench.editor else { run(m.install ?? "", String(localized: "Install \(m.name)")); return }   // says what to do
        app.catalog.install(m, in: e)
        app.workbench.bringToFront()
    }

    private func show(_ tab: String) {
        app.workbench.focus(session: tab)
        app.workbench.bringToFront()
    }

    /// The agent's own command, in a terminal in the workspace on screen, so what it does is in plain sight.
    private func run(_ cmd: String, _ title: String, in folder: String? = nil) {
        guard let e = app.workbench.editor else {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cmd, forType: .string)
            Banner.show(String(localized: "Open a chat to run it there — the command is on the clipboard: \(cmd)")); return
        }
        e.run(command: cmd, title: title, cwd: folder)
        app.workbench.bringToFront()
    }

    private func loadVersions() async {
        // Quiet: a version beside each agent (npm offline, say); unknown versions just stay blank.
        let rows = await app.quiet(AgentsVersions(), timeout: 60) ?? []
        var v: [String: (String?, String?)] = [:]
        for r in rows { v[r.id] = (r.version, r.latest) }
        for a in agents where v[a.id] == nil { v[a.id] = (nil, nil) }
        versions = v
        // What an installer runs with: without it, Install says what to get first. Not knowing, nothing is held back.
        if let found = await app.quiet(ProcessWhich(commands: ["npm", "brew"])) { lacking = Set(["npm", "brew"].filter { found[$0] == nil }) }
    }

    /// Ways to run an agent through another provider, as environment variables its docs define.
    static func presets(_ agent: String) -> [(String, [String])] {
        switch agent {
        case "claude": [
            ("Anthropic API Key", ["ANTHROPIC_API_KEY="]),
            ("Amazon Bedrock", ["CLAUDE_CODE_USE_BEDROCK=1", "AWS_REGION=us-east-1", "AWS_PROFILE=default"]),
            ("Google Vertex AI", ["CLAUDE_CODE_USE_VERTEX=1", "CLOUD_ML_REGION=us-east5", "ANTHROPIC_VERTEX_PROJECT_ID="]),
            ("Gateway (LiteLLM, Ollama…)", ["ANTHROPIC_BASE_URL=http://localhost:4000", "ANTHROPIC_AUTH_TOKEN="])
        ]
        case "codex": [("OpenAI API Key", ["OPENAI_API_KEY="]),
                       ("OpenAI-compatible Endpoint (OpenRouter…)", ["OPENAI_BASE_URL=https://openrouter.ai/api/v1", "OPENAI_API_KEY="])]
        case "gemini": [("Gemini API Key", ["GEMINI_API_KEY="]),
                        ("Google Vertex AI", ["GOOGLE_GENAI_USE_VERTEXAI=true", "GOOGLE_CLOUD_PROJECT=", "GOOGLE_CLOUD_LOCATION=us-central1"])]
        default: []
        }
    }
    private func addLines(_ lines: [String]) {
        var have = env.split(separator: "\n").map(String.init)
        for l in lines where !have.contains(where: { $0.hasPrefix(l.split(separator: "=").first.map { $0 + "=" } ?? l) }) { have.append(l) }
        env = have.joined(separator: "\n")
    }

    private var current: AgentManifest? { agents.first { $0.id == selection } }
    private static func envText(_ m: AgentManifest) -> String { m.env.map { "\($0)=\($1)" }.sorted().joined(separator: "\n") }
    private func load() {
        guard let m = current else { return }
        loaded = m.id
        command = m.command; args = m.args.joined(separator: " ")
        env = Self.envText(m)
    }
    private func reload() { files = AgentManifest.load(dir: Paths.agents); load() }

    private func reset(_ m: AgentManifest) {
        Task {
            let question = NSAlert(question: String(localized: "Reset how \(m.name) starts?"),
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
        guard let m = agents.first(where: { $0.id == loaded }) else { return }
        guard command != m.command || args != m.args.joined(separator: " ") || env != Self.envText(m) else { return }
        let (c, a, e) = (command, args, env)
        Task { await save(m, command: c, args: a, env: e) }
    }

    /// A secret the keychain refused, or a file that couldn't be written, says why.
    private func save(_ agent: AgentManifest, command: String, args: String, env: String) async {
        var m = agent
        m.command = command; m.args = args.split(separator: " ").map(String.init)
        var pairs = Dictionary(env.split(separator: "\n").compactMap { l -> (String, String)? in
            let p = l.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return p.count == 2 ? (String(p[0]).trimmingCharacters(in: .whitespaces), String(p[1])) : nil
        }, uniquingKeysWith: { $1 })
        // Secrets: the daemon puts them in the keychain; the file only says where they are.
        for (k, v) in pairs where AgentManifest.isSecret(k) && v != AgentManifest.keychainValue && !v.isEmpty {
            guard await app.call(AgentSetSecret(agent: m.id, key: k, value: v)) != nil else { return }
            pairs[k] = AgentManifest.keychainValue
        }
        for k in m.env.keys where pairs[k] == nil && m.env[k] == AgentManifest.keychainValue {
            await app.call(AgentSetSecret(agent: m.id, key: k))   // removed: forget it
        }
        m.env = pairs.filter { !$0.value.isEmpty }   // a preset's blank line until it's filled in
        do { try AgentManifest.saveOverride(m, dir: Paths.agents) } catch {
            Banner.show(String(localized: "Couldn't save \(m.name): \(error.localizedDescription)"), style: .error); return
        }
        files = AgentManifest.load(dir: Paths.agents)
        if field == nil { load() }   // a secret reads as the keychain's mark now; not under someone's typing
        app.agents = AgentManifest.load(dir: Paths.agents)
        app.availability.refresh(force: true)
    }
}

/// Segments exactly as wide as their column, in any language. A segmented Picker can ask for three times its longest label
/// (321 pt in Russian): a 250 pt column then centres on it, sliding off the pane on the left and over the card on the right.
private struct ColumnSegments: NSViewRepresentable {
    let labels: [String]
    @Binding var selection: Int

    func makeNSView(context: Context) -> NSSegmentedControl {
        let s = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: context.coordinator, action: #selector(Coordinator.changed))
        s.segmentDistribution = .fillProportionally
        return s
    }
    func updateNSView(_ s: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        s.selectedSegment = selection
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView s: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? s.intrinsicContentSize.width, height: s.intrinsicContentSize.height)
    }
    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    final class Coordinator: NSObject {
        var selection: Binding<Int>
        init(selection: Binding<Int>) { self.selection = selection }
        @objc func changed(_ s: NSSegmentedControl) { selection.wrappedValue = s.selectedSegment }
    }
}

/// Settings › Agents: where the agents are, and how many are on this Mac.
struct CatalogLink: View {
    let app: AppModel
    var body: some View {
        let all = app.catalog.all.count, have = app.catalog.all.filter { app.availability.ids.contains($0.id) }.count
        LabeledContent {
            Button("Open Catalog") { app.extensions.run("workbench.openSettings", ["section": .string("catalog")]) }
        } label: {
            Text("Agent Catalog")
            Text("\(have) installed · \(all - have) more to install")
        }
    }
}
