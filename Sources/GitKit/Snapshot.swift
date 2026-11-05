import Foundation
import Core

extension Git {
    /// The working tree as it is now (tracked and new files, .gitignore respected) written as a tree object, so a
    /// later diff shows exactly what changed since. A copy of the index is updated, never the real one; files whose
    /// stat didn't change aren't hashed again.
    public static func snapshotTree(_ cwd: String, remotes: Remotes = .none) throws -> String {
        // On a remote project git runs on the host, where neither GIT_INDEX_FILE nor this Mac's copy of the index reach:
        // `add -A` would stage everything in the host's real index.
        if remotes.of(cwd) != nil { throw GitError(args: ["add", "-A"], status: 1, stderr: "Snapshots aren't taken in remote projects.") }
        let rel = try run(["rev-parse", "--git-path", "index"], cwd: cwd, remotes: remotes).trimmingCharacters(in: .whitespacesAndNewlines)
        let real = URL(fileURLWithPath: rel, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)).path
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-index-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: copy) }
        if FileManager.default.fileExists(atPath: real) { try FileManager.default.copyItem(atPath: real, toPath: copy) }
        // Nobody asked for these: a repository's filters and index hooks don't run for them. Both write the index, and
        // writing it can read a racily clean file through its filter again.
        var env = ["GIT_INDEX_FILE": copy]
        env.merge(configEnv(RepoFilters.off(cwd), after: ProcessInfo.processInfo.environment)) { $1 }
        let quiet = ["-c", "core.hooksPath=/dev/null"]
        try run(quiet + ["add", "-A"], cwd: cwd, env: env, remotes: remotes)
        return try run(quiet + ["write-tree"], cwd: cwd, env: env, remotes: remotes).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Files changed since a snapshot, with line counts ("Changed 3 files +40 −5" after an agent's turn).
    public static func changesSince(tree: String, cwd: String, remotes: Remotes = .none) throws -> [(path: String, added: Int, removed: Int)] {
        let now = try snapshotTree(cwd, remotes: remotes)
        guard now != tree else { return [] }
        return try run(["diff", "--numstat", "--no-renames", "-z", rev(tree), now], cwd: cwd, remotes: remotes).split(separator: "\0").compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 2)
            guard f.count == 3 else { return nil }
            return (String(f[2]), Int(f[0]) ?? 0, Int(f[1]) ?? 0)
        }
    }
}

/// Putting a folder back as it was at a snapshot (an agent's turn undone).
extension Git {
    /// The files that differ now from snapshot `tree`, `.env` files left out (secrets the user put there stay), and the
    /// snapshot of now, which `restore` is given back so nothing that changes meanwhile is written over.
    public static func changed(since tree: String, cwd: String, remotes: Remotes = .none) throws -> (files: [String], now: String) {
        let now = try snapshotTree(cwd, remotes: remotes)
        let names = try run(["diff", "--name-only", "--no-renames", "-z", rev(tree), now], cwd: cwd, remotes: remotes)
        return (names.split(separator: "\0").map(String.init).filter { !(($0 as NSString).lastPathComponent).hasPrefix(".env") }, now)
    }

    /// `files` (paths from the repository's top, `cwd`) as they were in `tree`, content and mode; a file the tree hasn't
    /// goes to the Trash. Whatever of them is staged is unstaged first (back to HEAD, which is the turn's), so the next
    /// commit can't take the undone work. Refused when the folder isn't the snapshot `now` any more; afterwards none of
    /// them may still differ.
    public static func restore(_ files: [String], from tree: String, now: String, cwd: String, remotes: Remotes = .none) throws {
        guard try snapshotTree(cwd, remotes: remotes) == now else {
            throw GitError(args: ["restore"], status: 1, stderr: "The files changed since you looked; nothing was put back.")
        }
        let staged = files.isEmpty ? [] : try run(["ls-files", "-z", "--"] + literal(files), cwd: cwd, remotes: remotes)
            .split(separator: "\0").map(String.init)
        if !staged.isEmpty { try run(["restore", "--staged", "--"] + literal(staged), cwd: cwd, remotes: remotes) }
        let had = Set(try run(["ls-tree", "-r", "-z", "--full-tree", "--name-only", rev(tree)], cwd: cwd, remotes: remotes)
            .split(separator: "\0").map(String.init))
        let back = files.filter(had.contains)
        if !back.isEmpty { try run(["restore", "--source=" + rev(tree), "--worktree", "--"] + literal(back), cwd: cwd, remotes: remotes) }
        for f in files where !had.contains(f) && FileManager.default.fileExists(atPath: cwd + "/" + f) {
            try Trash.move(URL(fileURLWithPath: cwd + "/" + f))
        }
        let left = Set(try changed(since: tree, cwd: cwd, remotes: remotes).files).intersection(files)
        guard left.isEmpty else {
            throw GitError(args: ["restore"], status: 1, stderr: "These didn't go back: \(left.sorted().joined(separator: ", ")).")
        }
    }
}
