import Foundation
import Core
import GitKit
import Agents
import AgentData
import Integrations

extension Sessions.Launch {
    init(_ o: some LaunchOptions) {
        self.init()
        model = o.model
        effort = o.effort
        prompt = o.prompt
        title = o.title
        profile = o.profile
        draft = o.draft == true; openURLs = o.openURLs == true
        (cols, rows) = Self.size(cols: o.cols, rows: o.rows)
    }
}

extension SessionCreate: Handled {
    func handle(_ sessions: Sessions) throws -> Session {
        // cwd wins when both are given (e.g. an agent building an extension, shown in the current workspace).
        var dir = cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        if let worktreeId, dir == nil { dir = try sessions.store.worktree(named: worktreeId).path }
        guard let dir else { throw RPCError.invalidParams("cwd or worktreeId required") }
        var o = Sessions.Launch(self)
        if let tmux {   // a terminal running tmux: the record keeps the argv that attaches again (Tmux.session)
            let name = Tmux.name(tmux)
            guard !name.isEmpty else { throw RPCError.invalidParams("Name the tmux session.") }
            o.argv = Tmux.argv(name)
            if o.title == nil { o.title = "tmux \(name)" }
        } else if command == nil, (agent ?? "shell") == "shell", sessions.settings["terminal.tmux"]?.bool == true,
                  sessions.remotes.of(dir) != nil || (try? LoginPath.resolve("tmux")) != nil {
            o.argv = Tmux.argv(Tmux.own())   // a terminal in a tmux session of its own, which ends with it (Tmux.isOwn)
        }
        return try sessions.spawn(cwd: dir, manifest: sessions.manifest(tmux == nil ? agent : "shell", command: tmux == nil ? command : nil),
                                 worktreeId: worktreeId, o)
    }
}

extension SessionRestart: Handled {
    func handle(_ sessions: Sessions) throws -> Session {
        guard try sessions.store.session(id) != nil else { throw RPCError.invalidParams("no session") }
        // One copy of the conversation at a time: the resumed agent starts once the old one is gone (SIGKILL after 2 s).
        // Under its wake lock, and a paused one marked ended there: a tab opening it meanwhile can't wake a second copy.
        // If the new one can't start, the old one still ends as Ended. The record is read there, as it is then (a rename
        // just before is kept, in it and in the new session's title).
        let old: Session = try sessions.wakeLocks.withLock(id) {
            if let ls = sessions.existing(id) { Sessions.waitGone(ls.pty.terminate()) }
            else { try sessions.store.update(Session.self, id) { if $0.status == .hibernated { $0.status = .exited } } }
            guard let s = try sessions.store.session(id) else { throw RPCError.invalidParams("no session") }
            return s
        }
        let m = try sessions.manifest(old.agent, command: nil, fallbackArgv: old.argv)
        var o = Sessions.Launch(self); o.title = old.titleManual ? old.title : nil
        if o.profile == nil { o.profile = old.profile }   // the same account unless told otherwise
        // A remote agent still running in its tmux session on the host: the new tab attaches to it (after a dropped
        // connection, that's all a restart is), so there's still one copy. Starting afresh ends it.
        if resume != false { o.tmux = old.tmux }
        // The new session pins an id of its own, never the old one's.
        o.argv = Sessions.withoutSessionId(resume != false ? sessions.resumeArgv(old, m) : old.argv, flag: m.sessionIdFlag)
        let s = try sessions.spawn(cwd: old.cwd, manifest: m, worktreeId: old.worktreeId, o)
        sessions.discard(old, keepTmux: old.tmux == nil || resume != false)   // its exit, still to come, doesn't save it again
        return s
    }
}

extension SessionHandoff: Handled {
    func handle(_ sessions: Sessions) throws -> Session {
        guard let old = try sessions.store.session(id) else { throw RPCError.invalidParams("no session") }
        // The brief is a file on this Mac: an agent on a remote host couldn't read it.
        if sessions.remotes.of(old.cwd) != nil { throw RPCError.invalidParams("Handoff isn't available for remote projects yet.") }
        let transcript = try sessions.handoffFile(old, full: full == true)
        var o = Sessions.Launch(self)
        o.prompt = "Read \(transcript.path) — the transcript of the previous agent session in this project. "
            + (prompt ?? "Continue the task where the previous agent left off.")
        o.title = (old.title.isEmpty ? (old.agent ?? "agent") : old.title) + " (handoff)"
        return try sessions.spawn(cwd: old.cwd, manifest: sessions.manifest(agent ?? old.agent, command: nil), worktreeId: old.worktreeId, o)
    }
}

extension HistoryResume: Handled {
    func handle(_ sessions: Sessions) throws -> Session {
        guard let s = session else { throw RPCError.invalidParams("session required") }
        var cwd = s.cwd, wid = worktreeId
        if let w = wid, let wt = try sessions.store.worktree(w) { cwd = wt.path } else {
            let real = URL(fileURLWithPath: s.cwd).resolvingSymlinksInPath().path
            wid = try sessions.store.worktrees().first { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == real }?.id
        }
        guard FileManager.default.fileExists(atPath: cwd) else { throw RPCError.invalidParams("the session's folder no longer exists: \(cwd)") }
        var o = Sessions.Launch(self); o.title = s.title.isEmpty ? "Resumed \(s.agent.rawValue)" : s.title
        var m = try sessions.manifest(s.agent.rawValue, command: nil)
        m.args += Array(History.resumeCommand(for: s).dropFirst())
        return try sessions.spawn(cwd: cwd, manifest: m, worktreeId: wid, o)
    }
}

/// A late one (it was paused or ended since) wakes nothing.
extension SessionHook: Handled {
    var reportsFor: String? { id }
    static var quick: Bool { true }   // the agent waits for its hook
    func handle(_ sessions: Sessions) throws -> Done {
        guard let ls = sessions.existing(id) else {
            try sessions.trail(id)?.add("\(trailLine): nothing runs here")
            return Done()
        }
        if let transcript, !transcript.isEmpty { ls.transcriptPath = transcript; sessions.follow(ls, transcript: transcript) }
        if let cwd, ls.workIn(cwd) != nil { sessions.publish(ls) }
        if let notification, Hooks.isInformational(notification) {
            ls.trail.add("\(trailLine): asks nothing")
            return Done()
        }
        guard let event else { throw RPCError.invalidParams("missing event") }
        if event == "command" {   // a Bash command started or ended: the list and the row, not the status
            if let command, ls.ran(command) != nil { sessions.publish(ls) }
            sessions.touchCommands(ls)
            return Done()
        }
        ls.trail.add(trailLine)
        guard event == "done" else {
            ls.hook(event, trigger: trigger, message: notification.flatMap { Hooks.message($0, alreadyWaiting: ls.snapshot.status == .waiting) })
            return Done()
        }
        if let hit = notification.flatMap(Hooks.limitHit) { ls.hitLimit(hit) }
        let path = ls.transcriptPath
        let goal = path.flatMap(GoalStatus.last(inFile:))
        let (verdict, at) = ls.stop(backgroundTasks ?? [], crons: sessionCrons ?? [], goal: goal)
        switch verdict {
        case .goal: if let path, let goal { Self.watchGoal(ls, path: path, after: goal, stoppedAt: at) }
        case .command: DispatchQueue.global().asyncAfter(deadline: .now() + Self.commandWait) { ls.release(at) }
        case .done, .working: break
        }
        return Done()
    }

    /// What it says, for the session's trail.
    private var trailLine: String { ["hook", event, trigger, notification?["notification_type"]?.string].compactMap { $0 }.joined(separator: " ") }

    /// How long a command the agent waits for may run before its row says done anyway (a server TurnEnd took for a test).
    static let commandWait: TimeInterval = 600

    /// After a Stop with a goal open, Claude Code checks it (a model's answer, seconds): met, the turn is done; not met,
    /// it goes on and stops again. No answer within a minute: done.
    /// Limit: these waits live in this kelpd; one replaced by an update leaves the row working until the agent's next hook.
    static func watchGoal(_ ls: LiveSession, path: String, after: GoalStatus, stoppedAt: Date, tries: Int = 30) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            guard let now = GoalStatus.last(inFile: path), now.id != after.id else {
                if tries > 1 { watchGoal(ls, path: path, after: after, stoppedAt: stoppedAt, tries: tries - 1) } else { ls.release(stoppedAt) }
                return
            }
            if now.met { ls.release(stoppedAt) }
        }
    }
}

extension SessionAnnotate: Handled {
    static var quick: Bool { true }
    /// The window's own reading of a session (its notifier's summary): no agent sets another's status or summary.
    var onlyFromKelp: String? { "Only Kelp's window annotates a session." }
    func handle(_ sessions: Sessions) throws -> Done {
        guard let ls = sessions.existing(id) else { return Done() }
        if let summary { _ = ls.update { $0.summary = summary }; sessions.publish(ls) }
        if let st = status.flatMap(AgentStatus.init(rawValue:)) { ls.overrideStatus(st) }
        return Done()
    }
}

extension RecipeRender: Handled {
    func handle(_ workspaces: Workspaces) throws -> String {
        let w = try workspaces.store.worktree(named: id)
        let cfg = workspaces.trustedConfig(try workspaces.store.repo(w.repoId)?.path ?? w.path)   // the repo's own prompts only once trusted
        var all: [String: String] = ["branch": w.branch, "base": try workspaces.store.repo(w.repoId)?.baseBranch ?? "main"]
        all.merge(vars ?? [:]) { $1 }
        if all["stagedPatch"] == nil {
            all["stagedPatch"] = String(((try? Git.run(["diff", "--cached", "--stat"], cwd: w.path, remotes: workspaces.remotes)) ?? "").prefix(4000))
        }
        return Recipes.render(name, config: cfg, vars: all)
    }
}

extension Ping: Handled {
    static var quick: Bool { true }
    func handle(_: NoService) throws -> String { "pong" }
}
extension DaemonShutdown: Handled {
    /// In order, as daemon.upgrade: the stop starts once its reply is queued, and the replies queued go out before
    /// anyone is hung up (`Daemon.answerInOrder`), not on a timer a busy machine could outrun.
    static var inOrder: Bool { true }
    func handle(_: NoService) throws -> Done { Done() }
}

extension DaemonUpgrade: Handled {
    /// Answered on the reader thread, its reply queued right after: the hand-over (which drains what's queued) starts
    /// once it is, not on a timer that a busy cooperative pool could outrun (`Daemon.serve`).
    static var inOrder: Bool { true }
    func handle(_ upgrade: Upgrade) throws -> Done {
        // Only kelpd itself: a daemon hosted in another program (the tests) would exec that program.
        guard URL(fileURLWithPath: upgrade.executable).lastPathComponent == "kelpd", FileManager.default.isExecutableFile(atPath: upgrade.executable) else {
            throw RPCError.invalidParams("no kelpd to upgrade to at \(upgrade.executable)")
        }
        if let why = upgrade.refused() { throw RPCError.invalidParams(why) }
        // Before the reply, so a refusal reaches the app as this call's error and it asks the user at once, instead of
        // reconnecting to a daemon that stayed. The app waits for this answer; only its own connection is held meanwhile.
        guard Subprocess.allowingPrograms(upgrade.adoptable) else {
            let why = "The new background service can't take the running sessions over."
            Upgrade.refuse(root: upgrade.root, executable: upgrade.executable, why)
            throw RPCError.invalidParams(why)
        }
        upgrade.waitIdle()   // a clone or a worktree being made finishes instead of losing its git mid-way
        return Done()
    }
}

/// daemon.upgrade's: the binary the daemon runs and its exec in place, nothing else of it.
struct Upgrade {
    let executable: String, root: URL
    /// Whether the kelpd at `executable` takes the sessions over (`Handover.adoptable`).
    var adoptable: () -> Bool = { true }
    /// Until no slow work is running (at most a few seconds).
    var waitIdle: () -> Void = {}
    let run: @Sendable () -> Void

    /// Why the binary now at `executable` was refused, as long as it's still that one (same modification time).
    func refused() -> String? {
        guard let data = FileManager.default.contents(atPath: Self.refusal(root).path) else { return nil }   // none refused
        let parts = String(decoding: data, as: UTF8.self).split(separator: "\n", maxSplits: 1).map(String.init)
        return parts.count == 2 && Double(parts[0]) == Self.modified(executable) ? parts[1] : nil
    }
    static func refuse(root: URL, executable: String, _ why: String) {
        Log.start.attempt("keeping why the update was refused") {
            try "\(modified(executable))\n\(why)".write(to: refusal(root), atomically: true, encoding: .utf8)
        }
    }
    private static func refusal(_ root: URL) -> URL { root.appendingPathComponent("upgrade-refused") }
    /// When the file at `path` was last changed (seconds since 1970); 0 when there's none.
    static func modified(_ path: String) -> Double {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    }
}

/// The agents on this Mac, side by side, each through `offload`; latest from npm where they publish there.
extension AgentsVersions: AsyncHandled {
    func handle(_ sessions: Sessions) async throws -> [Item] {
        let manifests = AgentManifest.load(dir: sessions.root.appendingPathComponent("agents"))
        return await withTaskGroup(of: Item?.self) { g in
            for m in manifests {
                g.addTask {
                    try? await sessions.offloads.run { () -> Item? in
                        let path = Sessions.childPath   // the login shell's PATH: the first read waits for the shell
                        guard let exe = try? LoginPath.resolve(m.command) else { return nil }
                        let v = Sessions.run([exe, "--version"], path: path, timeout: 4).flatMap(Sessions.semver)
                        let npm = try? LoginPath.resolve("npm")
                        let latest = m.npm.flatMap { pkg in npm.flatMap { Sessions.run([$0, "view", pkg, "version"], path: path, timeout: 8) } }
                            .flatMap(Sessions.semver)
                        return Item(id: m.id, version: v, latest: latest)
                    }
                }
            }
            var out: [Item] = []
            for await r in g { if let r { out.append(r) } }
            return out
        }
    }
}

extension TaskFromIssue: AsyncHandled {
    func handle(_ work: ForgeWork) async throws -> Result {
        guard let r = try work.workspaces.store.repo(repoId) else { throw RPCError.invalidParams("no repo") }
        let body = body ?? "", url = url ?? ""
        var branch = branch.flatMap { $0.isEmpty ? nil : $0 }
            ?? IssueRef.branchName(ref.hasPrefix("#") ? String(ref.dropFirst()) : ref.lowercased(), title: title)
        if let branchPrefix, !branchPrefix.isEmpty, !branch.hasPrefix(branchPrefix) { branch = branchPrefix + branch }
        let unique = try await work.forges.offloads.run { [branch] in
            var unique = branch, n = 2
            while Git.branchExists(r.path, unique, remotes: work.workspaces.remotes) { unique = "\(branch)-\(n)"; n += 1 }
            return unique
        }
        let created = try await work.forges.offloads.run {
            try WorktreeCreate(repoId: r.id, branch: unique, note: "\(ref) \(title)", tabs: false).handle(work.workspaces)
        }
        // The record, the repo's config and the agent's PTY: disk and a process, through `offload` like the rest.
        let (w, s) = try await work.forges.offloads.run { () throws -> (Worktree, Session) in
            guard let w = try work.workspaces.store.update(Worktree.self, created.worktree.id, {
                $0.issue = ref
                $0.issueURL = url
                $0.linearIssueId = linearId ?? ""
            }) else { throw RPCError.internalError("worktree vanished") }
            let cfg = work.workspaces.trustedConfig(r.path)   // its issueCommand / recipes only once the user trusts the file
            let vars = ["title": title, "body": body, "url": url, "ref": ref, "branch": unique]
            var text = cfg.issueCommand.map { Recipes.fill($0, vars) } ?? Recipes.render("issue", config: cfg, vars: vars)
            if let extra = prompt, !extra.isEmpty { text += "\n\n" + extra }
            var o = Sessions.Launch()
            // Typed, not sent, unless asked: the issue's text is whoever filed it, not the user (it could tell the agent anything).
            o.model = model
            o.effort = effort
            o.profile = profile
            o.draft = draft != false
            o.openURLs = openURLs == true
            (o.cols, o.rows) = Sessions.Launch.size(cols: cols, rows: rows)
            o.prompt = text; o.title = "\(ref) \(title)".prefix(48).description
            return (w, try work.workspaces.sessions.spawn(cwd: w.path, manifest: work.workspaces.sessions.manifest(agent ?? "claude", command: nil),
                                                          worktreeId: w.id, o))
        }
        await work.forges.moveLinear(w, to: .inProgress)
        await work.forges.moveJira(w, toName: "progress", category: "indeterminate")
        work.workspaces.notify(ChangedEvent.worktree)
        // An untrusted .kelp.yaml's setup didn't run: said, as worktree.create says it, so the caller can ask.
        return Result(worktree: w, session: s, setupNeedsTrust: created.setupNeedsTrust == true)
    }
}

extension Methods {
    static let launchMethods: [any Handled.Type] = [SessionCreate.self, TmuxList.self, SessionRestart.self, SessionHandoff.self, HistoryResume.self,
        SessionHook.self, SessionAnnotate.self, RecipeRender.self, Ping.self, DaemonShutdown.self, DaemonUpgrade.self, ProcessRun.self, ProcessWhich.self,
        ProcessRefreshPath.self]
}

extension ProcessRefreshPath: Handled {
    func handle(_: NoService) throws -> Done { LoginPath.reread(); return Done() }   // runs the user's shell: not `quick`, on an offload thread
}

extension ProcessWhich: Handled {
    func handle(_: NoService) throws -> Result {
        Dictionary(commands.compactMap { c in (try? LoginPath.resolve(c)).map { (c, $0) } }) { a, _ in a }
    }
}

extension ProcessRun: Handled {
    func handle(_ sessions: Sessions) throws -> Result {
        guard argv.first?.isEmpty == false else { throw RPCError.invalidParams("Nothing to run.") }
        if let extensionId { try sessions.requireEnabledExtension(extensionId) }
        // What sessions get (PATH with `kelp` on it, this home), minus the markers of whatever started the daemon.
        var env = ProcessInfo.processInfo.environment.filter { k, _ in !PTY.scrubbed.contains { k.hasPrefix($0) } }
        env["PATH"] = Sessions.childPath
        env["KELP_HOME"] = sessions.root.path
        env["KELP_SOCKET"] = sessions.socketPath
        let dir = cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? NSHomeDirectory()
        let r = try Subprocess.run(argv, cwd: dir, env: env, stdin: stdin.map { Data($0.utf8) }, timeLimit: max(0.1, min(timeLimit ?? 60, 86400)),
                                   limit: Self.outputLimit)
        // Not a part as if it were all of it: a formatter's would replace the file's text.
        guard !r.truncated else {
            let name = ((argv.first ?? "") as NSString).lastPathComponent
            throw RPCError.internalError("\(name) printed more than \(Self.outputLimit >> 20) MB, more than Kelp reads.")
        }
        // Lossy on purpose: a tool's output with a stray byte should still show.
        return Result(code: r.status, stdout: String(decoding: r.stdout, as: UTF8.self), stderr: String(decoding: r.stderr, as: UTF8.self),
                      timedOut: r.timedOut)
    }

    /// Of each stream: the reply carries both, JSON-escaped (a control byte takes six), under a connection's `backlogLimit`.
    static let outputLimit = 16 << 20
}

extension Sessions {
    /// An extension's command runs only while that extension is installed and on (Settings › Extensions): a page or a
    /// list left open after turning it off can't run it any more. `id` is its folder's name; the manifest has its id.
    func requireEnabledExtension(_ id: String) throws {
        struct Manifest: Decodable { var id: String; var name: String? }
        // Paths.extensions of this home
        let file = root.appendingPathComponent("extensions").appendingPathComponent(id).appendingPathComponent("extension.json")
        guard !id.isEmpty, (id as NSString).lastPathComponent == id, id != "..", id != ".",
              let data = FileManager.default.contents(atPath: file.path),
              let m = try? JSONDecoder().decode(Manifest.self, from: data) else { throw RPCError.invalidParams("No extension \"\(id)\".") }
        // Limit: unset means none of the user's extensions is off (the app's default-off list names built-ins only).
        let off = Set(settings["extensions.disabled"]?.array?.compactMap(\.string) ?? [])
        guard !off.contains(m.id) else { throw RPCError.invalidParams("The extension “\(m.name ?? m.id)” is turned off.") }
    }
}
