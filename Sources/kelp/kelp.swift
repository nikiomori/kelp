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
  run <command-id> [json-args]         run an app command (ids from `kelp ui state`)
  ext list | new <id> [--name N] [--description D] | enable <id> | disable <id> | reload | path
  ext search [text]                    the extension library (github.com/nikiomori/kelp-extensions)
  ext install <id | github-url | ./folder> [--yes]   from the library, any GitHub folder (…/tree/<branch>/<path>) or
                                       disk; one from elsewhere on GitHub shows what it runs and asks first (--yes: don't)
  ext update [id]                      what came from GitHub, to the library's latest (or its branch's)
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
                    if v["hook_event_name"]?.string == "PermissionRequest" {   // the dialog: what it would run says more than any notice
                        h.notification = .obj(["notification_type": "permission_request", "tool_name": v["tool_name"] ?? .null,
                                               "tool_input": v["tool_input"] ?? .null, "cwd": v["cwd"] ?? .null])
                    } else if v["notification_type"] != nil || v["message"] != nil {
                        h.notification = .obj(["notification_type": v["notification_type"] ?? .null, "message": v["message"] ?? .null])
                    }
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
        case "session", "terminal", "wait", "report": try await sessions(cmd, sub, c)
        case "diff", "commit", "merge", "push", "comment": try await git(cmd, sub, c)
        case "github", "linear": try await forge(cmd, sub, c)
        case "settings", "ui", "run": try await settingsAndUI(cmd, sub, c)
        case "ext": try await ext(sub, c)
        case "open": try await open(sub, c)
        default: print(usage)
        }
    }

    /// `open <path|url> [--split right|down] [--focus]`: a tab in the app.
    static func open(_ sub: String?, _ c: RPCClient) async throws {
        let split = flag("--split")
        let focus = has("--focus") || sub == "--focus"
        guard let target = sub.flatMap({ $0 == "--focus" ? nil : $0 }) ?? args.first else { fail("open <path|url> [--split right|down] [--focus]") }
        let cwd = FileManager.default.currentDirectoryPath
        show(try await IDE.open(target, split: split, cwd: cwd, focus: focus, client: c))
    }

    /// `status`, `repo …`, `worktree …`.
    static func projects(_ cmd: String, _ sub: String?, _ c: RPCClient) async throws {
        switch (cmd, sub) {
        case ("status", _):
            let repos = try await c.call(RepoList()), wts = try await c.call(WorktreeList()), ss = try await c.call(SessionList())
            for r in repos {
                print("\(r.name)  \(r.path)")
                for w in wts where w.repoId == r.id {
                    let note = w.note.isEmpty ? "" : " — \(w.note)"
                    print("  \(w.branch)  [\(w.id.prefix(8))]\(note)")
                    for s in ss where s.worktreeId == w.id {
                        print("    \(s.agent ?? "cmd") \(s.status.rawValue)\(s.unread ? " •" : "")  [\(s.id.prefix(8))]")
                    }
                }
            }
        case ("repo", "add"):
            let git: Bool? = has("--init") ? true : has("--no-git") ? false : nil
            show(try await c.call(RepoAdd(path: args.first ?? FileManager.default.currentDirectoryPath, init: git)))
        case ("repo", "list"): show(try await c.call(RepoList()))
        case ("worktree", "create"):
            guard let b = args.first, !b.hasPrefix("-") else { fail("worktree create <branch>") }
            args.removeFirst()
            let base = flag("--base"), setup: Bool? = has("--no-setup") ? false : nil
            show(try await c.call(WorktreeCreate(repoId: try await currentRepoID(c), branch: b, base: base, setup: setup)))
        case ("worktree", "list"): show(try await c.call(WorktreeList(archived: has("--all") ? true : nil)))
        case ("worktree", "current"): show(try await currentWorktree(c))
        case ("worktree", "note"):
            _ = try await c.call(WorktreeNote(id: try await currentWorktreeID(c), note: args.joined(separator: " ")))
        case ("worktree", "remove"), ("worktree", "archive"):
            let force = has("--force"), drop = has("--drop-commits")   // two separate losses, each asked for by name
            let id = try await resolve(c, args.first ?? "", "worktree.list")
            if sub == "remove" {
                show(try await c.call(WorktreeRemove(id: id, force: force, dropCommits: drop)))
            } else {
                show(try await c.call(WorktreeArchive(id: id)))
            }
        default: print(usage)
        }
    }

    /// `session …`, `terminal …`, `wait`, `report`.
    static func sessions(_ cmd: String, _ sub: String?, _ c: RPCClient) async throws {
        switch (cmd, sub) {
        case ("session", "new"):
            let wait = has("--wait"), split = flag("--split")
            var p = SessionCreate(agent: flag("--agent"), command: flag("--cmd"))
            // A session outside every workspace would run where no tab or sidebar row shows it.
            if let w = flag("--worktree") { p.worktreeId = try await resolve(c, w, "worktree.list") }
            else if let w = try? await currentWorktree(c) { p.worktreeId = w.id }
            else { fail("not inside a Kelp project: run it in a project's folder or pass --worktree <id> (see `kelp status`)") }
            let s = try await c.call(p), id = s.id
            // Its tab beside yours; without the app it runs all the same (its row shows once the app opens).
            if let split { _ = try? await IDE.open("session:\(id)", split: split, cwd: FileManager.default.currentDirectoryPath, client: c) }
            guard wait else { show(try .from(s)); return }
            print(id)   // for `kelp terminal read`, once it ends
            exit(Int32(try await waitFor(c, id, timeout: nil) { $0.status == .exited }?.exitCode ?? 1))
        case ("session", "list"), ("terminal", "list"): show(try await c.call(SessionList()))
        case ("wait", let target?):   // until the session stops working, or reaches one of --for; prints the state it reached
            let want = flag("--for").map { Set($0.split(separator: ",").map(String.init)) }, timeout = flag("--timeout").map(duration)
            let id = try await resolve(c, target, "session.list")
            guard let s = try await waitFor(c, id, timeout: timeout, until: { want?.contains($0.status.rawValue) ?? ($0.status != .working) })
            else { fail("timed out") }
            print(s.status.rawValue)
            if s.status == .exited { exit(Int32(s.exitCode ?? 0)) }   // its command's exit code
        case ("report", let state?):   // inside a session: what this program is doing, on its row and tab
            guard let id = ProcessInfo.processInfo.environment["KELP_SESSION"] else { fail("report: run it inside a Kelp session") }
            let progress = flag("--progress").flatMap { Int($0) }, kind = flag("--kind"), msg = args.joined(separator: " ")
            _ = try await c.call(SessionReport(id: id, state: state, message: msg.isEmpty ? nil : msg, progress: progress, kind: kind))
        case ("terminal", "read"):
            show(try await c.call(SessionRead(id: try await resolve(c, args.first ?? "", "session.list"),
                                              bytes: args.dropFirst().first.flatMap(Int.init) ?? 8192)))
        case ("terminal", "send"):
            let enter = !has("--no-enter")
            guard args.count >= 2 else { fail("terminal send <session> <text>") }
            let id = try await resolve(c, args[0], "session.list")
            show(try await c.call(SessionSend(id: id, text: args.dropFirst().joined(separator: " "), enter: enter)))
        case ("session", "restart"):
            show(try .from(try await c.call(SessionRestart(id: try await resolve(c, args.first ?? "", "session.list")))))
        case ("session", "rename"):
            _ = try await c.call(SessionRename(id: try await resolve(c, args.first ?? "", "session.list"), title: args.dropFirst().joined(separator: " ")))
        case ("session", "handoff"):
            show(try .from(try await c.call(SessionHandoff(id: try await resolve(c, args.first ?? "", "session.list"), agent: flag("--agent")))))
        case ("terminal", "context"):
            show(try await c.call(SessionContext(id: try await resolve(c, args.first ?? "", "session.list"))))
        default: print(usage)
        }
    }

    /// `diff`, `commit`, `merge`, `push`, `comment …` in the current workspace.
    static func git(_ cmd: String, _ sub: String?, _ c: RPCClient) async throws {
        switch (cmd, sub) {
        case ("diff", _):
            for f in try await c.call(GitDiff(id: try await currentWorktreeID(c), source: flag("--source") ?? "all")) {
                print("\(f.path)  " + (f.tooLarge == true ? "(too large to count here)" : "+\(f.additions) -\(f.deletions)"))
            }
        case ("commit", _):
            show(try await c.call(GitCommit(id: try await currentWorktreeID(c), message: ([sub].compactMap { $0 } + args).joined(separator: " "), all: true)))
        case ("merge", _): show(try await c.call(GitMerge(id: try await currentWorktreeID(c))))
        case ("push", _): show(try await c.call(GitPush(id: try await currentWorktreeID(c))))
        case ("comment", "add"):
            guard args.count >= 3 else { fail("comment add <file> <line[-line]> <text>") }
            let range = args[1].split(separator: "-").compactMap { Int($0) }
            let id = try await currentWorktreeID(c), text = args.dropFirst(2).joined(separator: " ")
            show(try await c.call(CommentAdd(id: id, file: args[0], start: range.first ?? 1, end: range.last ?? 1, text: text)))
        case ("comment", "send"):
            show(try await c.call(CommentSend(id: try await currentWorktreeID(c), session: try await resolve(c, args.first ?? "", "session.list"))))
        default: print(usage)
        }
    }

    /// `github …`, `linear …`.
    static func forge(_ cmd: String, _ sub: String?, _ c: RPCClient) async throws {
        switch (cmd, sub) {
        case ("github", "prs"):
            for x in try await c.call(GitHubPRs(repoId: try await currentRepoID(c), filter: flag("--filter"))) { print("#\(x.number)  \(x.title)  \(x.url)") }
        case ("github", "issues"):
            for x in try await c.call(GitHubIssues(repoId: try await currentRepoID(c), filter: flag("--filter"))) {
                print("#\(x.number)  \(x.title)  \(x.url)")
            }
        case ("github", "checks"):
            let w = try await currentWorktree(c)
            let pr = args.first.flatMap(Int.init) ?? w.prNumber ?? 0
            for x in try await c.call(GitHubChecks(worktreeId: w.id, pr: pr)) { print("\(x.bucket)\t\(x.name)\t\(x.link)") }
        case ("github", "pr-create"):
            let wid = try await currentWorktreeID(c)
            show(.string(try await c.call(GitHubPRCreate(worktreeId: wid, title: flag("--title"), draft: has("--draft") ? true : nil)).url))
        case ("github", "pr-merge"):
            let wid = try await currentWorktreeID(c)
            show(try .from(try await c.call(GitHubPRMerge(worktreeId: wid, method: flag("--method") ?? "squash"))))
        case ("github", "issue"), ("linear", "start"):   // kelp github issue 123 | kelp linear start ENG-123
            let repo = try await currentRepoID(c)
            guard let ref = args.first else { fail("issue number / identifier required") }
            var p: [String: JSONValue] = ["repoId": .string(repo), "agent": .string(flag("--agent") ?? "claude")]
            if cmd == "github" {
                let n = Int(ref.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) ?? 0
                let open = try await c.call(GitHubIssues(repoId: repo))
                guard let i = open.first(where: { $0.number == n }) else { fail("issue #\(n) not found among open issues") }
                p["ref"] = .string("#\(n)"); p["title"] = .string(i.title); p["body"] = .string(i.body); p["url"] = .string(i.url)
            } else {
                let mine = try await c.call(LinearIssues())
                guard let i = mine.first(where: { $0.identifier.lowercased() == ref.lowercased() }) else { fail("\(ref) not found in your Linear issues") }
                p["ref"] = .string(i.identifier); p["title"] = .string(i.title); p["body"] = .string(i.description ?? ""); p["url"] = .string(i.url)
                p["linearId"] = .string(i.id)
            }
            if has("--send") { p["draft"] = false }
            let r = try await c.call(try JSONValue.object(p).decode(TaskFromIssue.self))
            print("\(r.worktree.branch)  \(r.worktree.path)")
            if !has("--send") { print("The issue's text is typed into the agent, not sent: look it over in Kelp and press Return.") }
            if r.setupNeedsTrust { print("Its .kelp.yaml setup didn't run: open the project in Kelp to look at it and trust it.") }
        case ("linear", "tasks"):
            for x in try await c.call(LinearIssues()) { print("\(x.identifier)  [\(x.state.name)]  \(x.title)") }
        case ("linear", "login"):
            guard let k = args.first else { fail("linear login <api-key>") }
            show(try .from(try await c.call(LinearSetKey(key: k))))
        default: print(usage)
        }
    }

    static func settingsAndUI(_ cmd: String, _ sub: String?, _ c: RPCClient) async throws {
        switch (cmd, sub) {
        case ("settings", nil): show(.object(try await c.call(SettingsGet())))
        case ("settings", "get"):
            guard let k = args.first else { fail("settings get <key>") }
            show(try await c.call(SettingsGet())[k] ?? .null)
        case ("settings", "set"):
            guard args.count >= 2 else { fail("settings set <key> <value>") }
            _ = try await c.call(SettingsSet(key: args[0], value: jsonOrText(args.dropFirst().joined(separator: " "))))
        case ("settings", "unset"):
            guard let k = args.first else { fail("settings unset <key>") }
            _ = try await c.call(SettingsSet(key: k, value: nil))
        case ("ui", "state"): show(try await c.call(UIStateGet()))
        case ("run", let id?):
            show(try .from(try await c.call(UICommand(id: id, args: args.isEmpty ? nil : jsonOrText(args.joined(separator: " "))))))
        default: print(usage)
        }
    }

    static func ext(_ sub: String?, _ c: RPCClient) async throws {
        switch sub {
        case "list":
            for e in try await IDE.extensions(client: c, dir: Paths.extensions).array ?? [] {
                let tags = [e["builtin"]?.bool == true ? "(built-in)" : nil, e["enabled"]?.bool == false ? "(disabled)" : nil].compactMap { $0 }
                print(([e["id"]?.string ?? "", e["name"]?.string ?? ""] + tags).joined(separator: "\t"))
            }
        case "new":
            let name = flag("--name"), description = flag("--description")
            guard let id = args.first else { fail("ext new <id> [--name N] [--description D]") }
            let folder = try IDE.scaffoldExtension(id: id, name: name, description: description, in: Paths.extensions)
            print("created \(folder.path)\nguide:   \(folder.deletingLastPathComponent().appendingPathComponent("EXTENSIONS.md").path)")
        case "enable", "disable":
            guard let id = args.first else { fail("ext enable|disable <id>") }
            try await IDE.setExtension(id, enabled: sub == "enable", client: c)
        case "reload": show(try .from(try await c.call(UICommand(id: "extensions.reload"))))
        case "path": print(Paths.extensions.path)
        case "search":
            for e in try await c.call(ExtensionLibrary()) where e.matches(args.joined(separator: " ")) {
                print([e.id, e.version, e.name, e.description ?? ""].joined(separator: "\t"))
            }
        case "install":
            guard let what = args.first else { fail("ext install <id | github-url | ./folder>") }
            var dir: ObjCBool = false
            if what.contains("/"), FileManager.default.fileExists(atPath: what, isDirectory: &dir), dir.boolValue {
                let src = URL(fileURLWithPath: what).standardizedFileURL
                installed(try IDE.installExtension(src, as: src.lastPathComponent, in: Paths.extensions))
            } else if what.contains("/") {
                installed(try await fetch(what, as: nil, c, review: !args.contains("--yes")))
            } else {
                guard let e = try await c.call(ExtensionLibrary()).first(where: { $0.id == what }) else { fail("no \(what) in the library (kelp ext search)") }
                installed(try await fetch(e.source, as: nil, c))
            }
        case "update":
            let library = try await c.call(ExtensionLibrary())
            var found = false
            for f in (try? FileManager.default.contentsOfDirectory(at: Paths.extensions, includingPropertiesForKeys: nil)) ?? [] {
                guard let source = IDE.extensionSource(f), let id = manifest(f)["id"]?.string, args.first.map({ $0 == id }) ?? true else { continue }
                found = true
                // One from elsewhere on GitHub may have moved on its branch: it's fetched again.
                let latest = library.first { $0.id == id }?.source
                if latest == source { print("\(id) is up to date"); continue }
                // The library's pinned commit was reviewed; a branch elsewhere may hold anything its owner pushed since.
                installed(try await fetch(latest ?? source, as: f.lastPathComponent, c, review: latest == nil && !args.contains("--yes")))
            }
            if !found { print(args.first.map { "\($0) wasn't installed from GitHub" } ?? "nothing here was installed from GitHub") }
        default: print(usage)
        }
    }

    /// Downloads it through the daemon and moves it in, as `name` (else its id). `review`: what it can run is shown
    /// first and asked about in a terminal; with no terminal to ask in, it's refused (`--yes` says yes).
    static func fetch(_ source: String, as name: String?, _ c: RPCClient, review: Bool = false) async throws -> URL {
        let folder = URL(fileURLWithPath: try await c.call(ExtensionFetch(source: source)).folder)
        if review {
            let (commands, pages) = IDE.commandsIn(manifest(folder))
            if !commands.isEmpty || !pages.isEmpty {
                print("\(source) can run:")
                commands.forEach { print("  \($0)") }
                pages.forEach { print("  \($0) (a web page, which can run any command)") }
                guard isatty(STDIN_FILENO) == 1 else { fail("not installed: run it again with --yes to install it as it is") }
                print("Install it? [y/N] ", terminator: "")
                guard readLine()?.lowercased().hasPrefix("y") == true else { fail("not installed") }
            }
        }
        return try IDE.installExtension(folder, as: name ?? folder.lastPathComponent, in: Paths.extensions, move: true)
    }

    static func manifest(_ folder: URL) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: folder.appendingPathComponent("extension.json")))) ?? .null
    }

    /// What was installed and what it can run: the CLI's version of the app's look before installing.
    static func installed(_ dest: URL) {
        let m = manifest(dest), (commands, pages) = IDE.commandsIn(m)
        print("installed \(m["id"]?.string ?? dest.lastPathComponent) \(m["version"]?.string ?? "") → \(dest.path)")
        if !commands.isEmpty || !pages.isEmpty { print("it can run:") }
        for x in commands { print("  \(x)") }
        for p in pages { print("  \(p) (a web page, which can run any command)") }
    }

    /// Looks at the session twice a second until `done` says so, or it ended or was paused (it can't change then);
    /// nil when `timeout` ran out first.
    static func waitFor(_ c: RPCClient, _ id: String, timeout: TimeInterval?, until done: (Session) -> Bool) async throws -> Session? {
        let end = timeout.map { Date().addingTimeInterval($0) }
        while true {
            guard let s = try await c.call(SessionList()).first(where: { $0.id == id }) else { fail("no session \(id)") }
            if done(s) || s.status == .exited || s.status == .hibernated { return s }
            if let end, Date() > end { return nil }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    /// "90", "30s", "10m", "1h" → seconds.
    static func duration(_ s: String) -> TimeInterval {
        let unit = ["s": 1.0, "m": 60, "h": 3600][String(s.suffix(1))]
        guard let n = Double(unit == nil ? s : String(s.dropLast())) else { fail("bad duration \(s): use 30s, 10m or 1h") }
        return n * (unit ?? 1)
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
