import Agents
import Core
import Foundation
import GitKit

extension Subprocess {
    /// What a short command prints (stdout, then stderr), or nil if it fails or takes longer than `timeout`.
    static func printed(_ argv: [String], path: String, timeout: Double) -> String? {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        env["NO_COLOR"] = "1"
        guard let result = try? Subprocess.run(argv, cwd: NSHomeDirectory(), env: env, timeLimit: timeout),
            result.status == 0, !result.timedOut, !result.truncated
        else { return nil }
        return String(decoding: result.stdout + result.stderr, as: UTF8.self)
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
