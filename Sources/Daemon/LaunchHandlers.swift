import AgentData
import Agents
import Core
import Foundation
import GitKit
import Integrations

extension SessionCreate: Handled {
    var inWorkspace: String? { worktreeId }   // said, not left to the walk: a session made there would let an agent into it
    /// A tmux session by name would attach to one of the user's (`new-session -A`), and type in it as the agent.
    var notForAgents: String? {
        tmux == nil ? nil : "An agent's terminals aren't tmux sessions: tmux sessions are the user's to attach."
    }
    func handle(_ sessions: Sessions) throws -> Session {
        // cwd wins when both are given (e.g. an agent building an extension, shown in the current workspace).
        var dir = cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        if let worktreeId, dir == nil {
            let worktree = try sessions.store.worktree(named: worktreeId)
            // An agent with no project ("No Project"): a folder of its own for its task, not the shared one.
            let agentHere = tmux == nil && command == nil && agent.map { $0 != "shell" } == true
            dir =
                agentHere && ScratchChats(root: sessions.root).holds(worktree.path)
                ? try ScratchChats(root: sessions.root).newChat() : worktree.path
        }
        guard let dir else { throw RPCError.invalidParams("cwd or worktreeId required") }
        var launch = Sessions.Launch(self)
        // Asked from inside a session, the parent asked for is that one, whatever id was sent (`Callers.caller`).
        let asked = parent.map { Sessions.asker ?? $0 }
        launch.parent = try sessions.parent(asked, of: self)
        launch.startedBy = try sessions.starter(asked, of: self)
        // "swift build", not the program's "Custom"; a prompt names the session itself, and its fresh workspace and branch.
        if launch.title == nil, prompt == nil, let command { launch.title = CommandName.of(command) }
        if let tmux {   // a terminal running tmux: the record keeps the argv that attaches again (Tmux.session)
            let name = Tmux.name(tmux)
            guard !name.isEmpty else { throw RPCError.invalidParams("Name the tmux session.") }
            launch.argv = Tmux.argv(name)
            if launch.title == nil { launch.title = "tmux \(name)" }
        } else if command == nil, (agent ?? "shell") == "shell", sessions.settings[SettingKeys.tmux],
            sessions.remotes.of(dir) != nil || LoginPath.find("tmux") != nil
        {
            // a terminal in a tmux session of its own, which ends with it (Tmux.isOwn)
            launch.argv = Tmux.argv(Tmux.own())
        }
        return try sessions.spawn(
            cwd: dir,
            manifest: sessions.setup.manifest(tmux == nil ? agent : "shell", command: tmux == nil ? command : nil),
            worktreeId: worktreeId, launch)
    }
}

extension SessionRestart: Handled {
    var actsOn: String? { id }   // it stops the session, and may brief it anew
    func handle(_ sessions: Sessions) throws -> Session {
        guard try sessions.store.session(id) != nil else { throw RPCError.invalidParams("no session") }
        sessions.reports.restarting(id, true)   // it comes back: its children stay, and its parent hears nothing
        defer { sessions.reports.restarting(id, false) }
        // One copy of the conversation at a time: the resumed agent starts once the old one is gone (SIGKILL after 2 s).
        // Under its wake lock, and a paused one marked ended there: a tab opening it meanwhile can't wake a second copy.
        // If the new one can't start, the old one still ends as Ended. The record is read there, as it is then (a rename
        // just before is kept, in it and in the new session's title).
        var owed: [OwedInput] = []
        let old: Session = try sessions.wakeLocks.withLock(id) {
            if let ls = sessions.existing(id) {
                owed = ls.takeOwed()   // from here on it may be gone from `live` at any moment
                Sessions.waitGone(ls.pty.terminate())
            } else {
                try sessions.store.update(Session.self, id) { if $0.status == .paused { $0.status = .exited } }
            }
            guard let session = try sessions.store.session(id) else { throw RPCError.invalidParams("no session") }
            return session
        }
        do {
            return try start(after: old, sessions, owed: owed)
        } catch {
            sessions.restartFailed(id)
            throw error
        }
    }

    private func start(after old: Session, _ sessions: Sessions, owed: [OwedInput]) throws -> Session {
        let manifest = try sessions.setup.manifest(old.agent, command: nil, fallbackArgv: old.argv)
        var launch = Sessions.Launch(self)
        launch.title = old.titleManual ? old.title : nil
        launch.parent = old.parent
        launch.startedBy = old.startedBy
        launch.origin = old.origin
        if launch.profile == nil { launch.profile = old.profile }   // the same account unless told otherwise
        // A remote agent still running in its tmux session on the host: the new tab attaches to it (after a dropped
        // connection, that's all a restart is), so there's still one copy. Starting afresh ends it.
        if resume != false { launch.tmux = old.tmux }
        // The new session pins an id of its own, never the old one's.
        launch.argv = Self.withoutSessionId(
            resume != false ? sessions.setup.resumeArgv(old, manifest) : old.argv, flag: manifest.sessionIdFlag)
        let session = try sessions.spawn(cwd: old.cwd, manifest: manifest, worktreeId: old.worktreeId, launch)
        try sessions.passChildren(of: old.id, to: session.id, owed: owed)
        sessions.discard(old, keepTmux: old.tmux == nil || resume != false)   // its exit, still to come, doesn't save it again
        return session
    }

    /// argv without `--session-id <id>`: two sessions can't share an id (Claude Code refuses one already used).
    static func withoutSessionId(_ argv: [String], flag: String?) -> [String] {
        guard let flag, let index = argv.firstIndex(of: flag) else { return argv }
        var stripped = argv
        stripped.removeSubrange(index...min(index + 1, stripped.count - 1))
        return stripped
    }
}

extension SessionFork: Handled {
    func handle(_ sessions: Sessions) throws -> Session {
        guard let old = try sessions.store.session(id) else { throw RPCError.invalidParams("no session") }
        if sessions.remotes.of(old.cwd) != nil {
            throw RPCError.invalidParams("Fork isn't available for remote projects yet.")
        }
        let manifest = try sessions.setup.manifest(old.agent, command: nil, fallbackArgv: old.argv)
        var launch = Sessions.Launch()
        launch.argv = try Self.argv(old, manifest, sessions)
        launch.title = (old.title.isEmpty ? manifest.name : old.title) + " (fork)"
        launch.profile = old.profile   // the same account: its conversations are there
        if let cols, let rows, cols > 0, rows > 0 { (launch.cols, launch.rows) = (UInt16(cols), UInt16(rows)) }
        return try sessions.spawn(cwd: old.cwd, manifest: manifest, worktreeId: old.worktreeId, launch)
    }

    /// Its command, going on from a copy of the conversation. Claude Code's pins one id, which the copy may not take
    /// (`following` pins the copy's once it's made); Codex's thread id ends its rollout's name.
    static func argv(_ old: Session, _ manifest: AgentManifest, _ sessions: Sessions) throws -> [String] {
        switch old.agent {
        case "claude":
            let resumed = SessionRestart.withoutSessionId(
                sessions.setup.resumeArgv(old, manifest), flag: manifest.sessionIdFlag)
            if let argv = manifest.forking(resumed) { return argv }
        case "codex":
            let file = sessions.agentUsage.conversationFile(of: old, live: sessions.existing(old.id))
            if let id = file.map({ String($0.deletingPathExtension().lastPathComponent.suffix(36)) }),
                UUID(uuidString: id) != nil
            {
                return old.argv.prefix { $0 != "resume" && $0 != "fork" } + ["fork", id]
            }
        default: break
        }
        throw RPCError.invalidParams("\(manifest.name) has no conversation to fork yet.")
    }
}

extension SessionHandoff: Handled {
    func handle(_ sessions: Sessions) throws -> Session {
        guard let old = try sessions.store.session(id) else { throw RPCError.invalidParams("no session") }
        // The brief is a file on this Mac: an agent on a remote host couldn't read it.
        if sessions.remotes.of(old.cwd) != nil {
            throw RPCError.invalidParams("Handoff isn't available for remote projects yet.")
        }
        let target = agent ?? old.agent
        var manifest = try sessions.setup.manifest(target, command: nil)
        let file = sessions.agentUsage.conversationFile(of: old, live: sessions.existing(old.id))
        let conversation = file.flatMap(Conversation.init(file:))
        let uncommitted = Self.uncommitted(old.cwd, sessions)
        let ask = prompt ?? "Continue the task where the previous agent left off."
        var launch = Sessions.Launch(self)
        launch.title = (old.title.isEmpty ? (old.agent ?? "agent") : old.title) + " (handoff)"
        if let opened = try native(old, file: file, conversation, uncommitted: uncommitted, sessions) {
            manifest.args += opened
            launch.prompt = ask
        } else {
            let brief = try Self.brief(of: old, conversation, limit: limit, uncommitted: uncommitted, sessions)
            launch.prompt = "Read \(brief.path) — the transcript of the previous agent session in this project. " + ask
        }
        return try sessions.spawn(cwd: old.cwd, manifest: manifest, worktreeId: old.worktreeId, launch)
    }

    private var limit: Int { full == true ? 400_000 : 40_000 }

    /// What `agent` starts with to open the conversation as its own; nil when it can't, and it reads the brief instead.
    /// Codex imports a Claude Code transcript itself, as a thread it resumes (only into the default account: another
    /// account's Codex wouldn't find it). pi and oh-my-pi open a session of theirs Kelp writes, which they go on in.
    private func native(
        _ old: Session, file: URL?, _ conversation: Conversation?, uncommitted: String, _ sessions: Sessions
    ) throws -> [String]? {
        switch agent ?? old.agent {
        case "codex" where old.agent == "claude" && profile == nil:
            return file.flatMap { sessions.agentUsage.codexThread(importing: $0, cwd: old.cwd) }.map { ["resume", $0] }
        case let target? where target == "pi" || target == "omp":
            guard let conversation else { return nil }
            let session = try conversation.piSession(
                cwd: old.cwd, agent: old.agent ?? "agent", limit: limit, uncommitted: uncommitted)
            // One per hand-off: the agent writes on in it, and an earlier one may still be open.
            let path = try Self.handoffFile("\(old.id)-\(UUID().uuidString.prefix(8).lowercased()).jsonl", sessions)
            try session.write(to: path, atomically: true, encoding: .utf8)
            return [target == "pi" ? "--session" : "--resume", path.path]
        default: return nil
        }
    }

    /// A session's conversation written to ~/.kelp/handoff/<id>.md for the next agent to read: the agent's own
    /// (what was asked and answered, what it changed and ran: Claude Code, Codex, pi) when there is one; otherwise the
    /// terminal's text. Both with what git says is uncommitted.
    private static func brief(
        of session: Session, _ conversation: Conversation?, limit: Int, uncommitted: String, _ sessions: Sessions
    ) throws -> URL {
        let body: String
        if let conversation {
            body = conversation.markdown(limit: limit, uncommitted: uncommitted)
        } else {
            let printed = try sessions.liveSessionOrLog(session.id, bytes: limit)
            // Lossy on purpose, see session.context.
            // swiftlint:disable:next optional_data_string_conversion
            body = [
                "```\n" + StatusDetector.stripANSI(String(decoding: printed, as: UTF8.self)) + "\n```",
                Conversation().notes(uncommitted: uncommitted)
            ].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        let file = try handoffFile("\(session.id).md", sessions)
        try ("# Previous session (\(session.agent ?? "agent"), \(session.cwd))\n\n" + body + "\n").write(
            to: file, atomically: true, encoding: .utf8)
        return file
    }

    private static func handoffFile(_ name: String, _ sessions: Sessions) throws -> URL {
        let dir = sessions.root.appendingPathComponent("handoff")
        try Paths.ensure(dir)
        return dir.appendingPathComponent(name)
    }

    /// `git status --short` in `cwd`, its first 60 lines.
    private static func uncommitted(_ cwd: String, _ sessions: Sessions) -> String {
        do {
            let status = try Git.run(["status", "--short"], cwd: cwd, remotes: sessions.remotes)
            return status.split(separator: "\n").prefix(60).joined(separator: "\n")
        } catch {
            return ""   // not a repository: nothing to say
        }
    }
}

extension HistoryResume: Handled {
    func handle(_ sessions: Sessions) throws -> Session {
        guard let session else { throw RPCError.invalidParams("session required") }
        let (cwd, wid) = try sessions.setup.resumePlace(session.cwd, worktreeId: worktreeId)
        guard FileManager.default.fileExists(atPath: cwd) else {
            throw RPCError.invalidParams("the session's folder no longer exists: \(cwd)")
        }
        var launch = Sessions.Launch(self)
        launch.title = session.title.isEmpty ? "Resumed \(session.agent.rawValue)" : session.title
        var manifest = try sessions.setup.manifest(session.agent.rawValue, command: nil)
        manifest.args += Array(History.resumeCommand(for: session).dropFirst())
        return try sessions.spawn(cwd: cwd, manifest: manifest, worktreeId: wid, launch)
    }
}

extension SessionSetup {
    /// Where a conversation from History goes on: `worktreeId`'s folder, else the folder it was in, on the workspace there.
    /// A chat with no project stays in its own folder (the agent finds its conversation by it), made again if it was swept
    /// empty, and on the No Project row.
    func resumePlace(_ was: String, worktreeId: String?) throws -> (cwd: String, worktreeId: String?) {
        let scratch = ScratchChats(root: root)
        if scratch.isChat(was) {
            try FileManager.default.createDirectory(atPath: was, withIntermediateDirectories: true)
            return (was, try store.worktrees().first { scratch.holds($0.path) }?.id)
        }
        if let worktreeId, let worktree = try store.worktree(worktreeId) { return (worktree.path, worktreeId) }
        let real = URL(fileURLWithPath: was).resolvingSymlinksInPath().path
        return (
            was,
            try store.worktrees().first { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == real }?.id
        )
    }
}

extension RecipeRender: Handled {
    func handle(_ workspaces: Workspaces) throws -> String {
        let worktree = try workspaces.store.worktree(named: id)
        // the repo's own prompts only once trusted
        let cfg = workspaces.trustedConfig(try workspaces.store.repo(worktree.repoId)?.path ?? worktree.path)
        var all: [String: String] = [
            "branch": worktree.branch, "base": try workspaces.store.repo(worktree.repoId)?.baseBranch ?? "main"
        ]
        all.merge(vars ?? [:]) { $1 }
        if all["stagedPatch"] == nil {
            all["stagedPatch"] = String(
                ((try? Git.run(["diff", "--cached", "--stat"], cwd: worktree.path, remotes: workspaces.remotes)) ?? "")
                    .prefix(
                        4000))
        }
        return Recipes.render(name, config: cfg, vars: all)
    }
}

/// The agents on this Mac, side by side, each through `offload`; latest from npm where they publish there.
extension AgentsVersions: AsyncHandled {
    func handle(_ sessions: Sessions) async throws -> [Item] {
        let manifests = AgentManifest.load(dir: sessions.root.appendingPathComponent("agents"))
        return await withTaskGroup(of: Item?.self) { group in
            for manifest in manifests {
                group.addTask {
                    try? await sessions.offloads.run { () -> Item? in
                        let path = Sessions.childPath   // the login shell's PATH: the first read waits for the shell
                        guard let exe = LoginPath.find(manifest.command) else { return nil }
                        let version = Subprocess.printed([exe, "--version"], path: path, timeout: 4).flatMap(
                            Self.semver)
                        let npm = LoginPath.find("npm")
                        let latest = manifest.npm.flatMap { pkg in
                            npm.flatMap { Subprocess.printed([$0, "view", pkg, "version"], path: path, timeout: 8) }
                        }
                        .flatMap(Self.semver)
                        return Item(id: manifest.id, version: version, latest: latest)
                    }
                }
            }
            var out: [Item] = []
            for await item in group { if let item { out.append(item) } }
            return out
        }
    }

    /// "claude 2.1.3 (Claude Code)" → "2.1.3".
    static func semver(_ output: String) -> String? { output.firstMatch(of: /\d+\.\d+\.\d+/).map { String($0.output) } }
}

extension TaskFromIssue: AsyncHandled {
    func handle(_ work: ForgeWork) async throws -> Result {
        guard let repo = try work.workspaces.store.repo(repoId) else { throw RPCError.invalidParams("no repo") }
        let body = body ?? "", url = url ?? ""
        var branch =
            branch.flatMap { $0.isEmpty ? nil : $0 }
            ?? IssueRef.branchName(ref.hasPrefix("#") ? String(ref.dropFirst()) : ref.lowercased(), title: title)
        let prefix = branchPrefix ?? work.workspaces.sessions.branchPrefix
        if !prefix.isEmpty, !branch.hasPrefix(prefix) { branch = prefix + branch }
        let unique = try await work.forges.offloads.run { [branch] in
            var unique = branch, number = 2
            while Git.branchExists(repo.path, unique, remotes: work.workspaces.remotes) {
                unique = "\(branch)-\(number)"
                number += 1
            }
            return unique
        }
        let created = try await work.forges.offloads.run {
            try work.workspaces.createBranchWorkspace(
                in: repo, WorktreeCreate(repoId: repo.id, branch: unique, note: "\(ref) \(title)", tabs: false))
        }
        // The record, the repo's config and the agent's PTY: disk and a process, through `offload` like the rest.
        let (worktree, session) = try await work.forges.offloads.run { () throws -> (Worktree, Session) in
            guard
                let updated = try work.workspaces.store.update(
                    Worktree.self, created.worktree.id,
                    {
                        $0.issue = ref
                        $0.issueURL = url
                        $0.linearIssueId = linearId ?? ""
                    })
            else { throw RPCError.internalError("worktree vanished") }
            // its issueCommand / recipes only once the user trusts the file
            let cfg = work.workspaces.trustedConfig(repo.path)
            let vars = ["title": title, "body": body, "url": url, "ref": ref, "branch": unique]
            var text =
                cfg.issueCommand.map { Recipes.fill($0, Recipes.framed(vars)) }
                ?? Recipes.render("issue", config: cfg, vars: vars)
            if let extra = prompt, !extra.isEmpty { text += "\n\n" + extra }
            var launch = Sessions.Launch()
            // Typed, not sent, unless asked: the issue's text is whoever filed it, not the user (it could tell the agent anything).
            launch.model = model
            launch.effort = effort
            launch.profile = profile
            launch.draft = draft != false
            launch.openURLs = openURLs == true
            (launch.cols, launch.rows) = Sessions.Launch.size(cols: cols, rows: rows)
            launch.prompt = text
            launch.title = "\(ref) \(title)".prefix(48).description
            return (
                updated,
                try work.workspaces.sessions.spawn(
                    cwd: updated.path,
                    manifest: work.workspaces.sessions.setup.manifest(agent ?? "claude", command: nil),
                    worktreeId: updated.id, launch)
            )
        }
        await work.forges.moveLinear(worktree, to: .inProgress)
        await work.forges.moveJira(worktree, toName: "progress", category: "indeterminate")
        work.workspaces.notify(ChangedEvent.worktree)
        // An untrusted .kelp.yaml's setup didn't run: said, as worktree.create says it, so the caller can ask.
        return Result(worktree: worktree, session: session, setupNeedsTrust: created.setupNeedsTrust == true)
    }
}

extension Methods {
    static let launchMethods: [any Handled.Type] = [
        SessionCreate.self, TmuxList.self, SessionRestart.self, SessionHandoff.self, SessionFork.self,
        HistoryResume.self,
        SessionHook.self, SessionAnnotate.self, RecipeRender.self, Ping.self, DaemonShutdown.self, DaemonUpgrade.self,
        ProcessRun.self, ProcessWhich.self,
        ProcessRefreshPath.self, SkillsBrowser.self
    ]
}
