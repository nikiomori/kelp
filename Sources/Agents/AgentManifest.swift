import Core
import Foundation
import os

/// An agent is data, not code: adding one means adding a JSON file to ~/.kelp/agents.
/// Only `id`, `name` and `command` are required in a file; everything else has defaults.
public struct AgentManifest: Codable, Sendable, Equatable, Identifiable {
    public struct AutoAnswer: Codable, Sendable, Equatable {
        public var pattern: String
        public var input: String
        /// For arrow-key menus: regex of the option to pick; the keys are computed from where the cursor (❯ / >) is.
        public var choose: String?
        /// Seconds the question has to stay on screen, untouched by the user, before it's answered (0.4 when not given).
        public var after: Double?
        public init(pattern: String, input: String, choose: String? = nil, after: Double? = nil) {
            self.pattern = pattern
            self.input = input
            self.choose = choose
            self.after = after
        }

        /// Text of the option under a TUI menu's cursor. TUIs redraw only changed lines, so it's what follows the last ❯ in the stream.
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
    /// Regexes matched against the tail of recent output when the agent goes quiet: it is asking the user something.
    public var waitingPatterns: [String] = AgentManifest.defaultWaiting
    /// Seconds without output before the heuristic decides the agent stopped.
    public var quietSeconds: Double = 3
    /// Whether its status is read at all: a plain shell has no "done", so nothing it prints makes it working.
    public var tracksStatus = true
    /// How it reports its own status, if it can (heuristics read the screen otherwise).
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
    /// `--session-id <uuid>` pins a new conversation to the Kelp session id; `--resume <uuid>` brings back exactly that one.
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
    /// What it is, in a few English words: Settings and the empty workspace show it beside the name, translated.
    public var about: String?
    /// `#rrggbb`: the tile with its initial, while (or when) no icon is found.
    public var color: String?
    /// Where its icon comes from when Kelp ships none: its Mac app's names, then its website's own icon.
    public var apps: [String] = [], site: String?
    /// Its place among the agents the empty workspace offers to install when none is on this Mac; nil: not offered there.
    public var featured: Int?
    /// The conversation it keeps on disk in a form Kelp reads, if any.
    public var transcript: Transcript?
    /// What it prints of its plan's limits while it runs, which its session reads (`LimitScreens.read`); nil: nothing.
    public var limitScreen: LimitScreen?
    /// Account profiles: each login in a config folder of its own, which `AgentHome`'s variable points it at.
    public var profiles = false
    /// Ways to run it through another provider, as variables its docs define (Settings › Agent Catalog adds them).
    public var providers: [Provider] = []

    public enum Transcript: String, Codable, Sendable, CaseIterable {
        /// Claude Code's `projects/<folder>/<id>.jsonl`: subagent journals, recaps, a fork with `--fork-session`, and
        /// Codex imports it at a hand-off.
        case claude
        /// Codex's rollouts: a fork goes on from its thread, and a hand-off from a Claude transcript imports into one.
        case codex
        /// pi's session files: a hand-off writes one, which the agent opens with `resumeIdFlag`.
        case pi
    }

    public enum LimitScreen: String, Codable, Sendable, CaseIterable {
        /// Claude Code's: how much of each limit is used ("80% of your weekly limit"), the account's usage from then on.
        case claude
        /// Cursor Agent's: that the plan ran out, held over what its `/usage` says.
        case cursor
        /// Codex's: that the plan ran out, for the session to go on after the reset (its usage comes from its app-server).
        case codex
    }

    public struct Provider: Codable, Sendable, Equatable {
        public var name: String, env: [String]
        public init(_ name: String, _ env: [String]) {
            self.name = name
            self.env = env
        }
    }

    /// `session.fork` can copy its conversation.
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
        // A file for a preset's agent (an override Settings saved, or one written by hand) keeps what Kelp knows of that
        // agent where the file says nothing: an override written before a fact was added still has it.
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
        // A format this Kelp doesn't read is none, not a file that doesn't load.
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
        // `hooks`, as agent files have it
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
        // What Kelp knows of a preset's agent is written only where this one differs: an override follows the preset.
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

    /// What an agent file says instead of a secret's value: the value is in the login keychain (`agent.<id>.<KEY>`).
    public static let keychainValue = "<in Keychain>"
    public static func isSecret(_ key: String) -> Bool {
        key.range(of: #"(KEY|TOKEN|SECRET|PASSWORD|AUTH)"#, options: .regularExpression) != nil
    }
    public static func secretAccount(agent: String, key: String) -> String { "agent.\(agent).\(key)" }

    /// The environment to launch with: secrets read from the keychain.
    public var resolvedEnv: [String: String] {
        env.reduce(into: [:]) { out, kv in
            out[kv.key] =
                kv.value == Self.keychainValue
                ? Keychain.get(Self.secretAccount(agent: id, key: kv.key)) ?? "" : kv.value
        }
    }

    /// The package manager its install command needs, when that's not something every Mac has (npm, Homebrew).
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

    /// `argv` changed to continue its conversation: the pinned id when there is one, else the agent's "latest here".
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

    /// `argv` pinned to `conversation`, the one the agent writes now (Claude Code's /resume or /clear switched to it), so a
    /// wake or restart brings back that one. Unchanged when it already names it, or names none.
    public func following(_ argv: [String], conversation: String) -> [String] {
        guard let pin = sessionIdFlag, let resume = resumeIdFlag,
            let index = argv.lastIndex(where: { $0 == pin || $0 == resume }),
            index + 1 < argv.count,
            argv[index + 1].lowercased() != conversation.lowercased()
        else { return argv }
        var pinned = argv
        pinned[index] = pin
        pinned[index + 1] = conversation   // pinned: a wake resumes it once it's on disk, else starts it under this id
        pinned.removeAll { $0 == "--fork-session" }   // the fork it asked for is made (`forking`): this is it
        return pinned
    }

    /// `argv` changed to continue a copy of its conversation (a session copied to another home, `HomeSeed`), leaving the
    /// one it names as it is; `following` drops the flag once the copy is made. Nil when no id is pinned, or the agent can't.
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
        .init(id: "custom", name: "Custom", command: "/bin/zsh", args: ["-lc", command])
    }
}
