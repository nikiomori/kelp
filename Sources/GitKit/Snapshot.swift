import Core
import Foundation
import os

extension Git {
    /// Writes the working tree as it is now (tracked and new files, .gitignore respected) as a tree object, so that a
    /// later diff shows exactly what changed since. A copy of the index is updated, never the real one, and files whose
    /// stat didn't change aren't hashed again.
    public static func snapshotTree(_ cwd: String, remotes: Remotes) throws -> String {
        let add = try addAll(cwd, remotes: remotes)
        if let host = remotes.of(cwd) { return try onHostIndexCopy(host, [add, ["write-tree"]]).last ?? "" }
        return try onIndexCopy(cwd, remotes: remotes) { env, quiet in
            try run(quiet + add, cwd: cwd, env: env, remotes: remotes)
            return try line(quiet + ["write-tree"], cwd: cwd, env: env, remotes: remotes)
        }
    }

    /// Takes what a turn begins with: `snapshotTree`, and what is staged (`indexTree`), written from the same copy of
    /// the index before `add -A` changes it. `staged` is nil when there are unresolved conflicts (git writes no tree of
    /// those) or when write-tree failed for another reason, and the turn does without it. The result is nil in a folder
    /// without git, which has no tree to write. That isn't a failure, but anything else git couldn't do here is.
    public static func turnSnapshot(_ cwd: String, remotes: Remotes) throws -> (tree: String, staged: String?)? {
        let add: [String]
        do { add = try addAll(cwd, remotes: remotes) } catch  where ProjectFiles.outsideGit(error) { return nil }
        if let host = remotes.of(cwd) {
            let out = try onHostIndexCopy(host, [add, ["write-tree"]], stagedFirst: true)
            let staged = out.count >= 2 && out[0] != "-" ? out[0] : nil
            return (out.last ?? "", staged)
        }
        return try onIndexCopy(cwd, remotes: remotes) { env, quiet in
            var staged: String?
            do { staged = try line(quiet + ["write-tree"], cwd: cwd, env: env, remotes: remotes) } catch {
                gitLog.debug("no staged tree for the turn (conflicts, most likely): \(error)")
            }
            try run(quiet + add, cwd: cwd, env: env, remotes: remotes)
            return (try line(quiet + ["write-tree"], cwd: cwd, env: env, remotes: remotes), staged)
        }
    }

    /// Returns `add -A` from the top, leaving out new files that look like secrets (a key, .env). Otherwise
    /// refs/kelp/turns would pin them in git for good, and `git push --mirror` would send them.
    private static func addAll(_ cwd: String, remotes: Remotes) throws -> [String] {
        let secrets = try run(
            ["ls-files", "-z", "-o", "--exclude-standard", "--full-name", "--", ":/"], cwd: cwd, remotes: remotes
        )
        .split(separator: "\0").map(String.init).filter { holdsSecrets(($0 as NSString).lastPathComponent) }
        return ["add", "-A"] + (secrets.isEmpty ? [] : ["--", ":/"] + secrets.map { ":(top,exclude,literal)" + $0 })
    }

    /// Returns the object that `rev` names (a ref, `HEAD`, `<tree>^{tree}`), or nil when there's none: a ref never
    /// made, a snapshot git has cleaned up, or a repository with no commit yet.
    public static func resolve(_ rev: String, cwd: String, remotes: Remotes) throws -> String? {
        let object = try line(["rev-parse", "--verify", "-q", rev], cwd: cwd, ok: [0, 1], remotes: remotes)
        return object.isEmpty ? nil : object
    }

    /// Returns the commit checked out, or nil before the first commit.
    public static func head(_ cwd: String, remotes: Remotes) throws -> String? {
        try resolve("HEAD", cwd: cwd, remotes: remotes)
    }

    /// Keeps `object` under `ref` (a snapshot under refs/kelp/…, so `git gc` leaves it), or drops the ref when `object`
    /// is nil. `reflog` is the line that the ref's log keeps for this change, so what the ref pointed at before stays
    /// reachable too.
    public static func setRef(
        _ ref: String, to object: String?, reflog: String? = nil, cwd: String, remotes: Remotes
    ) throws {
        let log = reflog.map { ["--create-reflog", "-m", $0] } ?? []
        try run(["update-ref"] + log + (object.map { [ref, $0] } ?? ["-d", ref]), cwd: cwd, remotes: remotes)
    }

    /// Sets each (ref, object) pair in `set` and drops `refs`, in one git run. A ref that is already gone doesn't stop
    /// the others.
    public static func deleteRefs(
        _ refs: [String], setting set: [(ref: String, object: String)] = [], cwd: String, remotes: Remotes
    ) throws {
        let lines = try set.map { "update \($0.ref) \(try rev($0.object))\n" } + refs.map { "delete \($0)\n" }
        try run(["update-ref", "--stdin"], cwd: cwd, stdin: lines.joined(), remotes: remotes)
    }

    /// Writes what is staged now as a tree object, which is kept beside a turn's snapshot so that undoing the turn puts
    /// the index back as well as the files. It is written from a copy of the index too, because `write-tree` on the
    /// real index rewrites it under its lock, and an agent's `git add` then finds the lock taken. Returns nil when
    /// unresolved conflicts leave no tree to write (git writes no tree of those, and this is checked only after
    /// write-tree failed). A file added with `git add -N` isn't in the tree.
    public static func indexTree(_ cwd: String, remotes: Remotes) throws -> String? {
        do {
            if let host = remotes.of(cwd) { return try onHostIndexCopy(host, [["write-tree"]]).last }
            return try onIndexCopy(cwd, remotes: remotes) { env, quiet in
                try line(quiet + ["write-tree"], cwd: cwd, env: env, remotes: remotes)
            }
        } catch let error as GitError {
            guard case .failed = error, try !run(["ls-files", "-u"], cwd: cwd, remotes: remotes).isEmpty else {
                throw error
            }
            return nil
        }
    }

    /// Runs `body` with the environment that points git at a copy of the index, never the real one, and with the
    /// arguments that keep the repository's hooks out of it.
    private static func onIndexCopy<T>(
        _ cwd: String, remotes: Remotes, _ body: (_ env: [String: String], _ quiet: [String]) throws -> T
    ) throws -> T {
        // On a remote project git runs on the host, which neither GIT_INDEX_FILE nor this Mac's copy of the index
        // reach. `add -A` would then stage everything in the host's real index, so `onHostIndexCopy` handles remote
        // projects instead.
        if remotes.of(cwd) != nil {
            throw GitError.refused("A remote project's index is copied on its host.")
        }
        let real = try indexFile(cwd, remotes: remotes)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-index-\(UUID().uuidString)").path
        defer { FileManager.default.removeIfAny(URL(fileURLWithPath: copy)) }
        if FileManager.default.fileExists(atPath: real) { try FileManager.default.copyItem(atPath: real, toPath: copy) }
        // Nobody asked for these runs, so a repository's filters and index hooks don't run for them. Both runs write
        // the index, and writing it can read a racily clean file through its filter again.
        var env = ["GIT_INDEX_FILE": copy]
        env.merge(configEnv(RepoFilters.off(cwd), after: ProcessInfo.processInfo.environment)) { $1 }
        return try body(env, ["-c", "core.hooksPath=/dev/null"])
    }

    /// Returns the real index file for `cwd` (`--git-path index`, because a linked worktree's index is in the main
    /// repository). git is asked once per folder, and again when the file it named isn't there.
    /// Limit: a folder that becomes another repository's worktree while its old index file stays copies that one.
    static func indexFile(_ cwd: String, remotes: Remotes) throws -> String {
        if let known = indexFiles.withLock({ $0[cwd] }), FileManager.default.fileExists(atPath: known) { return known }
        let rel = try line(["rev-parse", "--git-path", "index"], cwd: cwd, remotes: remotes)
        let real = URL(fileURLWithPath: rel, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)).path
        indexFiles.withLock { $0[cwd] = real }
        return real
    }
    private static let indexFiles = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    /// Runs `runs` of git on a remote project's host, one after another, in one round trip. They work on a copy of the
    /// index in the host's temporary folder (never the real one), with the repository's hooks off. Returns the lines
    /// they printed. `stagedFirst` adds a `write-tree` before them, whose line is `-` when it fails (conflicts), and
    /// that failure doesn't stop the others.
    private static func onHostIndexCopy(_ host: RemoteHost, _ runs: [[String]], stagedFirst: Bool = false) throws
        -> [String]
    {
        let quiet = "git -c core.quotePath=false -c core.fsmonitor=false -c core.hooksPath=/dev/null "
        let git =
            (stagedFirst ? "{ \(quiet)write-tree 2>/dev/null || echo -; } && " : "")
            + runs.map { quiet + $0.map(ShellQuote.word).joined(separator: " ") }.joined(separator: " && ")
        let script =
            "cd \(RemoteHost.cdArg(host.path)) && "
            + #"i=$(git rev-parse --git-path index) && t=$(mktemp "${TMPDIR:-/tmp}/kelp-index-XXXXXX") && "#
            + #"{ if [ -f "$i" ]; then cp "$i" "$t"; else rm -f "$t"; fi; } && "#
            + #"export GIT_INDEX_FILE="$t" GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 && "# + git
            + #"; r=$?; rm -f "$t"; exit $r"#
        do {
            let out = String(decoding: try host.run(script, timeLimit: 300), as: UTF8.self)
            return out.split(whereSeparator: \.isNewline).map(String.init)
        } catch let error as ProgramError {
            throw GitError.failed(args: runs.last ?? [], status: error.status, stderr: error.stderr)
        }
    }

    /// Files changed since a snapshot, with line counts ("Changed 3 files +40 −5" after an agent's turn).
    public static func changesSince(tree: String, cwd: String, remotes: Remotes) throws -> [(
        path: String, added: Int, removed: Int
    )] {
        let now = try snapshotTree(cwd, remotes: remotes)
        guard now != tree else { return [] }
        return try numstat(rev(tree), now, cwd: cwd, remotes: remotes)
    }

    /// The files that differ from tree `a` to tree `b`, with the lines added and removed (`git diff --numstat`).
    public static func numstat(_ base: String, _ head: String, cwd: String, remotes: Remotes) throws -> [(
        path: String, added: Int, removed: Int
    )] {
        try run(["diff", "--numstat", "--no-renames", "-z", base, head], cwd: cwd, remotes: remotes).split(
            separator: "\0"
        )
        .compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2)
            guard fields.count == 3 else { return nil }
            return (String(fields[2]), Int(fields[0]) ?? 0, Int(fields[1]) ?? 0)
        }
    }
}

extension Git {
    /// Returns the files that HEAD changed since it left `base` (their merge base), counting committed changes only.
    /// `status` has the rest.
    public static func branchFiles(_ cwd: String, base: String, remotes: Remotes) throws -> [String] {
        try run(["diff", "--name-only", "--no-renames", "-z", "\(try rev(base))...HEAD"], cwd: cwd, remotes: remotes)
            .split(separator: "\0").map(String.init)
    }
}

/// Puts a folder back as it was at a snapshot, to undo an agent's turn.
extension Git {
    /// Returns the files that differ now from snapshot `tree`, leaving out secrets (`holdsSecrets`), so what the user
    /// put there stays. It also returns the snapshot of now, which is given back to `restore` so that nothing that
    /// changes meanwhile is written over.
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

    /// Whether a file name is one of the user's secrets, which are never put back, nor snapshotted when new: `.env`,
    /// `.env.local`, `.env.production`, private keys and certificates (`id_rsa`, `*.pem`, `*.p12`), and a cloud SDK's
    /// `credentials.json`. A template committed for others (`.env.example`), direnv's `.envrc` and a public key
    /// (`id_rsa.pub`) are code like any other.
    static func holdsSecrets(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return name == ".env"
            || name.hasPrefix(".env.")
                && !["example", "sample", "template", "dist", "defaults"].contains(name.dropFirst(5))
            || ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "credentials.json"].contains(name)
            || ["pem", "key", "p12", "pfx"].contains(ext)
    }

    /// Puts `files` (paths from the repository's top, `cwd`) back as they were in `tree`, content and mode. A file that
    /// the tree doesn't have goes to the Trash. In the index, the files go back to what `index` (an `indexTree` taken
    /// with `tree`) had staged. What the user staged before the turn stays staged, and what was staged since (the
    /// undone work) is removed, so the next commit can't take it. Without `index` (a turn kept before index trees
    /// existed, or one begun amid conflicts), whatever of the files is staged is unstaged back to HEAD, which is the
    /// turn's. The restore is refused when the folder isn't the snapshot `now` any more, and afterwards none of the
    /// files may still differ.
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
        let new = files.filter { !had.contains($0) }
        if let host = remotes.of(cwd), !new.isEmpty {
            // On a host, new files move into the repository's own .git/kelp-trash (git doesn't list it), as the Files
            // panel trashes them.
            let quoted = new.map(ShellQuote.word).joined(separator: " ")
            try host.run(
                "cd \(RemoteHost.cdArg(host.path)) && "
                    + #"d=".git/kelp-trash/$(date +%s)-$$"; for f in \#(quoted); do [ -e "$f" ] || [ -L "$f" ] || continue; "#
                    + #"mkdir -p "$d/$(dirname -- "$f")" && mv -- "$f" "$d/$f" || exit 1; done"#, timeLimit: 120)
        }
        for file in new where remotes.of(cwd) == nil && FileManager.default.fileExists(atPath: cwd + "/" + file) {
            try Trash.move(URL(fileURLWithPath: cwd + "/" + file))
        }
        let left = Set(try changed(since: tree, cwd: cwd, remotes: remotes).files).intersection(files)
        guard left.isEmpty else {
            throw GitError.refused("These didn't go back: \(left.sorted().joined(separator: ", ")).")
        }
    }
}
