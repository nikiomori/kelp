import Foundation
import GRDB
import Core
import Agents

/// A build with a home of its own (Kelp Beta, Kelp Dev) starts where Kelp is: its kelpd's first run copies Kelp's projects,
/// workspaces, layouts, sidebar, settings, extensions, agents, remote projects and sessions with what they printed.
/// A Claude Code session that's live there comes back paused, and waking it (showing its tab does) continues a fork of its
/// conversation, never the one Kelp's agent writes. Any other live session ends here: no other agent can fork, and a second
/// one would write the same conversation. What runs in tmux isn't copied: closing it here would end it there. Routines are
/// switched off (they'd run twice). The workspaces are the same folders: what this build changes in them, Kelp sees.
public enum HomeSeed {
    /// Clones on APFS: what the sessions printed takes no room until one of the two writes.
    static let copied = ["settings.json", "hooks-claude.json", "agent-skills", "extensions", "agents", "remote", "scratch", "templates", "history"]

    /// Only a home with no database (the first run), and what's in it already stays. Limit: one that failed here starts
    /// empty, and tries again next time.
    public static func fill(_ home: URL, from stable: URL) {
        let fm = FileManager.default
        let db = home.appendingPathComponent("kelp.sqlite").path, source = stable.appendingPathComponent("kelp.sqlite").path
        guard !fm.fileExists(atPath: db), fm.fileExists(atPath: source) else { return }
        Log.start.attempt("copying \(stable.path) to \(home.path)") {
            try Paths.ensure(home)
            // The daemon's lock: a second kelpd (the app's, the CLI's) waits here, then finds the home filled.
            let lock = open(home.appendingPathComponent("kelpd.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            defer { close(lock) }
            flock(lock, LOCK_EX)
            guard !fm.fileExists(atPath: db) else { return }
            for f in copied where !fm.fileExists(atPath: home.appendingPathComponent(f).path) && fm.fileExists(atPath: stable.appendingPathComponent(f).path) {
                Log.start.attempt("copying \(f)") { try fm.copyItem(at: stable.appendingPathComponent(f), to: home.appendingPathComponent(f)) }
            }
            let temp = db + ".seed"
            for end in ["", "-wal", "-shm"] where fm.fileExists(atPath: temp + end) { try fm.removeItem(atPath: temp + end) }   // one that didn't finish
            var readOnly = Configuration(); readOnly.readonly = true
            let to = try DatabaseQueue(path: temp)
            try DatabaseQueue(path: source, configuration: readOnly).backup(to: to)   // consistent while Kelp's kelpd writes it
            try to.close()
            let store = try Store(path: temp)   // migrated first: Kelp's may be older than this build
            try adapt(store, home: home, stable: stable)
            // Into the file now: the pool closes its read-only connections last, and those can't.
            try store.db.writeWithoutTransaction { _ = try $0.checkpoint(.truncate) }
            try store.db.close()
            for end in ["-wal", "-shm"] where fm.fileExists(atPath: temp + end) { try fm.removeItem(atPath: temp + end) }
            try fm.moveItem(atPath: temp, toPath: db)   // last: a home with a database is filled
        }
    }

    private static func adapt(_ store: Store, home: URL, stable: URL) throws {
        let from = stable.path + "/", to = home.path + "/", standIns = from + "remote/"
        // This home has its own copy of remote projects' stand-ins and of the scratch folder; any other path (a project, a
        // worktree, git knows it by that path) is the same folder.
        func moved(_ path: String) -> String { path.hasPrefix(standIns) || path == from + "scratch" ? to + path.dropFirst(from.count) : path }
        for var r in try store.repos() where moved(r.path) != r.path { r.path = moved(r.path); try store.save(r) }
        for var w in try store.worktrees() where moved(w.path) != w.path { w.path = moved(w.path); try store.save(w) }
        let manifests = AgentManifest.load(dir: home.appendingPathComponent("agents"))
        for var s in try store.sessions() {
            if Sessions.tmuxName(s) != nil { try store.delete(s); continue }
            let remote = s.cwd.hasPrefix(standIns)
            if remote { s.cwd = moved(s.cwd) }   // a scratch session stays in Kelp's: its conversation is found by the folder
            if s.status != .exited {
                if !remote, let fork = manifests.first(where: { $0.id == s.agent })?.forking(s.argv) {
                    s.argv = fork.map { $0.replacingOccurrences(of: from, with: to) }   // its hooks and skills: this home's
                } else { s.status = .exited }
            }
            try store.save(s)
        }
        try store.db.write { try $0.execute(sql: "UPDATE routine SET enabled = 0") }
    }
}
