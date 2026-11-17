import Core
import Foundation

/// Kelp's hooks for Codex, passed on its command line: `-c hooks.<Event>=…` for each hook, then `-c hooks.state={…}`
/// trusting exactly those. Codex runs a hook it wasn't told to trust only after the user trusts it in `/hooks`, and
/// asks about it at start. It reads that trust from session flags just as from ~/.codex/config.toml (codex-rs
/// `hook_states_from_stack`), so nothing is written there. The trust is each hook's own hash, so a project's or another
/// tool's hooks gain nothing from it.
/// The hash is Codex's: the sha256 of the hook's JSON with sorted keys (`hook_hash`, `version_for_toml`). Codex could
/// change it, so the daemon checks once per Codex binary that Codex agrees (`hooks/list`) before passing these.
public enum CodexHooks {
    /// Event, its key label, what Kelp hears, and the tools it's for (nil: every one, or no tool's event).
    public typealias Event = (name: String, label: String, command: String, matcher: String?)

    /// The permission hook only tells: Codex shows its menu after the hook returns (Claude Code shows it meanwhile), so
    /// Kelp's Allow goes to that menu, not to the hook. A tool's end only for the tools Kelp acts on (`Hooks.endsActedOn`).
    public static let events: [Event] = [
        ("UserPromptSubmit", "user_prompt_submit", "kelp hook working", nil),
        ("PermissionRequest", "permission_request", "kelp hook waiting --no-answer", nil),
        ("PreToolUse", "pre_tool_use", "kelp hook command", nil),
        ("PostToolUse", "post_tool_use", "kelp hook command", Hooks.endsActedOn),
        ("SubagentStart", "subagent_start", "kelp hook subagent", nil),
        ("SubagentStop", "subagent_stop", "kelp hook subagent", nil),
        ("PreCompact", "pre_compact", "kelp hook compacting", nil),
        ("PostCompact", "post_compact", "kelp hook compacted", nil),
        ("Stop", "stop", "kelp hook done", nil)
    ]

    /// On a remote project's host, in tmux, where there's no `kelp`: each says its state as Claude Code's do there
    /// (`Hooks.hostReport`), which Kelp reads as the program's own report. Fewer: a state is all a host's hook tells.
    public static let hostEvents: [Event] = [
        ("UserPromptSubmit", "user_prompt_submit", Hooks.hostReport("state=working"), nil),
        ("PostToolUse", "post_tool_use", Hooks.hostReport("state=working"), nil),
        (
            "PermissionRequest", "permission_request", Hooks.hostReport("state=blocked:kind=permission", payload: true),
            nil
        ),
        ("Stop", "stop", Hooks.hostReport("state=done"), nil)
    ]

    /// Codex's name for a hook given on the command line (`<session-flags>`, first group, first handler).
    public static func key(_ label: String) -> String { "/<session-flags>/config.toml:\(label):0:0" }

    /// The hash Codex keeps as trusted for one of them: the handler as Codex fills it in (no async, the ten-minute timeout).
    public static func hash(label: String, command: String, matcher: String? = nil) -> String {
        // Codex's JSON, keys in order, nothing escaped that serde_json leaves as is.
        let json =
            #"{"event_name":"# + ShellQuote.doubleQuoted(label) + #","hooks":[{"async":false,"command":"#
            + ShellQuote.doubleQuoted(command) + #","timeout":600,"type":"command"}]"#
            + (matcher.map { #","matcher":"# + ShellQuote.doubleQuoted($0) } ?? "") + "}"
        return "sha256:" + Data(json.utf8).sha256
    }

    /// The `-c` pairs: each hook, then their trust.
    public static var args: [String] { args(events) }
    public static var hostArgs: [String] { args(hostEvents) }

    public static func args(_ events: [Event]) -> [String] {
        let hooks = events.flatMap { event in
            let command = ShellQuote.doubleQuoted(event.command)
            let matcher = event.matcher.map { "matcher=\(ShellQuote.doubleQuoted($0))," } ?? ""
            return ["-c", "hooks.\(event.name)=[{\(matcher)hooks=[{type=\"command\",command=\(command)}]}]"]
        }
        // One table: `-c` splits a dotted key at every ".", and the keys hold "config.toml".
        let state = events.map { event in
            let trusted = ShellQuote.doubleQuoted(
                hash(label: event.label, command: event.command, matcher: event.matcher))
            return "\(ShellQuote.doubleQuoted(key(event.label)))={trusted_hash=\(trusted)}"
        }
        return hooks + ["-c", "hooks.state={" + state.joined(separator: ",") + "}"]
    }
}
