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

    public init(
        id: String, name: String, command: String, args: [String] = [], env: [String: String] = [:],
        waitingPatterns: [String] = AgentManifest.defaultWaiting, quietSeconds: Double = 3,
        hooks: HookTransport? = nil,
        modelFlag: String? = nil, models: [String] = [], effortArgs: [String: [String]] = [:],
        autoAnswers: [AutoAnswer] = [], resumeArgs: [String] = [], pluginDirFlag: String? = nil,
        contextFlag: String? = nil,
        sessionIdFlag: String? = nil, resumeIdFlag: String? = nil
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.waitingPatterns = waitingPatterns
        self.quietSeconds = quietSeconds
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
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AgentManifest(id: "", name: "", command: "")
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? defaults.args
        env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? defaults.env
        waitingPatterns =
            try container.decodeIfPresent([String].self, forKey: .waitingPatterns) ?? defaults.waitingPatterns
        quietSeconds = try container.decodeIfPresent(Double.self, forKey: .quietSeconds) ?? defaults.quietSeconds
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
        install = try container.decodeIfPresent(String.self, forKey: .install)
        update = try container.decodeIfPresent(String.self, forKey: .update)
        npm = try container.decodeIfPresent(String.self, forKey: .npm)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, command, args, env, waitingPatterns, quietSeconds, modelFlag, models, effortArgs, autoAnswers,
            resumeArgs
        case sessionIdFlag, resumeIdFlag, pluginDirFlag, contextFlag, install, update, npm
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
        try container.encodeIfPresent(install, forKey: .install)
        try container.encodeIfPresent(update, forKey: .update)
        try container.encodeIfPresent(npm, forKey: .npm)
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

    /// Installs and updates of the agents people use most, as their own docs give them; the npm package says what's newest.
    static func withInstall(_ manifest: AgentManifest) -> AgentManifest {
        let known: [String: (install: String, update: String?, npm: String?)] = [
            "claude": ("curl -fsSL https://claude.ai/install.sh | bash", "claude update", "@anthropic-ai/claude-code"),
            "codex": ("npm install -g @openai/codex", "npm install -g @openai/codex@latest", "@openai/codex"),
            "gemini": (
                "npm install -g @google/gemini-cli", "npm install -g @google/gemini-cli@latest", "@google/gemini-cli"
            ),
            "opencode": ("curl -fsSL https://opencode.ai/install | bash", "opencode upgrade", "opencode-ai"),
            "cursor": ("curl https://cursor.com/install -fsS | bash", "cursor-agent update", nil),
            "qwen": (
                "npm install -g @qwen-code/qwen-code", "npm install -g @qwen-code/qwen-code@latest",
                "@qwen-code/qwen-code"
            ),
            "amp": ("npm install -g @sourcegraph/amp", "npm install -g @sourcegraph/amp@latest", "@sourcegraph/amp"),
            "copilot": ("npm install -g @github/copilot", "npm install -g @github/copilot@latest", "@github/copilot"),
            "auggie": (
                "npm install -g @augmentcode/auggie", "npm install -g @augmentcode/auggie@latest", "@augmentcode/auggie"
            ),
            "crush": ("brew install charmbracelet/tap/crush", "brew upgrade crush", nil),
            "aider": ("python3 -m pip install aider-install && aider-install", nil, nil),
            "droid": ("curl -fsSL https://app.factory.ai/cli | sh", nil, nil),
            "hermes": ("curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash", "hermes update", nil),
            "kimi": ("curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash", "kimi upgrade", nil),
            "omp": ("curl -fsSL https://omp.sh/install | sh", "omp update", "@oh-my-pi/pi-coding-agent"),
            "fx": ("curl -fsSL https://fx.sh/setup.sh | bash", "fx upgrade", nil),
            // Pi's and Grok's installers run again as the update; Pi's fetches Node when it's missing, which npm wouldn't.
            "pi": (
                "curl -fsSL https://pi.dev/install.sh | sh", "curl -fsSL https://pi.dev/install.sh | sh",
                "@earendil-works/pi-coding-agent"
            ),
            "grok": (
                "curl -fsSL https://x.ai/cli/install.sh | bash", "curl -fsSL https://x.ai/cli/install.sh | bash", nil
            ),
            "antigravity": ("curl -fsSL https://antigravity.google/cli/install.sh | bash", nil, nil),   // updates itself while it runs
            "kilo": ("npm install -g @kilocode/cli", "kilo upgrade", "@kilocode/cli"),
            // CONFIGURE=false: no provider questions in the installer's tab; goose asks on its first run.
            "goose": (
                "curl -fsSL https://github.com/aaif-goose/goose/releases/download/stable/download_cli.sh | CONFIGURE=false bash",
                "goose update", nil
            ),
            "kiro": ("curl -fsSL https://cli.kiro.dev/install | bash", "kiro-cli update", nil)
        ]
        guard let entry = known[manifest.id] else { return manifest }
        var manifest = manifest
        if manifest.install == nil { manifest.install = entry.install }
        if manifest.update == nil { manifest.update = entry.update }
        if manifest.npm == nil { manifest.npm = entry.npm }
        return manifest
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
        guard id == "claude", let pin = sessionIdFlag, let resume = resumeIdFlag,
            argv.contains(pin) || argv.contains(resume)
        else { return nil }
        return resuming(argv) + ["--fork-session"]
    }

    public static let trust = AutoAnswer(
        pattern:
            #"(?i)(do you trust|trust (the files|this folder|the contents)|one you trust|allow .* to work in this folder)"#,
        input: "\r",
        choose: #"(?i)(yes|trust|allow|proceed)"#)

    public static let presets: [AgentManifest] = [
        .init(
            id: "claude", name: "Claude Code", command: "claude", hooks: .settingsFlag("--settings"),
            modelFlag: "--model", models: ["opus", "sonnet", "haiku"],
            autoAnswers: [trust], resumeArgs: ["--continue"], pluginDirFlag: "--plugin-dir",
            contextFlag: "--append-system-prompt",
            sessionIdFlag: "--session-id", resumeIdFlag: "--resume"),
        // Its conversation in its own process, which ends with the tab: in Codex's shared background server (0.157 on) it
        // would run on after the tab closed, and a Codex started with -c (not on that server) couldn't open it again.
        // No update question: it stands before the prompt, which waits behind it, and Kelp offers updates itself.
        .init(
            id: "codex", name: "Codex", command: "codex",
            args: ["--no-daemon", "-c", "check_for_update_on_startup=false"], hooks: .codexConfig,
            modelFlag: "-m", models: ["gpt-5-codex", "gpt-5"],
            effortArgs: [
                "low": ["-c", "model_reasoning_effort=low"], "medium": ["-c", "model_reasoning_effort=medium"],
                "high": ["-c", "model_reasoning_effort=high"]
            ],
            autoAnswers: [trust], resumeArgs: ["resume", "--last"]),
        .init(
            id: "opencode", name: "OpenCode", command: "opencode", hooks: .pluginDir(env: "OPENCODE_CONFIG_DIR"),
            modelFlag: "-m",
            resumeArgs: ["--continue"]),
        .init(
            id: "gemini", name: "Gemini CLI", command: "gemini", modelFlag: "-m",
            models: ["gemini-2.5-pro", "gemini-2.5-flash"], autoAnswers: [trust]),
        .init(
            id: "cursor", name: "Cursor Agent", command: "cursor-agent", modelFlag: "--model", autoAnswers: [trust],
            resumeArgs: ["resume"]),
        // Pi and Antigravity report through OSC 7501 only if Kelp's reply to their probe beats the terminal's DA reply;
        // their variables make them report anyway.
        .init(
            id: "pi", name: "Pi", command: "pi", env: ["PI_PROGRAM_STATUS": "1"], modelFlag: "--model",
            resumeArgs: ["--continue"], resumeIdFlag: "--session"),
        .init(id: "amp", name: "Amp", command: "amp"),
        // A hand-off opens a session file (`--session` / `--resume <file>`): a wake goes on in it, not in "latest here".
        .init(
            id: "omp", name: "oh-my-pi", command: "omp", modelFlag: "--model", resumeArgs: ["--continue"],
            resumeIdFlag: "--resume"),
        .init(id: "fx", name: "fx", command: "fx", hooks: .herdr, modelFlag: "--model", resumeArgs: ["--continue"]),
        // Others people run; Kelp offers whichever of these actually work on this Mac (AgentAvailability).
        .init(id: "grok", name: "Grok", command: "grok", modelFlag: "--model", resumeArgs: ["--continue"]),
        .init(
            id: "antigravity", name: "Antigravity", command: "agy", env: ["AGY_CLI_OSC7501": "on"],
            modelFlag: "--model",
            effortArgs: Dictionary(uniqueKeysWithValues: ["low", "medium", "high"].map { ($0, ["--effort", $0]) }),
            resumeArgs: ["--continue"]),
        .init(
            id: "qwen", name: "Qwen Code", command: "qwen",
            hooks: .settingsFile(
                env: "QWEN_CODE_SYSTEM_SETTINGS_PATH", replaces: "/Library/Application Support/QwenCode/settings.json"),
            modelFlag: "--model", resumeArgs: ["--continue"]),
        .init(
            id: "kimi", name: "Kimi", command: "kimi", modelFlag: "--model",
            autoAnswers: [trust], resumeArgs: ["--continue"]),
        .init(
            id: "kilo", name: "Kilo Code", command: "kilo", hooks: .pluginDir(env: "KILO_CONFIG_DIR"),
            modelFlag: "--model",
            resumeArgs: ["--continue"]),
        .init(id: "crush", name: "Crush", command: "crush", resumeArgs: ["--continue"]),
        .init(
            id: "droid", name: "Droid", command: "droid", hooks: .settingsFlag("--settings"),
            resumeArgs: ["--resume", "--last"]),
        .init(id: "hermes", name: "Hermes", command: "hermes"),
        .init(
            id: "copilot", name: "GitHub Copilot", command: "copilot", modelFlag: "--model", resumeArgs: ["--continue"]),
        .init(id: "aider", name: "Aider", command: "aider"),
        .init(id: "goose", name: "Goose", command: "goose"),
        .init(id: "auggie", name: "Augment", command: "auggie"),
        .init(id: "kiro", name: "Kiro", command: "kiro-cli")
    ]

    /// Presets overridden/extended by `*.json` files in `dir`. Bad files are skipped, never fatal.
    public static func load(dir: URL) -> [AgentManifest] {
        var all = Dictionary(uniqueKeysWithValues: presets.map { ($0.id, withInstall($0)) })
        for file in FileManager.default.items(in: dir) where file.pathExtension == "json" {
            let manifest = Data(contentsIfAny: file).flatMap { data in
                Logger.kelp("agents").attempt("skipping \(file.lastPathComponent), which doesn't read as an agent") {
                    try JSONDecoder().decode(AgentManifest.self, from: data)
                }
            }
            if let manifest { all[manifest.id] = withInstall(manifest) }
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
