import AgentData
import Agents
import Core
import Foundation
import GitKit
import Integrations

extension SessionCreate: Handled {
    /// Its workspace said, not left to the walk: a session made there would let an agent into it. Where it runs (`cwd`)
    /// wins over `worktreeId`: held to the workspace that holds it. A tmux session by name would attach to one of the
    /// user's (`new-session -A`), and type in it as the agent.
    var fence: Fence {
        Fence(
            inWorkspace: worktreeId, writesInFolder: cwd,
            notForAgents: tmux == nil
                ? nil : "An agent's terminals aren't tmux sessions: tmux sessions are the user's to attach.")
    }
    func handle(_ sessions: Sessions) throws -> Session {
        // cwd wins when both are given (e.g. an agent building an extension, shown in the current workspace).
        var dir = cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        if let worktreeId, dir == nil {
            let worktree = try sessions.store.worktree(named: worktreeId)
            // An agent with no project ("No Project"): a folder of its own for its task, not the shared one.
            let agentHere = tmux == nil && command == nil && !Session.isTerminal(agent)
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
        launch.role = role
        // "swift build", not the program's "Custom"; a prompt names the session itself, and its fresh workspace and branch.
        if launch.title == nil, prompt == nil, let command { launch.title = CommandName.of(command) }
        if let tmux {   // a terminal running tmux: the record keeps the argv that attaches again (Tmux.session)
            let name = Tmux.name(tmux)
            guard !name.isEmpty else { throw RPCError.invalidParams("Name the tmux session.") }
            launch.argv = Tmux.argv(name)
            if launch.title == nil { launch.title = "tmux \(name)" }
        } else if command == nil, Session.isTerminal(agent),
            sessions.settings[SettingKeys.tmux]
        {
            // a terminal in a tmux session of its own, which ends with it (Tmux.isOwn): on a host as an agent's is there,
            // the host's login shell, and without tmux there the shell alone
            if sessions.remotes.of(dir) != nil {
                launch.onHostInTmux = true
            } else if LoginPath.find("tmux") != nil {
                launch.argv = Tmux.argv(Tmux.own())
            }
        }
        return try sessions.spawn(
            cwd: dir,
            manifest: sessions.setup.manifest(
                tmux == nil ? agent : Session.shellAgent, command: tmux == nil ? command : nil),
            worktreeId: worktreeId, launch)
    }
}

extension SessionRestart: Handled {
    var fence: Fence { Fence(actsOn: id) }   // it stops the session, and may brief it anew
    func handle(_ sessions: Sessions) throws -> Session {
        guard try sessions.store.session(id) != nil else { throw RPCError.invalidParams("no session") }
        // It comes back: its children stay, and its parent hears nothing. One restart at a time: a second one meanwhile
        // would find the old record still there and start a second copy of the conversation.
        guard sessions.reports.restarting(id, true) else {
            throw RPCError.invalidParams("It's restarting already: wait for its new tab.")
        }
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
        launch.role = old.role
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
        switch manifest.transcript {
        case .claude?:
            let resumed = SessionRestart.withoutSessionId(
                sessions.setup.resumeArgv(old, manifest), flag: manifest.sessionIdFlag)
            if let argv = manifest.forking(resumed) { return argv }
        case .codex?:
            let file = sessions.agentUsage.conversations.conversationFile(of: old, live: sessions.existing(old.id))
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
        guard let flag = manifest.resumeIdFlag else {
            throw RPCError.invalidParams("\(manifest.name) can't go on with a conversation by its id")
        }
        manifest.args += [flag, session.id]
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
            let stat = Log.session.attempt("git diff --cached --stat for a recipe") {
                try Git.run(["diff", "--cached", "--stat"], cwd: worktree.path, remotes: workspaces.remotes)
            }
            all["stagedPatch"] = String((stat ?? "").prefix(4000))
        }
        return Recipes.render(name, config: cfg, vars: all)
    }
}

/// The agents on this Mac, side by side, each through `offload`; latest from npm where they publish there.
extension AgentsVersions: AsyncHandled {
    func handle(_ sessions: Sessions) async throws -> [Item] {
        let manifests = AgentManifest.load(dir: Paths.agents(in: sessions.root))
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

extension Methods {
    static let launchMethods: [any Answered.Type] = [
        SessionCreate.self, SessionRestart.self, SessionFork.self, SessionHandoff.self, HistoryResume.self,
        RecipeRender.self, AgentsVersions.self, TaskFromIssue.self, SessionMoveAcross.self
    ]
}
