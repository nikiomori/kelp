import Core
import Foundation

/// Kelp's hooks for Codex, passed on its command line: `-c hooks.<Event>=…` for each hook, then `-c hooks.state={…}`
/// to trust exactly those hooks. Codex runs a hook it wasn't told to trust only after the user trusts it in `/hooks`,
/// and asks about it at start. Codex reads that trust from session flags just as it does from ~/.codex/config.toml
/// (codex-rs `hook_states_from_stack`), so nothing is written there. The trust names each hook's own hash, so a
/// project's or another tool's hooks gain nothing from it.
/// The hash is computed the way Codex does it: the sha256 of the hook's JSON with sorted keys (`hook_hash`,
/// `version_for_toml`). Codex could change that, so the daemon checks once per Codex binary that Codex agrees
/// (`hooks/list`) before passing these flags.
public enum CodexHooks {
    /// A hook: the event, its key label, the command Kelp runs, and the tools it's for (nil for every tool, or for an
    /// event that isn't a tool's).
    public typealias Event = (name: String, label: String, command: String, matcher: String?)

    /// The permission hook only reports. Codex shows its menu after the hook returns (Claude Code shows it while the
    /// hook runs), so Kelp's Allow goes to that menu, not to the hook. A tool's end is reported only for the tools Kelp
    /// acts on (`Hooks.endsActedOn`).
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

    /// The hooks for a remote project's host, in tmux, where there's no `kelp`. Each reports its state the way Claude
    /// Code's hooks do there (`Hooks.hostReport`), and Kelp reads that as the program's own report. There are fewer of
    /// them, because a state is all that a host's hook can tell.
    public static let hostEvents: [Event] = [
        ("UserPromptSubmit", "user_prompt_submit", hostTurn("UserPromptSubmit", "working"), nil),
        ("PostToolUse", "post_tool_use", Hooks.hostReport("state=working"), nil),
        (
            "PermissionRequest", "permission_request", Hooks.hostReport("state=blocked:kind=permission", payload: true),
            nil
        ),
        ("Stop", "stop", hostTurn("Stop", "done"), nil)
    ]

    /// In 0.171 a child's session_id is the root's and agent_id is its own. 0.133 omits agent_id;
    /// 0.129 also uses the child's own session_id. The rollout's session_meta identifies user threads in all three.
    /// Both hook inputs are flat, compact JSON; quotes in the prompt and reply are escaped.
    private static func hostTurn(_ event: String, _ state: String) -> String {
        Hooks.hostStart + #"p=$(cat);case "$p" in \{*\}) ;; *) exit 0;; esac;"#
            + #"case "$p" in *\"agent_id\":*|*\"agent_type\":*) exit 0;; esac;"#
            + Hooks.hostField + #"[ "$(f hook_event_name)" = \#(event) ] || exit 0;"#
            + #"id=$(f session_id);printf %s "$id" | LC_ALL=C grep -Eq "^[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}$" || exit 0;"#
            + #"t=$(printf %s "$p" | sed -nE 's/.*"transcript_path": *"(([^"\\]|\\.)*)".*/\1/p' | sed -E 's/\\(["\\/])/\1/g');"#
            + #"r=state=\#(state);case "$t" in /*/rollout-*-"$id".jsonl) "#
            + #"m=;[ -f "$t" ] && m=$(head -n 1 -- "$t" 2>/dev/null);"#
            + #"case ${m#*\"source\":} in \{\"subagent\":*|\{\"internal\":*) exit 0;; "#
            + #"\"cli\"*|\"vscode\"*|\"exec\"*|\"mcp\"*|\{\"custom\":*) "#
            + #"case "$m" in *\"type\":\"session_meta\"*) case ${m#*\"id\":} in \"$id\"*) r=$r:conv=$id;; esac;; esac;; esac;; "#
            + #"/*/rollout-*.jsonl) exit 0;; esac;tmux set-option -q \#(RemoteHost.statusOption) "$r";"#
            + Hooks.hostSend
    }

    /// Codex's name for a hook given on the command line (`<session-flags>`, first group, first handler).
    public static func key(_ label: String) -> String { "/<session-flags>/config.toml:\(label):0:0" }

    /// Returns the hash that Codex keeps as trusted for a hook. It hashes the handler as Codex fills it in (not async,
    /// with the ten-minute timeout).
    public static func hash(label: String, command: String, matcher: String? = nil) -> String {
        // This is Codex's JSON, with keys in order, and nothing escaped that serde_json leaves as it is.
        let json =
            #"{"event_name":"# + ShellQuote.doubleQuoted(label) + #","hooks":[{"async":false,"command":"#
            + ShellQuote.doubleQuoted(command) + #","timeout":600,"type":"command"}]"#
            + (matcher.map { #","matcher":"# + ShellQuote.doubleQuoted($0) } ?? "") + "}"
        return "sha256:" + Data(json.utf8).sha256
    }

    /// The `-c` pairs: one for each hook, then one that trusts them.
    public static var args: [String] { args(events) }
    public static var hostArgs: [String] { args(hostEvents) }

    public static func args(_ events: [Event]) -> [String] {
        let hooks = events.flatMap { event in
            let command = ShellQuote.doubleQuoted(event.command)
            let matcher = event.matcher.map { "matcher=\(ShellQuote.doubleQuoted($0))," } ?? ""
            return ["-c", "hooks.\(event.name)=[{\(matcher)hooks=[{type=\"command\",command=\(command)}]}]"]
        }
        // The trust goes in one table, because `-c` splits a dotted key at every "." and the keys contain
        // "config.toml".
        let state = events.map { event in
            let trusted = ShellQuote.doubleQuoted(
                hash(label: event.label, command: event.command, matcher: event.matcher))
            return "\(ShellQuote.doubleQuoted(key(event.label)))={trusted_hash=\(trusted)}"
        }
        return hooks + ["-c", "hooks.state={" + state.joined(separator: ",") + "}"]
    }
}
