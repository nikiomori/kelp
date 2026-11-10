import Core
import Foundation

/// Folders an agent already trusts, read from its own config (never written). Kelp answers an agent's "trust this
/// folder?" itself only inside them; anywhere else the question is the user's, as the agent intends (a repository's own
/// agent settings can run hooks and servers the moment it's trusted).
public enum AgentTrust {
    /// Whether `agent` trusts any of `folders` (or a folder above one). `env` is the session's: an account profile can point
    /// the agent at a config of its own (CLAUDE_CONFIG_DIR, CODEX_HOME).
    public static func trusts(
        agent: String, folders: [String], env: [String: String] = [:], home: String = NSHomeDirectory()
    ) -> Bool {
        let trusted = trustedFolders(agent: agent, env: env, home: home)
        return folders.contains { folder in trusted.contains { !$0.isEmpty && Paths.inside(folder, $0) } }
    }

    public static func trustedFolders(agent: String, env: [String: String], home: String) -> [String] {
        switch agent {
        case "claude": claude(env["CLAUDE_CONFIG_DIR"].map { $0 + "/.claude.json" } ?? home + "/.claude.json")
        case "codex": codex((env["CODEX_HOME"] ?? home + "/.codex") + "/config.toml")
        case "gemini": gemini(home + "/.gemini/trustedFolders.json")
        case "kimi": kimi(env["KIMI_CODE_HOME"] ?? home + "/.kimi-code")
        default: []   // no way to read its trust: Kelp doesn't answer for it
        }
    }

    /// `projects[path].hasTrustDialogAccepted`.
    static func claude(_ file: String) -> [String] {
        guard let projects = json(file)?["projects"] as? [String: Any] else { return [] }
        return projects.compactMap { path, v in
            (v as? [String: Any])?["hasTrustDialogAccepted"] as? Bool == true ? path : nil
        }
    }

    /// `[projects."<path>"]` sections with `trust_level = "trusted"`.
    static func codex(_ file: String) -> [String] {
        guard let text = String(contentsIfAny: URL(fileURLWithPath: file)) else { return [] }
        var out: [String] = [], section: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                section =
                    line.hasPrefix("[projects.\"") && line.hasSuffix("\"]")
                    ? String(line.dropFirst(11).dropLast(2)) : nil
            } else if let project = section, line.replacingOccurrences(of: " ", with: "") == "trust_level=\"trusted\"" {
                out.append(project)
            }
        }
        return out
    }

    /// `{"<path>": "TRUST_FOLDER" | "TRUST_PARENT" | "DO_NOT_TRUST"}`; a trusted parent covers the folders in it.
    static func gemini(_ file: String) -> [String] {
        guard let levels = json(file) as? [String: String] else { return [] }
        return levels.compactMap { path, level in
            level == "TRUST_FOLDER"
                ? path : level == "TRUST_PARENT" ? (path as NSString).deletingLastPathComponent : nil
        }
    }

    /// One JSON file per workspace under `workspace-trust/`: `{"root":"/path","trustedAt":…}`.
    static func kimi(_ home: String) -> [String] {
        let dir = home + "/workspace-trust"
        return (FileManager.default.enumerator(atPath: dir)?.allObjects as? [String] ?? []).compactMap {
            json(dir + "/" + $0)?["root"] as? String
        }
    }

    private static func json(_ file: String) -> [String: Any]? {
        FileManager.default.contents(atPath: file).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
    }
}
