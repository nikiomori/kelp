import Agents
import Core
import Foundation
import GitKit

/// RPCs that chain several steps or wait on other processes.
extension Sessions {

    /// What a short command prints (stdout, then stderr), or nil if it fails or takes longer than `timeout`.
    static func run(_ argv: [String], path: String, timeout: Double) -> String? {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        env["NO_COLOR"] = "1"
        guard let result = try? Subprocess.run(argv, cwd: NSHomeDirectory(), env: env, timeLimit: timeout),
            result.status == 0, !result.timedOut, !result.truncated
        else { return nil }
        return String(decoding: result.stdout + result.stderr, as: UTF8.self)
    }

    /// "claude 2.1.3 (Claude Code)" → "2.1.3".
    static func semver(_ output: String) -> String? { output.firstMatch(of: /\d+\.\d+\.\d+/).map { String($0.output) } }

    /// Transcript of a session written to ~/.kelp/handoff/<id>.md for the next agent to read. Claude Code's own
    /// conversation (what was asked and answered) when there is one; otherwise the terminal's text.
    func handoffFile(_ session: Session, full: Bool) throws -> URL {
        let limit = full ? 400_000 : 40_000
        let body: String
        if let transcript = existing(session.id).flatMap(agentUsage.transcript(of:)),
            let talk = AgentUsage.conversation(transcript: transcript, limit: limit), !talk.isEmpty
        {
            body = talk
        } else {
            let printed = try liveSessionOrLog(session.id, bytes: limit)
            // swiftlint:disable:next optional_data_string_conversion
            body = "```\n" + StatusDetector.stripANSI(String(decoding: printed, as: UTF8.self)) + "\n```"   // lossy on purpose, see session.context
        }
        let dir = root.appendingPathComponent("handoff")
        try Paths.ensure(dir)
        let file = dir.appendingPathComponent("\(session.id).md")
        try ("# Previous session (\(session.agent ?? "agent"), \(session.cwd))\n\n" + body + "\n").write(
            to: file, atomically: true, encoding: .utf8)
        return file
    }
}

extension SessionMove: Handled {
    func handle(_ sessions: Sessions) throws -> Done {
        guard let to = try sessions.store.worktree(worktreeId), !to.archived else {
            throw RPCError.invalidParams("no worktree")
        }
        try sessions.wakeLocks.withLock(id) {
            guard
                let session = try sessions.existing(id)?.snapshot
                    ?? sessions.store.sessions().first(where: { $0.id == id })
            else {
                throw RPCError.invalidParams("no session")
            }
            // Its process keeps its folder: a workspace elsewhere is other files, which only a new agent can have.
            guard let from = try session.worktreeId.flatMap(sessions.store.worktree), from.path == to.path else {
                throw RPCError.invalidParams("Only a screen of the same folder can take it.")
            }
            if let ls = sessions.existing(id) {
                _ = ls.update { $0.worktreeId = worktreeId }
                sessions.publish(ls)
            } else {
                try sessions.change(id) { $0.worktreeId = worktreeId }
            }
        }
        return Done()
    }
}

extension SessionRename: Handled {
    var actsOn: String? { id }   // its title on the user's row: an agent names only its own and those it started
    func handle(_ sessions: Sessions) throws -> Done {
        // Under its wake lock: a paused record read here and saved back must not land over a wake that started meanwhile.
        try sessions.wakeLocks.withLock(id) {
            if let ls = sessions.existing(id) {
                _ = ls.update {
                    $0.title = title
                    $0.titleManual = !title.isEmpty
                }
                sessions.publish(ls)
            } else {
                try sessions.change(id) {
                    $0.title = title
                    $0.titleManual = !title.isEmpty
                }
            }
        }
        return Done()
    }
}

extension Sessions {
    /// argv without `--session-id <id>`: two sessions can't share an id (Claude Code refuses one already used).
    static func withoutSessionId(_ argv: [String], flag: String?) -> [String] {
        guard let flag, let index = argv.firstIndex(of: flag) else { return argv }
        var stripped = argv
        stripped.removeSubrange(index...min(index + 1, stripped.count - 1))
        return stripped
    }
}
