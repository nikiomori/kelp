import Foundation

extension AgentManifest {
    /// Ways to run them through another provider, as environment variables their docs define.
    static let claudeProviders: [Provider] = [
        .init("Anthropic API Key", ["ANTHROPIC_API_KEY="]),
        .init("Amazon Bedrock", ["CLAUDE_CODE_USE_BEDROCK=1", "AWS_REGION=us-east-1", "AWS_PROFILE=default"]),
        .init(
            "Google Vertex AI", ["CLAUDE_CODE_USE_VERTEX=1", "CLOUD_ML_REGION=us-east5", "ANTHROPIC_VERTEX_PROJECT_ID="]
        ),
        .init("Gateway (LiteLLM, Ollama…)", ["ANTHROPIC_BASE_URL=http://localhost:4000", "ANTHROPIC_AUTH_TOKEN="])
    ]
    static let codexProviders: [Provider] = [
        .init("OpenAI API Key", ["OPENAI_API_KEY="]),
        .init(
            "OpenAI-compatible Endpoint (OpenRouter…)",
            ["OPENAI_BASE_URL=https://openrouter.ai/api/v1", "OPENAI_API_KEY="])
    ]
    static let geminiProviders: [Provider] = [
        .init("Gemini API Key", ["GEMINI_API_KEY="]),
        .init(
            "Google Vertex AI",
            ["GOOGLE_GENAI_USE_VERTEXAI=true", "GOOGLE_CLOUD_PROJECT=", "GOOGLE_CLOUD_LOCATION=us-central1"])
    ]

    /// The agents Kelp knows, as their own docs give them: how each starts, resumes, reports and installs (its npm package
    /// says what's newest).
    public static let presets: [AgentManifest] = [
        .init(
            id: "claude", name: "Claude Code", command: "claude", hooks: .settingsFlag("--settings"),
            modelFlag: "--model", models: ["opus", "sonnet", "haiku"],
            autoAnswers: [trust], resumeArgs: ["--continue"], pluginDirFlag: "--plugin-dir",
            contextFlag: "--append-system-prompt",
            sessionIdFlag: "--session-id", resumeIdFlag: "--resume",
            install: "curl -fsSL https://claude.ai/install.sh | bash", update: "claude update",
            npm: "@anthropic-ai/claude-code", about: "Anthropic’s coding agent", color: "#D97857", apps: ["Claude"],
            site: "claude.ai", featured: 0, transcript: .claude, profiles: true, providers: claudeProviders),
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
            autoAnswers: [trust], resumeArgs: ["resume", "--last"],
            install: "npm install -g @openai/codex", update: "npm install -g @openai/codex@latest",
            npm: "@openai/codex", about: "OpenAI’s coding agent", color: "#262626", apps: ["ChatGPT", "Codex"],
            site: "chatgpt.com", featured: 1, transcript: .codex, profiles: true, providers: codexProviders),
        .init(
            id: "opencode", name: "OpenCode", command: "opencode", hooks: .pluginDir(env: "OPENCODE_CONFIG_DIR"),
            modelFlag: "-m",
            resumeArgs: ["--continue"],
            install: "curl -fsSL https://opencode.ai/install | bash", update: "opencode upgrade", npm: "opencode-ai",
            about: "Open source, works with any model provider", site: "opencode.ai", featured: 3),
        .init(
            id: "gemini", name: "Gemini CLI", command: "gemini", modelFlag: "-m",
            models: ["gemini-2.5-pro", "gemini-2.5-flash"], autoAnswers: [trust],
            install: "npm install -g @google/gemini-cli", update: "npm install -g @google/gemini-cli@latest",
            npm: "@google/gemini-cli", about: "Retired by Google in June 2026: Antigravity takes its place",
            color: "#007AFF", site: "gemini.google.com", providers: geminiProviders),
        .init(
            id: "cursor", name: "Cursor Agent", command: "cursor-agent", modelFlag: "--model", autoAnswers: [trust],
            resumeArgs: ["resume"],
            install: "curl https://cursor.com/install -fsS | bash", update: "cursor-agent update",
            about: "Cursor’s agent in the terminal", color: "#262626", apps: ["Cursor"], site: "cursor.com", featured: 4
        ),
        // Pi and Antigravity report through OSC 7501 only if Kelp's reply to their probe beats the terminal's DA reply;
        // their variables make them report anyway. Pi's installer runs again as the update; it fetches Node when it's
        // missing, which npm wouldn't.
        .init(
            id: "pi", name: "Pi", command: "pi", env: ["PI_PROGRAM_STATUS": "1"], modelFlag: "--model",
            resumeArgs: ["--continue"], resumeIdFlag: "--session",
            install: "curl -fsSL https://pi.dev/install.sh | sh", update: "curl -fsSL https://pi.dev/install.sh | sh",
            npm: "@earendil-works/pi-coding-agent", about: "A minimal, extensible terminal agent, any model",
            site: "pi.dev", transcript: .pi),
        .init(
            id: "amp", name: "Amp", command: "amp",
            install: "npm install -g @sourcegraph/amp", update: "npm install -g @sourcegraph/amp@latest",
            npm: "@sourcegraph/amp", about: "Sourcegraph’s agent", site: "ampcode.com"),
        // A hand-off opens a session file (`--session` / `--resume <file>`): a wake goes on in it, not in "latest here".
        .init(
            id: "omp", name: "oh-my-pi", command: "omp", modelFlag: "--model", resumeArgs: ["--continue"],
            resumeIdFlag: "--resume",
            install: "curl -fsSL https://omp.sh/install | sh", update: "omp update", npm: "@oh-my-pi/pi-coding-agent",
            about: "Pi with an IDE’s tools wired in, any model", site: "omp.sh", transcript: .pi),
        .init(
            id: "fx", name: "fx", command: "fx", hooks: .herdr, modelFlag: "--model", resumeArgs: ["--continue"],
            install: "curl -fsSL https://fx.sh/setup.sh | bash", update: "fx upgrade",
            about: "Vercel’s small native agent, any model", site: "fx.sh"),
        // Others people run; Kelp offers whichever of these actually work on this Mac (AgentAvailability).
        // Grok's installer runs again as the update.
        .init(
            id: "grok", name: "Grok", command: "grok", modelFlag: "--model", resumeArgs: ["--continue"],
            install: "curl -fsSL https://x.ai/cli/install.sh | bash",
            update: "curl -fsSL https://x.ai/cli/install.sh | bash", about: "xAI’s coding agent", color: "#262626",
            apps: ["Grok"], site: "grok.com"),
        .init(
            id: "antigravity", name: "Antigravity", command: "agy", env: ["AGY_CLI_OSC7501": "on"],
            modelFlag: "--model",
            effortArgs: Dictionary(uniqueKeysWithValues: ["low", "medium", "high"].map { ($0, ["--effort", $0]) }),
            resumeArgs: ["--continue"],
            install: "curl -fsSL https://antigravity.google/cli/install.sh | bash",
            about: "Google’s Antigravity agent in the terminal", apps: ["Antigravity"], site: "antigravity.google",
            featured: 2),   // updates itself while it runs
        .init(
            id: "qwen", name: "Qwen Code", command: "qwen",
            hooks: .settingsFile(
                env: "QWEN_CODE_SYSTEM_SETTINGS_PATH", replaces: "/Library/Application Support/QwenCode/settings.json"),
            modelFlag: "--model", resumeArgs: ["--continue"],
            install: "npm install -g @qwen-code/qwen-code", update: "npm install -g @qwen-code/qwen-code@latest",
            npm: "@qwen-code/qwen-code", about: "Alibaba’s open source agent", site: "qwen.ai"),
        .init(
            id: "kimi", name: "Kimi", command: "kimi", modelFlag: "--model",
            autoAnswers: [trust], resumeArgs: ["--continue"],
            install: "curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash", update: "kimi upgrade",
            about: "Moonshot AI’s coding agent", apps: ["Kimi"], site: "kimi.com"),
        .init(
            id: "kilo", name: "Kilo Code", command: "kilo", hooks: .pluginDir(env: "KILO_CONFIG_DIR"),
            modelFlag: "--model",
            resumeArgs: ["--continue"],
            install: "npm install -g @kilocode/cli", update: "kilo upgrade", npm: "@kilocode/cli",
            about: "Open source agent, any model provider", site: "kilo.ai"),
        .init(
            id: "crush", name: "Crush", command: "crush", resumeArgs: ["--continue"],
            install: "brew install charmbracelet/tap/crush", update: "brew upgrade crush",
            about: "Charm’s open source agent, any model", site: "charm.land"),
        .init(
            id: "droid", name: "Droid", command: "droid", hooks: .settingsFlag("--settings"),
            resumeArgs: ["--resume", "--last"],
            install: "curl -fsSL https://app.factory.ai/cli | sh", about: "Factory’s agent", apps: ["Factory"],
            site: "factory.ai"),
        .init(
            id: "hermes", name: "Hermes", command: "hermes",
            install: "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash", update: "hermes update",
            about: "Nous Research’s self-improving agent", color: "#408CD9", site: "hermes-agent.nousresearch.com"),
        .init(
            id: "copilot", name: "GitHub Copilot", command: "copilot", modelFlag: "--model", resumeArgs: ["--continue"],
            install: "npm install -g @github/copilot", update: "npm install -g @github/copilot@latest",
            npm: "@github/copilot", about: "GitHub Copilot in the terminal", site: "github.com"),
        .init(
            id: "aider", name: "Aider", command: "aider",
            install: "python3 -m pip install aider-install && aider-install",
            about: "Pair programming in git, any model", site: "aider.chat"),
        // CONFIGURE=false: no provider questions in the installer's tab; goose asks on its first run.
        .init(
            id: "goose", name: "Goose", command: "goose",
            install:
                "curl -fsSL https://github.com/aaif-goose/goose/releases/download/stable/download_cli.sh | CONFIGURE=false bash",
            update: "goose update", about: "Open source, extensible agent, any model"),
        .init(
            id: "auggie", name: "Augment", command: "auggie",
            install: "npm install -g @augmentcode/auggie", update: "npm install -g @augmentcode/auggie@latest",
            npm: "@augmentcode/auggie", about: "Augment Code’s agent", site: "augmentcode.com"),
        .init(
            id: "kiro", name: "Kiro", command: "kiro-cli",
            install: "curl -fsSL https://cli.kiro.dev/install | bash", update: "kiro-cli update",
            about: "AWS’s agent in the terminal", apps: ["Kiro"], site: "kiro.dev")
    ]
}
