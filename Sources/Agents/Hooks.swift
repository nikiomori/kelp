import Core
import Foundation

// Hooks: the settings and plugin that make an agent report its status to Kelp, and reading what a hook sends.

public enum Hooks {
    /// Claude-style settings file: Stop → done, Notification → waiting (`kelp hook` drops the ones that ask nothing),
    /// AskUserQuestion, an MCP server's question and a permission dialog → waiting until answered; each tool as it starts
    /// and ends and each batch of them (`command`: a Bash one for the list, `AgentCommand`, any for what it says of the turn,
    /// `State.tool`); each subagent as it starts and ends. `kelp` must be on PATH in the session.
    public static func settingsJSON() -> String {
        func entry(_ ev: String, _ matcher: String?) -> String {
            #"{\#(matcher.map { #""matcher":"\#($0)","# } ?? "")"hooks":[{"type":"command","command":"kelp hook \#(ev)"}]}"#
        }
        func hook(_ ev: String, _ matcher: String? = nil) -> String { "[\(entry(ev, matcher))]" }
        // It waits for Kelp's Allow or Deny (`session.permissionWait`), up to ten minutes; Claude's menu shows meanwhile.
        let permission = #"[{"hooks":[{"type":"command","command":"kelp hook waiting","timeout":610}]}]"#
        let command = entry("command", nil)
        return
            #"{"hooks":{"Stop":\#(hook("done")),"Notification":\#(hook("waiting")),"UserPromptSubmit":\#(hook("working")),"StopFailure":\#(hook("done")),"#
            + #""PreToolUse":[\#(entry("waiting", "AskUserQuestion")),\#(command)],"PostToolUse":[\#(entry("working", "AskUserQuestion")),\#(command)],"#
            + #""PostToolUseFailure":[\#(command)],"PostToolBatch":[\#(command)],"PermissionRequest":\#(permission),"#
            + #""Elicitation":\#(hook("waiting")),"ElicitationResult":\#(hook("working")),"#
            + #""SubagentStart":\#(hook("subagent")),"SubagentStop":\#(hook("subagent")),"#
            + #""PreCompact":\#(hook("compacting")),"SessionStart":\#(hook("compacted", "compact"))}}"#
    }

    /// A hook's command on a host (`hostSettingsJSON`, `CodexHooks.hostEvents`): the report into the tmux session's
    /// option and, through tmux, to the agent's tty. `unless`: shell that ends it first when the report doesn't hold.
    public static func hostReport(_ report: String, unless: String = "") -> String {
        hostStart + unless + "r='\(report)';tmux set-option -q \(RemoteHost.statusOption) \"$r\";" + hostSend
    }
    static let hostStart = #"[ -n "$TMUX" ]||exit 0;"#
    static let hostSend = #"printf '\033Ptmux;\033\033]7501;%s\007\033\\' "$r">/dev/$(ps -o tty= -p $PPID|tr -d ' ')"#

    /// Claude-style settings for an agent in tmux on a remote project's host, passed on its command line. There's no `kelp`
    /// there, and tmux swallows the OSC 7501 an agent writes, so each hook writes the report itself, wrapped so that tmux
    /// lets it through, to the tty of the agent that ran it (a hook has none of its own). A report also stays in a tmux
    /// option, for whichever connection comes next (`RemoteHost.command(_:inTmux:)`). A subagent's goes on a line of its
    /// own: `agent_type` as its title, the one thing the hook knows of it. A Stop with work that wakes the agent still going
    /// isn't the end of the turn (`TurnEnd`), and JSON escapes a reply's own quotes, so one quoting these can't pass for it.
    /// Out of tmux they do nothing: there the agent answers the terminal's probe and reports for itself.
    public static func hostSettingsJSON() throws -> String {
        func agent(_ report: String, unless: String = "") -> JSONValue { hook(hostReport(report, unless: unless)) }
        func subagent(_ report: String) -> JSONValue {
            hook(
                hostStart + #"p=$(cat);f(){ printf %s "$p"|sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p";};r=\#(report);"#
                    + hostSend)
        }
        func hook(_ command: String) -> JSONValue {
            .array([.object(["hooks": .array([.object(["type": "command", "command": .string(command)])])])])
        }
        func only(_ tool: String, _ entry: JSONValue) -> JSONValue {
            guard case .object(var first)? = entry.array?.first else { return entry }
            first["matcher"] = .string(tool)
            return .array([.object(first)])
        }
        let hooks: [String: JSONValue] = [
            "UserPromptSubmit": agent("state=working"), "PostToolUse": agent("state=working"),
            "ElicitationResult": agent("state=working"),
            "Stop": agent(
                "state=done",
                unless:
                    #"p=$(tr -d ' ');case "$p" in *'"type":"subagent"'*|*'"type":"workflow"'*|*'"type":"teammate"'*)exit;;esac;"#
            ),
            "StopFailure": agent("state=error"), "PermissionRequest": agent("state=blocked:kind=permission"),
            "PreToolUse": only("AskUserQuestion", agent("state=blocked:kind=question")),
            "Elicitation": agent("state=blocked:kind=question"),
            "SubagentStart": subagent(
                #""state=working:id=$(f agent_id):title=$(printf %s "$(f agent_type)"|base64|tr -d '\n')""#),
            "SubagentStop": subagent(#""state=clear:id=$(f agent_id)""#)
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(JSONValue.object(["hooks": .object(hooks)])), as: UTF8.self)
    }

    /// Notifications that ask the user nothing, by Claude Code's `notification_type`: the "waiting for your input" it repeats a
    /// minute after a turn ends (Qwen Code too), a login that went through, a background agent that finished, a push Claude
    /// sent, computer use starting or ending, a resume after a plan limit, a refusal fallback, a keychain that failed, a
    /// plugin's, an MCP server's question that was answered or declined. Any other type (or none) is a permission or a
    /// question.
    static let informational: Set<String> = [
        "idle_prompt", "auth_success", "agent_completed", "push_notification", "computer_use_enter",
        "computer_use_exit",
        "quota_auto_resume_fired", "quota_auto_resume_stale", "quota_auto_resume_disabled", "model_refusal_fallback",
        "auth_storage_failure", "plugin_notification", "elicitation_complete", "elicitation_response"
    ]
    public static func isInformational(_ payload: JSONValue) -> Bool {
        payload["notification_type"]?.string.map(informational.contains) == true || atPrompt(payload)
    }

    /// The agent says it has been sitting at its prompt.
    public static func atPrompt(_ payload: JSONValue) -> Bool {
        payload["notification_type"]?.string == "idle_prompt"
            || payload["message"]?.string?.hasPrefix("Claude is waiting for your input") == true
    }

    /// What a StopFailure says ended the turn (an overloaded API, a login gone): the row's error, unless it's a plan limit.
    public static func failure(_ payload: JSONValue) -> String? {
        payload["notification_type"]?.string == "stop_failure" ? payload["message"]?.string ?? "" : nil
    }

    /// A StopFailure that passes by itself: the API overloaded or failing, a dropped connection. Not a login, a bill or a
    /// request the API refused, which a "continue" only repeats. The agent has already retried for a while by then.
    public static func passes(_ payload: JSONValue) -> Bool {
        guard payload["notification_type"]?.string == "stop_failure" else { return false }
        switch payload["error"]?.string {
        case "overloaded", "server_error", "rate_limit": return true
        case "unknown":
            let text = payload["message"]?.string?.lowercased() ?? ""
            return text.contains("connection") || text.contains("timed out")
        default: return false
        }
    }

    /// The plan limit a StopFailure says ended the turn. Only there: the same words in a reply or a file stop nothing.
    public static func limitHit(_ payload: JSONValue) -> ClaudeLimits.Reading? {
        guard payload["notification_type"]?.string == "stop_failure", let text = payload["message"]?.string else {
            return nil
        }
        return ClaudeLimits.parse(text).first { $0.percent >= 100 }
    }

    /// Kilo Code / OpenCode plugin (`HookTransport.pluginDir`): busy → working, a permission or question → waiting, idle → done.
    /// A subagent's session (one with a parent) idles before the turn ends: skipped. Hooks run one after another, so they
    /// arrive in order.
    public static let pluginJS = """
        // Kelp's status hooks, for Kelp's sessions only (written by Kelp; changes are overwritten).
        import { spawn } from "node:child_process";
        const children = new Set();
        let last, queue = Promise.resolve();
        const report = (state) => {
          if (!process.env.KELP_SESSION || state === last) return;
          last = state;
          queue = queue.then(() => new Promise((done) => {
            const c = spawn("kelp", ["hook", state], { stdio: "ignore" });
            c.on("exit", done); c.on("error", done);
          }));
        };
        export const KelpStatus = async () => ({
          event: async ({ event }) => {
            const p = event?.properties ?? {};
            if (p.info?.parentID) children.add(p.info.id);
            if (children.has(p.sessionID ?? p.info?.id)) return;
            switch (event?.type) {
              case "session.status":
                if (p.status?.type === "busy") report("working");
                if (p.status?.type === "idle") report("done");   // newer versions send only this
                break;
              case "permission.asked": case "question.asked": report("waiting"); break;
              case "permission.replied": case "question.replied": case "question.rejected": report("working"); break;
              case "session.idle": case "session.error": report("done"); break;
            }
          },
        });

        """

    /// The config dir for `HookTransport.pluginDir`, with the plugin in it.
    public static func writePlugin(dir: URL) throws {
        let plugins = dir.appendingPathComponent("plugin")
        try Paths.ensure(plugins)
        try pluginJS.write(to: plugins.appendingPathComponent("kelp.js"), atomically: true, encoding: .utf8)
    }

    public static func writeSettings(to url: URL) throws {
        try Paths.ensure(url.deletingLastPathComponent())
        try settingsJSON().write(to: url, atomically: true, encoding: .utf8)
    }

    /// Kelp's hooks over what `base` holds (kept as it is, its own hooks run too): the file stands in for that one.
    public static func writeSettings(to url: URL, over base: URL) throws {
        guard FileManager.default.fileExists(atPath: base.path) else { return try writeSettings(to: url) }
        // There but unreadable (root's only) or not plain JSON: standing in for it would drop an admin's policy. No hooks
        // then (the caller reads the screen).
        guard let data = FileManager.default.contents(atPath: base.path),
            case .object(var all)? = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: base.path])
        }
        guard
            case .object(let ours)? = try JSONDecoder().decode(JSONValue.self, from: Data(settingsJSON().utf8))["hooks"]
        else { return }
        var hooks: [String: JSONValue] = if case .object(let existing)? = all["hooks"] { existing } else { [:] }
        for (event, list) in ours { hooks[event] = .array((hooks[event]?.array ?? []) + (list.array ?? [])) }
        all["hooks"] = .object(hooks)
        try Paths.ensure(url.deletingLastPathComponent())
        try JSONEncoder().encode(JSONValue.object(all)).write(to: url, options: .atomic)
    }
}
