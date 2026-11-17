import Core
import Foundation
import os

/// An agent is data, not code: adding one means adding a JSON file to ~/.kelp/agents.
/// Only `id`, `name` and `command` are required in a file; everything else has defaults.
public struct AgentManifest: Codable, Sendable, Equatable, Identifiable {
    public struct AutoAnswer: Codable, Sendable, Equatable {
        public var pattern: String
        public var input: String
        /// For arrow-key menus, a regex for the option to pick. The arrow keys to send are worked out from where the
        /// cursor (❯ / >) is.
        public var choose: String?
        /// Seconds the question has to stay on screen, untouched by the user, before it's answered (0.4 when not given).
        public var after: Double?
        public init(pattern: String, input: String, choose: String? = nil, after: Double? = nil) {
            self.pattern = pattern
            self.input = input
            self.choose = choose
            self.after = after
        }

        /// Returns the text of the option under a TUI menu's cursor. TUIs redraw only the lines that changed, so the
        /// option is whatever follows the last ❯ in the stream.
        public static func optionAtCursor(_ screen: String) -> String? {
            guard let mark = screen.range(of: "❯", options: .backwards) ?? screen.range(of: "›", options: .backwards)
            else { return nil }
            // split on isNewline: "\r\n" is a single Character, so splitting on "\n" alone would glue options together
            return String(screen[mark.upperBound...].prefix(80).split(whereSeparator: \.isNewline).first ?? "")
                .trimmingCharacters(in: .whitespaces)
        }
    }

    public var id: String
    public var name: String
    public var command: String
    public var args: [String] = []
    public var env: [String: String] = [:]
    /// Regexes matched against the tail of recent output when the agent goes quiet. A match means the agent is asking
    /// the user something.
    public var waitingPatterns: [String] = AgentManifest.defaultWaiting
    /// Seconds without output before the heuristic decides the agent stopped.
    public var quietSeconds: Double = 3
    /// Whether the agent's status is read at all. A plain shell has no "done", so nothing it prints may mark it as
    /// working.
    public var tracksStatus = true
    /// How the agent reports its own status, if it can. Otherwise heuristics read the screen.
    public var hooks: HookTransport?
    /// `--model`-style flag and suggested models for the picker.
    public var modelFlag: String?
    public var models: [String] = []
    /// Effort level -> extra args.
    public var effortArgs: [String: [String]] = [:]
    /// Prompts answered automatically in the first seconds of a session (e.g. "trust this folder?").
    public var autoAnswers: [AutoAnswer] = []
    /// Args that resume the latest conversation in this directory (restart / hibernation) when no id was pinned.
    public var resumeArgs: [String] = []
    /// `--session-id <uuid>` pins a new conversation to the Kelp session id, and `--resume <uuid>` brings back exactly
    /// that conversation.
    /// Without them, two agents in one folder resume each other's conversations.
    public var sessionIdFlag: String?
    public var resumeIdFlag: String?
    /// If set, `{pluginDirFlag} <dir>` loads Kelp's skills (extensions, settings) for the session only.
    public var pluginDirFlag: String?
    /// If set, `{contextFlag} <text>` tells the agent it runs inside Kelp and which skills to use for it.
    public var contextFlag: String?
    /// The agent's own install / update commands (run in a terminal you can watch), and its npm package for
    /// "is there a newer version".
    public var install: String?, update: String?, npm: String?
    /// What the agent is, in a few English words. Settings and the empty workspace show it, translated, beside the
    /// name.
    public var about: String?
    /// The `#rrggbb` color of the tile with the agent's initial, shown while no icon is found, or when none is.
    public var color: String?
    /// Where the agent's icon comes from when Kelp ships none: the names of its Mac app, then its website's own icon.
    public var apps: [String] = [], site: String?
    /// The agent's place in the list that the empty workspace offers to install when no agent is on this Mac. When it
    /// is nil, the agent isn't offered there.
    public var featured: Int?
    /// The format of the conversation that the agent keeps on disk, if Kelp can read it.
    public var transcript: Transcript?
    /// What the agent prints about its plan's limits while it runs, which its session reads (`LimitScreens.read`). It
    /// is nil when the agent prints nothing of the kind.
    public var limitScreen: LimitScreen?
    /// Whether the agent has account profiles. Each login gets a config folder of its own, and the variable from
    /// `AgentHome` points the agent at it.
    public var profiles = false
    /// Ways to run the agent through another provider, as variables its docs define (Settings › Agent Catalog adds
    /// them).
    public var providers: [Provider] = []

    public enum Transcript: String, Codable, Sendable, CaseIterable {
        /// Claude Code's `projects/<folder>/<id>.jsonl`. It gives subagent journals, recaps and a fork with
        /// `--fork-session`, and Codex imports it at a hand-off.
        case claude
        /// Codex's rollouts. A fork goes on from the rollout's thread, and a hand-off imports a Claude transcript into
        /// a new rollout.
        case codex
        /// pi's session files. A hand-off writes one, and the agent opens it with `resumeIdFlag`.
        case pi
    }

    public enum LimitScreen: String, Codable, Sendable, CaseIterable {
        /// Claude Code says how much of each limit is used ("80% of your weekly limit"), and that becomes the
        /// account's usage from then on.
        case claude
        /// Cursor Agent says that the plan ran out, and that takes priority over what its `/usage` says.
        case cursor
        /// Codex says that the plan ran out, so the session can go on after the reset. Codex's usage comes from its
        /// app-server.
        case codex
    }

    public struct Provider: Codable, Sendable, Equatable {
        public var name: String, env: [String]
        public init(_ name: String, _ env: [String]) {
            self.name = name
            self.env = env
        }
    }

    /// Whether `session.fork` can copy the agent's conversation.
    public var forks: Bool { transcript == .claude || transcript == .codex }

    public init(
        id: String, name: String, command: String, args: [String] = [], env: [String: String] = [:],
        waitingPatterns: [String] = AgentManifest.defaultWaiting, quietSeconds: Double = 3, tracksStatus: Bool = true,
        hooks: HookTransport? = nil,
        modelFlag: String? = nil, models: [String] = [], effortArgs: [String: [String]] = [:],
        autoAnswers: [AutoAnswer] = [], resumeArgs: [String] = [], pluginDirFlag: String? = nil,
        contextFlag: String? = nil,
        sessionIdFlag: String? = nil, resumeIdFlag: String? = nil,
        install: String? = nil, update: String? = nil, npm: String? = nil, about: String? = nil,
        color: String? = nil, apps: [String] = [], site: String? = nil, featured: Int? = nil,
        transcript: Transcript? = nil, limitScreen: LimitScreen? = nil, profiles: Bool = false,
        providers: [Provider] = []
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.waitingPatterns = waitingPatterns
        self.quietSeconds = quietSeconds
        self.tracksStatus = tracksStatus
        self.hooks = hooks
        self.modelFlag = modelFlag
        self.models = models
        self.effortArgs = effortArgs
        self.autoAnswers = autoAnswers
        self.resumeArgs = resumeArgs
        self.pluginDirFlag = pluginDirFlag
        self.contextFlag = contextFlag
        self.sessionIdFlag = sessionIdFlag
        self.resumeIdFlag = resumeIdFlag
        self.install = install
        self.update = update
        self.npm = npm
        self.about = about
        self.color = color
        self.apps = apps
        self.site = site
        self.featured = featured
        self.transcript = transcript
        self.limitScreen = limitScreen
        self.profiles = profiles
        self.providers = providers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AgentManifest(id: "", name: "", command: "")
        let id = try container.decode(String.self, forKey: .id)
        self.id = id
        // A file for a preset's agent (an override that Settings saved, or one written by hand) keeps the preset's
        // facts wherever the file says nothing. So an override written before a fact was added still gets that fact.
        let preset = Self.presets.first { $0.id == id }
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? defaults.args
        env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? defaults.env
        waitingPatterns =
            try container.decodeIfPresent([String].self, forKey: .waitingPatterns) ?? defaults.waitingPatterns
        quietSeconds = try container.decodeIfPresent(Double.self, forKey: .quietSeconds) ?? defaults.quietSeconds
        tracksStatus = try container.decodeIfPresent(Bool.self, forKey: .tracksStatus) ?? true
        hooks = try HookTransport(from: container)
        modelFlag = try container.decodeIfPresent(String.self, forKey: .modelFlag)
        models = try container.decodeIfPresent([String].self, forKey: .models) ?? []
        effortArgs = try container.decodeIfPresent([String: [String]].self, forKey: .effortArgs) ?? [:]
        autoAnswers = try container.decodeIfPresent([AutoAnswer].self, forKey: .autoAnswers) ?? []
        resumeArgs = try container.decodeIfPresent([String].self, forKey: .resumeArgs) ?? []
        pluginDirFlag = try container.decodeIfPresent(String.self, forKey: .pluginDirFlag)
        contextFlag = try container.decodeIfPresent(String.self, forKey: .contextFlag)
        sessionIdFlag = try container.decodeIfPresent(String.self, forKey: .sessionIdFlag)
        resumeIdFlag = try container.decodeIfPresent(String.self, forKey: .resumeIdFlag)
        install = try container.decodeIfPresent(String.self, forKey: .install) ?? preset?.install
        update = try container.decodeIfPresent(String.self, forKey: .update) ?? preset?.update
        npm = try container.decodeIfPresent(String.self, forKey: .npm) ?? preset?.npm
        about = try container.decodeIfPresent(String.self, forKey: .about) ?? preset?.about
        color = try container.decodeIfPresent(String.self, forKey: .color) ?? preset?.color
        apps = try container.decodeIfPresent([String].self, forKey: .apps) ?? preset?.apps ?? []
        site = try container.decodeIfPresent(String.self, forKey: .site) ?? preset?.site
        featured = try container.decodeIfPresent(Int.self, forKey: .featured) ?? preset?.featured
        // A format that this version of Kelp doesn't read becomes nil, so the file still loads.
        transcript =
            try container.decodeIfPresent(String.self, forKey: .transcript).map { Transcript(rawValue: $0) }
            ?? preset?.transcript
        limitScreen =
            try container.decodeIfPresent(String.self, forKey: .limitScreen).map { LimitScreen(rawValue: $0) }
            ?? preset?.limitScreen
        profiles = try container.decodeIfPresent(Bool.self, forKey: .profiles) ?? preset?.profiles ?? false
        providers = try container.decodeIfPresent([Provider].self, forKey: .providers) ?? preset?.providers ?? []
    }

    enum CodingKeys: String, CodingKey {
        case id, name, command, args, env, waitingPatterns, quietSeconds, tracksStatus, modelFlag, models, effortArgs,
            autoAnswers, resumeArgs
        case sessionIdFlag, resumeIdFlag, pluginDirFlag, contextFlag, install, update, npm
        case about, color, apps, site, featured, transcript, limitScreen, profiles, providers
        // The keys that `hooks` is stored under in agent files.
        case hooksSettingsFlag, hooksConfigDirEnv, hooksSettingsEnv, hooksHerdr, hooksCodexConfig
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(command, forKey: .command)
        try container.encode(args, forKey: .args)
        try container.encode(env, forKey: .env)
        try container.encode(waitingPatterns, forKey: .waitingPatterns)
        try container.encode(quietSeconds, forKey: .quietSeconds)
        if !tracksStatus { try container.encode(tracksStatus, forKey: .tracksStatus) }
        try hooks?.encode(to: &container)
        try container.encodeIfPresent(modelFlag, forKey: .modelFlag)
        try container.encode(models, forKey: .models)
        try container.encode(effortArgs, forKey: .effortArgs)
        try container.encode(autoAnswers, forKey: .autoAnswers)
        try container.encode(resumeArgs, forKey: .resumeArgs)
        try container.encodeIfPresent(sessionIdFlag, forKey: .sessionIdFlag)
        try container.encodeIfPresent(resumeIdFlag, forKey: .resumeIdFlag)
        try container.encodeIfPresent(pluginDirFlag, forKey: .pluginDirFlag)
        try container.encodeIfPresent(contextFlag, forKey: .contextFlag)
        // A preset's facts are written only where this manifest differs, so an override keeps following the preset.
        let preset = Self.presets.first { $0.id == id }
        func fact<T: Encodable & Equatable>(_ value: T, _ base: T, _ key: CodingKeys) throws {
            if value != base { try container.encode(value, forKey: key) }
        }
        try fact(install, preset?.install, .install)
        try fact(update, preset?.update, .update)
        try fact(npm, preset?.npm, .npm)
        try fact(about, preset?.about, .about)
        try fact(color, preset?.color, .color)
        try fact(apps, preset?.apps ?? [], .apps)
        try fact(site, preset?.site, .site)
        try fact(featured, preset?.featured, .featured)
        try fact(transcript, preset?.transcript, .transcript)
        try fact(limitScreen, preset?.limitScreen, .limitScreen)
        try fact(profiles, preset?.profiles ?? false, .profiles)
        try fact(providers, preset?.providers ?? [], .providers)
    }

    /// What an agent file holds in place of a secret's value. The value is in the login keychain (`agent.<id>.<KEY>`).
    public static let keychainValue = "<in Keychain>"
    public static func isSecret(_ key: String) -> Bool {
        key.range(of: #"(KEY|TOKEN|SECRET|PASSWORD|AUTH)"#, options: .regularExpression) != nil
    }
    public static func secretAccount(agent: String, key: String) -> String { "agent.\(agent).\(key)" }

    /// The environment to launch with, with secrets read from the keychain.
    public var resolvedEnv: [String: String] {
        env.reduce(into: [:]) { out, kv in
            out[kv.key] =
                kv.value == Self.keychainValue
                ? Keychain.get(Self.secretAccount(agent: id, key: kv.key)) ?? "" : kv.value
        }
    }

    /// The package manager that the install command needs, when it isn't one every Mac has (npm, Homebrew).
    public var installNeeds: String? {
        guard let first = install?.split(separator: " ").first.map(String.init), ["npm", "brew"].contains(first) else {
            return nil
        }
        return first
    }

    public static let defaultWaiting = [
        #"(?i)\[y/n\]"#, #"(?i)\(y/n\)"#, #"(?i)do you want to"#, #"(?i)press enter"#,
        #"(?i)\ballow\b(?:(?!\. )[^\n?]){1,100}\?"#,   // "Allow write to main.rs?", not Grok's "…allow SpaceXAI to retain … purposes."
        #"(?im)\bapprove\b.*\?\s*$"#, #"(?im)^\W*(\d+[.)]\s*)?approve\b"#, #"❯ ?1\."#   // approve: a question or an option, not prose
    ]

    public var commandLine: [String] { [command] + args }

    /// Full argv for a launch with the chosen options.
    public func argv(model: String? = nil, effort: String? = nil, resume: Bool = false) -> [String] {
        var launch = commandLine
        if let model, !model.isEmpty, let flag = modelFlag { launch += [flag, model] }
        if let effort, let extra = effortArgs[effort] { launch += extra }
        if resume { launch += resumeArgs }
        return launch
    }

    /// True when `argv` already names the conversation to continue.
    public func resumes(_ argv: [String]) -> Bool {
        resumeIdFlag.map(argv.contains) == true || (!resumeArgs.isEmpty && argv.contains(where: resumeArgs.contains))
    }

    /// Returns `argv` changed to continue its conversation: by the pinned id when there is one, or else by the agent's
    /// "latest here" arguments.
    public func resuming(_ argv: [String]) -> [String] {
        if let pin = sessionIdFlag, let resume = resumeIdFlag, let index = argv.firstIndex(of: pin),
            index + 1 < argv.count
        {
            var resumed = argv
            resumed[index] = resume
            return resumed
        }
        return resumes(argv) ? argv : argv + resumeArgs
    }

    /// Returns `argv` pinned to `conversation`, the one the agent is writing now (Claude Code's /resume or /clear
    /// switched to it), so that a wake or restart brings back that conversation. `argv` stays unchanged when it already
    /// names that conversation, or names none.
    public func following(_ argv: [String], conversation: String) -> [String] {
        guard let pin = sessionIdFlag, let resume = resumeIdFlag,
            let index = argv.lastIndex(where: { $0 == pin || $0 == resume }),
            index + 1 < argv.count,
            argv[index + 1].lowercased() != conversation.lowercased()
        else { return argv }
        var pinned = argv
        pinned[index] = pin
        pinned[index + 1] = conversation   // a wake resumes this id once it's on disk, or else starts it
        pinned.removeAll { $0 == "--fork-session" }   // the fork `forking` asked for exists now
        return pinned
    }

    /// Returns `argv` changed to continue a copy of its conversation (a session copied to another home, `HomeSeed`),
    /// leaving the conversation it names as it is. `following` drops the flag once the copy is made. Returns nil when
    /// no id is pinned, or when the agent can't fork.
    public func forking(_ argv: [String]) -> [String]? {
        guard transcript == .claude, let pin = sessionIdFlag, let resume = resumeIdFlag,
            argv.contains(pin) || argv.contains(resume)
        else { return nil }
        return resuming(argv) + ["--fork-session"]
    }

    public static let trust = AutoAnswer(
        pattern:
            #"(?i)(do you trust|trust (the files|this folder|the contents)|one you trust|allow .* to work in this folder)"#,
        input: "\r",
        choose: #"(?i)(yes|trust|allow|proceed)"#)

    /// Presets overridden/extended by `*.json` files in `dir`. Bad files are skipped, never fatal.
    public static func load(dir: URL) -> [AgentManifest] {
        var all = Dictionary(uniqueKeysWithValues: presets.map { ($0.id, $0) })
        for file in FileManager.default.items(in: dir) where file.pathExtension == "json" {
            let manifest = Data(contentsIfAny: file).flatMap { data in
                Logger.kelp("agents").attempt("skipping \(file.lastPathComponent), which doesn't read as an agent") {
                    try JSONDecoder().decode(AgentManifest.self, from: data)
                }
            }
            if let manifest { all[manifest.id] = manifest }
        }
        return all.values.sorted { $0.name < $1.name }
    }

    /// Settings UI: save an override (binary, args, env…) or reset to the preset by deleting it.
    public static func saveOverride(_ manifest: AgentManifest, dir: URL) throws {
        try Paths.ensure(dir)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: dir.appendingPathComponent("\(manifest.id).json"))
    }
    public static func resetOverride(id: String, dir: URL) {
        FileManager.default.removeIfAny(dir.appendingPathComponent("\(id).json"))
    }

    /// A "custom command" agent: any shell command.
    public static func custom(_ command: String) -> AgentManifest {
        .init(id: Session.customAgent, name: "Custom", command: "/bin/zsh", args: ["-lc", command])
    }
}
