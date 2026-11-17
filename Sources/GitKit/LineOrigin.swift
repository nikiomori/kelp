import Core
import Foundation

extension Git {
    /// Where a line came from, as `git blame` says.
    public struct LineBlame: Equatable, Sendable {
        /// The commit that brought the line, or nil when nothing did yet (changed since HEAD, before the first step).
        public var commit: String?
        public var author: String, date: Date, summary: String
        /// Which of the steps given to `lineOrigin` brought the line: 0 is the first, and `steps.count - 1` is the
        /// last, which runs to now. It is nil for a real commit.
        public var step: Int?
    }

    /// Returns who last changed `line` (1-based) of `file`, as the file is on disk now. `steps` are snapshots of the
    /// folder taken while HEAD was what it is now, oldest first, each with who made the changes after it and what to
    /// call them. Each snapshot becomes a commit of its own on top of HEAD (written to git's objects, never to a ref,
    /// so `git gc` removes them). The folder as it is now becomes one more commit, and `git blame` runs over them. A
    /// change made after step i's snapshot and before the next belongs to step i, and a change made before the first
    /// snapshot belongs to nobody yet. Returns nil when the line isn't there, when the file isn't in git's view
    /// (ignored, or a secret the snapshots leave out), or when a snapshot is gone.
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
        // Each commit holds the folder as it was when the next step began, and the first commit holds the folder before
        // any step.
        let trees = steps.map(\.tree) + [try snapshotTree(cwd, remotes: remotes)]
        var commits: [String] = [], parent = head
        for (i, tree) in trees.enumerated() {
            let who = i == 0 ? "Kelp" : steps[i - 1].author, what = i == 0 ? "Before" : steps[i - 1].message
            // The name goes in the environment too, because a name set there (GIT_AUTHOR_NAME) wins over -c.
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

    /// Returns what `git blame --porcelain` says about one line, or nil when git refuses (no such line or file).
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
