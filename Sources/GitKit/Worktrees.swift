import Core
import Foundation

extension Git {
    /// Slug safe for directory names: "feat/login ui" -> "feat-login-ui".
    public static func slug(_ branch: String) -> String {
        String(branch.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" ? $0 : "-" })
    }

    /// New branch from `base` in a fresh worktree; copies `copyFiles` present in the repo root. `existing`: a branch that is
    /// there already, checked out as it is (a remote one, "origin/x", gets a local "x" that follows it); `base` unused.
    /// `copying`: the project's own files a worktree gets (`copyFiles`, `.worktreeinclude`'s: `.env` and the like), which
    /// a pull request's code shouldn't have to read.
    public static func addWorktree(   // swiftlint:disable:this function_parameter_count
        repo: String, branch: String, base: String, into dir: URL, copyFiles: [String], existing: Bool = false,
        copying: Bool = true, remotes: Remotes
    ) throws -> String {
        // "feat/a" and "feat-a" make one slug: the second gets "-2" rather than a confusing "already exists" from git.
        var path = dir.appendingPathComponent(slug(branch)).path, n = 2
        while FileManager.default.fileExists(atPath: path) {
            path = dir.appendingPathComponent("\(slug(branch))-\(n)").path
            n += 1
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !existing {
            try run(["worktree", "add", "-b", rev(branch), path, rev(base)], cwd: repo, remotes: remotes)
        } else if branchExists(repo, branch, remotes: remotes) {
            try run(["worktree", "add", path, rev(branch)], cwd: repo, remotes: remotes)
        } else {   // "origin/x": a local "x" following it, or the local "x" there is already
            let local = branch.split(separator: "/", maxSplits: 1).last.map(String.init) ?? branch
            if branchExists(repo, local, remotes: remotes) {
                try run(["worktree", "add", path, rev(local)], cwd: repo, remotes: remotes)
            } else {
                try run(
                    ["worktree", "add", "--track", "-b", rev(local), path, rev(branch)], cwd: repo, remotes: remotes)
            }
        }
        let fm = FileManager.default
        for file in copying ? Array(Set(copyFiles + includedIgnoredFiles(repo: repo, remotes: remotes))) : [] {
            let src = (repo as NSString).appendingPathComponent(file),
                dst = (path as NSString).appendingPathComponent(file)
            guard fm.fileExists(atPath: src), !fm.fileExists(atPath: dst), staysInside(dst, path) else { continue }
            gitLog.attempt("copying \(file) into the new worktree") {
                try fm.createDirectory(
                    atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try fm.copyItem(atPath: src, toPath: dst)
            }
        }
        return path
    }

    /// A pull request's head (GitHub's pull/N/head, else GitLab's merge-requests/N/head, from `origin`) as a local branch,
    /// and that branch's name: `wanted` (the PR's own branch name) only when it is free and already at the head, your own PR
    /// up to date; else `pr-<N>`, moved to the head now. A local branch that only shares the PR's name is never taken for it.
    @discardableResult
    public static func fetchPullRequest(repo: String, number: Int, wanted: String? = nil, remotes: Remotes)
        throws -> String
    {
        do { try run(["fetch", "-q", "origin", "pull/\(number)/head"], cwd: repo, remotes: remotes) } catch let github {
            // GitHub's error, if GitLab's way fails too: most projects are GitHub's.
            do {
                try run(["fetch", "-q", "origin", "merge-requests/\(number)/head"], cwd: repo, remotes: remotes)
            } catch { throw github }
        }
        func line(_ args: [String]) throws -> String { try Git.line(args, cwd: repo, ok: [0, 1], remotes: remotes) }
        let head = try line(["rev-parse", "FETCH_HEAD"])
        // Kept past its branch (`holdsPullRequest`): a workspace made later on top of it is the PR's code too.
        try run(["update-ref", "refs/kelp/pr/\(number)", head], cwd: repo, remotes: remotes)
        func at(_ branch: String) throws -> String { try line(["rev-parse", "--verify", "-q", "refs/heads/" + branch]) }
        func openIn(_ branch: String) throws -> String {
            try line(["for-each-ref", "--format=%(worktreepath)", "refs/heads/" + branch])
        }
        if let wanted, Git.isRevision(wanted), try at(wanted) == head, try openIn(wanted).isEmpty { return wanted }
        // pr-<N>, moved on from an older fetch of this PR; pr-<N>-2… when it holds commits of its own, which stay.
        var mine = "pr-\(number)", attempt = 2
        while true {
            let now = try at(mine), open = try openIn(mine)
            if now.isEmpty {
                try run(["branch", mine, head], cwd: repo, remotes: remotes)
                return mine
            }
            if !open.isEmpty {
                throw GitError.refused("Pull request #\(number) is open already, in \(open).")
            }
            if try now == head || line(["merge-base", now, head]) == now {
                try run(["branch", "-f", mine, head], cwd: repo, remotes: remotes)
                return mine
            }
            mine = "pr-\(number)-\(attempt)"
            attempt += 1
        }
    }

    /// Whether `rev` in `repo` holds a pull request's code that the project's branches don't (origin's and upstream's: one
    /// merged and pushed is the project's own): a head Kelp fetched (`fetchPullRequest`), a `pr-*` branch, or a branch that follows a PR's ref
    /// (`gh pr checkout`, `glab mr checkout`: its `branch.<name>.merge` is refs/pull/… or refs/merge-requests/…). A
    /// fetched head found merged and pushed is dropped. Unknown (git failed): it does.
    public static func holdsPullRequest(_ repo: String, at rev: String = "HEAD", remotes: Remotes) -> Bool {
        do {
            let merges = try run(
                ["config", "--get-regexp", #"^branch\..*\.merge$"#], cwd: repo, ok: [0, 1], remotes: remotes)
            let following = merges.split(separator: "\n").compactMap { line -> String? in
                let kv = line.split(separator: " ", maxSplits: 1)
                guard kv.count == 2, kv[1].hasPrefix("refs/pull/") || kv[1].hasPrefix("refs/merge-requests/") else {
                    return nil
                }
                return "refs/heads/" + kv[0].dropFirst("branch.".count).dropLast(".merge".count)
            }
            let heads = try run(
                [
                    "for-each-ref", "--merged", rev, "--format=%(refname) %(objectname)", "refs/kelp/pr/",
                    "refs/heads/pr-*"
                ]
                    + following, cwd: repo, remotes: remotes)
            for line in heads.split(separator: "\n") {
                let ref = String(line.prefix { $0 != " " }), sha = String(line.drop { $0 != " " }.dropFirst())
                // The project's branches: origin's, and upstream's in a fork's checkout (where origin is the user's fork).
                let own = ["--not", "--remotes=origin", "--remotes=upstream"]
                guard try run(["rev-list", "-n1", sha] + own, cwd: repo, remotes: remotes).isEmpty else { return true }
                if ref.hasPrefix("refs/kelp/pr/") { try run(["update-ref", "-d", ref], cwd: repo, remotes: remotes) }
            }
            return false
        } catch { return true }
    }

    /// Gitignored files matching `.worktreeinclude` globs (e.g. `.env*`, `config/*.local.json`) — copied into new worktrees.
    public static func includedIgnoredFiles(repo: String, remotes: Remotes) -> [String] {
        guard let text = String(contentsIfAny: URL(fileURLWithPath: repo + "/.worktreeinclude")) else { return [] }
        let pats = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter {
            !$0.isEmpty && !$0.hasPrefix("#")
        }
        let ignored =
            ((try? run(["ls-files", "--others", "--ignored", "--exclude-standard", "-z"], cwd: repo, remotes: remotes))
            ?? "")
            .split(separator: "\0").map(String.init)
        return ignored.filter { file in
            pats.contains { fnmatch($0, file, 0) == 0 || fnmatch($0, (file as NSString).lastPathComponent, 0) == 0 }
        }
    }

    /// `dst` is still in `root` once symlinks are followed: a folder the branch commits as a link (`conf -> ~/x`) would
    /// take the copy (the user's ignored `.env`), or the folders made for it, out of the worktree.
    static func staysInside(_ dst: String, _ root: String) -> Bool {
        Paths.inside((dst as NSString).deletingLastPathComponent, root)
    }

    /// Symlink shared directories (node_modules, .venv…) from the main checkout instead of reinstalling.
    public static func linkShared(_ dirs: [String], repo: String, worktree: String) {
        place(dirs, repo: repo, worktree: worktree) { src, dst in
            gitLog.attempt("linking \(dst) to the main checkout's") {
                try FileManager.default.createSymbolicLink(atPath: dst, withDestinationPath: src)
            }
        }
    }

    /// `.kelp.yaml`'s `clone:` paths copied into a new worktree as APFS clones: seconds and next to no disk, and each
    /// branch has its own (`npm install` there changes only its copy). Off APFS (another volume) a path is left out:
    /// a real copy of a node_modules would hold the new worktree up for minutes. Returns the paths left out, and why.
    @discardableResult
    public static func cloneShared(_ dirs: [String], repo: String, worktree: String) -> [String] {
        var left: [String] = []
        place(dirs, repo: repo, worktree: worktree) { src, dst in
            // A link the branch commits (node_modules -> ~/.ssh) isn't followed.
            if clonefile(src, dst, UInt32(CLONE_NOFOLLOW)) != 0 {
                left.append("\((src as NSString).lastPathComponent): \(String(cString: strerror(errno)))")
            }
        }
        return left
    }

    private static func place(
        _ dirs: [String], repo: String, worktree: String, _ put: (_ src: String, _ dst: String) -> Void
    ) {
        // Only paths inside the project: "/etc", "../x" or "a/../../b" would link (or create folders) outside it.
        for dir in dirs where !dir.hasPrefix("/") && !dir.hasPrefix("~") && !dir.split(separator: "/").contains("..") {
            let src = (repo as NSString).appendingPathComponent(dir),
                dst = (worktree as NSString).appendingPathComponent(dir)
            guard FileManager.default.fileExists(atPath: src), !FileManager.default.fileExists(atPath: dst),
                staysInside(dst, worktree)
            else { continue }
            gitLog.attempt("making the folder for \(dir)") {
                try FileManager.default.createDirectory(
                    atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            }
            put(src, dst)
        }
    }

    /// The repo's other checkouts, wherever `git worktree add` put them (an agent's `.claude/worktrees/…`, Kelp's own):
    /// `git worktree list` without its first entry, the main checkout.
    /// NUL-separated here (`-z`), so a path with a newline in it can't read as another worktree or a lock; a host's git
    /// may be older than that (2.36), so a remote project's list is read by lines.
    public static func linkedWorktrees(_ repo: String, remotes: Remotes) throws -> [(
        path: String, branch: String?, locked: Bool
    )] {
        let nul = remotes.of(repo) == nil
        let out = try run(["worktree", "list", "--porcelain"] + (nul ? ["-z"] : []), cwd: repo, remotes: remotes)
        return out.components(separatedBy: nul ? "\0\0" : "\n\n").dropFirst().compactMap { block in
            let lines = block.split(separator: nul ? "\0" : "\n")
            guard let worktreeLine = lines.first(where: { $0.hasPrefix("worktree ") }) else { return nil }
            let branch = lines.first { $0.hasPrefix("branch refs/heads/") }.map { String($0.dropFirst(18)) }.flatMap {
                Git.isRevision($0) ? $0 : nil
            }
            return (
                String(worktreeLine.dropFirst(9)), branch, lines.contains { $0 == "locked" || $0.hasPrefix("locked ") }
            )
        }
    }

    public static func renameBranch(_ path: String, from old: String, to new: String, remotes: Remotes) throws {
        try run(["branch", "-m", rev(old), rev(new)], cwd: path, remotes: remotes)
    }

    public static func branchExists(_ repo: String, _ branch: String, remotes: Remotes) -> Bool {
        succeeds(["rev-parse", "--verify", "--quiet", "refs/heads/" + branch], cwd: repo, remotes: remotes)
    }

    public static func isDirty(_ path: String, remotes: Remotes) throws -> Bool {
        // Whatever `status.showUntrackedFiles` says: new files count, it decides what's asked before a folder goes.
        let changes = try run(["status", "--porcelain", "--untracked-files=normal"], cwd: path, remotes: remotes)
        // A new link is no work: what it points at isn't in this folder (an agent links the project's Vendor in, and
        // `Vendor/` in .gitignore doesn't match a link). A host's folder isn't read from here: there, it counts.
        let local = remotes.of(path) == nil
        return changes.split(separator: "\n").contains { line in
            guard local, line.hasPrefix("?? ") else { return true }
            let file = (path as NSString).appendingPathComponent(String(line.dropFirst(3)))
            var info = stat()
            return lstat(file, &info) != 0 || info.st_mode & S_IFMT != S_IFLNK
        }
    }

    /// Remove worktree and its branch. Refuses dirty worktrees unless `force`, and a branch with commits that are on no
    /// other branch or remote unless `force` or `dropCommits` (they'd be gone for good). Both checks come first: on
    /// refusal nothing has been removed. A local folder goes to the Trash: what git doesn't see (ignored .env files, a
    /// local database, submodules' own work) isn't checked above, and `worktree remove --force` would delete it for good.
    public static func removeWorktree(
        repo: String, path: String, branch: String?, force: Bool, dropCommits: Bool = false, remotes: Remotes
    ) throws {
        try checkRemovable(
            repo: repo, path: path, branch: branch, force: force, dropCommits: dropCommits, remotes: remotes)
        let host = remotes.of(repo), local = host == nil && remotes.of(path) == nil
        if host != nil || (local && FileManager.default.fileExists(atPath: path)) {
            // Only a folder git lists as this repo's worktree goes to the Trash (or aside on a host), whatever the record says.
            let real = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            // A host's path as git lists it, links followed there (git lists /private/tmp for /tmp).
            let here =
                try host.map { remote in
                    String(
                        decoding: try remote.run(
                            "cd -- \(ShellQuote.word(path)) 2>/dev/null && pwd -P || printf %s \(ShellQuote.word(path))"
                        ),
                        as: UTF8.self
                    ).trimmingCharacters(in: .newlines)
                } ?? real(path)
            guard
                let entry = try linkedWorktrees(repo, remotes: remotes).first(where: {
                    (local ? real($0.path) : $0.path) == here
                })
            else {
                throw GitError.refused("\(path) is not a worktree of this repository")
            }
            // Locked (`git worktree lock`: kept on purpose): git wouldn't remove its record, so the folder stays too.
            guard !entry.locked else {
                throw GitError.refused("\(path) is locked (git worktree unlock)")
            }
        }
        if local, FileManager.default.fileExists(atPath: path) { try Trash.move(URL(fileURLWithPath: path)) }
        // A remote project's: what git doesn't see (ignored .env files, a local database) is moved aside on the host, into
        // ~/.kelp-trash, rather than deleted for good by `worktree remove --force`. The shell's pid keeps two removals
        // of a same-named folder in one second apart.
        if let host {
            let quote = ShellQuote.word,
                aside = "\((path as NSString).lastPathComponent)-\(Int(Date().timeIntervalSince1970))"
            _ = try host.run(
                "d=\"${KELP_TRASH:-$HOME/.kelp-trash}\"; mkdir -p \"$d\" && if [ -e \(quote(path)) ]; then mv -- \(quote(path)) \"$d\"/\(quote(aside))-$$; fi"
            )
        }
        // Its record only: `worktree prune` would also drop worktrees whose folder is just away (an unmounted disk).
        try run(["worktree", "remove", "--force", path], cwd: repo, remotes: remotes)
        if let branch { try run(["branch", "-D", rev(branch)], cwd: repo, remotes: remotes) }
    }

    /// What `removeWorktree` would refuse, without removing anything.
    public static func checkRemovable(
        repo: String, path: String, branch: String?, force: Bool, dropCommits: Bool = false, remotes: Remotes
    ) throws {
        if !force, try isDirty(path, remotes: remotes) {
            throw GitError.refused("Worktree has uncommitted changes")
        }
        // `force` is about uncommitted changes; commits are lost only when asked for by name (dropCommits).
        if let branch, !dropCommits { try checkBranchDeletable(repo: repo, branch, remotes: remotes) }
        // Commits made on a detached HEAD belong to no branch at all: removing the folder would leave them to `git gc`.
        if !dropCommits, remotes.of(path) != nil || FileManager.default.fileExists(atPath: path),
            case let count = commitsOnNoBranch(path, remotes: remotes), count > 0
        {
            throw GitError.refused(
                "This workspace has \(count) commit\(count == 1 ? "" : "s") on no branch (a detached HEAD). Create a branch for them first."
            )
        }
    }

    private static func checkBranchDeletable(repo: String, _ branch: String, remotes: Remotes) throws {
        if case let count = try onlyOnBranch(repo: repo, branch, remotes: remotes), count > 0 {
            throw GitError.refused(
                "\(branch) has \(count) commit\(count == 1 ? "" : "s") that aren't on any other branch or remote"
            )
        }
    }

    /// A worktree whose folder is gone (a removal that stopped after the Trash, a folder deleted by hand): git's record of
    /// it goes, and its branch by `removeWorktree`'s rule: refused while it has commits no other branch or remote has,
    /// unless `dropCommits`.
    public static func forgetWorktree(
        repo: String, path: String, branch: String?, dropCommits: Bool = false, remotes: Remotes
    ) throws {
        let branch = branch.flatMap { branchExists(repo, $0, remotes: remotes) ? $0 : nil }
        if let branch, !dropCommits { try checkBranchDeletable(repo: repo, branch, remotes: remotes) }
        // Only the folder it was in is there to follow links in to where git lists it (/tmp is /private/tmp).
        let local = remotes.of(repo) == nil
        let real = { (folder: String) in
            let url = URL(fileURLWithPath: folder)
            return local
                ? url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(
                    url.lastPathComponent
                )
                .path : folder
        }
        if let entry = try linkedWorktrees(repo, remotes: remotes).first(where: { real($0.path) == real(path) }) {
            try run(["worktree", "remove", "--force", entry.path], cwd: repo, remotes: remotes)
        }
        if let branch { try run(["branch", "-D", rev(branch)], cwd: repo, remotes: remotes) }
    }

    /// Commits made on a detached HEAD in the worktree at `path` that no branch or remote has (no commits yet: 0).
    public static func commitsOnNoBranch(_ path: String, remotes: Remotes) -> Int {
        let out = try? line(
            ["rev-list", "--count", "HEAD", "--not", "--branches", "--remotes"], cwd: path, remotes: remotes)
        return Int(out ?? "") ?? 0
    }

    /// Whether `branch` was made with a group made at `since` and has moved since: its oldest reflog entry, its making, is
    /// from then (a minute either side) and not where it is now. A branch that was there before (one opened to look at)
    /// or that git didn't log the making of says no: what it holds isn't the group's own work.
    public static func moved(repo: String, _ branch: String, since: Date, remotes: Remotes) throws -> Bool {
        let ref = "refs/heads/" + branch
        guard isRevision(branch), succeeds(["rev-parse", "--verify", "--quiet", ref], cwd: repo, remotes: remotes)
        else {
            return false
        }
        let tip = try line(["rev-parse", ref], cwd: repo, remotes: remotes)
        let log = try run(["reflog", "show", "--format=%H %ct", ref], cwd: repo, remotes: remotes)
        guard let oldest = log.split(separator: "\n").last?.split(separator: " "), oldest.count == 2,
            let made = TimeInterval(String(oldest[1]))
        else { return false }
        return abs(made - since.timeIntervalSince1970) < 60 && String(oldest[0]) != tip
    }

    /// Whether the commit `branch` is on now is in `base` (merged or fast-forwarded there).
    public static func isIn(repo: String, _ branch: String, base: String, remotes: Remotes) -> Bool {
        isRevision(branch) && isRevision(base) && branch != base
            && succeeds(
                ["merge-base", "--is-ancestor", "refs/heads/" + branch, "refs/heads/" + base], cwd: repo,
                remotes: remotes)
    }

    /// Commits on `branch` that no other local branch and no remote branch has: what deleting it would lose.
    public static func onlyOnBranch(repo: String, _ branch: String, remotes: Remotes) throws -> Int {
        // --exclude before --branches takes the branch's name without refs/heads/ (with it, nothing is excluded).
        let out = try line(
            ["rev-list", "--count", "refs/heads/" + branch, "--not", "--exclude=" + branch, "--branches", "--remotes"],
            cwd: repo, remotes: remotes)
        return Int(out) ?? 0
    }
}
