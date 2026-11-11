import Core
import Foundation

extension Git {
    /// Lanes for commits in topological order (children before parents). A commit takes the lane that was waiting for it
    /// (or the first free one); its first parent continues there, other parents join their lane or open a new one.
    public static func lanes(_ commits: [(hash: String, parents: [String])]) -> [(
        lane: Int, top: [[Int]], bottom: [[Int]]
    )] {
        var lanes: [String?] = []
        var out: [(lane: Int, top: [[Int]], bottom: [[Int]])] = []
        for commit in commits {
            let col = lanes.firstIndex(of: commit.hash) ?? lanes.firstIndex(of: nil) ?? lanes.count
            var top: [[Int]] = [], through: [Int] = []
            for (lane, hash) in lanes.enumerated() {
                guard let hash else { continue }
                if hash == commit.hash {
                    top.append([lane, col])
                } else {
                    top.append([lane, lane])
                    through.append(lane)
                }
            }
            if col == lanes.count { lanes.append(nil) }
            for lane in lanes.indices where lanes[lane] == commit.hash { lanes[lane] = nil }
            var bottom = through.map { [$0, $0] }
            for (index, parent) in commit.parents.enumerated() {
                // An already-waiting parent is joined, except that a first parent waiting further right comes to this lane:
                // the trunk stays leftmost and the right lane converges into it at the parent's row.
                if let parentLane = lanes.firstIndex(of: parent), index > 0 || parentLane < col {
                    bottom.append([col, parentLane])
                    continue
                }
                let parentLane = index == 0 ? col : (lanes.firstIndex(of: nil) ?? lanes.count)
                if parentLane == lanes.count { lanes.append(parent) } else { lanes[parentLane] = parent }
                bottom.append([col, parentLane])
            }
            while lanes.last == .some(nil) { lanes.removeLast() }
            out.append((col, top, bottom))
        }
        return out
    }

    /// The first `limit` commits of every branch, tag and remote, newest first, with graph lanes.
    public static func graph(_ path: String, limit: Int, remotes: Remotes) throws -> (
        commits: [GraphCommit], more: Bool
    ) {
        let fmt = "%H%x1f%P%x1f%an%x1f%at%x1f%D%x1f%s%x1e"
        let raw = try run(
            ["log", "--topo-order", "--format=\(fmt)", "-n\(limit + 1)", "--branches", "--tags", "--remotes", "HEAD"],
            cwd: path, remotes: remotes)
        var rows: [(String, [String], String, Double, [String], String)] = []
        for rec in raw.split(separator: "\u{1e}") {
            let fields = rec.trimmingCharacters(in: .newlines).split(
                separator: "\u{1f}", omittingEmptySubsequences: false
            )
            .map(String.init)
            guard fields.count == 6 else { continue }
            rows.append(
                (
                    fields[0], fields[1].split(separator: " ").map(String.init), fields[2], Double(fields[3]) ?? 0,
                    fields[4].isEmpty ? [] : fields[4].components(separatedBy: ", "), fields[5]
                ))
        }
        let more = rows.count > limit
        rows = Array(rows.prefix(limit))
        let layouts = lanes(rows.map { ($0.0, $0.1) })
        return (
            zip(rows, layouts).map { row, layout in
                GraphCommit(
                    hash: row.0, parents: row.1, author: row.2, date: row.3, subject: row.5, refs: row.4,
                    lane: layout.lane, top: layout.top,
                    bottom: layout.bottom)
            }, more
        )
    }

    /// Files a commit changed against its first parent: `[(status letter, path)]`.
    /// `-z`: "M\0path\0" or, renamed or copied, "R100\0old\0new\0".
    public static func commitFiles(_ path: String, commit: String, remotes: Remotes) throws -> [FileChange] {
        var entries = try run(
            ["show", "--format=", "--name-status", "-z", "-M", "--diff-merges=first-parent", rev(commit)], cwd: path,
            remotes: remotes
        )
        .split(separator: "\0").map(String.init)[...]
        var out: [FileChange] = []
        while let status = entries.popFirst()?.first {
            let count = status == "R" || status == "C" ? 2 : 1
            guard let name = entries.prefix(count).last else { break }
            entries = entries.dropFirst(count)
            out.append(FileChange(path: name, index: String(status), worktree: "."))
        }
        return out
    }

    /// The body of a commit's message, its author's email and its size against the first parent, in one git run.
    /// A binary file counts as a file, not as lines.
    public static func commitDetails(_ path: String, commit: String, remotes: Remotes) throws -> CommitDetails {
        let out = try run(
            ["show", "--numstat", "--format=%ae%x1f%b%x1e", "-M", "--diff-merges=first-parent", rev(commit)], cwd: path,
            remotes: remotes)
        let parts = out.split(separator: "\u{1e}", maxSplits: 1, omittingEmptySubsequences: false)
        let head = (parts.first ?? "").split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false)
        var details = CommitDetails(
            body: head.count > 1 ? head[1].trimmingCharacters(in: .whitespacesAndNewlines) : "",
            email: String(head.first ?? ""), files: 0, added: 0, removed: 0)
        for line in (parts.count > 1 ? parts[1] : "").split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2)
            guard fields.count == 3 else { continue }
            details.files += 1
            details.added += Int(fields[0]) ?? 0
            details.removed += Int(fields[1]) ?? 0
        }
        return details
    }

    /// Source Control reads this on every change in the folder: one for-each-ref answers what took five git processes
    /// (each an ssh round trip for a remote project). Detached or before the first commit, HEAD is asked for itself.
    public static func branches(_ path: String, remotes: Remotes) throws -> BranchInfo {
        let refs = try run(
            [
                "for-each-ref",
                "--format=%(HEAD)%00%(refname)%00%(objectname:short)%00%(upstream:short)%00%(upstream:track,nobracket)",
                "refs/heads", "refs/remotes"
            ], cwd: path, remotes: remotes)
        var info = BranchInfo(
            current: nil, head: nil, local: [], remote: [], upstream: nil, ahead: nil, behind: nil, merging: false)
        for line in refs.split(separator: "\n") {
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5 else { continue }
            if fields[1].hasPrefix("refs/remotes/") {
                if !fields[1].hasSuffix("/HEAD") {
                    info.remote.append(String(fields[1].dropFirst("refs/remotes/".count)))
                }
                continue
            }
            let name = String(fields[1].dropFirst("refs/heads/".count))
            guard Git.isRevision(name) else { continue }   // one that reads as an option isn't offered (nor pushed, merged…)
            info.local.append(name)
            guard fields[0] == "*" else { continue }
            info.current = name
            info.head = fields[2]
            guard !fields[3].isEmpty, fields[4] != "gone" else { continue }   // "gone": the upstream branch was deleted
            info.upstream = fields[3]
            info.ahead = 0
            info.behind = 0
            for part in fields[4].split(separator: ",") {   // "ahead 2, behind 1"; "" when even
                let words = part.split(separator: " ")
                if words.count == 2, words[0] == "ahead" {
                    info.ahead = Int(words[1])
                } else if words.count == 2, words[0] == "behind" {
                    info.behind = Int(words[1])
                }
            }
        }
        if info.current == nil {
            let symbolic = try line(["symbolic-ref", "--short", "-q", "HEAD"], cwd: path, ok: [0, 1], remotes: remotes)
            info.current = Git.isRevision(symbolic) ? symbolic : nil
            info.head = try? line(["rev-parse", "--short", "HEAD"], cwd: path, remotes: remotes)
        }
        // No upstream (never pushed, or its branch deleted): ahead is what's on no remote yet, as the graph marks it.
        if info.upstream == nil, info.current != nil, info.head != nil, !info.remote.isEmpty,
            let count = Int(
                (try? line(["rev-list", "--count", "HEAD", "--not", "--remotes"], cwd: path, remotes: remotes)) ?? "")
        {
            info.ahead = count
        }
        info.merging = isMerging(path, remotes: remotes)
        return info
    }

    /// The newest `limit` commits a push would send and a pull would bring. With an upstream: HEAD against it; without
    /// one (never pushed, or its branch deleted), what is on no remote branch yet, as `branches` counts it.
    public static func unsynced(_ path: String, limit: Int = 5, remotes: Remotes) throws -> Unsynced {
        var lists = try unsyncedLists(path, limit: limit, remotes: remotes)
        lists.fetched = try lastFetch(path, remotes: remotes)
        return lists
    }

    /// When FETCH_HEAD was written: git writes it on every fetch and pull, whether anything came or not. A remote
    /// project's isn't read (one more ssh round trip for a word in a popover).
    static func lastFetch(_ path: String, remotes: Remotes) throws -> Double? {
        guard remotes.of(path) == nil else { return nil }
        let file = try line(
            ["rev-parse", "--path-format=absolute", "--git-path", "FETCH_HEAD"], cwd: path, remotes: remotes)
        var info = stat()
        guard !file.isEmpty, stat(file, &info) == 0 else { return nil }
        return Double(info.st_mtimespec.tv_sec)
    }

    private static func unsyncedLists(_ path: String, limit: Int, remotes: Remotes) throws -> Unsynced {
        func commits(_ range: [String]) throws -> [Unsynced.Commit] {
            try run(
                ["log", "--format=%h%x09%an%x09%at%x09%s", "-n\(max(1, limit))"] + range, cwd: path, remotes: remotes
            )
            .split(separator: "\n").compactMap { line in
                let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
                return fields.count == 4
                    ? Unsynced.Commit(
                        hash: String(fields[0]), subject: String(fields[3]), author: String(fields[1]),
                        date: Double(fields[2]) ?? 0) : nil
            }
        }
        // 128: no upstream (or its branch deleted), in which case git prints nothing.
        if !(try run(["rev-parse", "--abbrev-ref", "@{upstream}"], cwd: path, ok: [0, 128], remotes: remotes)).isEmpty {
            return Unsynced(outgoing: try commits(["@{upstream}..HEAD"]), incoming: try commits(["HEAD..@{upstream}"]))
        }
        // Nothing to compare with before the first commit, or while no remote branch exists (a push has nowhere to land yet).
        let remote = try run(["for-each-ref", "--format=%(refname)", "refs/remotes"], cwd: path, remotes: remotes)
        let head = try run(["rev-parse", "--verify", "-q", "HEAD"], cwd: path, ok: [0, 1], remotes: remotes)
        guard remote.split(separator: "\n").contains(where: { !$0.hasSuffix("/HEAD") }), !head.isEmpty else {
            return Unsynced(outgoing: [], incoming: [])
        }
        return Unsynced(outgoing: try commits(["HEAD", "--not", "--remotes"]), incoming: [])
    }

    /// Switch to a local branch, a remote one (creates the tracking branch), or a new one.
    public static func switchBranch(
        _ path: String, to name: String, create: Bool = false, remote: Bool = false, remotes: Remotes
    ) throws {
        let local = remote ? String(name.drop { $0 != "/" }.dropFirst()) : name
        // Checked as git will read it, after "origin/" is taken off: "origin/-Cmain" would be `git switch -Cmain`.
        guard !local.hasPrefix("-"), !name.hasPrefix("-") else {
            throw GitError.refused("“\(name)” isn't a branch name.")
        }
        if create {
            try run(["switch", "-c", name], cwd: path, remotes: remotes)
            return
        }
        try run(["switch", local], cwd: path, remotes: remotes)
    }

    /// Undo working-tree changes: tracked files go back to the index, untracked files are deleted. Answers the patch that
    /// puts them back (`putBack`); a change too big to keep that way is refused, nothing discarded.
    @discardableResult
    /// `keep` gets the patch before anything changes, and nothing does if it throws: what's thrown away is kept first.
    public static func discard(
        _ path: String, files: [String], remotes: Remotes, keep: (Data) throws -> Void = { _ in }
    ) throws -> Data {
        let untracked = Set(try status(path, remotes: remotes).filter(\.untracked).map(\.path))
        let (newFiles, tracked) = (files.filter { untracked.contains($0) }, files.filter { !untracked.contains($0) })
        // Fixed prefixes, no colour: a user's diff.noprefix or color.diff=always would give a patch `git apply` can't take.
        let plain = ["--binary", "--no-color", "--src-prefix=a/", "--dst-prefix=b/"]
        let changes = { try runData(["diff"] + plain + ["--"] + literal(tracked), cwd: path, remotes: remotes) }
        var back = Data(), ofTracked = Data()
        do {
            if !tracked.isEmpty { ofTracked = try changes() }
            back = ofTracked
            for file in newFiles {
                back += try runData(
                    ["diff"] + plain + ["--no-index", "--", "/dev/null", file], cwd: path, ok: [0, 1], remotes: remotes)
            }
            // All of them, held in the daemon a minute.
            if back.count > Subprocess.outputLimit { throw GitError.tooMuch }
        } catch GitError.tooMuch {   // any other failure says what it was
            throw GitError.refused(
                "This change is too big to keep for Undo, so Kelp left it as it is: "
                    + "discard it in a terminal (git restore) if you're sure.")
        }
        try keep(back)
        if !tracked.isEmpty {
            // An edit saved since the patch was taken isn't in it and would go with no undo: the files are read again,
            // right before they are written, and nothing is discarded if they changed. Limit: one saved between this
            // diff and the restore, the next git run (milliseconds; a round trip on a host), still goes.
            guard try changes() == ofTracked else {
                throw GitError.refused(
                    "The files changed while they were being discarded, so they were left as they are.")
            }
            try run(["restore", "--worktree", "--"] + literal(tracked), cwd: path, remotes: remotes)
        }
        // New files go to the Trash on this Mac: should Undo fail, they are still there to put back.
        if remotes.of(path) == nil {
            for file in newFiles { try Trash.move(URL(fileURLWithPath: path).appendingPathComponent(file)) }
        } else if !newFiles.isEmpty {
            // No Trash on a host: `back` holds each whole (a binary patch), the only copy once this ran, for as long as
            // the caller keeps it. Limit: a new file saved again between its diff above and here goes as it is now.
            try run(["clean", "-f", "-q", "--"] + literal(newFiles), cwd: path, remotes: remotes)
        }
        return back
    }

    /// Applies what a discard threw away again: `discard`'s patch, or with `hunk` a hunk's own (`FileDiff.patch(hunk:)`).
    /// git changes nothing in a file that has moved on since, so a newer edit is never written over. A discard that failed
    /// partway left some files as they were: those are let be, the rest put back, each file on its own.
    public static func putBack(_ path: String, patch: Data, hunk: Bool, remotes: Remotes) throws {
        let apply = ["apply"] + (hunk ? ["--recount", "--unidiff-zero"] : ["--binary"]) + ["-"]
        do { try runData(apply, cwd: path, stdin: patch, remotes: remotes) } catch {
            let files = perFile(patch)
            guard !hunk, files.count > 1 else { throw error }
            var back = 0, gone = 0, refused: Error?
            for part in files {
                // Already as the patch leaves it (its undo applies): let be, and not counted as one to put back.
                do {
                    try runData(["apply", "--binary", "-R", "--check", "-"], cwd: path, stdin: part, remotes: remotes)
                } catch {
                    gone += 1
                    do {
                        try runData(apply, cwd: path, stdin: part, remotes: remotes)
                        back += 1
                    } catch { refused = refused ?? error }
                }
            }
            if let refused {
                guard back > 0 else { throw refused }
                throw PartlyPutBack(back: back, of: gone, why: (refused as? GitError)?.message ?? "\(refused)")
            }
        }
    }

    /// Some of a discard's files put back, the rest refused (changed since): a try later puts back those once they're as they were.
    public struct PartlyPutBack: Error { public let back: Int, of: Int, why: String }

    /// A patch cut at each file's `diff --git` line.
    static func perFile(_ patch: Data) -> [Data] {
        let mark = Data("\ndiff --git ".utf8)
        var parts: [Data] = [], start = patch.startIndex, from = patch.startIndex
        while let found = patch.range(of: mark, in: from..<patch.endIndex) {
            parts.append(patch[start...found.lowerBound])
            start = found.lowerBound + 1
            from = found.upperBound
        }
        parts.append(patch[start...])
        return parts.filter { !$0.isEmpty }
    }

    public enum Remote: String, Sendable { case pull, push, fetch }

    public static func remote(_ path: String, _ op: Remote, remotes: Remotes) throws {
        switch op {
        case .pull:
            // Diverged branches make git refuse until it's told how to reconcile them. With neither pull.rebase nor pull.ff set
            // (the user's own answer), a merge: the first of git's hints.
            let chosen = try ["pull.rebase", "pull.ff"].contains {
                !(try run(["config", "--get", $0], cwd: path, ok: [0, 1], remotes: remotes)).isEmpty
            }
            try run(["pull"] + (chosen ? [] : ["--no-rebase"]), cwd: path, remotes: remotes)
        case .fetch: try run(["fetch", "--all", "--prune"], cwd: path, remotes: remotes)
        case .push:
            let branch = try currentBranch(path, remotes: remotes)
            let hasUpstream = succeeds(["rev-parse", "--abbrev-ref", "@{upstream}"], cwd: path, remotes: remotes)
            try run(hasUpstream ? ["push"] : ["push", "-u", "origin", branch], cwd: path, remotes: remotes)
        }
    }

    /// Pop puts staged changes back as staged when it can (`--index`), like VS Code.
    public static func stash(_ path: String, pop: Bool, remotes: Remotes) throws {
        guard pop else {
            try run(["stash", "push", "--include-untracked"], cwd: path, remotes: remotes)
            return
        }
        if (try? run(["stash", "pop", "--index"], cwd: path, remotes: remotes)) == nil {
            try run(["stash", "pop"], cwd: path, remotes: remotes)
        }
    }
}
