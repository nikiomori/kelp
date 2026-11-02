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
