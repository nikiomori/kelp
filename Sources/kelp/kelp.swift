import Foundation
import Core

// kelp: every action in the UI is available here, so agents can drive the app too.
let usage = """
usage: kelp <command>
  status                               repos, worktrees and sessions at a glance
  repo add [path] [--init | --no-git] | repo list
                                       a folder outside a repository needs one: git init it, or add it without git
  worktree create <branch> [--repo id] [--base b] | list | current | note <text> | remove <id> [--force] [--drop-commits] | archive <id>
  session new [--agent id] [--worktree id] [--cmd "..."] [--split right|down] [--wait] | list
                                       --split opens its tab beside yours; --wait prints its id, then exits with
                                       its command's exit code when it ends
  wait <session> [--for done,waiting,idle,exited] [--timeout 10m]   until it stops working (or reaches one of those)
  why <session> [--all]                its status, where that came from (a hook, the program, the screen)
                                       and the last changes and hooks that led there
  terminal list | read <session> [bytes] | send <session> <text> [--no-enter]
  diff [--source unstaged|staged|all|branch] | commit <msg> | merge | push
  comment add <file> <line[-line]> <text> | send <session>
  session restart|rename <id> [title]|handoff <id> [--agent a]
  terminal context <session>          bounded transcript (for pasting elsewhere)
  attach <session>                     make this terminal the session's terminal (detach: close it)
  hook <working|waiting|done>          (called by agent hooks inside a session)
  report <working|blocked|done|error|idle|clear> [message] [--progress 0-100] [--kind permission|question|auth]
                                       inside a session: what you're doing, on your row and tab
  install | uninstall                  launchd agent for the daemon
  github prs|issues [--filter mine|review] | checks [pr] | pr-create [--title t] [--draft] | pr-merge | issue <n> [--send]
  linear login <key> | tasks | start <ENG-123> [--send]
                                       issue / start: the brief is typed into the new agent, not sent (--send sends it)
  open <path[:line]|url> [--split right|down] [--focus]   open a tab in the app (relative paths are fine);
                                                --focus also brings Kelp forward and shows that workspace
  settings | settings get <key> | set <key> <json-or-text> | unset <key>
  ui state                             what the app shows: workspace, tabs, extensions, commands
  shot [file]                          the app's window as a PNG; prints where it went (a temporary file by default)
  run <command-id> [json-args]         run an app command (ids from `kelp ui state`)
  ext list | new <id> [--name N] [--description D] | enable <id> | disable <id> | reload | path
  ext search [text]                    the extension library (github.com/nikiomori/kelp-extensions)
  ext install <id | github-url | ./folder> [--yes]   from the library, any GitHub folder (…/tree/<branch>/<path>) or
                                       disk; one from elsewhere on GitHub shows what it runs and asks first (--yes: don't)
  ext update [id]                      what came from GitHub, to the library's latest (or its branch's)
  routine add <name> --prompt <text> [--agent id] [--model m] [--every hourly|daily|weekdays|weekly] [--at 9:00]
              [--day mon] [--skip-missed]   an agent on a schedule in this project, in a workspace of its own; one
                                       missed while the Mac slept runs once when it wakes (--skip-missed: doesn't)
  routine list | run <id> | rm <id>    routines and their runs of the last two weeks; run now; delete
"""

// Internal: the daemon starts agents through this so the PTY becomes their controlling terminal
// (posix_spawn can't do TIOCSCTTY). Without it no SIGWINCH reaches them and resizes are ignored.
func ctty() -> Never {
    _ = ioctl(0, TIOCSCTTY, 0)
    let rest = Array(CommandLine.arguments.dropFirst(2))
    let cargs = rest.map { strdup($0) } + [nil]
    execvp(rest[0], cargs)
    FileHandle.standardError.write(Data("kelp: \(rest[0]): \(String(cString: strerror(errno)))\n".utf8)); exit(127)
}

func fail(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1) }

nonisolated(unsafe) var args = Array(CommandLine.arguments.dropFirst())
func flag(_ n: String) -> String? {
    guard let i = args.firstIndex(of: n), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
}
func has(_ n: String) -> Bool { if let i = args.firstIndex(of: n) { args.remove(at: i); return true }; return false }

func daemonBinary() -> String {
    let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    return me.deletingLastPathComponent().appendingPathComponent("kelpd").path
}

func connect() throws -> RPCClient {
    if let c = try? RPCClient(socket: Paths.socket.path) { return c }
    // Start the daemon on demand.
    let p = Process(); p.executableURL = URL(fileURLWithPath: daemonBinary())
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try? p.run()
    for _ in 0..<50 { usleep(100_000); if let c = try? RPCClient(socket: Paths.socket.path) { return c } }
    throw RPCError.internalError("cannot reach the Kelp daemon at \(Paths.socket.path)")
}

func show(_ v: JSONValue) {
    let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if case .string(let s) = v { print(s) } else if v != .null, let d = try? e.encode(v), let s = String(bytes: d, encoding: .utf8) { print(s) }
}
/// A typed result, printed as the JSON it came as.
func show<T: Encodable>(_ v: T) { show((try? JSONValue.from(v)) ?? .null) }

/// A CLI value: JSON when it parses (3, true, [1], "x"), else the text itself.
func jsonOrText(_ s: String) -> JSONValue { (try? JSONDecoder().decode(JSONValue.self, from: Data(s.utf8))) ?? .string(s) }

/// The workspace the current directory is in; an agent's own one (KELP_SESSION) when several share the folder.
func currentWorktree(_ c: RPCClient) async throws -> Worktree {
    guard let w = try await IDE.workspace(cwd: FileManager.default.currentDirectoryPath, client: c) else {
        throw RPCError.invalidParams("not inside a kelp worktree")   // throws: callers use try? to fall back
    }
    return w
}
func currentWorktreeID(_ c: RPCClient) async throws -> String { try await currentWorktree(c).id }
func currentRepoID(_ c: RPCClient) async throws -> String {
    if let r = flag("--repo") { return r }
    let cwd = FileManager.default.currentDirectoryPath
    if let id = try await c.call(RepoList()).first(where: { IDE.inside(cwd, $0.path) })?.id { return id }
    if let id = (try? await currentWorktree(c))?.repoId { return id }
    fail("no repo here; pass --repo <id> or run `kelp repo add`")
}

func plist() -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>Label</key><string>dev.kelp.daemon</string>
      <key>ProgramArguments</key><array><string>\(daemonBinary())</string></array>
      <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
    </dict></plist>
    """
}

@main struct Main {
    static func main() async {
        if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "__ctty" { ctty() }
        signal(SIGPIPE, SIG_IGN)
        guard !args.isEmpty else { print(usage); return }
        let cmd = args.removeFirst()
        do {
            switch cmd {
            case "install":
                let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/dev.kelp.daemon.plist")
                try plist().write(to: u, atomically: true, encoding: .utf8)
                _ = try? Process.run(URL(fileURLWithPath: "/bin/launchctl"), arguments: ["load", u.path])
                print("installed \(u.path)")
            case "uninstall":
                let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/dev.kelp.daemon.plist")
                _ = try? Process.run(URL(fileURLWithPath: "/bin/launchctl"), arguments: ["unload", u.path])
                try? FileManager.default.removeItem(at: u)
            case "attach":
                guard let id = args.first else { fail("kelp attach <session>") }
                Attach.run(id)
            case "hook":   // inside an agent session: report status to the daemon
                guard let id = ProcessInfo.processInfo.environment["KELP_SESSION"], let ev = args.first else { fail("hook: needs KELP_SESSION and an event") }
                let c = try RPCClient(socket: ProcessInfo.processInfo.environment["KELP_SOCKET"] ?? Paths.socket.path, patience: 2)
                var h = SessionHook(id: id, event: ev)
                // Claude Code hooks pass a JSON payload on stdin (session id, transcript path).
                if isatty(0) == 0, let d = try? FileHandle.standardInput.readToEnd(), let v = try? JSONDecoder().decode(JSONValue.self, from: d) {
                    h.transcript = v["transcript_path"]?.string
                    h.cwd = v["cwd"]?.string   // where it works now: its own worktree, maybe
                    h.trigger = v["trigger"]?.string   // PreCompact: manual (/compact) or auto
                    h.backgroundTasks = v["background_tasks"]?.array   // Stop: subagents still running
                    h.sessionCrons = v["session_crons"]?.array   // Stop: timers that will wake it
                    if ev == "command" { h.command = AgentCommand(hook: v) }   // a Bash command started or ended
                    h.notification = SessionHook.notification(of: v)
                }
                _ = try await c.call(h)
            default:
                let c = try connect()
                try await run(cmd, c)
            }
        } catch let e as RPCError { fail("error: \(e.message)") }
        catch { fail("error: \(error)") }
    }

    static func run(_ cmd: String, _ c: RPCClient) async throws {
        let sub = args.first.flatMap { $0.hasPrefix("-") ? nil : $0 }
        if sub != nil { args.removeFirst() }
        switch cmd {
        case "status", "repo", "worktree": try await projects(cmd, sub, c)
        case "session", "terminal", "wait", "why", "report": try await sessions(cmd, sub, c)
        case "diff", "commit", "merge", "push", "comment": try await git(cmd, sub, c)
        case "github", "linear": try await forge(cmd, sub, c)
        case "settings", "ui", "run": try await settingsAndUI(cmd, sub, c)
        case "ext": try await ext(sub, c)
        case "open": try await open(sub, c)
        case "shot": try await shot(sub, c)
        case "routine": try await routines(sub, c)
        default: print(usage)
        }
    }

    /// Accept a full id or a unique prefix (what `kelp status` prints) of a session (`session.list`) or else a workspace.
    static func resolve(_ c: RPCClient, _ prefix: String, _ listMethod: String) async throws -> String {
        guard !prefix.isEmpty else { fail("id required") }
        let ids = listMethod == SessionList.name ? try await c.call(SessionList()).map(\.id) : try await c.call(WorktreeList()).map(\.id)
        let found = ids.filter { $0.hasPrefix(prefix) }
        guard found.count == 1 else { fail(found.isEmpty ? "no match for \(prefix)" : "ambiguous: \(prefix)") }
        return found[0]
    }
}
