// An agent's card in Settings › Agent Catalog: its install state, launch fields, and saving them.
import Agents
import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI

extension AgentsSettings {
    /// Found after its installer ended: offered in New Agent from now on.
    func started(_ m: AgentManifest) -> some View {
        HStack {
            Label {
                status(String(localized: "\(m.name) is installed"), String(localized: "Offered in New Agent."))
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Spacer()
            Button("Start \(m.name)") {
                guard let starter = app.workbench.starter else {
                    Banner.show(String(localized: "Open a chat to start \(m.name) there."))
                    return
                }
                starter.newAgent(m.id)
                app.workbench.bringToFront()
            }
        }
    }

    func status(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).fontWeight(.medium)
            Text(detail).font(.ui(TextSize.caption)).foregroundStyle(.secondary).fixedSize(
                horizontal: false, vertical: true)
        }
    }

    /// A command as it runs, to read or copy.
    func commandLine(_ cmd: String) -> some View {
        HStack(alignment: .top) {
            Text(cmd).font(.uiMono(TextSize.caption)).textSelection(.enabled).fixedSize(
                horizontal: false, vertical: true)
            Spacer()
            Button {
                copyText(cmd)
            } label: {
                Image(systemName: "doc.on.doc").font(.symbol())
            }.buttonStyle(PointerButtonStyle()).help("Copy")
        }
        .padding(Metrics.gapWide)
        .background(Color(nsColor: .fillRest), in: RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous))
    }

    @ViewBuilder func versionRow(_ m: AgentManifest) -> some View {
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
    func launch(_ m: AgentManifest) -> some View {
        Section {
            input("Command", $command, .command)
            input("Arguments", $args, .args, prompt: "space separated")
            input("Environment", $env, .env, prompt: "KEY=value, one per line", lines: 3...6)
            HStack {
                if !m.providers.isEmpty {
                    Menu("Provider Presets") {
                        ForEach(m.providers, id: \.name) { p in Button(p.name) { addLines(p.env) } }
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
            .font(.ui(TextSize.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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

    func install(_ m: AgentManifest) {
        guard let starter = app.workbench.starter else {
            run(m.install ?? "", String(localized: "Install \(m.name)"))
            return
        }   // says what to do
        app.catalog.install(m, in: starter)
        app.workbench.bringToFront()
    }

    func show(_ tab: String) {
        app.workbench.focus(session: tab)
        app.workbench.bringToFront()
    }

    /// The agent's own command, in a terminal in the workspace on screen, so what it does is in plain sight.
    private func run(_ cmd: String, _ title: String, in folder: String? = nil) {
        guard let starter = app.workbench.starter else {
            copyText(cmd)
            Banner.show(String(localized: "Open a chat to run it there — the command is on the clipboard: \(cmd)"))
            return
        }
        starter.run(command: cmd, title: title, cwd: folder)
        app.workbench.bringToFront()
    }

    func loadVersions() async {
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

    private func addLines(_ lines: [String]) {
        var have = env.split(separator: "\n").map(String.init)
        for l in lines
        where !have.contains(where: { $0.hasPrefix(l.split(separator: "=").first.map { $0 + "=" } ?? l) }) {
            have.append(l)
        }
        env = have.joined(separator: "\n")
    }

    var current: AgentManifest? { agents.first { $0.id == selection } }
    private static func envText(_ m: AgentManifest) -> String {
        m.env.map { "\($0)=\($1)" }.sorted().joined(separator: "\n")
    }
    func load() {
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
            guard await app.call(AgentSave(agent: m.id)) != nil else { return }
            reload()
        }
    }

    /// Only what changed: looking at an agent mustn't leave an override behind. The values go along now, since the fields
    /// may hold another agent by the time the keychain answers.
    func persist() {
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
        let file: JSONValue
        do { file = try JSONValue.from(manifest) } catch {
            Banner.show(
                String(localized: "Couldn't save \(manifest.name): \(error.localizedDescription)"), style: .error)
            return
        }
        guard await app.call(AgentSave(agent: manifest.id, manifest: file)) != nil else { return }
        files = AgentManifest.load(dir: Paths.agents)
        if field == nil { load() }   // a secret reads as the keychain's mark now; not under someone's typing
        app.agents = AgentManifest.load(dir: Paths.agents)
        app.availability.refresh(force: true)
    }
}
