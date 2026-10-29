import Foundation
import Core
import AgentData

extension Sessions {
    /// What a Claude Code session's requests start with, as its /context counts it (system prompt, tools, MCP, memory
    /// files, skills): a copy of Claude Code in the session's folder, with its skills, model and system prompt, prints
    /// it and exits. `-p` with `--no-session-persistence` leaves no session in /resume and nothing in the prompt history.
    /// Read once a half hour per folder and flags; nil for another agent, a remote project, or when it can't be read.
    func claudeSetup(_ s: Session) -> SessionContextParts.Setup? {
        guard s.agent == "claude", remotes.of(s.cwd) == nil else { return nil }
        let carried = ["--plugin-dir", "--append-system-prompt", "--model", "--mcp-config"]
        let flags = s.argv.indices.dropLast().filter { carried.contains(s.argv[$0]) }.flatMap { [s.argv[$0], s.argv[$0 + 1]] }
        let key = ([s.cwd, s.profile ?? ""] + flags).joined(separator: "\n")
        if let hit = contextSetups.withLock({ $0[key] }), Date().timeIntervalSince(hit.at) < 1800 { return hit.setup }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.childPath; env["NO_COLOR"] = "1"
        if let name = s.profile, let p = profile(name, agent: "claude") { env[p.key] = p.dir }
        var setup: SessionContextParts.Setup?
        do {
            let exe = try LoginPath.resolve(s.argv.first ?? "claude")
            let r = try Subprocess.run([exe, "-p", "/context", "--no-session-persistence"] + flags, cwd: s.cwd, env: env, timeLimit: 30)
            if r.status == 0, !r.timedOut { setup = ClaudeContext.setup(String(decoding: r.stdout, as: UTF8.self)) }
        } catch {
            Log.session.error("Claude Code's /context wasn't read: \(error)")
        }
        contextSetups.withLock { [setup] in $0[key] = (Date(), setup) }
        return setup
    }
}
