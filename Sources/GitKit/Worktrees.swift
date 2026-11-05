import Foundation
import Core

extension Git {
    /// Slug safe for directory names: "feat/login ui" -> "feat-login-ui".
    public static func slug(_ branch: String) -> String {
        String(branch.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" ? $0 : "-" })
    }

    /// New branch from `base` in a fresh worktree; copies `copyFiles` present in the repo root.
    public static func addWorktree(repo: String, branch: String, base: String, into dir: URL, copyFiles: [String], remotes: Remotes = .none) throws -> String {
        // "feat/a" and "feat-a" make one slug: the second gets "-2" rather than a confusing "already exists" from git.
        var path = dir.appendingPathComponent(slug(branch)).path, n = 2
        while FileManager.default.fileExists(atPath: path) { path = dir.appendingPathComponent("\(slug(branch))-\(n)").path; n += 1 }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try run(["worktree", "add", "-b", rev(branch), path, rev(base)], cwd: repo, remotes: remotes)
        let fm = FileManager.default
        for f in Array(Set(copyFiles + includedIgnoredFiles(repo: repo, remotes: remotes))) {
            let src = (repo as NSString).appendingPathComponent(f), dst = (path as NSString).appendingPathComponent(f)
            guard fm.fileExists(atPath: src), !fm.fileExists(atPath: dst), staysInside(dst, path) else { continue }
            try? fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? fm.copyItem(atPath: src, toPath: dst)
        }
        return path
    }

    /// Gitignored files matching `.worktreeinclude` globs (e.g. `.env*`, `config/*.local.json`) — copied into new worktrees.
    public static func includedIgnoredFiles(repo: String, remotes: Remotes = .none) -> [String] {
        guard let text = try? String(contentsOfFile: repo + "/.worktreeinclude", encoding: .utf8) else { return [] }
        let pats = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let ignored = ((try? run(["ls-files", "--others", "--ignored", "--exclude-standard", "-z"], cwd: repo, remotes: remotes)) ?? "")
            .split(separator: "\0").map(String.init)
        return ignored.filter { f in pats.contains { fnmatch($0, f, 0) == 0 || fnmatch($0, (f as NSString).lastPathComponent, 0) == 0 } }
    }

    /// `dst` is still in `root` once symlinks are followed: a folder the branch commits as a link (`conf -> ~/x`) would
    /// take the copy (the user's ignored `.env`), or the folders made for it, out of the worktree.
    static func staysInside(_ dst: String, _ root: String) -> Bool {
        var folder = (dst as NSString).deletingLastPathComponent
        while !FileManager.default.fileExists(atPath: folder), folder.count > 1 { folder = (folder as NSString).deletingLastPathComponent }
        let real = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path, inside = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        return real == inside || real.hasPrefix(inside + "/")
    }

    /// Symlink shared directories (node_modules, .venv…) from the main checkout instead of reinstalling.
    public static func linkShared(_ dirs: [String], repo: String, worktree: String) {
        place(dirs, repo: repo, worktree: worktree) { src, dst in try? FileManager.default.createSymbolicLink(atPath: dst, withDestinationPath: src) }
    }

    /// `.kelp.yaml`'s `clone:` paths copied into a new worktree as APFS clones: seconds and next to no disk, and each
    /// branch has its own (`npm install` there changes only its copy). Off APFS (another volume) a path is left out:
    /// a real copy of a node_modules would hold the new worktree up for minutes.
    public static func cloneShared(_ dirs: [String], repo: String, worktree: String) {
        place(dirs, repo: repo, worktree: worktree) { src, dst in _ = clonefile(src, dst, 0) }
    }

    private static func place(_ dirs: [String], repo: String, worktree: String, _ put: (_ src: String, _ dst: String) -> Void) {
        // Only paths inside the project: "/etc", "../x" or "a/../../b" would link (or create folders) outside it.
        for d in dirs where !d.hasPrefix("/") && !d.hasPrefix("~") && !d.split(separator: "/").contains("..") {
            let src = (repo as NSString).appendingPathComponent(d), dst = (worktree as NSString).appendingPathComponent(d)
            guard FileManager.default.fileExists(atPath: src), !FileManager.default.fileExists(atPath: dst), staysInside(dst, worktree) else { continue }
            try? FileManager.default.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            put(src, dst)
        }
    }

    /// The repo's other checkouts, wherever `git worktree add` put them (an agent's `.claude/worktrees/…`, Kelp's own):
    /// `git worktree list` without its first entry, the main checkout.
    /// NUL-separated here (`-z`), so a path with a newline in it can't read as another worktree or a lock; a host's git
    /// may be older than that (2.36), so a remote project's list is read by lines.
    public static func linkedWorktrees(_ repo: String, remotes: Remotes = .none) throws -> [(path: String, branch: String?, locked: Bool)] {
        let nul = remotes.of(repo) == nil
        let out = try run(["worktree", "list", "--porcelain"] + (nul ? ["-z"] : []), cwd: repo, remotes: remotes)
        return out.components(separatedBy: nul ? "\0\0" : "\n\n").dropFirst().compactMap { b in
            let lines = b.split(separator: nul ? "\0" : "\n")
            guard let p = lines.first(where: { $0.hasPrefix("worktree ") }) else { return nil }
            let branch = lines.first { $0.hasPrefix("branch refs/heads/") }.map { String($0.dropFirst(18)) }.flatMap { Git.isRevision($0) ? $0 : nil }
            return (String(p.dropFirst(9)), branch, lines.contains { $0 == "locked" || $0.hasPrefix("locked ") })
        }
    }

    public static func renameBranch(_ path: String, from old: String, to new: String, remotes: Remotes = .none) throws {
        try run(["branch", "-m", rev(old), rev(new)], cwd: path, remotes: remotes)
    }

    public static func branchExists(_ repo: String, _ b: String, remotes: Remotes = .none) -> Bool {
        (try? run(["rev-parse", "--verify", "--quiet", "refs/heads/" + b], cwd: repo, remotes: remotes)) != nil
    }

    public static func isDirty(_ path: String, remotes: Remotes = .none) throws -> Bool {
        // Whatever `status.showUntrackedFiles` says: new files count, it decides what's asked before a folder goes.
        !(try run(["status", "--porcelain", "--untracked-files=normal"], cwd: path, remotes: remotes)).isEmpty
    }

    /// Remove worktree and its branch. Refuses dirty worktrees unless `force`, and a branch with commits that are on no
    /// other branch or remote unless `force` or `dropCommits` (they'd be gone for good). Both checks come first: on
    /// refusal nothing has been removed. A local folder goes to the Trash: what git doesn't see (ignored .env files, a
    /// local database, submodules' own work) isn't checked above, and `worktree remove --force` would delete it for good.
    public static func removeWorktree(repo: String, path: String, branch: String?, force: Bool, dropCommits: Bool = false, remotes: Remotes = .none) throws {
        try checkRemovable(repo: repo, path: path, branch: branch, force: force, dropCommits: dropCommits, remotes: remotes)
        let host = remotes.of(repo), local = host == nil && remotes.of(path) == nil
        if host != nil || (local && FileManager.default.fileExists(atPath: path)) {
            // Only a folder git lists as this repo's worktree goes to the Trash (or aside on a host), whatever the record says.
            let real = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            // A host's path as git lists it, links followed there (git lists /private/tmp for /tmp).
            let here = try host.map { h in
                String(decoding: try h.run("cd -- \(IDE.shellWord(path)) 2>/dev/null && pwd -P || printf %s \(IDE.shellWord(path))"),
                       as: UTF8.self).trimmingCharacters(in: .newlines)
            } ?? real(path)
            guard let entry = try linkedWorktrees(repo, remotes: remotes).first(where: { (local ? real($0.path) : $0.path) == here }) else {
                throw GitError(args: ["worktree", "remove"], status: 1, stderr: "\(path) is not a worktree of this repository")
            }
            // Locked (`git worktree lock`: kept on purpose): git wouldn't remove its record, so the folder stays too.
            guard !entry.locked else { throw GitError(args: ["worktree", "remove"], status: 1, stderr: "\(path) is locked (git worktree unlock)") }
        }
        if local, FileManager.default.fileExists(atPath: path) { try Trash.move(URL(fileURLWithPath: path)) }
        // A remote project's: what git doesn't see (ignored .env files, a local database) is moved aside on the host, into
        // ~/.kelp-trash, rather than deleted for good by `worktree remove --force`. The shell's pid keeps two removals
        // of a same-named folder in one second apart.
        if let host {
            let q = IDE.shellWord, aside = "\((path as NSString).lastPathComponent)-\(Int(Date().timeIntervalSince1970))"
            _ = try host.run("d=\"${KELP_TRASH:-$HOME/.kelp-trash}\"; mkdir -p \"$d\" && if [ -e \(q(path)) ]; then mv -- \(q(path)) \"$d\"/\(q(aside))-$$; fi")
        }
        // Its record only: `worktree prune` would also drop worktrees whose folder is just away (an unmounted disk).
        try run(["worktree", "remove", "--force", path], cwd: repo, remotes: remotes)
        if let branch { try run(["branch", "-D", rev(branch)], cwd: repo, remotes: remotes) }
    }

    /// What `removeWorktree` would refuse, without removing anything.
    public static func checkRemovable(repo: String, path: String, branch: String?, force: Bool, dropCommits: Bool = false, remotes: Remotes = .none) throws {
        if !force, try isDirty(path, remotes: remotes) {
            throw GitError(args: ["worktree", "remove"], status: 1, stderr: "worktree has uncommitted changes")
        }
        // `force` is about uncommitted changes; commits are lost only when asked for by name (dropCommits).
        if let branch, !dropCommits, case let n = try onlyOnBranch(repo: repo, branch, remotes: remotes), n > 0 {
            throw GitError(args: ["branch", "-D", branch], status: 1,
                           stderr: "\(branch) has \(n) commit\(n == 1 ? "" : "s") that aren't on any other branch or remote")
        }
        // Commits made on a detached HEAD belong to no branch at all: removing the folder would leave them to `git gc`.
        if !dropCommits, remotes.of(path) != nil || FileManager.default.fileExists(atPath: path),
           case let n = commitsOnNoBranch(path, remotes: remotes), n > 0 {
            throw GitError(args: ["worktree", "remove"], status: 1,
                           stderr: "This workspace has \(n) commit\(n == 1 ? "" : "s") on no branch (a detached HEAD). Create a branch for them first.")
        }
    }

    /// Commits made on a detached HEAD in the worktree at `path` that no branch or remote has (no commits yet: 0).
    public static func commitsOnNoBranch(_ path: String, remotes: Remotes = .none) -> Int {
        let out = try? run(["rev-list", "--count", "HEAD", "--not", "--branches", "--remotes"], cwd: path, remotes: remotes)
        return Int(out?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    /// Commits on `branch` that no other local branch and no remote branch has: what deleting it would lose.
    public static func onlyOnBranch(repo: String, _ branch: String, remotes: Remotes = .none) throws -> Int {
        // --exclude before --branches takes the branch's name without refs/heads/ (with it, nothing is excluded).
        let out = try run(["rev-list", "--count", "refs/heads/" + branch, "--not", "--exclude=" + branch, "--branches", "--remotes"],
                          cwd: repo, remotes: remotes)
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}
