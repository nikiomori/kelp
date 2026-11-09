import Core
import Foundation

extension Git {
    /// The working tree as it is now (tracked and new files, .gitignore respected) written as a tree object, so a
    /// later diff shows exactly what changed since. A copy of the index is updated, never the real one; files whose
    /// stat didn't change aren't hashed again.
    public static func snapshotTree(_ cwd: String, remotes: Remotes = .none) throws -> String {
        // On a remote project git runs on the host, where neither GIT_INDEX_FILE nor this Mac's copy of the index reach:
        // `add -A` would stage everything in the host's real index.
        if remotes.of(cwd) != nil {
            throw GitError(args: ["add", "-A"], status: 1, stderr: "Snapshots aren't taken in remote projects.")
        }
        let rel = try line(["rev-parse", "--git-path", "index"], cwd: cwd, remotes: remotes)
        let real = URL(fileURLWithPath: rel, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)).path
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-index-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: copy) }
        if FileManager.default.fileExists(atPath: real) { try FileManager.default.copyItem(atPath: real, toPath: copy) }
        // Nobody asked for these: a repository's filters and index hooks don't run for them. Both write the index, and
        // writing it can read a racily clean file through its filter again.
        var env = ["GIT_INDEX_FILE": copy]
        env.merge(configEnv(RepoFilters.off(cwd), after: ProcessInfo.processInfo.environment)) { $1 }
        let quiet = ["-c", "core.hooksPath=/dev/null"]
        // New files that look like secrets (a key, .env) stay out: refs/kelp/turns would pin them in git for good, and
        // `git push --mirror` send them.
        let secrets = try run(
            ["ls-files", "-z", "-o", "--exclude-standard", "--full-name", "--", ":/"], cwd: cwd, remotes: remotes
        )
        .split(separator: "\0").map(String.init).filter { holdsSecrets(($0 as NSString).lastPathComponent) }
        try run(
            quiet + ["add", "-A"]
                + (secrets.isEmpty ? [] : ["--", ":/"] + secrets.map { ":(top,exclude,literal)" + $0 }),
            cwd: cwd, env: env, remotes: remotes)
        return try line(quiet + ["write-tree"], cwd: cwd, env: env, remotes: remotes)
    }

    /// Files changed since a snapshot, with line counts ("Changed 3 files +40 −5" after an agent's turn).
    public static func changesSince(tree: String, cwd: String, remotes: Remotes = .none) throws -> [(
        path: String, added: Int, removed: Int
    )] {
        let now = try snapshotTree(cwd, remotes: remotes)
        guard now != tree else { return [] }
        return try run(["diff", "--numstat", "--no-renames", "-z", rev(tree), now], cwd: cwd, remotes: remotes).split(
            separator: "\0"
        ).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2)
            guard fields.count == 3 else { return nil }
            return (String(fields[2]), Int(fields[0]) ?? 0, Int(fields[1]) ?? 0)
        }
    }
}

extension Git {
    /// The files HEAD changed since it left `base` (their merge base), committed only: `status` has the rest.
    public static func branchFiles(_ cwd: String, base: String, remotes: Remotes = .none) throws -> [String] {
        try run(["diff", "--name-only", "--no-renames", "-z", "\(try rev(base))...HEAD"], cwd: cwd, remotes: remotes)
            .split(separator: "\0").map(String.init)
    }
}

/// Putting a folder back as it was at a snapshot (an agent's turn undone).
extension Git {
    /// The files that differ now from snapshot `tree`, secrets left out (`holdsSecrets`: what the user put there stays), and the
    /// snapshot of now, which `restore` is given back so nothing that changes meanwhile is written over.
    public static func changed(since tree: String, cwd: String, remotes: Remotes = .none) throws -> (
        files: [String], now: String
    ) {
        let now = try snapshotTree(cwd, remotes: remotes)
        let names = try run(["diff", "--name-only", "--no-renames", "-z", rev(tree), now], cwd: cwd, remotes: remotes)
        return (
            names.split(separator: "\0").map(String.init).filter { !holdsSecrets(($0 as NSString).lastPathComponent) },
            now
        )
    }

    /// `.env`, `.env.local`, `.env.production`, private keys and certificates (`id_rsa`, `*.pem`, `*.p12`), a cloud
    /// SDK's `credentials.json`: the user's secrets, never put back nor snapshotted when new. A template committed for
    /// others (`.env.example`), direnv's `.envrc` and a public key (`id_rsa.pub`) are code like any other.
    static func holdsSecrets(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return name == ".env"
            || name.hasPrefix(".env.")
                && !["example", "sample", "template", "dist", "defaults"].contains(name.dropFirst(5))
            || ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "credentials.json"].contains(name)
            || ["pem", "key", "p12", "pfx"].contains(ext)
    }

    /// `files` (paths from the repository's top, `cwd`) as they were in `tree`, content and mode; a file the tree hasn't
    /// goes to the Trash. Whatever of them is staged is unstaged first (back to HEAD, which is the turn's), so the next
    /// commit can't take the undone work. Refused when the folder isn't the snapshot `now` any more; afterwards none of
    /// them may still differ.
    public static func restore(_ files: [String], from tree: String, now: String, cwd: String, remotes: Remotes = .none)
        throws
    {
        guard try snapshotTree(cwd, remotes: remotes) == now else {
            throw GitError(
                args: ["restore"], status: 1, stderr: "The files changed since you looked; nothing was put back.")
        }
        let staged =
            files.isEmpty
            ? []
            : try run(["ls-files", "-z", "--"] + literal(files), cwd: cwd, remotes: remotes)
                .split(separator: "\0").map(String.init)
        if !staged.isEmpty { try run(["restore", "--staged", "--"] + literal(staged), cwd: cwd, remotes: remotes) }
        let had = Set(
            try run(["ls-tree", "-r", "-z", "--full-tree", "--name-only", rev(tree)], cwd: cwd, remotes: remotes)
                .split(separator: "\0").map(String.init))
        let back = files.filter(had.contains)
        if !back.isEmpty {
            try run(
                ["restore", "--source=" + rev(tree), "--worktree", "--"] + literal(back), cwd: cwd, remotes: remotes)
        }
        for file in files where !had.contains(file) && FileManager.default.fileExists(atPath: cwd + "/" + file) {
            try Trash.move(URL(fileURLWithPath: cwd + "/" + file))
        }
        let left = Set(try changed(since: tree, cwd: cwd, remotes: remotes).files).intersection(files)
        guard left.isEmpty else {
            throw GitError(
                args: ["restore"], status: 1, stderr: "These didn't go back: \(left.sorted().joined(separator: ", ")).")
        }
    }
}
