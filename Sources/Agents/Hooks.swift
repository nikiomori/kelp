import Core
import Foundation

// Hooks are the settings and plugin that make an agent report its status to Kelp. This file also reads what a hook
// sends.

public enum Hooks {
    /// One of Claude Code's hooks that Kelp listens to. `here` is what `kelp hook` reports for it in a local session,
    /// and `host` is the command it runs in tmux on a remote project's host. Either is nil where that side doesn't
    /// listen. `wait` is how long the agent waits for the hook locally.
    struct Listen {
        let hook: String, matcher: String?, here: String?, host: String?, wait: Int?
        init(hook: String, matcher: String? = nil, here: String?, host: String? = nil, wait: Int? = nil) {
            self.hook = hook
            self.matcher = matcher
            self.here = here
            self.host = host
            self.wait = wait
        }
    }

    /// The hooks Kelp listens to. In a local session, Stop means done, and Notification means waiting (`kelp hook`
    /// drops the notifications that ask nothing). AskUserQuestion, an MCP server's question and a permission dialog
    /// mean waiting until answered (by Kelp's Allow or Deny, `session.permissionWait`, for up to ten minutes). Kelp
    /// also hears each tool as it starts, the end of the tools it acts on (`endsActedOn`), and each batch of tools.
    /// These go to `command`, which uses a Bash call for the command list (`AgentCommand`) and any tool for what it
    /// says of the turn (`State.tool`). Kelp also hears each subagent as it starts and ends, and each compaction.
    /// On a host, each hook writes its own report (`hostSettingsJSON`). The order matters, because within one hook the
    /// first entry that matches comes first.
    static let listens: [Listen] = [
        .init(hook: "Stop", here: "done", host: hostReport("state=done", unless: hostStopUnless, conv: true)),
        .init(hook: "Notification", here: "waiting"),
        .init(hook: "UserPromptSubmit", here: "working", host: hostReport("state=working", conv: true)),
        .init(hook: "StopFailure", here: "done", host: hostReport("state=error", payload: true)),
        .init(
            hook: "PreToolUse", matcher: "AskUserQuestion", here: "waiting",
            host: hostReport("state=blocked:kind=question", payload: true)),
        .init(hook: "PreToolUse", here: "command"),
        .init(hook: "PostToolUse", matcher: "AskUserQuestion", here: "working", host: hostReport("state=working")),
        .init(hook: "PostToolUse", matcher: endsActedOn, here: "command"),
        .init(hook: "PostToolUseFailure", matcher: commandTools, here: "command"),
        // A tool's end isn't the end of a dialog, because another tool in its batch may still be asking, or the tool
        // that ended was a subagent's.
        .init(hook: "PostToolBatch", here: "command", host: hostReport("state=working", unless: hostSubagentsOwn)),
        .init(
            hook: "PermissionRequest", here: "waiting",
            host: hostReport("state=blocked:kind=permission", payload: true),
            wait: 610),
        .init(hook: "Elicitation", here: "waiting", host: hostReport("state=blocked:kind=question")),
        .init(hook: "ElicitationResult", here: "working", host: hostReport("state=working")),
        .init(
            hook: "SubagentStart", here: "subagent",
            host: hostSubagent(
                #""state=working:id=$(f agent_id):title=$(printf %s "$(f agent_type)"|base64|tr -d '\n')""#)),
        .init(hook: "SubagentStop", here: "subagent", host: hostSubagent(#""state=clear:id=$(f agent_id)""#)),
        .init(hook: "PreCompact", here: "compacting"),
        .init(hook: "SessionStart", matcher: "compact", here: "compacted")
    ]

    /// The tools whose end `kelp hook command` acts on: a command, for the command list (`AgentCommand`: Bash, Droid's
    /// Execute); a changed file (`SessionHook.edited`); a published page (`Artifacts.published`); and a worktree
    /// entered or left (the hook's `cwd`). The end of any other tool (Read, Grep, WebFetch, a subagent's Task) told
    /// Kelp nothing it uses, and each one cost a shell and a `kelp` run. The pattern is anchored, because Claude Code
    /// treats a matcher with more than names and `|` as a regex.
    static let endsActedOn =
        "^(Bash|Execute|Edit|Write|MultiEdit|NotebookEdit|EnterWorktree|ExitWorktree)$|^mcp__.*("
        + Artifacts.publishers.joined(separator: "|") + ")$|^("
        + Artifacts.codexPublishers.keys.sorted().joined(separator: "|") + ")$"
    /// The end of a failed tool is read only for a command (`AgentCommand`).
    static let commandTools = "^(Bash|Execute)$"

    /// Returns a Claude-style settings file with the local side of `listens`. `kelp` must be on PATH in the session.
    public static func settingsJSON() throws -> String {
        try settings(listens.compactMap { l in l.here.map { (l, "kelp hook \($0)", l.wait) } })
    }

    /// Builds `{"hooks": {<hook>: [{"matcher", "hooks": [{"type": "command", "command", "timeout"}]}]}}`, in the order
    /// of `listens`.
    private static func settings(_ commands: [(Listen, String, Int?)]) throws -> String {
        var hooks: [String: JSONValue] = [:]
        for (listen, command, wait) in commands {
            var run: [String: JSONValue] = ["type": "command", "command": .string(command)]
            if let wait { run["timeout"] = .int(wait) }
            var entry: [String: JSONValue] = ["hooks": .array([.object(run)])]
            if let matcher = listen.matcher { entry["matcher"] = .string(matcher) }
            hooks[listen.hook] = .array((hooks[listen.hook]?.array ?? []) + [.object(entry)])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(JSONValue.object(["hooks": .object(hooks)])), as: UTF8.self)
    }

    /// Builds a hook's command on a host (`hostSettingsJSON`, `CodexHooks.hostEvents`). The command writes the report
    /// into the tmux session's option and, through tmux, to the agent's tty. `unless` is shell code that exits first
    /// when the report doesn't apply, and code that reads the payload keeps it in `p`. With `payload`, the hook's input
    /// goes along too (`hook=`, its JSON in base64), so Kelp can say what a dialog asks or why a turn failed, as a
    /// local hook does. When the input is too long for one report, only the tool and its file go. With `conv`, the
    /// report names the hook's conversation (`conv=`), which /clear or /resume changes.
    public static func hostReport(_ report: String, unless: String = "", payload: Bool = false, conv: Bool = false)
        -> String
    {
        guard payload || conv else {
            return hostStart + unless + "r='\(report)';tmux set-option -q \(RemoteHost.statusOption) \"$r\";" + hostSend
        }
        var script = hostStart + (unless.contains("p=$(") ? unless : unless + "p=$(cat);") + hostField
        var fields = report
        if payload {
            script +=
                #"h=$(printf %s "$p"|base64|tr -d '\n');[ ${#h} -le 2700 ]||h=$(printf '{"tool_name":"%s","tool_input":"#
                + #"{"file_path":"%s"}}' "$(f tool_name)" "$(f file_path)"|base64|tr -d '\n');"#
            fields += ":hook=$h"
        }
        if conv { fields += ":conv=$(f session_id)" }
        return script + "r=\"\(fields)\";tmux set-option -q \(RemoteHost.statusOption) \"$r\";" + hostSend
    }
    /// Defines `f key`, which prints a string field of the payload in `p`.
    static let hostField = #"f(){ printf %s "$p"|sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p";};"#
    static let hostStart = #"[ -n "$TMUX" ]||exit 0;"#
    static let hostSend = #"printf '\033Ptmux;\033\033]7501;%s\007\033\\' "$r">/dev/$(ps -o tty= -p $PPID|tr -d ' ')"#
    /// A Stop while work that will wake the agent is still going isn't the end of the turn (`TurnEnd`). JSON escapes
    /// the quotes in a reply, so a reply that quotes these patterns can't pass for them.
    static let hostStopUnless =
        #"p=$(tr -d ' ');case "$p" in *'"type":"subagent"'*|*'"type":"workflow"'*|*'"type":"teammate"'*)exit;;esac;"#
    /// A subagent's tools don't act for the main agent, so their hooks report nothing for it.
    static let hostSubagentsOwn = #"p=$(cat);case "$p" in *'"agent_id"'*)exit;;esac;"#

    /// Builds a subagent's report, which goes on a line of its own. Its title is `agent_type`, the one thing the hook
    /// knows about the subagent.
    static func hostSubagent(_ report: String) -> String {
        hostStart + "p=$(cat);" + hostField + "r=\(report);" + hostSend
    }

    /// Claude-style settings for an agent in tmux on a remote project's host, passed on its command line. They hold the
    /// host side of `listens`. There's no `kelp` on the host, and tmux swallows the OSC 7501 that an agent writes. So
    /// each hook writes the report itself, wrapped so that tmux lets it through, to the tty of the agent that ran it,
    /// because a hook has no tty of its own. A report also stays in a tmux option for whichever connection comes next
    /// (`RemoteHost.command(_:inTmux:)`). Outside tmux the hooks do nothing, because there the agent answers the
    /// terminal's probe and reports for itself.
    public static func hostSettingsJSON() throws -> String {
        try settings(listens.compactMap { l in l.host.map { (l, $0, nil) } })
    }

    /// The host's hooks for an agent in a project's dev container (`DevContainer`). There is no tmux there, so each
    /// hook writes its report straight to the agent's terminal, which `docker exec -t` passes through to Kelp. The hook
    /// finds the agent's tty in /proc, because a slim image may have no ps.
    public static func containerSettingsJSON() throws -> String {
        try settings(listens.compactMap { l in l.host.map { (l, inContainer($0), nil) } })
    }
    static func inContainer(_ host: String) -> String {
        host.replacingOccurrences(of: hostStart, with: "")
            .replacingOccurrences(of: "tmux set-option -q \(RemoteHost.statusOption) \"$r\";", with: "")
            .replacingOccurrences(of: hostSend, with: containerSend)
    }
    static let containerSend =
        #"t=$(readlink /proc/$PPID/fd/0 2>/dev/null)||t=/dev/$(ps -o tty= -p $PPID|tr -d ' ');"#
        + #"printf '\033]7501;%s\007' "$r">"$t""#

    /// Notifications that ask the user nothing, by Claude Code's `notification_type`. They are the "waiting for your
    /// input" that it repeats a minute after a turn ends (Qwen Code too), a login that went through, a background agent
    /// that finished, a push Claude sent, computer use starting or ending, a resume after a plan limit, a refusal
    /// fallback, a keychain that failed, a plugin's notification, and an MCP server's question that was answered or
    /// declined. Any other type, or none, is a permission or a question.
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

    /// Returns what a StopFailure says ended the turn (an overloaded API, a lost login). It becomes the row's error,
    /// unless it's a plan limit.
    public static func failure(_ payload: JSONValue) -> String? {
        payload["notification_type"]?.string == "stop_failure" ? payload["message"]?.string ?? "" : nil
    }

    /// Whether a StopFailure passes by itself: the API overloaded or failing, or a dropped connection. A login, a bill
    /// or a request the API refused doesn't pass, and a "continue" only repeats it. The agent has already retried for a
    /// while by then.
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

    /// Returns the plan limit that a StopFailure says ended the turn. Only a StopFailure counts, because the same words
    /// in a reply or a file stop nothing.
    public static func limitHit(_ payload: JSONValue) -> LimitScreens.Reading? {
        guard payload["notification_type"]?.string == "stop_failure", let text = payload["message"]?.string else {
            return nil
        }
        return LimitScreens.parse(text).first { $0.percent >= 100 }
    }

    /// The Kilo Code and OpenCode plugin (`HookTransport.pluginDir`): busy means working, a permission or a question
    /// means waiting, and idle means done. A subagent's session (one with a parent) goes idle before the turn ends, so
    /// it is skipped. The `kelp hook` runs happen one after another, so they arrive in order.
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
                if (p.status?.type === "offline") report("waiting");   // Kilo: no network, the person retries
                break;
              case "permission.asked": case "question.asked": report("waiting"); break;
              case "permission.replied": case "question.replied": case "question.rejected": report("working"); break;
              case "session.idle": case "session.error": report("done"); break;
            }
          },
        });

        """

    /// OpenCode 2's hooks, as a plugin of its terminal UI, because the UI's process belongs to the session. Its server
    /// may be shared by every terminal and started with the first terminal's environment. Only the session the terminal
    /// shows counts,
    /// because the server sends every terminal's events. A subagent's run ends before its parent's, so only the shown
    /// session's own start and end count, while a subagent's questions do count.
    public static let tuiPluginJS = """
        // Kelp's status hooks, for Kelp's sessions only (written by Kelp; changes are overwritten).
        import { spawn } from "node:child_process";
        let last, queue = Promise.resolve();
        const report = (state) => {
          if (state === last) return;
          last = state;
          queue = queue.then(() => new Promise((done) => {
            const c = spawn("kelp", ["hook", state], { stdio: "ignore" });
            c.on("exit", done); c.on("error", done);
          }));
        };
        export default {
          id: "kelp.status",
          setup(api) {
            if (!process.env.KELP_SESSION) return;
            return api.data.listen(({ details: event }) => {
              const route = api.ui.router.current(), d = event?.data ?? {};
              const id = event?.type === "form.created" ? d.form?.sessionID : d.sessionID;
              if (route?.type !== "session" || !id) return;
              const shown = api.data.session.root(route.sessionID), own = id === shown;
              if (!own && api.data.session.root(id) !== shown) return;
              switch (event.type) {
                case "session.execution.started": if (own) report("working"); break;
                case "session.execution.succeeded": case "session.execution.interrupted":
                case "session.execution.failed": if (own) report("done"); break;
                case "permission.asked": case "form.created": report("waiting"); break;
                case "permission.replied": case "permission.rejected": case "form.replied": case "form.cancelled":
                  report("working"); break;
              }
            });
          },
        };

        """

    /// Writes the config dir for `HookTransport.pluginDir`: the plugin, and OpenCode 2's plugin in `tuiPlugin(in:)`.
    public static func writePlugin(dir: URL) throws {
        let plugins = dir.appendingPathComponent("plugin"), tui = tuiPlugin(in: dir)
        try Paths.ensure(plugins)
        try Paths.ensure(tui)
        try pluginJS.write(to: plugins.appendingPathComponent("kelp.js"), atomically: true, encoding: .utf8)
        try tuiPluginJS.write(to: tui.appendingPathComponent("tui.js"), atomically: true, encoding: .utf8)
    }

    /// OpenCode 2 loads a folder's `tui.js` as a plugin of its terminal UI (not `index.js` or `server.js`, which would
    /// be its server's).
    public static func tuiPlugin(in dir: URL) -> URL { dir.appendingPathComponent("tui") }

    public static func writeSettings(to url: URL) throws {
        try Paths.ensure(url.deletingLastPathComponent())
        try settingsJSON().write(to: url, atomically: true, encoding: .utf8)
    }

    /// Writes Kelp's hooks on top of what `base` holds, into a file that stands in for `base`. Everything in `base` is
    /// kept, and its own hooks run too.
    public static func writeSettings(to url: URL, over base: URL) throws {
        guard FileManager.default.fileExists(atPath: base.path) else { return try writeSettings(to: url) }
        // When the file exists but is unreadable (root's only) or isn't plain JSON, standing in for it would drop an
        // admin's policy. So there are no hooks then, and the caller reads the screen.
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
