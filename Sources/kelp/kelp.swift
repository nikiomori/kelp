import Core
import Foundation

// kelp: every action in the UI is available here too, so agents can drive the app.
let usage = """
    usage: kelp <command>
      status                               repos, worktrees and sessions at a glance
      repo add [path] [--init | --no-git] | repo list
                                           a folder outside a repository needs one: git init it, or add it without git
      worktree create <branch> [--repo id] [--base b] [--no-setup] | list [--all] | current | note <text>
             | remove <id> [--force] [--drop-commits] | archive <id>
      session new [--agent id] [--worktree id] [--cmd "..."] [--prompt text] [--title t] [--model m] [--split right|down] [--wait] [--outlive] | list
                                           [--env NAME=value]… [--arg word]…: on top of the agent's, kept on restart
                                           from inside an agent, --agent starts its child: its news comes to the agent as input, and it ends
                                           with the agent. --outlive: not a child
                                           --cmd there goes on the line under its terminal, --split or not, and goes on
                                           when the agent ends; with --outlive it's a tab of its own
                                           elsewhere --split opens its tab beside yours
                                           --wait prints its id, then exits with its command's exit code when it ends
      wait <session> [--for done,waiting,idle,exited] [--timeout 10m]   until it stops working (or reaches one of those)
      wait --children all|any [--timeout 10m]   inside an agent: until its children stopped
      why <session> [--all]                its status, where that came from (a hook, the program, the screen)
                                           and the last changes and hooks that led there
      terminal list | read <session> [bytes] | send <session> <text> [--no-enter]
      diff [--source unstaged|staged|all|branch] | commit <msg> | merge | push
      commit add <file>… -m <subject> [-m <body>]   propose a commit; the user edits and makes it in Kelp
      comment add <file> <line[-line]> <text> | send <session>
      session restart|rename <id> [title]|handoff <id> [--agent a]
      terminal context <session>          bounded transcript (for pasting elsewhere)
      attach <session> [--detach]          make this terminal the session's terminal (detach: close it, or Ctrl+\\ with --detach)
      agents                               who runs and who needs you, live, for a narrow terminal: Enter opens one, Ctrl+\\ comes
                                           back, y/n answers a permission request. Printed once when it isn't a terminal
      usage                                each agent's plan limits: percent used, when it resets, when it was read
                                           (stale: over half an hour ago), as JSON
      hook <working|waiting|done>          (called by agent hooks inside a session)
      report <working|blocked|done|error|idle|clear> [message] [--progress 0-100] [--kind permission|question|auth]
                                           inside a session: what you're doing, on your row and tab
      github prs|issues [--filter mine|review] | checks [pr] | pr-create [--title t] [--draft] | pr-merge [--method squash|merge|rebase] | issue <n> [--send]
      linear login <key> | tasks | start <ENG-123> [--send]
                                           issue / start: the brief is typed into the new agent, not sent (--send sends it)
      open <path[:line]|url> [--split right|down] [--focus]   open a tab in the app (relative paths are fine);
                                                    --focus also brings Kelp forward and shows that workspace
      settings | settings get <key> | set <key> <json-or-text> | unset <key>
      ui state                             what the app shows: workspace, tabs, extensions, commands
      shot [file]                          the app's window as a PNG; prints where it went (a temporary file by default)
      \(Main.browserUsage)
                                           a page in a tab beside you, the user watching: snapshot lists what's on it with refs
                                           (e12) to click and type in; its own cookies unless --shared (the user's)
      run <command-id> [json-args]         run an app command (ids from `kelp ui state`)
      ext list | new <id> [--name N] [--description D] | enable <id> | disable <id> | reload | path
      ext search [text]                    the extension library (github.com/nikiomori/kelp-extensions)
      ext install <id | github-url | ./folder> [--yes]   from the library, any GitHub folder (…/tree/<branch>/<path>) or
                                           disk; one from elsewhere on GitHub shows what it runs and asks first (--yes: don't)
      ext update [id]                      what came from GitHub, to the library's latest (or its branch's)
      routine add <name> --prompt <text> [--agent id] [--model m] [--every hourly|daily|weekdays|weekly] [--at 9:00]
                  [--day mon] [--skip-missed]   an agent on a schedule in this project, in a workspace of its own; one
                                           missed while the Mac slept runs once when it wakes (--skip-missed: doesn't);
                                           an agent's asks the user on its row first
      routine list | run <id> | rm <id>    routines and their runs of the last two weeks; run now; delete
      artifact guide <doc|review|slides|design|dashboard|proof> [part]   how and where to make one: read it first
      artifact check <design> [--width 390|768|1280]   what the window finds wrong on a design: cut-off text, contrast
      artifact links <design>              where its buttons and links go, board to board; → (nothing) is a dead end
      artifact new <kind> <title> [--from <file>] [--no-open]   a page of that kind in the project's .kelp/artifacts, opened beside you; prints its file
      artifact list | open <name> | add <url> [--title t] [--type t]   the project's pages (published ones open in the user's
      artifact marks <name> [--all] | reply <name> <#> <text>   the user's open marks on a page; say something on one
      artifact ask <name> <data-id> <question> | suggest <name> <request>…   ask on an element; offer what's next
      artifact export <name> <png|pdf|pptx|html|zip|mp4|gif|mov> [to]   pictures, PDF, PowerPoint, HTML, ZIP, video
                                           browser, where they're signed in); list one an agent published elsewhere
      artifact beats <name>                    a motion page's music: its tempo and beats, at the page's seconds
      artifact captions <name> --text <file>   a motion page's subtitles from a script, a line each, timed by length
      \(Main.dbUsage)
                                           the project's databases (compose, .env, database.yml, SQLite files) through
                                           Kelp, which holds their passwords: one statement a call; an agent's change
                                           waits for the user's Allow where the database asks
      \(Main.addonUsage)
                                           what this workspace's agents get besides the prompt: MCP servers and
                                           skills, from the agents' own files and from what a chat loaded; a server
                                           added here goes to Claude Code and Codex, off is for this project
      \(Main.vmUsage)
                                           a Linux machine for commands: run goes through SSH (no network address), the
                                           project folder at the same path inside; it pauses and sleeps when unused, and
                                           the next command wakes it
      schema [method|type] | --openrpc     the daemon's methods, events and types; all of it as an OpenRPC document
      call <method> [json-params]          any of those methods, its result as JSON (for one with no command
                                           above); inside an agent the same rules hold as for every command
    """

// Internal: the daemon starts agents through this so the PTY becomes their controlling terminal
// (posix_spawn can't do TIOCSCTTY). Without it no SIGWINCH reaches them and resizes are ignored.
func ctty() -> Never {
    _ = ioctl(0, TIOCSCTTY, 0)
    let rest = Array(CommandLine.arguments.dropFirst(2))
    let cargs = rest.map { strdup($0) } + [nil]
    execvp(rest[0], cargs)
    FileHandle.standardError.write(Data("kelp: \(rest[0]): \(String(cString: strerror(errno)))\n".utf8))
    exit(127)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

nonisolated(unsafe) var args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    let value = args[index + 1]
    args.removeSubrange(index...index + 1)
    return value
}
/// Every value of a flag given more than once (`--env A=1 --env B=2`).
func all(_ name: String) -> [String] {
    var values: [String] = []
    while let value = flag(name) { values.append(value) }
    return values
}
/// `NAME=value` pairs as variables. A value may be empty (`ANTHROPIC_API_KEY=`); a pair without `=` stops the command.
func variables(_ pairs: [String]) -> [String: String] {
    Dictionary(
        pairs.map { pair in
            guard let eq = pair.firstIndex(of: "="), eq != pair.startIndex else {
                fail("--env takes NAME=value, not \(pair)")
            }
            return (String(pair[..<eq]), String(pair[pair.index(after: eq)...]))
        }
    ) { $1 }
}
func has(_ name: String) -> Bool {
    if let index = args.firstIndex(of: name) {
        args.remove(at: index)
        return true
    }
    return false
}

/// Returns the daemon binary beside this binary, wherever it was started from. argv[0] is a bare "kelp" when it came
/// off the PATH (Homebrew's link), so the path is resolved instead.
func daemonBinary() -> String {
    let me = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    return me.deletingLastPathComponent().appendingPathComponent("kelpd").path
}

func connect() throws -> RPCClient {
    if let client = try? RPCClient(socket: Paths.socket.path) { return client }
    // Start the daemon on demand.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: daemonBinary())
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch {
        throw RPCError.internalError(
            "couldn't start the Kelp daemon (\(daemonBinary())): \(error.localizedDescription)")
    }
    for _ in 0..<50 {
        usleep(100_000)
        if let client = try? RPCClient(socket: Paths.socket.path) { return client }
    }
    throw RPCError.internalError("cannot reach the Kelp daemon at \(Paths.socket.path)")
}

func show(_ value: JSONValue) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if case .string(let text) = value {
        print(text)
    } else if value != .null, let data = try? encoder.encode(value), let text = String(bytes: data, encoding: .utf8) {
        print(text)
    }
}
/// Prints a typed result as the JSON it came as.
func show<T: Encodable>(_ v: T) { show((try? JSONValue.from(v)) ?? .null) }

/// Reads a CLI value as JSON when it parses (3, true, [1], "x"), or else as the text itself.
func jsonOrText(_ text: String) -> JSONValue {
    (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .string(text)
}

/// Returns the workspace the current directory is in. When several share the folder, it is the agent's own workspace
/// (KELP_SESSION).
func currentWorktree(_ client: RPCClient) async throws -> Worktree {
    guard let worktree = try await worktreeHere(client) else {
        throw RPCError.invalidParams("not inside a kelp worktree")
    }
    return worktree
}
/// Returns nil outside every workspace, for a command that has somewhere else to go then. A daemon that didn't answer
/// is an error.
func worktreeHere(_ c: RPCClient) async throws -> Worktree? {
    if let here = try await IDE.workspace(cwd: FileManager.default.currentDirectoryPath, client: c) { return here }
    // A chat started outside its workspace's folder (a remote project's commit agent, which runs here) still belongs
    // to that workspace.
    guard let own = ProcessInfo.processInfo.environment["KELP_SESSION"],
        let id = try await c.call(SessionList()).first(where: { $0.id == own })?.worktreeId
    else { return nil }
    return try await c.call(WorktreeList()).first { $0.id == id }
}
func currentWorktreeID(_ client: RPCClient) async throws -> String { try await currentWorktree(client).id }
func currentRepoID(_ client: RPCClient) async throws -> String {
    if let repo = flag("--repo") { return repo }
    let cwd = FileManager.default.currentDirectoryPath
    // Take the nearest project, so for a project inside another (~/code/app in ~/code), the inner one wins.
    if let id = try await client.call(RepoList()).filter({ Paths.inside(cwd, $0.path) }).max(by: {
        $0.path.count < $1.path.count
    })?.id {
        return id
    }
    if let id = try await worktreeHere(client)?.repoId { return id }
    fail("no repo here; pass --repo <id> or run `kelp repo add`")
}

@main struct Main {
    static func main() async {
        if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "__ctty" { ctty() }
        signal(SIGPIPE, SIG_IGN)
        guard !args.isEmpty else {
            print(usage)
            return
        }
        let cmd = args.removeFirst()
        do {
            switch cmd {
            case "attach":
                let detachKey = has("--detach")
                guard let id = args.first else { fail("kelp attach <session>") }
                Attach.run(id, detachKey: detachKey)
            case "schema":   // No daemon needed, because the file ships with this binary.
                guard let file = Paths.resource("rpc", "json") else { fail("this build has no schema") }
                print(
                    has("--openrpc")
                        ? file
                        : RPCSchema.text(try JSONDecoder().decode(JSONValue.self, from: Data(file.utf8)), args.first))
            case "ext" where ["types", "check"].contains(args.first ?? ""):   // No daemon: these read files.
                if args.first == "types" {
                    print(ExtBridge.declarations)
                    break
                }
                let folder = URL(fileURLWithPath: args.dropFirst().first ?? ".").standardizedFileURL
                let found = ExtCheck.problems(in: folder)
                guard !found.isEmpty else {
                    print("OK: \(folder.path)")
                    break
                }
                found.forEach { print($0) }
                exit(1)
            case "hook":   // Inside an agent session: report the status to the daemon.
                guard let id = ProcessInfo.processInfo.environment["KELP_SESSION"], let ev = args.first else {
                    fail("hook: needs KELP_SESSION and an event")
                }
                var hook = SessionHook(id: id, event: ev, at: ProcessInfo.processInfo.systemUptime)
                var hookPayload: JSONValue?
                // Claude Code hooks pass a JSON payload on stdin (session id, transcript path).
                if isatty(0) == 0, let data = try? FileHandle.standardInput.readToEnd(),
                    let payload = try? JSONDecoder().decode(JSONValue.self, from: data)
                {
                    hookPayload = payload
                    hook.hookName = payload["hook_event_name"]?.string
                    hook.agentId = payload["agent_id"]?.string
                    hook.agentType = payload["agent_type"]?.string
                    hook.transcript = payload["transcript_path"]?.string
                    hook.cwd = payload["cwd"]?.string   // Where the agent works now, maybe its own worktree.
                    hook.trigger = payload["trigger"]?.string   // PreCompact: manual (/compact) or auto
                    hook.backgroundTasks = payload["background_tasks"]?.array   // Stop: subagents still running.
                    hook.sessionCrons = payload["session_crons"]?.array   // Stop: timers that will wake the agent.
                    // A Bash command started or ended.
                    if ev == "command" { hook.command = AgentCommand(hook: payload) }
                    hook.notification = SessionHook.notification(of: payload)
                    hook.goal = SessionHook.goal(of: payload)
                    hook.endedTasks = SessionHook.endedTasks(of: payload)
                    hook.edited = SessionHook.edited(of: payload)
                    if hook.hookName == "Stop" { hook.reply = payload["last_assistant_message"]?.string }
                }
                try await hook.send(socket: ProcessInfo.processInfo.environment["KELP_SOCKET"] ?? Paths.socket.path)
                // For a permission question, Allow or Deny given in Kelp comes back as this hook's decision, not as
                // keys typed into the menu, which stays on screen meanwhile (Claude Code shows it while its hook runs).
                // `--no-answer` is for an agent that shows its menu only after the hook (Codex), which is answered in
                // that menu.
                if hook.hookName == "PermissionRequest", !args.contains("--no-answer"),
                    let answer = try await connect().call(SessionPermissionWait(id: id))
                {
                    let decision =
                        answer == "allow"
                        ? #"{"behavior":"allow"}"# : #"{"behavior":"deny","message":"Denied in Kelp"}"#
                    print(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":"# + decision + "}}")
                }
                if ev == "command", let payload = hookPayload, let page = Artifacts.published(hook: payload) {
                    await notePublished(
                        page, cwd: payload["cwd"]?.string ?? FileManager.default.currentDirectoryPath, session: id)
                }
            default:
                let client = try connect()
                try await run(cmd, client)
            }
        } catch let rpcError as RPCError { fail("error: \(rpcError.message)") } catch { fail("error: \(error)") }
    }

    static func run(_ cmd: String, _ client: RPCClient) async throws {
        let sub = args.first.flatMap { $0.hasPrefix("-") ? nil : $0 }
        if sub != nil { args.removeFirst() }
        switch cmd {
        case "status", "repo", "worktree": try await projects(cmd, sub, client)
        case "session", "terminal", "wait", "why", "report": try await sessions(cmd, sub, client)
        case "agents": try await agents(client)
        case "usage": try await usageLimits(client)
        case "diff", "commit", "merge", "push", "comment": try await git(cmd, sub, client)
        case "github", "linear": try await forge(cmd, sub, client)
        case "settings", "ui", "run": try await settingsAndUI(cmd, sub, client)
        case "call": try await call(sub, client)
        case "ext": try await ext(sub, client)
        case "open": try await open(sub, client)
        case "edit": try await edit(sub, client)
        case "shot": try await shot(sub, client)
        case "browser": try await browser(sub, client)
        case "routine": try await routines(sub, client)
        case "artifact": try await artifacts(sub, client)
        case "vm": try await vm(sub, client)
        case "db": try await db(sub, client)
        case "mcp": try await addons(.server, sub, client)
        case "skill": try await addons(.skill, sub, client)
        default: print(usage)
        }
    }

    /// Returns a session's full id, given the id or a unique prefix of it (as `kelp status` prints it).
    static func session(_ client: RPCClient, _ prefix: String) async throws -> String {
        guard !prefix.isEmpty else { fail("id required") }
        return unique(prefix, among: try await client.call(SessionList()).map(\.id))
    }

    /// Returns a workspace's full id, given the id or a unique prefix of it.
    static func workspace(_ client: RPCClient, _ prefix: String) async throws -> String {
        guard !prefix.isEmpty else { fail("id required") }
        return unique(prefix, among: try await client.call(WorktreeList()).map(\.id))
    }

    static func unique(_ prefix: String, among ids: [String]) -> String {
        let found = ids.filter { $0.hasPrefix(prefix) }
        guard found.count == 1 else { fail(found.isEmpty ? "no match for \(prefix)" : "ambiguous: \(prefix)") }
        return found[0]
    }
}
