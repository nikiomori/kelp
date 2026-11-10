import Core
import Foundation

extension Git {
    /// The working tree as it is now (tracked and new files, .gitignore respected) written as a tree object, so a
    /// later diff shows exactly what changed since. A copy of the index is updated, never the real one; files whose
    /// stat didn't change aren't hashed again.
    public static func snapshotTree(_ cwd: String, remotes: Remotes) throws -> String {
        try onIndexCopy(cwd, remotes: remotes) { env, quiet in
            // New files that look like secrets (a key, .env) stay out: refs/kelp/turns would pin them in git for good,
            // and `git push --mirror` send them.
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
    }

    /// The object `rev` names (a ref, `HEAD`, `<tree>^{tree}`), nil when there's none: a ref never made, a snapshot
    /// git has cleaned up, a repository with no commit yet.
    public static func resolve(_ rev: String, cwd: String, remotes: Remotes) throws -> String? {
        let object = try line(["rev-parse", "--verify", "-q", rev], cwd: cwd, ok: [0, 1], remotes: remotes)
        return object.isEmpty ? nil : object
    }

    /// The commit checked out; nil before the first one.
    public static func head(_ cwd: String, remotes: Remotes) throws -> String? {
        try resolve("HEAD", cwd: cwd, remotes: remotes)
    }

    /// Keeps `object` under `ref` (a snapshot under refs/kelp/…, so `git gc` leaves it); nil drops the ref. `reflog`: the
    /// line the ref's log keeps for this, so what it pointed at before stays reachable too.
    public static func setRef(
        _ ref: String, to object: String?, reflog: String? = nil, cwd: String, remotes: Remotes
    ) throws {
        let log = reflog.map { ["--create-reflog", "-m", $0] } ?? []
        try run(["update-ref"] + log + (object.map { [ref, $0] } ?? ["-d", ref]), cwd: cwd, remotes: remotes)
    }

    /// Drops `refs` in one git run; one already gone stops none of the others.
    public static func deleteRefs(_ refs: [String], cwd: String, remotes: Remotes) throws {
        try run(
            ["update-ref", "--stdin"], cwd: cwd, stdin: refs.map { "delete \($0)\n" }.joined(), remotes: remotes)
    }

    /// What is staged now, written as a tree object: kept beside a turn's snapshot, so undoing the turn puts the index
    /// back as well as the files. From a copy of the index too (`write-tree` on the real one rewrites it, under its
    /// lock, which an agent's `git add` then finds taken). nil when there is none to write: unresolved conflicts (git
    /// writes no tree of those), a remote project. A file added with `git add -N` isn't in it.
    public static func indexTree(_ cwd: String, remotes: Remotes) throws -> String? {
        guard remotes.of(cwd) == nil, try run(["ls-files", "-u"], cwd: cwd, remotes: remotes).isEmpty else {
            return nil
        }
        return try onIndexCopy(cwd, remotes: remotes) { env, quiet in
            try line(quiet + ["write-tree"], cwd: cwd, env: env, remotes: remotes)
        }
    }

    /// `body` with the environment that points git at a copy of the index, never the real one, and the arguments that
    /// keep the repository's hooks out of it.
    private static func onIndexCopy<T>(
        _ cwd: String, remotes: Remotes, _ body: (_ env: [String: String], _ quiet: [String]) throws -> T
    ) throws -> T {
        // On a remote project git runs on the host, where neither GIT_INDEX_FILE nor this Mac's copy of the index reach:
        // `add -A` would stage everything in the host's real index.
        if remotes.of(cwd) != nil {
            throw GitError.refused("Snapshots aren't taken in remote projects.")
        }
        let rel = try line(["rev-parse", "--git-path", "index"], cwd: cwd, remotes: remotes)
        let real = URL(fileURLWithPath: rel, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)).path
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-index-\(UUID().uuidString)").path
        defer { FileManager.default.removeIfAny(URL(fileURLWithPath: copy)) }
        if FileManager.default.fileExists(atPath: real) { try FileManager.default.copyItem(atPath: real, toPath: copy) }
        // Nobody asked for these: a repository's filters and index hooks don't run for them. Both write the index, and
        // writing it can read a racily clean file through its filter again.
        var env = ["GIT_INDEX_FILE": copy]
        env.merge(configEnv(RepoFilters.off(cwd), after: ProcessInfo.processInfo.environment)) { $1 }
        return try body(env, ["-c", "core.hooksPath=/dev/null"])
    }

    /// Files changed since a snapshot, with line counts ("Changed 3 files +40 −5" after an agent's turn).
    public static func changesSince(tree: String, cwd: String, remotes: Remotes) throws -> [(
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
    public static func branchFiles(_ cwd: String, base: String, remotes: Remotes) throws -> [String] {
        try run(["diff", "--name-only", "--no-renames", "-z", "\(try rev(base))...HEAD"], cwd: cwd, remotes: remotes)
            .split(separator: "\0").map(String.init)
    }
}

/// Putting a folder back as it was at a snapshot (an agent's turn undone).
extension Git {
    /// The files that differ now from snapshot `tree`, secrets left out (`holdsSecrets`: what the user put there stays), and the
    /// snapshot of now, which `restore` is given back so nothing that changes meanwhile is written over.
    public static func changed(since tree: String, cwd: String, remotes: Remotes) throws -> (
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
    /// goes to the Trash. In the index they go back to what `index` (an `indexTree` taken with `tree`) had staged: what
    /// the user staged before the turn stays staged, what was staged since (the undone work) goes, so the next commit
    /// can't take it. Without one (a turn kept before these were, or begun amid conflicts) whatever of them is staged
    /// is unstaged, back to HEAD, which is the turn's. Refused when the folder isn't the snapshot `now` any more;
    /// afterwards none of them may still differ.
    public static func restore(
        _ files: [String], from tree: String, now: String, index: String? = nil, cwd: String, remotes: Remotes
    ) throws {
        func names(_ args: [String]) throws -> Set<String> {
            Set(try run(args, cwd: cwd, remotes: remotes).split(separator: "\0").map(String.init))
        }
        let inTree = { (tree: String) in try names(["ls-tree", "-r", "-z", "--full-tree", "--name-only", rev(tree)]) }
        // Read first, so that nothing slow stands between the check below and the writes after it.
        var staged = files.isEmpty ? [] : try names(["ls-files", "-z", "--"] + literal(files))
        // git takes only paths the index or the source has.
        if let index { staged.formUnion(try inTree(index).intersection(files)) }
        let had = try inTree(tree)
        // Limit: an edit saved after this check and before the restores below (two git runs later, milliseconds) is
        // written over; it isn't in `now`, so Redo doesn't bring it back.
        guard try snapshotTree(cwd, remotes: remotes) == now else {
            throw GitError.refused("The files changed since you looked; nothing was put back.")
        }
        if !staged.isEmpty {
            let source = try index.map { ["--source=" + (try rev($0))] } ?? []
            try run(["restore", "--staged"] + source + ["--"] + literal(staged.sorted()), cwd: cwd, remotes: remotes)
        }
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
            throw GitError.refused("These didn't go back: \(left.sorted().joined(separator: ", ")).")
        }
    }
}
