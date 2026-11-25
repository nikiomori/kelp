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
    let openCode2 = OpenCode2()
    /// `kelp browser` for agents on a host (HostBrowser.swift), with the ports brought from hosts it shares.
    let hostBrowser: HostBrowser

    init(
        root: URL, socketPath: String, store: Store, settings: SettingsStore, remotes: Remotes, agentUsage: AgentUsage
    ) {
        self.root = root
        self.socketPath = socketPath
        self.store = store
        self.settings = settings
        self.remotes = remotes
        self.agentUsage = agentUsage
        hostBrowser = HostBrowser(root: root, remotes: remotes, forwards: Forwards(store: store), store: store)
    }

    /// The command line that runs: `argv` itself, or for a remote project, ssh running it in the project's folder on
    /// the host. Records keep the plain argv, so a restart or a wake wraps it once (older records kept the ssh line,
    /// which runs as it is).
    /// An agent on a host gets `kelp browser` there (`hostBrowsing`), set up anew at each start and attach.
    func launchArgv(
        _ argv: [String], cwd: String, manifest: AgentManifest, tmux: String? = nil, env: [String: String] = [:]
    ) throws -> [String] {
        var run = argv
        if let remote = remotes.of(cwd), argv.first != remote.ssh {
            var (own, secret) = Self.hostEnv(manifest, env)
            let envFile = try Self.sendEnv(secret, to: remote)
            // A command line (`.custom`: zsh -lc "…") goes to sh there, because the host may have no zsh.
            var onHost = Session.customCommand(agent: manifest.id, argv).map { ["sh", "-c", $0] } ?? argv
            // Added here, not in the record, so every start gets this kelpd's hook settings, and a title or a restart
            // never sees them.
            if tmux != nil, case .settingsFlag(let flag)? = manifest.hooks, !onHost.contains(flag) {
                onHost += [flag, try Hooks.hostSettingsJSON()]
            }
            if tmux != nil, manifest.hooks == .codexConfig, !onHost.isEmpty, codexHooks.agrees(on: remote) {
                onHost.insert(contentsOf: CodexHooks.hostArgs, at: 1)
            }
            if HostBrowser.wanted(manifest, tmux: tmux), let session = env["KELP_SESSION"],
                let browsing = hostBrowsing(session, cwd: cwd, remote)
            {
                onHost = Self.withHostKelp(onHost, &own, browsing, flag: manifest.pluginDirFlag)
            }
            let loginShell = manifest.id == Session.shellAgent && Tmux.session(argv) == nil
            let command =
                tmux.map { remote.command(loginShell ? [] : onHost, inTmux: $0, envFile: envFile, exports: own) }
                ?? remote.command(loginShell ? nil : onHost, envFile: envFile, exports: own)
            run = [remote.ssh] + remote.sshArgs(tty: true) + [command]
        }
        let box = run == argv ? devContainer(cwd) : nil
        if let box {
            let (own, secret) = Self.hostEnv(manifest, env)
            run = DevContainer.wrap(
                try DevContainer.inside(argv, manifest), cwd: cwd, in: box,
                readOnly: DevContainer.named(in: argv), env: Array(own.keys) + Array(secret.keys))
        }
        if box == nil, run == argv, let machine = machine(cwd), let kelp = PTY.trampoline,
            let inside = Self.inMachine(argv, manifest, machine: machine, cwd: cwd, kelp: kelp)
        {
            run = inside
        }
        guard let exe = run.first else { throw RPCError.invalidParams("empty command") }
        let resolved = try LoginPath.resolve(exe)
        // Codex's hooks are added here, not stored in the record (as on a host), so a wake gets this kelpd's hooks.
        let hooks = tmux == nil && box == nil && codexHooksOn(manifest, argv: argv, cwd: cwd) ? CodexHooks.args : []
        return [resolved] + hooks + run.dropFirst()
    }

    /// What an agent on a host gets for `kelp browser`: the folder Kelp keeps there, the socket in it, and whether it
    /// gets the browser skill.
    struct HostBrowsing: Equatable {
        var dir: String, socket: String, skill: Bool
    }

    /// Runs `argv` on the host with Kelp's socket in its environment (`own`), the browser skill's plugin folder
    /// (`flag`), and Kelp's `kelp` first on PATH. PATH is set after the login shell's files ran, which would otherwise
    /// set it anew.
    static func withHostKelp(
        _ argv: [String], _ own: inout [String: String], _ browsing: HostBrowsing, flag: String?
    ) -> [String] {
        own["KELP_SOCKET"] = browsing.socket
        let skill = browsing.skill ? flag.map { [$0, browsing.dir + "/plugin"] } ?? [] : []
        return ["sh", "-c", #"PATH="$0/bin:$PATH"; export PATH; exec "$@""#, browsing.dir] + argv + skill
    }

    /// The machine that `cwd`'s project runs its terminals in (Run Terminals In on its menu), while that machine exists
    /// and shares folders (Linux, macOS). Returns nil when they run here. A dev container, when the project has one
    /// turned on, comes first.
    func machine(_ cwd: String) -> String? {
        guard remotes.of(cwd) == nil,
            let on = store.look(
                "the projects in machines", { try $0.daemonState(Repo.machineKey, as: [String: String].self) }),
            !on.isEmpty,
            let worktree = (store.look("the workspaces") { try $0.worktrees() } ?? [])
                .filter({ Paths.inside(cwd, $0.path) }).max(by: { $0.path.count < $1.path.count }),
            let name = on[worktree.repoId]
        else { return nil }
        do {
            return try VMService(home: root, helper: "").machine(name).kind.sharesFolders ? name : nil
        } catch {
            Log.vm.info("\(name), which a project's terminals run in, is gone: they run here")
            return nil
        }
    }

    /// The command line that runs a terminal (`shell`: the machine's login shell) or a command (`custom`, a Run
    /// command) in `machine` through `kelp vm run`, in `cwd` there (the folder is shared at the same path). Returns nil
    /// for what stays on this Mac: an agent, a tmux session, or a command that already is `kelp vm run` (a machine's
    /// own terminal).
    static func inMachine(
        _ argv: [String], _ manifest: AgentManifest, machine: String, cwd: String, kelp: String
    ) -> [String]? {
        let run = [kelp, "vm", "run", machine, "--cwd", cwd]
        switch manifest.id {
        case Session.shellAgent where Tmux.session(argv) == nil: return run
        case Session.customAgent:
            guard let line = Session.customCommand(agent: manifest.id, argv), !line.hasPrefix("kelp vm ") else {
                return nil
            }
            return run + ["--", line]
        default: return nil
        }
    }

    /// The workspace folder holding `cwd`, and its project's folder, when that project runs in its dev container and
    /// the folder has one. Returns nil when it runs here.
    func devContainer(_ cwd: String) -> (folder: String, project: String)? {
        guard remotes.of(cwd) == nil,
            let on = store.look(
                "the projects in dev containers", { try $0.daemonState(Repo.devContainerKey, as: [String].self) }),
            !on.isEmpty,
            let worktree = (store.look("the workspaces") { try $0.worktrees() } ?? [])
                .filter({ Paths.inside(cwd, $0.path) }).max(by: { $0.path.count < $1.path.count }),
            on.contains(worktree.repoId), DevContainer.configured(in: worktree.path),
            let repo = store.look("a project", { try $0.repo(worktree.repoId) }) ?? nil
        else { return nil }
        return (worktree.path, repo.path)
    }

    /// The environment a program on a host gets from here: its agent's settings and secrets (`secret`, sent separately)
    /// and Kelp's own variables (the port block, colour, links). Not this Mac's paths (a profile's folder, the socket,
    /// PATH), which mean nothing there.
    static func hostEnv(_ manifest: AgentManifest, _ env: [String: String]) -> (
        own: [String: String], secret: [String: String]
    ) {
        var own = ["COLORTERM": "truecolor", "FORCE_HYPERLINK": "1"]
        for key in ["KELP_PORT", "COLORTERM", "FORCE_HYPERLINK"] { own[key] = env[key] ?? own[key] }
        return (own, manifest.resolvedEnv.filter { !$0.value.isEmpty && RemoteHost.isName($0.key) })
    }

    /// Writes `env` into a file of its own on the host (`RemoteHost.envFile`, readable by its user alone), which the
    /// program's command reads and removes as it starts (`RemoteHost.prelude`), so it is never on a command line there.
    /// Returns the file's name, or nil when there is nothing to send.
    static func sendEnv(_ env: [String: String], to remote: RemoteHost) throws -> String? {
        guard !env.isEmpty else { return nil }
        let name = UUID().uuidString.lowercased()
        let text = env.sorted { $0.key < $1.key }.filter { RemoteHost.isName($0.key) }
            .map { "export \($0.key)=\(ShellQuote.word($0.value))\n" }.joined()
        // A file that no start read is removed after five minutes (only this user's, because other users' files can't
        // be removed).
        let left = #"find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'kelp-env-*' -mmin +5 -exec rm -f {} + 2>/dev/null; "#
        try remote.run(
            left + "umask 077; set -C; cat > \(RemoteHost.envFile(name))", stdin: Data(text.utf8), timeLimit: 20)
        return name
    }

    /// A local Codex that agrees on Kelp's hooks gets them on its command line (`CodexHookCheck`).
    func codexHooksOn(_ manifest: AgentManifest, argv: [String], cwd: String) -> Bool {
        guard manifest.hooks == .codexConfig, remotes.of(cwd) == nil, let exe = argv.first else { return false }
        // If Codex isn't found, it won't start either.
        do { return codexHooks.agrees(try LoginPath.resolve(exe)) } catch { return false }
    }

    /// One place for a session's environment, used to start it and to wake it: the account profile it was started with
    /// comes back with it (it used to be dropped on wake and restart, so the session returned on the default login).
    func launchEnv(_ manifest: AgentManifest, _ rec: Session) -> [String: String] {
        var env = hookedEnv(manifest, rec)
        env["PATH"] = Sessions.childPath
        // What Kelp's servers sign in with, by the names Codex's command line gives them. A variable the person set
        // themselves keeps their value.
        if manifest.id == Session.codexAgent, remotes.of(rec.cwd) == nil {
            env.merge(codexEnvironment(worktreeId: rec.worktreeId)) { theirs, _ in theirs }
        }
        return env
    }

    /// `launchEnv` without its PATH, whose first read waits for the login shell (seconds, up to 8). Taking a running
    /// session over needs only this, and it happens before this kelpd answers anyone.
    /// `secrets` are read from the keychain, which can wait for a locked login. They aren't read for a running program,
    /// whose environment is long set, because nobody is served while kelpd takes sessions over.
    func hookedEnv(_ manifest: AgentManifest, _ rec: Session, secrets: Bool = true) -> [String: String] {
        var env = (secrets ? manifest.resolvedEnv : manifest.env).merging(rec.env ?? [:]) { $1 }
        if let name = rec.profile, let prof = profile(name, agent: manifest.id) { env[prof.key] = prof.dir }
        // Not set for tmux, because its server keeps the first client's environment for every pane, whichever tab
        // they're shown in.
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

    /// The first of the ten ports given to the session's folder (`PortBlocks`).
    private func portBlock(_ rec: Session) throws -> Int {
        let all = try store.worktrees()
        let folder = rec.worktreeId.flatMap { id in all.first { $0.id == id }?.path } ?? rec.cwd
        return PortBlocks.port(for: folder, among: all.map(\.path))
    }

    /// Returns the editor (`kelp edit --wait`) that opens a long prompt, handed to the agent's external editor
    /// (Ctrl+G), in a Kelp tab. It names `kelp` without its path, because agents split the string at spaces. There is
    /// none for a shell, which has no prompt to hand over, nor on a host, which has no `kelp`.
    private func promptEditor(_ manifest: AgentManifest, _ rec: Session, given: String?) -> String? {
        let mine = given ?? ProcessInfo.processInfo.environment["VISUAL"]
        guard mine == nil, manifest.id != Session.shellAgent, remotes.of(rec.cwd) == nil, Tmux.session(rec.argv) == nil,
            settings[SettingKeys.editInKelp]
        else { return nil }
        return "kelp edit --wait"
    }

    /// Where a session's Claude conversations are: under its profile's config dir when it has one.
    func claudeProjects(_ rec: Session) -> URL {
        rec.profile.flatMap { profile($0, agent: Session.claudeAgent) }.map {
            URL(fileURLWithPath: $0.dir).appendingPathComponent("projects")
        }
            ?? agentUsage.conversations.homes.withLock { $0 }.claude
    }

    /// Account profiles keep each agent login in its own config dir (`AgentHome`'s variable): switching needs no re-login.
    func profile(_ name: String, agent: String) -> (key: String, dir: String)? {
        guard let key = AgentHome.variable(agent) else { return nil }
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

    /// The agent's manifest: nil for a terminal or a command, or an agent whose file is gone.
    func agent(_ id: String?) -> AgentManifest? {
        AgentManifest.load(dir: Paths.agents(in: root)).first { $0.id == id }
    }

    /// The conversation `agent` keeps on disk, as its manifest says.
    func transcript(of agent: String?) -> AgentManifest.Transcript? { self.agent(agent)?.transcript }

    func manifest(_ id: String?, command: String?, fallbackArgv: [String]? = nil) throws -> AgentManifest {
        if let command { return .custom(command) }
        if id == Session.customAgent, let argv = fallbackArgv {
            return .init(
                id: Session.customAgent, name: "Custom", command: argv.first ?? "/bin/zsh",
                args: Array(argv.dropFirst()))
        }
        let id = id ?? Session.shellAgent
        if id == Session.shellAgent {
            return .init(
                id: Session.shellAgent, name: "Shell",
                command: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
                args: ["-l"], tracksStatus: false)
        }
        guard let manifest = agent(id) else {
            throw RPCError.invalidParams("Unknown agent \(id): Settings › Agents lists the agents Kelp starts.")
        }
        return manifest
    }
}
