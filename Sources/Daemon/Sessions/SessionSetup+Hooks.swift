import AgentData
import Agents
import Core
import Foundation
import os

/// An agent's hooks: Kelp's plugin dir and the environment that points the agent at it, which hooks this launch really
/// wired, and the trust question Kelp may answer.
extension SessionSetup {
    /// Kelp's plugin dir for an agent; its hooks file is this with ".json".
    func hooksDir(_ manifest: AgentManifest) -> URL { root.appendingPathComponent("hooks-\(manifest.id)") }

    /// What `transport` needs in the environment. A variable the user set themselves stays theirs, and the hooks aren't
    /// wired (`wiredHooks`); `.settingsFlag` is on the command line (`spawn`).
    func wire(
        _ transport: HookTransport, _ manifest: AgentManifest, _ rec: Session, _ env: inout [String: String]
    ) {
        let dir = hooksDir(manifest), file = dir.appendingPathExtension("json")
        if let key = transport.env, env[key] != nil { return }
        do {
            switch transport {
            case .settingsFlag, .codexConfig: break
            case .pluginDir(let key):
                try Hooks.writePlugin(dir: dir)
                if manifest.id == "opencode", openCode2.runs(rec.argv) {
                    guard env[OpenCode2.cliConfig] == nil else { return }
                    env[OpenCode2.cliConfig] = OpenCode2.cliConfig(
                        plugin: Hooks.tuiPlugin(in: dir), config: OpenCode2.configDir(env))
                } else {
                    if manifest.id == "kilo" {
                        let config = ProcessInfo.processInfo.environment.merging(env) { $1 }["XDG_CONFIG_HOME"]
                        try Self.linkKiloInstructions(
                            into: dir,
                            config: config.map { URL(fileURLWithPath: $0) }
                                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config"))
                    }
                    env[key] = dir.path
                }
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

    /// Kilo looks for the global AGENTS.md only in KILO_CONFIG_DIR once it's set: the person's own (`config`'s
    /// kilo/AGENTS.md), linked in, or the link gone with it.
    static func linkKiloInstructions(into dir: URL, config: URL) throws {
        let fm = FileManager.default
        let theirs = config.appendingPathComponent("kilo/AGENTS.md"), link = dir.appendingPathComponent("AGENTS.md")
        var info = stat()
        if lstat(link.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK { try fm.removeItem(at: link) }
        if fm.fileExists(atPath: theirs.path) { try fm.createSymbolicLink(at: link, withDestinationURL: theirs) }
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
            case .pluginDir(let key)?:
                env[key] == dir.path || env[OpenCode2.cliConfig]?.contains(Hooks.tuiPlugin(in: dir).path) == true
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
        // For a remote project the question is always the user's: it is decided before running any git (which would go
        // over ssh, under the session's wake lock, to a host that may not answer).
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
}
