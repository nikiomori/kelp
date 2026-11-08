import CryptoKit
import Foundation

/// Kelp's hooks for Codex, on its command line: `-c hooks.<Event>=…` for each, then `-c hooks.state={…}` trusting exactly
/// those. Codex runs a hook it wasn't told to trust only after the user trusts it in `/hooks`, and asks about it at start;
/// it reads that trust from session flags as from ~/.codex/config.toml (codex-rs `hook_states_from_stack`), so nothing
/// is written there. The trust is each hook's own hash, so a project's or another tool's hooks gain nothing from it.
/// The hash is Codex's: sha256 of the hook's JSON with sorted keys (`hook_hash`, `version_for_toml`). Codex could change
/// it, so the daemon checks once per Codex binary that Codex agrees (`hooks/list`) before passing these.
public enum CodexHooks {
    /// Event, its key label, what Kelp hears. The permission hook only tells: Codex shows its menu after the hook
    /// returns (Claude Code shows it meanwhile), so Kelp's Allow goes to that menu, not to the hook.
    public static let events: [(name: String, label: String, command: String)] = [
        ("UserPromptSubmit", "user_prompt_submit", "kelp hook working"),
        ("PermissionRequest", "permission_request", "kelp hook waiting --no-answer"),
        ("PreToolUse", "pre_tool_use", "kelp hook command"),
        ("PostToolUse", "post_tool_use", "kelp hook command"),
        ("SubagentStart", "subagent_start", "kelp hook subagent"),
        ("SubagentStop", "subagent_stop", "kelp hook subagent"),
        ("PreCompact", "pre_compact", "kelp hook compacting"),
        ("PostCompact", "post_compact", "kelp hook compacted"),
        ("Stop", "stop", "kelp hook done")
    ]

    /// Codex's name for a hook given on the command line (`<session-flags>`, first group, first handler).
    public static func key(_ label: String) -> String { "/<session-flags>/config.toml:\(label):0:0" }

    /// The hash Codex keeps as trusted for one of them: the handler as Codex fills it in (no async, the ten-minute timeout).
    public static func hash(label: String, command: String) -> String {
        // Codex's JSON, keys in order, nothing escaped that serde_json leaves as is.
        let json =
            #"{"event_name":"# + quoted(label) + #","hooks":[{"async":false,"command":"# + quoted(command)
            + #","timeout":600,"type":"command"}]}"#
        return "sha256:" + SHA256.hash(data: Data(json.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The `-c` pairs: each hook, then their trust.
    public static var args: [String] {
        let hooks = events.flatMap { e in
            ["-c", "hooks.\(e.name)=[{hooks=[{type=\"command\",command=\(quoted(e.command))}]}]"]
        }
        // One table: `-c` splits a dotted key at every ".", and the keys hold "config.toml".
        let state = events.map {
            "\(quoted(key($0.label)))={trusted_hash=\(quoted(hash(label: $0.label, command: $0.command)))}"
        }
        return hooks + ["-c", "hooks.state={" + state.joined(separator: ",") + "}"]
    }

    /// A basic string, as both TOML and JSON write one (these commands hold no control characters).
    public static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
