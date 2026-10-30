import Foundation
import Core

extension Main {
    /// `status`, `repo …`, `worktree …`.
    static func projects(_ cmd: String, _ sub: String?, _ c: RPCClient) async throws {
        switch (cmd, sub) {
        case ("status", _):
            let repos = try await c.call(RepoList()), wts = try await c.call(WorktreeList()), ss = try await c.call(SessionList())
            for r in repos {
                print("\(r.name)  \(r.path)")
                for w in wts where w.repoId == r.id {
                    let note = w.note.isEmpty ? "" : " — \(w.note)"
                    print("  \(w.branch)  [\(w.id.prefix(8))]\(note)")
                    for s in ss where s.worktreeId == w.id {
                        print("    \(s.agent ?? "cmd") \(s.status.rawValue)\(s.unread ? " •" : "")  [\(s.id.prefix(8))]")
                    }
                }
            }
        case ("repo", "add"):
            let git: Bool? = has("--init") ? true : has("--no-git") ? false : nil
            show(try await c.call(RepoAdd(path: args.first ?? FileManager.default.currentDirectoryPath, init: git)))
        case ("repo", "list"): show(try await c.call(RepoList()))
        case ("worktree", "create"):
            guard let b = args.first, !b.hasPrefix("-") else { fail("worktree create <branch>") }
            args.removeFirst()
            let base = flag("--base"), setup: Bool? = has("--no-setup") ? false : nil
            show(try await c.call(WorktreeCreate(repoId: try await currentRepoID(c), branch: b, base: base, setup: setup)))
        case ("worktree", "list"): show(try await c.call(WorktreeList(archived: has("--all") ? true : nil)))
        case ("worktree", "current"): show(try await currentWorktree(c))
        case ("worktree", "note"):
            _ = try await c.call(WorktreeNote(id: try await currentWorktreeID(c), note: args.joined(separator: " ")))
        case ("worktree", "remove"), ("worktree", "archive"):
            let force = has("--force"), drop = has("--drop-commits")   // two separate losses, each asked for by name
            let id = try await resolve(c, args.first ?? "", "worktree.list")
            if sub == "remove" {
                show(try await c.call(WorktreeRemove(id: id, force: force, dropCommits: drop)))
            } else {
                show(try await c.call(WorktreeArchive(id: id)))
            }
        default: print(usage)
        }
    }
}
