import Foundation
import Core

extension Git {
    /// Lanes for commits in topological order (children before parents). A commit takes the lane that was waiting for it
    /// (or the first free one); its first parent continues there, other parents join their lane or open a new one.
    public static func lanes(_ commits: [(hash: String, parents: [String])]) -> [(lane: Int, top: [[Int]], bottom: [[Int]])] {
        var lanes: [String?] = []
        var out: [(lane: Int, top: [[Int]], bottom: [[Int]])] = []
        for c in commits {
            let col = lanes.firstIndex(of: c.hash) ?? lanes.firstIndex(of: nil) ?? lanes.count
            var top: [[Int]] = [], through: [Int] = []
            for (i, h) in lanes.enumerated() {
                guard let h else { continue }
                if h == c.hash { top.append([i, col]) } else { top.append([i, i]); through.append(i) }
            }
            if col == lanes.count { lanes.append(nil) }
            for i in lanes.indices where lanes[i] == c.hash { lanes[i] = nil }
            var bottom = through.map { [$0, $0] }
            for (n, p) in c.parents.enumerated() {
                // An already-waiting parent is joined, except that a first parent waiting further right comes to this lane:
                // the trunk stays leftmost and the right lane converges into it at the parent's row.
                if let k = lanes.firstIndex(of: p), n > 0 || k < col { bottom.append([col, k]); continue }
                let k = n == 0 ? col : (lanes.firstIndex(of: nil) ?? lanes.count)
                if k == lanes.count { lanes.append(p) } else { lanes[k] = p }
                bottom.append([col, k])
            }
            while lanes.last == .some(nil) { lanes.removeLast() }
            out.append((col, top, bottom))
        }
        return out
    }

    /// The first `limit` commits of every branch, tag and remote, newest first, with graph lanes.
    public static func graph(_ path: String, limit: Int, remotes: Remotes = .none) throws -> (commits: [GraphCommit], more: Bool) {
        let fmt = "%H%x1f%P%x1f%an%x1f%at%x1f%D%x1f%s%x1e"
        let raw = try run(["log", "--topo-order", "--format=\(fmt)", "-n\(limit + 1)", "--branches", "--tags", "--remotes", "HEAD"],
                          cwd: path, remotes: remotes)
        var rows: [(String, [String], String, Double, [String], String)] = []
        for rec in raw.split(separator: "\u{1e}") {
            let f = rec.trimmingCharacters(in: .newlines).split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 6 else { continue }
            rows.append((f[0], f[1].split(separator: " ").map(String.init), f[2], Double(f[3]) ?? 0,
                         f[4].isEmpty ? [] : f[4].components(separatedBy: ", "), f[5]))
        }
        let more = rows.count > limit
        rows = Array(rows.prefix(limit))
        let l = lanes(rows.map { ($0.0, $0.1) })
        return (zip(rows, l).map { r, g in
            GraphCommit(hash: r.0, parents: r.1, author: r.2, date: r.3, subject: r.5, refs: r.4, lane: g.lane, top: g.top, bottom: g.bottom)
        }, more)
    }

    /// Files a commit changed against its first parent: `[(status letter, path)]`.
    /// `-z`: "M\0path\0" or, renamed or copied, "R100\0old\0new\0".
    public static func commitFiles(_ path: String, commit: String, remotes: Remotes = .none) throws -> [FileChange] {
        var f = try run(["show", "--format=", "--name-status", "-z", "-M", "--diff-merges=first-parent", rev(commit)], cwd: path, remotes: remotes)
            .split(separator: "\0").map(String.init)[...]
        var out: [FileChange] = []
        while let s = f.popFirst()?.first {
            let n = s == "R" || s == "C" ? 2 : 1
            guard let p = f.prefix(n).last else { break }
            f = f.dropFirst(n)
            out.append(FileChange(path: p, index: String(s), worktree: "."))
        }
        return out
    }

    /// The body of a commit's message, its author's email and its size against the first parent, in one git run.
    /// A binary file counts as a file, not as lines.
    public static func commitDetails(_ path: String, commit: String, remotes: Remotes = .none) throws -> CommitDetails {
        let out = try run(["show", "--numstat", "--format=%ae%x1f%b%x1e", "-M", "--diff-merges=first-parent", rev(commit)], cwd: path, remotes: remotes)
        let parts = out.split(separator: "\u{1e}", maxSplits: 1, omittingEmptySubsequences: false)
        let head = (parts.first ?? "").split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false)
        var d = CommitDetails(body: head.count > 1 ? head[1].trimmingCharacters(in: .whitespacesAndNewlines) : "",
                              email: String(head.first ?? ""), files: 0, added: 0, removed: 0)
        for line in (parts.count > 1 ? parts[1] : "").split(separator: "\n") {
            let f = line.split(separator: "\t", maxSplits: 2)
            guard f.count == 3 else { continue }
            d.files += 1; d.added += Int(f[0]) ?? 0; d.removed += Int(f[1]) ?? 0
        }
        return d
    }

    /// Source Control reads this on every change in the folder: one for-each-ref answers what took five git processes
    /// (each an ssh round trip for a remote project). Detached or before the first commit, HEAD is asked for itself.
    public static func branches(_ path: String, remotes: Remotes = .none) throws -> BranchInfo {
        let refs = try run(["for-each-ref", "--format=%(HEAD)%00%(refname)%00%(objectname:short)%00%(upstream:short)%00%(upstream:track,nobracket)",
                            "refs/heads", "refs/remotes"], cwd: path, remotes: remotes)
        var b = BranchInfo(current: nil, head: nil, local: [], remote: [], upstream: nil, ahead: nil, behind: nil, merging: false)
        for line in refs.split(separator: "\n") {
            let f = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 5 else { continue }
            if f[1].hasPrefix("refs/remotes/") {
                if !f[1].hasSuffix("/HEAD") { b.remote.append(String(f[1].dropFirst("refs/remotes/".count))) }
                continue
            }
            let name = String(f[1].dropFirst("refs/heads/".count))
            guard Git.isRevision(name) else { continue }   // one that reads as an option isn't offered (nor pushed, merged…)
            b.local.append(name)
            guard f[0] == "*" else { continue }
            b.current = name; b.head = f[2]
            guard !f[3].isEmpty, f[4] != "gone" else { continue }   // "gone": the upstream branch was deleted
            b.upstream = f[3]; b.ahead = 0; b.behind = 0
            for part in f[4].split(separator: ",") {   // "ahead 2, behind 1"; "" when even
                let w = part.split(separator: " ")
                if w.count == 2, w[0] == "ahead" { b.ahead = Int(w[1]) } else if w.count == 2, w[0] == "behind" { b.behind = Int(w[1]) }
            }
        }
        if b.current == nil {
            let c = try run(["symbolic-ref", "--short", "-q", "HEAD"], cwd: path, ok: [0, 1], remotes: remotes).trimmingCharacters(in: .whitespacesAndNewlines)
            b.current = Git.isRevision(c) ? c : nil
            b.head = (try? run(["rev-parse", "--short", "HEAD"], cwd: path, remotes: remotes))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // No upstream (never pushed, or its branch deleted): ahead is what's on no remote yet, as the graph marks it.
        if b.upstream == nil, b.current != nil, b.head != nil, !b.remote.isEmpty,
           let n = Int((try? run(["rev-list", "--count", "HEAD", "--not", "--remotes"], cwd: path, remotes: remotes))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") {
            b.ahead = n
        }
        b.merging = (try? run(["rev-parse", "-q", "--verify", "MERGE_HEAD"], cwd: path, remotes: remotes)) != nil
        return b
    }

    /// The newest `limit` commits a push would send and a pull would bring. With an upstream: HEAD against it; without
    /// one (never pushed, or its branch deleted), what is on no remote branch yet, as `branches` counts it.
    public static func unsynced(_ path: String, limit: Int = 5, remotes: Remotes = .none) throws -> Unsynced {
        func commits(_ range: [String]) throws -> [Unsynced.Commit] {
            try run(["log", "--format=%h%x09%an%x09%at%x09%s", "-n\(max(1, limit))"] + range, cwd: path, remotes: remotes)
                .split(separator: "\n").compactMap { l in
                    let f = l.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
                    return f.count == 4 ? Unsynced.Commit(hash: String(f[0]), subject: String(f[3]), author: String(f[1]), date: Double(f[2]) ?? 0) : nil
                }
        }
        // 128: no upstream (or its branch deleted), in which case git prints nothing.
        if !(try run(["rev-parse", "--abbrev-ref", "@{upstream}"], cwd: path, ok: [0, 128], remotes: remotes)).isEmpty {
            return Unsynced(outgoing: try commits(["@{upstream}..HEAD"]), incoming: try commits(["HEAD..@{upstream}"]))
        }
        // Nothing to compare with before the first commit, or while no remote branch exists (a push has nowhere to land yet).
        let remote = try run(["for-each-ref", "--format=%(refname)", "refs/remotes"], cwd: path, remotes: remotes)
        let head = try run(["rev-parse", "--verify", "-q", "HEAD"], cwd: path, ok: [0, 1], remotes: remotes)
        guard remote.split(separator: "\n").contains(where: { !$0.hasSuffix("/HEAD") }), !head.isEmpty else { return Unsynced(outgoing: [], incoming: []) }
        return Unsynced(outgoing: try commits(["HEAD", "--not", "--remotes"]), incoming: [])
    }

    /// Switch to a local branch, a remote one (creates the tracking branch), or a new one.
    public static func switchBranch(_ path: String, to name: String, create: Bool = false, remote: Bool = false, remotes: Remotes = .none) throws {
        let local = remote ? String(name.drop { $0 != "/" }.dropFirst()) : name
        // Checked as git will read it, after "origin/" is taken off: "origin/-Cmain" would be `git switch -Cmain`.
        guard !local.hasPrefix("-"), !name.hasPrefix("-") else {
            throw GitError(args: ["switch", name], status: 1, stderr: "“\(name)” isn't a branch name.")
        }
        if create { try run(["switch", "-c", name], cwd: path, remotes: remotes); return }
        try run(["switch", local], cwd: path, remotes: remotes)
    }

    /// Undo working-tree changes: tracked files go back to the index, untracked files are deleted. Answers the patch that
    /// puts them back (`putBack`); a change too big to keep that way is refused, nothing discarded.
    @discardableResult
    public static func discard(_ path: String, files: [String], remotes: Remotes = .none) throws -> Data {
        let untracked = Set(try status(path, remotes: remotes).filter(\.untracked).map(\.path))
        let (u, t) = (files.filter { untracked.contains($0) }, files.filter { !untracked.contains($0) })
        // Fixed prefixes, no colour: a user's diff.noprefix or color.diff=always would give a patch `git apply` can't take.
        let plain = ["--binary", "--no-color", "--src-prefix=a/", "--dst-prefix=b/"]
        var back = Data()
        do {
            if !t.isEmpty { back = try runData(["diff"] + plain + ["--"] + literal(t), cwd: path, remotes: remotes) }
            for f in u { back += try runData(["diff"] + plain + ["--no-index", "--", "/dev/null", f], cwd: path, ok: [0, 1], remotes: remotes) }
        } catch {
            throw GitError(args: ["diff"], status: 1, stderr: "This change is too big to keep for Undo, so Kelp left it as it is.")
        }
        // New files go to the Trash on this Mac: should Undo fail, they are still there to put back.
        if remotes.of(path) == nil {
            for f in u { try Trash.move(URL(fileURLWithPath: path).appendingPathComponent(f)) }
        } else if !u.isEmpty {
            try run(["clean", "-f", "-q", "--"] + literal(u), cwd: path, remotes: remotes)
        }
        if !t.isEmpty { try run(["restore", "--worktree", "--"] + literal(t), cwd: path, remotes: remotes) }
        return back
    }

    /// Applies what a discard threw away again: `discard`'s patch, or with `hunk` a hunk's own (`FileDiff.patch(hunk:)`).
    /// git changes nothing when the files have moved on since, so a newer edit is never written over.
    public static func putBack(_ path: String, patch: Data, hunk: Bool, remotes: Remotes = .none) throws {
        try runData(["apply"] + (hunk ? ["--recount", "--unidiff-zero"] : ["--binary"]) + ["-"], cwd: path, stdin: patch, remotes: remotes)
    }

    public enum Remote: String, Sendable { case pull, push, fetch }

    public static func remote(_ path: String, _ op: Remote, remotes: Remotes = .none) throws {
        switch op {
        case .pull:
            // Diverged branches make git refuse until it's told how to reconcile them. With neither pull.rebase nor pull.ff set
            // (the user's own answer), a merge: the first of git's hints.
            let chosen = try ["pull.rebase", "pull.ff"].contains { !(try run(["config", "--get", $0], cwd: path, ok: [0, 1], remotes: remotes)).isEmpty }
            try run(["pull"] + (chosen ? [] : ["--no-rebase"]), cwd: path, remotes: remotes)
        case .fetch: try run(["fetch", "--all", "--prune"], cwd: path, remotes: remotes)
        case .push:
            let b = try currentBranch(path, remotes: remotes)
            let hasUpstream = (try? run(["rev-parse", "--abbrev-ref", "@{upstream}"], cwd: path, remotes: remotes)) != nil
            try run(hasUpstream ? ["push"] : ["push", "-u", "origin", b], cwd: path, remotes: remotes)
        }
    }

    /// Pop puts staged changes back as staged when it can (`--index`), like VS Code.
    public static func stash(_ path: String, pop: Bool, remotes: Remotes = .none) throws {
        guard pop else { try run(["stash", "push", "--include-untracked"], cwd: path, remotes: remotes); return }
        if (try? run(["stash", "pop", "--index"], cwd: path, remotes: remotes)) == nil { try run(["stash", "pop"], cwd: path, remotes: remotes) }
    }
}
