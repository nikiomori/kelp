import AgentData
import Core
import Foundation

extension Sessions {
    /// What a Claude Code session's requests start with, as its /context counts it (system prompt, tools, MCP, memory
    /// files, skills): a copy of Claude Code in the session's folder, with its skills, model and system prompt, prints
    /// it and exits. `-p` with `--no-session-persistence` leaves no session in /resume and nothing in the prompt history.
    /// Nobody watches this copy and `-p` asks nothing, so as with `planProbes`, no hook or MCP server runs in it, and a folder
    /// whose agent config differs from the base branch (someone's PR) isn't opened at all.
    /// Read once a half hour per folder and flags; nil for another agent, a remote project, or when it can't be read.
    /// Limit: the project's own MCP servers aren't counted.
    func claudeSetup(_ session: Session) -> SessionContextParts.Setup? {
        guard session.agent == "claude", remotes.of(session.cwd) == nil else { return nil }
        let carried = ["--plugin-dir", "--append-system-prompt", "--model", "--mcp-config"]
        let flags = session.argv.indices.dropLast().filter { carried.contains(session.argv[$0]) }.flatMap {
            [session.argv[$0], session.argv[$0 + 1]]
        }
        let key = ([session.cwd, session.profile ?? ""] + flags).joined(separator: "\n")
        if let hit = contextSetups.withLock({ $0[key] }), Date().timeIntervalSince(hit.at) < 1800 { return hit.setup }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.childPath
        env["NO_COLOR"] = "1"
        if let name = session.profile, let home = profile(name, agent: "claude") { env[home.key] = home.dir }
        var setup: SessionContextParts.Setup?
        do {
            if configSettled(session) {
                let exe = try LoginPath.resolve(session.argv.first ?? "claude")
                let result = try Subprocess.run(
                    [exe] + Self.setupArgs + flags, cwd: session.cwd, env: env, timeLimit: 30)
                if result.status == 0, !result.timedOut {
                    setup = ClaudeContext.setup(String(decoding: result.stdout, as: UTF8.self))
                }
            }
        } catch {
            Log.session.error("Claude Code's /context wasn't read: \(error)")
        }
        contextSetups.withLock { [setup] in $0[key] = (Date(), setup) }
        return setup
    }

    static let setupArgs = [
        "-p", "/context", "--no-session-persistence", "--strict-mcp-config", "--settings", #"{"disableAllHooks":true}"#
    ]

    /// The session's folder is a project's, with the agent config of its base branch.
    private func configSettled(_ session: Session) -> Bool {
        let project = Log.session.attempt("the project of \(session.id)") {
            try session.worktreeId.flatMap { try store.worktree($0) }.flatMap { worktree in
                try store.repo(worktree.repoId).map { (worktree, $0) }
            }
        }
        guard let (worktree, repo) = project ?? nil else { return false }
        return !AgentConfig.changed(worktree.path, base: repo.baseBranch, remotes: remotes)
    }
}
