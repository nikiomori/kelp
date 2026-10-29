import Foundation
import CryptoKit
import Core

/// A project's commands from `.kelp.yaml` (setup, run, test…) run only after the user trusts that file: a clone
/// mustn't run anything just by being opened. Trust is for the file's exact contents; editing it asks again.
extension Workspaces {
    var trustFile: URL { root.appendingPathComponent("trusted-configs.json") }

    func configText(_ repoPath: String) -> String { (try? String(contentsOfFile: repoPath + "/.kelp.yaml", encoding: .utf8)) ?? "" }
    static func digest(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// The file read once, its parsed config and whether the user trusts exactly that text: checking one read and using
    /// another would let a write in between (an agent, a pull) slip in unseen.
    func configAndTrust(_ repoPath: String) -> (text: String, config: RepoConfig, trusted: Bool) {
        let text = configText(repoPath), cfg = RepoConfig.parse(text)
        guard !Self.asksNothing(cfg) else { return (text, cfg, true) }
        return (text, cfg, trustLock.withLock { knownDigests() }[repoPath] == Self.digest(text))
    }

    /// trusted-configs.json is read and written under one lock: two projects trusted at once both stay trusted.
    func knownDigests() -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: trustFile))) ?? [:]
    }

    /// Nothing in it runs, links, or speaks to an agent for the user: a file like that needs no trust.
    static func asksNothing(_ c: RepoConfig) -> Bool {
        c.setup == nil && c.scripts.isEmpty && c.tabs.isEmpty && c.shared.isEmpty && c.recipes.isEmpty && c.issueCommand == nil
    }

    /// The project's .kelp.yaml if the user trusts it as it is now, else nothing of it: a cloned repository's prompts
    /// (recipe.*, issueCommand) reach an agent as the user's own words, so they wait for trust like its commands.
    func trustedConfig(_ repoPath: String) -> RepoConfig {
        let c = configAndTrust(repoPath)
        return c.trusted ? c.config : RepoConfig()
    }

    /// The project folder whose .kelp.yaml a workspace uses.
    func configRepo(_ worktreeId: String) throws -> (Worktree, String) {
        let w = try store.worktree(named: worktreeId)
        return (w, try store.repo(w.repoId)?.path ?? w.path)
    }
}

extension ScriptsList: Handled {
    func handle(_ workspaces: Workspaces) throws -> Result {
        let (_, repo) = try workspaces.configRepo(worktreeId)
        let read = workspaces.configAndTrust(repo), cfg = read.config
        // Everything trusting it would allow, and the digest of exactly this text (one read): trust is given to what was shown.
        return Result(scripts: cfg.scripts, setup: cfg.setup, tabs: cfg.tabs, shared: cfg.shared, recipes: cfg.recipes, issueCommand: cfg.issueCommand,
                      digest: Workspaces.digest(read.text), trusted: read.trusted, file: repo + "/.kelp.yaml")
    }
}

extension ScriptsTrust: Handled {
    /// Only from Kelp's window: the program on the other end of the socket must be the KelpApp next to this daemon.
    /// Agents and scripts reach this socket too (KELP_SOCKET) and could read the digest; they can't become that
    /// program. What this guards against is a cloned repository's .kelp.yaml running unseen, not a hostile agent: a
    /// process of this user can drive the app (synthetic key events) or write trusted-configs.json itself.
    var onlyFromKelp: String? { "Only Kelp's window can trust a project's commands: open the project there and run one." }
    func handle(_ workspaces: Workspaces) throws -> Done {
        let (_, repo) = try workspaces.configRepo(worktreeId)
        let now = Workspaces.digest(workspaces.configText(repo))
        // The digest from scripts.list: a file changed since it was shown (an agent, a pull) isn't what was trusted.
        guard let digest else { throw RPCError.invalidParams("scripts.trust needs the digest of the .kelp.yaml that was shown.") }
        guard digest == now else { throw RPCError.invalidParams(".kelp.yaml changed since it was shown. Look at it again before trusting it.") }
        try workspaces.trustLock.withLock {
            var known = workspaces.knownDigests()
            known[repo] = now
            try JSONEncoder().encode(known).write(to: workspaces.trustFile, options: .atomic)
        }
        return Done()
    }
}

extension ScriptsRun: Handled {
    func handle(_ workspaces: Workspaces) throws -> Session {
        let (w, repo) = try workspaces.configRepo(worktreeId)
        let read = workspaces.configAndTrust(repo)   // the command run is from the text that was checked
        guard read.trusted else { throw RPCError.invalidParams("This project's commands aren't trusted yet.") }
        let cfg = read.config
        guard let s = cfg.scripts.first(where: { $0.name == name }) ?? cfg.setup.flatMap({ name == "setup" ? .init(name: name, command: $0) : nil }) else {
            throw RPCError.invalidParams("No “\(name)” command in .kelp.yaml.")
        }
        var o = Sessions.Launch(); o.title = name
        return try workspaces.sessions.spawn(cwd: w.path, manifest: .custom(s.command), worktreeId: w.id, o)
    }
}

extension Methods {
    static let projectMethods: [any Handled.Type] = [ScriptsList.self, ScriptsTrust.self, ScriptsRun.self, RunDetect.self, RunStart.self, RepoAddRemote.self,
        FilesReadRemote.self, FilesWriteRemote.self,
        SettingsGet.self, SettingsSet.self, UsageGet.self, UsageReport.self, UsageAgents.self, HistoryList.self] + fileMethods
}
