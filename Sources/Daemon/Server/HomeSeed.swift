import Agents
import Core
import Foundation
import GRDB

/// Seeds a build that has a home of its own (Kelp Beta, Kelp Dev) from where Kelp is. Its kelpd's first run copies
/// Kelp's projects, workspaces, layouts, sidebar, settings, extensions, agents, remote projects, and sessions with what
/// they printed. A Claude Code session that's live in Kelp comes back paused, and waking it (showing its tab does)
/// continues a fork of its conversation, never the one Kelp's agent writes. Any other live session ends here, because
/// no other agent can fork and a second copy would write the same conversation. Sessions in tmux aren't copied, because
/// closing one here would end it in Kelp. Routines are switched off (they'd run twice). The workspaces are the same
/// folders, so Kelp sees what this build changes in them.
public enum HomeSeed {
    /// The files copied. They are clones on APFS, so what the sessions printed takes no room until one of the two homes
    /// writes.
    static let copied = [
        "settings.json", "hooks-claude.json", "agent-skills", "extensions", "agents", "remote", "scratch", "templates",
        "history"
    ]

    /// Fills only a home with no database (the first run), and what's in it already stays. Limit: a home that failed
    /// here starts empty, and tries again next time.
    public static func fill(_ home: URL, from stable: URL) {
        let fm = FileManager.default
        let db = home.appendingPathComponent("kelp.sqlite").path,
            source = stable.appendingPathComponent("kelp.sqlite").path
        guard !fm.fileExists(atPath: db), fm.fileExists(atPath: source) else { return }
        Log.start.attempt("copying \(stable.path) to \(home.path)") {
            try Paths.ensure(home)
            // The daemon's lock: a second kelpd (started by the app or the CLI) waits here, then finds the home already
            // filled.
            let lock = open(home.appendingPathComponent("kelpd.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            defer { close(lock) }
            flock(lock, LOCK_EX)
            guard !fm.fileExists(atPath: db) else { return }
            for name in copied
            where !fm.fileExists(atPath: home.appendingPathComponent(name).path)
                && fm.fileExists(atPath: stable.appendingPathComponent(name).path)
            {
                Log.start.attempt("copying \(name)") {
                    try fm.copyItem(at: stable.appendingPathComponent(name), to: home.appendingPathComponent(name))
                }
            }
            let temp = db + ".seed"
            for end in ["", "-wal", "-shm"] where fm.fileExists(atPath: temp + end) {
                try fm.removeItem(atPath: temp + end)
            }   // left by a seed that didn't finish
            var readOnly = Configuration()
            readOnly.readonly = true
            let to = try DatabaseQueue(path: temp)
            try DatabaseQueue(path: source, configuration: readOnly).backup(to: to)   // consistent while Kelp's kelpd writes it
            try to.close()
            let store = try Store(path: temp)   // migrated first: Kelp's store may be older than this build
            try adapt(store, home: home, stable: stable)
            // Checkpoint into the file now, because the pool closes its read-only connections last and those can't
            // checkpoint.
            try store.db.writeWithoutTransaction { _ = try $0.checkpoint(.truncate) }
            try store.db.close()
            for end in ["-wal", "-shm"] where fm.fileExists(atPath: temp + end) {
                try fm.removeItem(atPath: temp + end)
            }
            try fm.moveItem(atPath: temp, toPath: db)   // last, because a home with a database counts as filled
        }
    }

    private static func adapt(_ store: Store, home: URL, stable: URL) throws {
        let from = stable.path + "/", to = home.path + "/", standIns = from + "remote/"
        // This home has its own copy of the remote projects' stand-ins and of the scratch folder. Any other path (a
        // project or a worktree, which git knows by that path) is the same folder.
        func moved(_ path: String) -> String {
            path.hasPrefix(standIns) || path == from + "scratch" ? to + path.dropFirst(from.count) : path
        }
        for var repo in try store.repos() where moved(repo.path) != repo.path {
            repo.path = moved(repo.path)
            try store.save(repo)
        }
        for var worktree in try store.worktrees() where moved(worktree.path) != worktree.path {
            worktree.path = moved(worktree.path)
            try store.save(worktree)
        }
        let manifests = AgentManifest.load(dir: Paths.agents(in: home))
        for var session in try store.sessions() {
            if Sessions.tmuxName(session) != nil {
                try store.delete(session)
                continue
            }
            let remote = session.cwd.hasPrefix(standIns)
            if remote { session.cwd = moved(session.cwd) }   // a scratch session stays in Kelp's: its conversation is found by the folder
            if session.status != .exited {
                if !remote, let fork = manifests.first(where: { $0.id == session.agent })?.forking(session.argv) {
                    session.argv = fork.map { $0.replacingOccurrences(of: from, with: to) }   // its hooks and skills: this home's
                } else {
                    session.status = .exited
                }
            }
            try store.save(session)
        }
        try store.db.write { try $0.execute(sql: "UPDATE routine SET enabled = 0") }
    }
}
