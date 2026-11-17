import Core
import Foundation

extension Main {
    /// Runs `status`, `repo …` and `worktree …`.
    static func projects(_ cmd: String, _ sub: String?, _ client: RPCClient) async throws {
        switch (cmd, sub) {
        case ("status", _):
            let repos = try await client.call(RepoList()), wts = try await client.call(WorktreeList()),
                ss = try await client.call(SessionList())
            for r in repos {
                print("\(r.name)  \(r.path)")
                for w in wts where w.repoId == r.id {
                    let note = w.note.isEmpty ? "" : " — \(w.note)"
                    print("  \(w.branch)  [\(w.id.prefix(8))]\(note)")
                    for s in ss where s.worktreeId == w.id {
                        print(
                            "    \(s.agent ?? "cmd") \(s.status.rawValue)\(s.unread ? " •" : "")  [\(s.id.prefix(8))]")
                    }
                }
            }
        case ("repo", "add"):
            let git: Bool? = has("--init") ? true : has("--no-git") ? false : nil
            show(
                try await client.call(RepoAdd(path: args.first ?? FileManager.default.currentDirectoryPath, init: git)))
        case ("repo", "list"): show(try await client.call(RepoList()))
        case ("worktree", "create"):
            guard let branch = args.first, !branch.hasPrefix("-") else { fail("worktree create <branch>") }
            args.removeFirst()
            let base = flag("--base"), setup: Bool? = has("--no-setup") ? false : nil
            show(
                try await client.call(
                    WorktreeCreate(repoId: try await currentRepoID(client), branch: branch, base: base, setup: setup)))
        case ("worktree", "list"): show(try await client.call(WorktreeList(archived: has("--all") ? true : nil)))
        case ("worktree", "current"): show(try await currentWorktree(client))
        case ("worktree", "note"):
            _ = try await client.call(
                WorktreeNote(id: try await currentWorktreeID(client), note: args.joined(separator: " ")))
        case ("worktree", "remove"), ("worktree", "archive"):
            let force = has("--force"), drop = has("--drop-commits")   // Two separate losses, each named by its flag.
            let id = try await workspace(client, args.first ?? "")
            if sub == "remove" {
                show(try await client.call(WorktreeRemove(id: id, force: force, dropCommits: drop)))
            } else {
                show(try await client.call(WorktreeArchive(id: id)))
            }
        default: print(usage)
        }
    }
}
