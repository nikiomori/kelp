import Foundation
import Core

/// An agent is data, not code: adding one means adding a JSON file to ~/.kelp/agents.
/// Only `id`, `name` and `command` are required in a file; everything else has defaults.
public struct AgentManifest: Codable, Sendable, Equatable, Identifiable {
    public struct AutoAnswer: Codable, Sendable, Equatable {
        public var pattern: String; public var input: String
        /// For arrow-key menus: regex of the option to pick; the keys are computed from where the cursor (❯ / >) is.
        public var choose: String?
        public init(pattern: String, input: String, choose: String? = nil) { self.pattern = pattern; self.input = input; self.choose = choose }

        /// Text of the option under a TUI menu's cursor. TUIs redraw only changed lines, so it's what follows the last ❯ in the stream.
        public static func optionAtCursor(_ screen: String) -> String? {
            guard let mark = screen.range(of: "❯", options: .backwards) ?? screen.range(of: "›", options: .backwards) else { return nil }
            // split on isNewline: "\r\n" is a single Character, so splitting on "\n" alone would glue options together
            return String(screen[mark.upperBound...].prefix(80).split(whereSeparator: \.isNewline).first ?? "").trimmingCharacters(in: .whitespaces)
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
    /// If set, hooks are supported: `{hooksSettingsFlag} <file>` is appended and the file holds Stop/Notification hooks.
    public var hooksSettingsFlag: String?
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

    public init(id: String, name: String, command: String, args: [String] = [], env: [String: String] = [:],
                waitingPatterns: [String] = AgentManifest.defaultWaiting, quietSeconds: Double = 3, hooksSettingsFlag: String? = nil,
                modelFlag: String? = nil, models: [String] = [], effortArgs: [String: [String]] = [:],
                autoAnswers: [AutoAnswer] = [], resumeArgs: [String] = [], pluginDirFlag: String? = nil, contextFlag: String? = nil,
                sessionIdFlag: String? = nil, resumeIdFlag: String? = nil) {
        self.id = id; self.name = name; self.command = command; self.args = args; self.env = env
        self.waitingPatterns = waitingPatterns; self.quietSeconds = quietSeconds; self.hooksSettingsFlag = hooksSettingsFlag
        self.modelFlag = modelFlag; self.models = models; self.effortArgs = effortArgs
        self.autoAnswers = autoAnswers; self.resumeArgs = resumeArgs; self.pluginDirFlag = pluginDirFlag; self.contextFlag = contextFlag
        self.sessionIdFlag = sessionIdFlag; self.resumeIdFlag = resumeIdFlag
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AgentManifest(id: "", name: "", command: "")
        id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        command = try c.decode(String.self, forKey: .command)
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? d.args
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? d.env
        waitingPatterns = try c.decodeIfPresent([String].self, forKey: .waitingPatterns) ?? d.waitingPatterns
        quietSeconds = try c.decodeIfPresent(Double.self, forKey: .quietSeconds) ?? d.quietSeconds
        hooksSettingsFlag = try c.decodeIfPresent(String.self, forKey: .hooksSettingsFlag)
        modelFlag = try c.decodeIfPresent(String.self, forKey: .modelFlag)
        models = try c.decodeIfPresent([String].self, forKey: .models) ?? []
        effortArgs = try c.decodeIfPresent([String: [String]].self, forKey: .effortArgs) ?? [:]
        autoAnswers = try c.decodeIfPresent([AutoAnswer].self, forKey: .autoAnswers) ?? []
        resumeArgs = try c.decodeIfPresent([String].self, forKey: .resumeArgs) ?? []
        pluginDirFlag = try c.decodeIfPresent(String.self, forKey: .pluginDirFlag)
        contextFlag = try c.decodeIfPresent(String.self, forKey: .contextFlag)
        sessionIdFlag = try c.decodeIfPresent(String.self, forKey: .sessionIdFlag)
        resumeIdFlag = try c.decodeIfPresent(String.self, forKey: .resumeIdFlag)
        install = try c.decodeIfPresent(String.self, forKey: .install)
        update = try c.decodeIfPresent(String.self, forKey: .update)
        npm = try c.decodeIfPresent(String.self, forKey: .npm)
    }

    /// What an agent file says instead of a secret's value: the value is in the login keychain (`agent.<id>.<KEY>`).
    public static let keychainValue = "<in Keychain>"
    public static func isSecret(_ key: String) -> Bool { key.range(of: #"(KEY|TOKEN|SECRET|PASSWORD|AUTH)"#, options: .regularExpression) != nil }
    public static func secretAccount(agent: String, key: String) -> String { "agent.\(agent).\(key)" }

    /// The environment to launch with: secrets read from the keychain.
    public var resolvedEnv: [String: String] {
        env.reduce(into: [:]) { out, kv in
            out[kv.key] = kv.value == Self.keychainValue ? Keychain.get(Self.secretAccount(agent: id, key: kv.key)) ?? "" : kv.value
        }
    }

    /// Installs and updates of the agents people use most, as their own docs give them; the npm package says what's newest.
    static func withInstall(_ m: AgentManifest) -> AgentManifest {
        let known: [String: (install: String, update: String?, npm: String?)] = [
            "claude": ("curl -fsSL https://claude.ai/install.sh | bash", "claude update", "@anthropic-ai/claude-code"),
            "codex": ("npm install -g @openai/codex", "npm install -g @openai/codex@latest", "@openai/codex"),
            "gemini": ("npm install -g @google/gemini-cli", "npm install -g @google/gemini-cli@latest", "@google/gemini-cli"),
            "opencode": ("curl -fsSL https://opencode.ai/install | bash", "opencode upgrade", "opencode-ai"),
            "cursor": ("curl https://cursor.com/install -fsS | bash", "cursor-agent update", nil),
            "qwen": ("npm install -g @qwen-code/qwen-code", "npm install -g @qwen-code/qwen-code@latest", "@qwen-code/qwen-code"),
            "amp": ("npm install -g @sourcegraph/amp", "npm install -g @sourcegraph/amp@latest", "@sourcegraph/amp"),
            "copilot": ("npm install -g @github/copilot", "npm install -g @github/copilot@latest", "@github/copilot"),
            "auggie": ("npm install -g @augmentcode/auggie", "npm install -g @augmentcode/auggie@latest", "@augmentcode/auggie"),
            "crush": ("brew install charmbracelet/tap/crush", "brew upgrade crush", nil),
            "aider": ("python3 -m pip install aider-install && aider-install", nil, nil),
            "droid": ("curl -fsSL https://app.factory.ai/cli | sh", nil, nil)
        ]
        guard let k = known[m.id] else { return m }
        var m = m
        if m.install == nil { m.install = k.install }
        if m.update == nil { m.update = k.update }
        if m.npm == nil { m.npm = k.npm }
        return m
    }

    public static let defaultWaiting = [
        #"(?i)\[y/n\]"#, #"(?i)\(y/n\)"#, #"(?i)do you want to"#, #"(?i)press enter"#,
        #"(?i)\ballow\b(?:(?!\. )[^\n?]){1,100}\?"#,   // "Allow write to main.rs?", not Grok's "…allow SpaceXAI to retain … purposes."
        #"(?im)\bapprove\b.*\?\s*$"#, #"(?im)^\W*(\d+[.)]\s*)?approve\b"#, #"❯ ?1\."#   // approve: a question or an option, not prose
    ]

    public var commandLine: [String] { [command] + args }

    /// Full argv for a launch with the chosen options.
    public func argv(model: String? = nil, effort: String? = nil, resume: Bool = false) -> [String] {
        var a = commandLine
        if let model, !model.isEmpty, let f = modelFlag { a += [f, model] }
        if let effort, let e = effortArgs[effort] { a += e }
        if resume { a += resumeArgs }
        return a
    }

    /// True when `argv` already names the conversation to continue.
    public func resumes(_ argv: [String]) -> Bool {
        resumeIdFlag.map(argv.contains) == true || (!resumeArgs.isEmpty && argv.contains(where: resumeArgs.contains))
    }

    /// `argv` changed to continue its conversation: the pinned id when there is one, else the agent's "latest here".
    public func resuming(_ argv: [String]) -> [String] {
        if let f = sessionIdFlag, let r = resumeIdFlag, let i = argv.firstIndex(of: f), i + 1 < argv.count {
            var a = argv; a[i] = r; return a
        }
        return resumes(argv) ? argv : argv + resumeArgs
    }

    /// `argv` pinned to `conversation`, the one the agent writes now (Claude Code's /resume or /clear switched to it), so a
    /// wake or restart brings back that one. Unchanged when it already names it, or names none.
    public func following(_ argv: [String], conversation: String) -> [String] {
        guard let pin = sessionIdFlag, let r = resumeIdFlag, let i = argv.lastIndex(where: { $0 == pin || $0 == r }), i + 1 < argv.count,
              argv[i + 1].lowercased() != conversation.lowercased() else { return argv }
        var a = argv; a[i] = pin; a[i + 1] = conversation   // pinned: a wake resumes it once it's on disk, else starts it under this id
        return a
    }

    public static let trust = AutoAnswer(pattern: #"(?i)(do you trust|trust (the files|this folder|the contents)|one you trust|allow .* to work in this folder)"#, input: "\r",
                                  choose: #"(?i)(yes|trust|allow|proceed)"#)

    public static let presets: [AgentManifest] = [
        .init(id: "claude", name: "Claude Code", command: "claude", hooksSettingsFlag: "--settings",
              modelFlag: "--model", models: ["opus", "sonnet", "haiku"],
              autoAnswers: [trust], resumeArgs: ["--continue"], pluginDirFlag: "--plugin-dir", contextFlag: "--append-system-prompt",
              sessionIdFlag: "--session-id", resumeIdFlag: "--resume"),
        .init(id: "codex", name: "Codex", command: "codex", modelFlag: "-m", models: ["gpt-5-codex", "gpt-5"],
              effortArgs: ["low": ["-c", "model_reasoning_effort=low"], "medium": ["-c", "model_reasoning_effort=medium"], "high": ["-c", "model_reasoning_effort=high"]],
              autoAnswers: [trust], resumeArgs: ["resume", "--last"]),
        .init(id: "opencode", name: "OpenCode", command: "opencode", modelFlag: "-m", resumeArgs: ["--continue"]),
        .init(id: "gemini", name: "Gemini CLI", command: "gemini", modelFlag: "-m", models: ["gemini-2.5-pro", "gemini-2.5-flash"], autoAnswers: [trust]),
        .init(id: "cursor", name: "Cursor Agent", command: "cursor-agent", modelFlag: "--model", autoAnswers: [trust], resumeArgs: ["resume"]),
        .init(id: "pi", name: "Pi", command: "pi"),
        .init(id: "amp", name: "Amp", command: "amp"),
        // Others people run; Kelp offers whichever of these actually work on this Mac (AgentAvailability).
        .init(id: "grok", name: "Grok", command: "grok"),
        .init(id: "antigravity", name: "Antigravity", command: "agy"),
        .init(id: "qwen", name: "Qwen Code", command: "qwen"),
        .init(id: "kimi", name: "Kimi", command: "kimi"),
        .init(id: "kilo", name: "Kilo Code", command: "kilo"),
        .init(id: "crush", name: "Crush", command: "crush"),
        .init(id: "droid", name: "Droid", command: "droid"),
        .init(id: "copilot", name: "GitHub Copilot", command: "copilot"),
        .init(id: "aider", name: "Aider", command: "aider"),
        .init(id: "goose", name: "Goose", command: "goose"),
        .init(id: "auggie", name: "Augment", command: "auggie"),
        .init(id: "kiro", name: "Kiro", command: "kiro-cli")
    ]

    /// Presets overridden/extended by `*.json` files in `dir`. Bad files are skipped, never fatal.
    public static func load(dir: URL) -> [AgentManifest] {
        var all = Dictionary(uniqueKeysWithValues: presets.map { ($0.id, withInstall($0)) })
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            if let d = try? Data(contentsOf: f), let m = try? JSONDecoder().decode(AgentManifest.self, from: d) { all[m.id] = withInstall(m) }
        }
        return all.values.sorted { $0.name < $1.name }
    }

    /// Settings UI: save an override (binary, args, env…) or reset to the preset by deleting it.
    public static func saveOverride(_ m: AgentManifest, dir: URL) throws {
        try Paths.ensure(dir)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(m).write(to: dir.appendingPathComponent("\(m.id).json"))
    }
    public static func resetOverride(id: String, dir: URL) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).json"))
    }

    /// A "custom command" agent: any shell command.
    public static func custom(_ command: String) -> AgentManifest {
        .init(id: "custom", name: "Custom", command: "/bin/zsh", args: ["-lc", command])
    }
}

public enum Hooks {
    /// Claude-style settings file: Stop → done, Notification → waiting (`kelp hook` drops the idle reminder),
    /// AskUserQuestion → waiting until answered. `kelp` must be on PATH in the session.
    public static func settingsJSON() -> String {
        func hook(_ ev: String, _ matcher: String? = nil) -> String {
            #"[{\#(matcher.map { #""matcher":"\#($0)","# } ?? "")"hooks":[{"type":"command","command":"kelp hook \#(ev)"}]}]"#
        }
        return #"{"hooks":{"Stop":\#(hook("done")),"Notification":\#(hook("waiting")),"UserPromptSubmit":\#(hook("working")),"#
            + #""PreToolUse":\#(hook("waiting", "AskUserQuestion")),"PostToolUse":\#(hook("working", "AskUserQuestion")),"#
            + #""PreCompact":\#(hook("compacting")),"SessionStart":\#(hook("compacted", "compact"))}}"#
    }

    /// Claude Code repeats "waiting for your input" a minute after a turn ends; that's a finished agent, not a question.
    public static func isIdleReminder(_ payload: JSONValue) -> Bool {
        payload["notification_type"]?.string == "idle_prompt"
            || payload["message"]?.string?.hasPrefix("Claude is waiting for your input") == true
    }

    /// Stop with subagents or a workflow still running: the turn is paused until they wake it, not done.
    /// Background shells and monitors don't count (a dev server never finishes).
    public static func hasBackgroundWork(_ payload: JSONValue) -> Bool {
        payload["background_tasks"]?.array?.contains { !["shell", "monitor"].contains($0["type"]?.string ?? "") } == true
    }

    public static func writeSettings(to url: URL) throws {
        try Paths.ensure(url.deletingLastPathComponent())
        try settingsJSON().write(to: url, atomically: true, encoding: .utf8)
    }
}
