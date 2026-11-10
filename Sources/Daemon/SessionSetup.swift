import AgentData
import Agents
import Core
import Foundation
import os

/// What a session starts with: its agent's manifest, the command line that runs it (here or over ssh), its environment,
/// account and hooks, the trust question answered for it, the conversation it resumes, Kelp's skills (SessionSkills.swift)
/// and what Claude Code's /context counts (ClaudeSetup.swift). Made once by `Sessions`, which starts, wakes and takes
/// over the sessions with it; it holds no session itself.
final class SessionSetup: Sendable {
    let root: URL
    let socketPath: String
    let store: Store
    let settings: SettingsStore
    let remotes: Remotes
    let agentUsage: AgentUsage   // where the agents keep their conversations
    /// What Claude Code's /context counted, by folder and flags, and when (`claudeSetup`).
    let contextSetups = OSAllocatedUnfairLock<[String: (at: Date, setup: SessionContextParts.Setup?)]>(initialState: [:]
    )
    /// Whether this Codex takes Kelp's hooks (`CodexHooks`), once per binary.
    let codexHooks = CodexHookCheck()

    init(
        root: URL, socketPath: String, store: Store, settings: SettingsStore, remotes: Remotes, agentUsage: AgentUsage
    ) {
        self.root = root
        self.socketPath = socketPath
        self.store = store
        self.settings = settings
        self.remotes = remotes
        self.agentUsage = agentUsage
    }

    /// What runs: `argv` itself, or for a remote project ssh running it in the project's folder on the host. Records
    /// keep the plain argv, so a restart or a wake wraps it once (older records kept the ssh line: that runs as it is).
    func launchArgv(_ argv: [String], cwd: String, manifest: AgentManifest, tmux: String? = nil) throws -> [String] {
        var run = argv
        if let remote = remotes.of(cwd), argv.first != remote.ssh {
            // A command line (`.custom`: zsh -lc "…") goes to sh there: the host may have no zsh.
            var onHost = manifest.id == "custom" && argv.count == 3 && argv[1] == "-lc" ? ["sh", "-c", argv[2]] : argv
            // Here, not in the record: every start gets this kelpd's, and a title or a restart never sees it.
            if tmux != nil, case .settingsFlag(let flag)? = manifest.hooks, !onHost.contains(flag) {
                onHost += [flag, try Hooks.hostSettingsJSON()]
            }
            if tmux != nil, manifest.hooks == .codexConfig, !onHost.isEmpty, codexHooks.agrees(on: remote) {
                onHost.insert(contentsOf: CodexHooks.hostArgs, at: 1)
            }
            let loginShell = manifest.id == "shell" && Tmux.session(argv) == nil
            let command = tmux.map { remote.command(onHost, inTmux: $0) } ?? remote.command(loginShell ? nil : onHost)
            run = [remote.ssh] + remote.sshArgs(tty: true) + [command]
        }
        guard let exe = run.first else { throw RPCError.invalidParams("empty command") }
        let resolved = try LoginPath.resolve(exe)
        // Codex's hooks: here, not in the record, as the host's are, so a wake gets this kelpd's.
        let hooks = tmux == nil && codexHooksOn(manifest, argv: argv, cwd: cwd) ? CodexHooks.args : []
        return [resolved] + hooks + run.dropFirst()
    }

    /// A local Codex that agrees on Kelp's hooks gets them on its command line (`CodexHookCheck`).
    func codexHooksOn(_ manifest: AgentManifest, argv: [String], cwd: String) -> Bool {
        guard manifest.hooks == .codexConfig, remotes.of(cwd) == nil, let exe = argv.first else { return false }
        // Not found: it won't start either.
        do { return codexHooks.agrees(try LoginPath.resolve(exe)) } catch { return false }
    }

    /// One place for a session's environment, used to start it and to wake it: the account profile it was started with
    /// comes back with it (it used to be dropped on wake and restart, so the session returned on the default login).
    func launchEnv(_ manifest: AgentManifest, _ rec: Session) -> [String: String] {
        var env = hookedEnv(manifest, rec)
        env["PATH"] = Sessions.childPath
        return env
    }

    /// `launchEnv` without its PATH, whose first read waits for the login shell (seconds, up to 8): what taking a running
    /// session over needs, which happens before this kelpd answers anyone.
    /// `secrets`: read from the keychain, which can wait for a locked login. Not for a running program, whose environment is
    /// long set: nobody is served while kelpd takes sessions over.
    func hookedEnv(_ manifest: AgentManifest, _ rec: Session, secrets: Bool = true) -> [String: String] {
        var env = secrets ? manifest.resolvedEnv : manifest.env
        if let name = rec.profile, let prof = profile(name, agent: manifest.id) { env[prof.key] = prof.dir }
        // Not into tmux: its server keeps the first client's environment for every pane, whichever tab they're shown in.
        if Tmux.session(rec.argv) == nil { env["KELP_SESSION"] = rec.id }
        if let editor = promptEditor(manifest, rec, given: env["VISUAL"]) { env["VISUAL"] = editor }
        env["KELP_SOCKET"] = socketPath
        env["KELP_HOME"] = root.path
        if env["KELP_PORT"] == nil, let port = Log.store.attempt("a folder's ports", { try portBlock(rec) }) {
            env["KELP_PORT"] = String(port)
        }
        // Written at each start and wake, so a session woken after an update gets this kelpd's hooks.
        if remotes.of(rec.cwd) == nil, let transport = manifest.hooks { wire(transport, manifest, rec, &env) }
        return env
    }

    /// The first of the session's folder's ten ports (`PortBlocks`).
    private func portBlock(_ rec: Session) throws -> Int {
        let all = try store.worktrees()
        let folder = rec.worktreeId.flatMap { id in all.first { $0.id == id }?.path } ?? rec.cwd
        return PortBlocks.port(for: folder, among: all.map(\.path))
    }

    /// A long prompt, handed to the agent's external editor (Ctrl+G), opens in a Kelp tab: only the name, since agents split
    /// the string at spaces. Not for a shell, which has no prompt to hand over, nor on a host, which has no `kelp`.
    private func promptEditor(_ manifest: AgentManifest, _ rec: Session, given: String?) -> String? {
        let mine = given ?? ProcessInfo.processInfo.environment["VISUAL"]
        guard mine == nil, manifest.id != "shell", remotes.of(rec.cwd) == nil, Tmux.session(rec.argv) == nil,
            settings[SettingKeys.editInKelp]
        else { return nil }
        return "kelp edit --wait"
    }

    /// Kelp's plugin dir for an agent; its hooks file is this with ".json".
    func hooksDir(_ manifest: AgentManifest) -> URL { root.appendingPathComponent("hooks-\(manifest.id)") }

    /// What `transport` needs in the environment. A variable the user set themselves stays theirs, and the hooks aren't
    /// wired (`wiredHooks`); `.settingsFlag` is on the command line (`spawn`).
    private func wire(
        _ transport: HookTransport, _ manifest: AgentManifest, _ rec: Session, _ env: inout [String: String]
    ) {
        let dir = hooksDir(manifest), file = dir.appendingPathExtension("json")
        if let key = transport.env, env[key] != nil { return }
        do {
            switch transport {
            case .settingsFlag, .codexConfig: break
            case .pluginDir(let key):
                try Hooks.writePlugin(dir: dir)
                env[key] = dir.path
            case .settingsFile(let key, let base):
                try base.map { try Hooks.writeSettings(to: file, over: URL(fileURLWithPath: $0)) }
                    ?? Hooks.writeSettings(to: file)
                env[key] = file.path
            case .herdr:
                env["HERDR_SOCKET_PATH"] = socketPath
                env["HERDR_PANE_ID"] = rec.id
            }
        } catch {
            Log.session.error("\(manifest.id, privacy: .public)'s hooks weren't written, its screen is read: \(error)")
        }
    }

    /// Where a session's Claude conversations are: under its profile's config dir when it has one.
    func claudeProjects(_ rec: Session) -> URL {
        rec.profile.flatMap { profile($0, agent: "claude") }.map {
            URL(fileURLWithPath: $0.dir).appendingPathComponent("projects")
        }
            ?? agentUsage.conversations.homes.withLock { $0 }.claude
    }

    /// Account profiles keep each agent login in its own config dir: switching needs no re-login.
    static let configDirEnv = ["claude": "CLAUDE_CONFIG_DIR", "codex": "CODEX_HOME"]
    func profile(_ name: String, agent: String) -> (key: String, dir: String)? {
        guard let key = Self.configDirEnv[agent] else { return nil }
        for entry in settings[SettingKeys.accounts]
        where entry["name"]?.string == name && entry["agent"]?.string == agent {
            if let dir = entry["dir"]?.string {
                Log.session.attempt("making profile \(name)'s folder") {
                    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                }
                return (key, dir)
            }
        }
        return nil
    }

    /// The manifest its live session reads: with the hooks this launch wired, or none.
    func liveManifest(
        _ manifest: AgentManifest, cwd: String, worktreeId: String?, env: [String: String], argv: [String]
    )
        -> AgentManifest
    {
        wiredHooks(trustAnswered(manifest, cwd: cwd, worktreeId: worktreeId, env: env), env: env, argv: argv, cwd: cwd)
    }

    /// Only hooks this launch really wired report: not a remote session's (Kelp's files are on this Mac), nor one whose
    /// variable the user set themselves, whose file couldn't be written, or whose flag a custom command line left out.
    /// Those have their screen read instead. `cwd`: where it starts now; nil for one taken over running, whose Codex
    /// may have started under a kelpd that gave it none.
    func wiredHooks(_ manifest: AgentManifest, env: [String: String], argv: [String], cwd: String? = nil)
        -> AgentManifest
    {
        let dir = hooksDir(manifest)
        let wired =
            switch manifest.hooks {
            case .settingsFlag(let flag)?: argv.contains { $0 == flag || $0.hasPrefix(flag + "=") }
            case .pluginDir(let key)?: env[key] == dir.path
            case .settingsFile(let key, _)?: env[key] == dir.appendingPathExtension("json").path
            case .herdr?: env["HERDR_PANE_ID"] != nil
            case .codexConfig?: cwd.map { codexHooksOn(manifest, argv: argv, cwd: $0) } ?? false
            case nil: false
            }
        var out = manifest
        if !wired { out.hooks = nil }
        return out
    }

    /// The agent's "trust this folder?" is answered by Kelp only when that question is actually coming and the user already
    /// settled it: the agent doesn't trust the session's folder yet (else it asks nothing, and an armed answer could only
    /// ever press a different menu) but does trust the project's main checkout. Anything else, including a repository it
    /// has never seen or one on a remote host, is the user's to answer.
    func trustAnswered(_ manifest: AgentManifest, cwd: String, worktreeId: String?, env: [String: String])
        -> AgentManifest
    {
        guard manifest.autoAnswers.contains(AgentManifest.trust) else { return manifest }
        var out = manifest
        out.autoAnswers.removeAll { $0 == AgentManifest.trust }
        // A remote project's question is always the user's: decided before any git (over ssh, under its wake lock, for a host
        // that may not answer).
        guard remotes.of(cwd) == nil else { return out }
        // The project only counts for its own workspace's folder: any other cwd passed with its worktreeId is just a folder.
        // (A workspace on another branch of a trusted project is trusted the way Claude trusts a folder, whatever is checked
        // out in it.)
        var project: String?
        if let wid = worktreeId, let worktree = store.look("workspace \(wid)", { try $0.worktree(wid) }),
            let repo = store.look("project \(worktree.repoId)", { try $0.repo(worktree.repoId) }),
            Paths.inside(cwd, worktree.path),
            !AgentConfig.changed(worktree.path, base: repo.baseBranch, remotes: remotes)
        {
            project = repo.path
        }
        // The config the agent will read: the session's variables over the daemon's own (a kelpd started from a shell
        // passes on that shell's CLAUDE_CONFIG_DIR), as PTY builds its environment.
        let env = ProcessInfo.processInfo.environment.merging(env) { $1 }
        // A chat's own empty folder that Kelp just made for it ("No Project") has nothing in it the question guards.
        let expectedAndSettled =
            !AgentTrust.trusts(agent: manifest.id, folders: [cwd], env: env)
            && (project.map { AgentTrust.trusts(agent: manifest.id, folders: [$0], env: env) } == true
                || ScratchChats(root: root).isFresh(cwd))
        return expectedAndSettled ? manifest : out
    }

    /// argv that brings back this session's own conversation. A remote one's conversations are on its host: the agent's
    /// own "latest in this folder" finds it there.
    func resumeArgv(_ rec: Session, _ manifest: AgentManifest) -> [String] {
        guard rec.agent == "claude", remotes.of(rec.cwd) == nil, let flag = manifest.resumeIdFlag,
            let pin = manifest.sessionIdFlag
        else { return manifest.resuming(rec.argv) }
        if let index = rec.argv.firstIndex(of: flag) {
            // Nothing was typed in the session this forks (`HomeSeed`): no conversation to copy, a new one of its own.
            if rec.argv.contains("--fork-session"), let id = rec.argv.dropFirst(index + 1).first,
                ClaudeHistory.session(id: id, cwd: rec.cwd, root: claudeProjects(rec)) == nil
            {
                return manifest.following(rec.argv, conversation: UUID().uuidString.lowercased())
            }
            return rec.argv
        }
        if let index = rec.argv.firstIndex(of: pin), index + 1 < rec.argv.count {
            // Pinned but nothing typed yet: no conversation to resume, start it under the same id.
            return ClaudeHistory.session(id: rec.argv[index + 1], cwd: rec.cwd, root: claudeProjects(rec)) != nil
                ? manifest.resuming(rec.argv) : rec.argv
        }
        let conversations = ClaudeHistory.sessions(cwd: rec.cwd, root: claudeProjects(rec))
        // From before ids were pinned (or restarted with "latest in this folder", which hands it another agent's
        // conversation): the first conversation that started here between this session and the next one, unless another
        // session has it; none → start fresh. Limit: misses prompts typed out of order across sessions.
        let base = rec.argv.filter { !manifest.resumeArgs.contains($0) }
        let all = store.look("the sessions") { try $0.sessions() } ?? []
        let claimed = Set(
            all.filter { $0.id != rec.id }.flatMap { other in
                other.argv.indices.dropLast().filter { [pin, flag].contains(other.argv[$0]) }.map {
                    other.argv[$0 + 1].lowercased()
                }
            })
        let next =
            all.filter { $0.agent == "claude" && $0.cwd == rec.cwd && $0.createdAt > rec.createdAt }.map(\.createdAt)
            .min() ?? .distantFuture
        let own =
            conversations
            .filter {
                $0.started >= rec.createdAt.addingTimeInterval(-2) && $0.started < next
                    && !claimed.contains($0.id.lowercased())
            }
            .min { $0.started < $1.started }
        return own.map { base + [flag, $0.id] } ?? base
    }

    func manifest(_ id: String?, command: String?, fallbackArgv: [String]? = nil) throws -> AgentManifest {
        if let command { return .custom(command) }
        if id == "custom", let argv = fallbackArgv {
            return .init(id: "custom", name: "Custom", command: argv.first ?? "/bin/zsh", args: Array(argv.dropFirst()))
        }
        let id = id ?? "shell"
        // A plain shell has no meaningful "done": keep the heuristic quiet.
        if id == "shell" {
            return .init(
                id: "shell", name: "Shell", command: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
                args: ["-l"], quietSeconds: 1e9)
        }
        guard
            let manifest = AgentManifest.load(dir: root.appendingPathComponent("agents")).first(where: { $0.id == id })
        else {
            throw RPCError.invalidParams("unknown agent \(id)")
        }
        return manifest
    }
}
