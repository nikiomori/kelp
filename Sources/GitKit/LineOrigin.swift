import Core
import Foundation

extension Git {
    /// Where a line came from, as `git blame` says.
    public struct LineBlame: Equatable, Sendable {
        /// The commit that brought it; nil when nothing did yet (changed since HEAD, before the first step).
        public var commit: String?
        public var author: String, date: Date, summary: String
        /// Which of `lineOrigin`'s steps brought it: 0 the first, `steps.count - 1` the last (it runs to now); nil for a
        /// real commit.
        public var step: Int?
    }

    /// Who last changed `line` (1-based) of `file`, as it is on disk now. `steps` are snapshots of the folder taken while
    /// HEAD was what it is now, oldest first, each with who made the changes after it and what to call them: each
    /// becomes a commit of its own on top of HEAD (written to git's objects, never to a ref, so `git gc` takes them),
    /// then the folder now one more, and `git blame` runs over them. What changed after step i's snapshot and before the
    /// next is step i's; what changed before the first, nobody's yet. Nil: the line isn't there, the file isn't in git's
    /// view (ignored, a secret the snapshots leave out), or a snapshot is gone.
    public static func lineOrigin(
        _ cwd: String, file: String, line: Int, steps: [(tree: String, author: String, message: String)],
        remotes: Remotes
    ) throws -> LineBlame? {
        let range = ["-L", "\(line),\(line)"]
        guard !steps.isEmpty else {
            return try blame(cwd, range + ["--", file], remotes: remotes).map { found in
                var found = found
                if found.commit.map(isZero) == true { found.commit = nil }
                return found
            }
        }
        guard let head = try resolve("HEAD", cwd: cwd, remotes: remotes) else { return nil }
        // Each commit holds the folder as the step after it began; the first one the folder before any step.
        let trees = steps.map(\.tree) + [try snapshotTree(cwd, remotes: remotes)]
        var commits: [String] = [], parent = head
        for (i, tree) in trees.enumerated() {
            let who = i == 0 ? "Kelp" : steps[i - 1].author, what = i == 0 ? "Before" : steps[i - 1].message
            // The name in the environment too: one set there (GIT_AUTHOR_NAME) wins over -c.
            let name = ["GIT_AUTHOR_NAME": who, "GIT_COMMITTER_NAME": who]
            parent = try Git.line(
                [
                    "-c", "user.name=\(who)", "-c", "user.email=kelp@localhost", "-c", "commit.gpgSign=false",
                    "commit-tree", tree, "-p", parent, "-m", what.isEmpty ? "Turn" : what
                ],
                cwd: cwd, env: name, remotes: remotes)
            commits.append(parent)
        }
        guard var found = try blame(cwd, range + [parent, "--", file], remotes: remotes) else { return nil }
        if let commit = found.commit, let index = commits.firstIndex(of: commit) {
            found.step = index == 0 ? nil : index - 1
            if index == 0 { found.commit = nil }
        }
        return found
    }

    private static func isZero(_ hash: String) -> Bool { hash.allSatisfy { $0 == "0" } }

    /// `git blame --porcelain`'s answer for one line; nil when git refuses (no such line, or file).
    private static func blame(_ cwd: String, _ args: [String], remotes: Remotes) throws -> LineBlame? {
        let out = try run(["blame", "--porcelain"] + args, cwd: cwd, ok: [0, 128], remotes: remotes)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first?.split(separator: " ").first, first.count >= 40 else { return nil }
        func field(_ key: String) -> String? {
            lines.first { $0.hasPrefix(key + " ") }.map { String($0.dropFirst(key.count + 1)) }
        }
        return LineBlame(
            commit: String(first), author: field("author") ?? "",
            date: Date(timeIntervalSince1970: Double(field("author-time") ?? "") ?? 0),
            summary: field("summary") ?? "", step: nil)
    }
}
