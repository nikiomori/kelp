import Foundation

/// Where each agent keeps its own files, as its own environment moves them: the one place that knows (usage logs,
/// conversations, trusted folders, account profiles). Read only; Kelp never writes there.
public enum AgentHome {
    /// By agent id: the variable that moves its folder, the folder under the home dir without it, and the folder inside.
    private static let known: [String: (variable: String?, fallback: String, inside: String)] = [
        "claude": ("CLAUDE_CONFIG_DIR", ".claude", ""), "codex": ("CODEX_HOME", ".codex", ""),
        "grok": ("GROK_HOME", ".grok", ""), "kimi": ("KIMI_CODE_HOME", ".kimi-code", ""),
        "pi": ("PI_CODING_AGENT_DIR", ".pi/agent", ""), "omp": ("PI_CODING_AGENT_DIR", ".omp/agent", ""),
        "qwen": ("QWEN_HOME", ".qwen", ""), "copilot": ("COPILOT_HOME", ".copilot", ""),
        // GEMINI_CLI_HOME stands in for the home dir, which holds .gemini.
        "gemini": ("GEMINI_CLI_HOME", "", ".gemini"), "antigravity": (nil, "", ".gemini/antigravity-cli")
    ]

    /// `agent`'s folder under `env` (the session's or this process's); nil for an agent Kelp doesn't know the folder of.
    public static func dir(
        _ agent: String, env: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> URL? {
        guard let entry = known[agent] else { return nil }
        let base = entry.variable.flatMap { env[$0] } ?? (home as NSString).appendingPathComponent(entry.fallback)
        let url = URL(fileURLWithPath: base)
        return entry.inside.isEmpty ? url : url.appendingPathComponent(entry.inside)
    }

    /// `dir` of an agent Kelp knows, under this process's environment.
    public static func root(_ agent: String) -> URL {
        dir(agent) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("." + agent)
    }

    /// The variable that points `agent` at a folder of its own: an account profile sets it.
    public static func variable(_ agent: String) -> String? { known[agent]?.variable }
}
