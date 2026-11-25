import Foundation

// Value types for git's output, which the daemon sends and the app shows. Running git itself is GitKit's job, in the
// daemon.

/// A thin wrapper over the system git. Its output is read here, and git is run in GitKit.
public enum Git {
    /// Whether file events can change what `git status` says. Any path outside `.git/` can. Inside `.git/`, only paths
    /// that move the index, HEAD or a branch count, because lock and object files churn during every git command,
    /// including Kelp's own status calls. Kelp's own refs under refs/kelp/ (a turn's snapshot, a pull request's head)
    /// change neither.
    public static func touchesStatus(_ paths: [String]) -> Bool {
        paths.contains { path in
            guard let range = path.range(of: "/.git/") else { return true }
            let rest = path[range.upperBound...]
            return rest == "index" || rest == "HEAD" || rest == "MERGE_HEAD" || rest == "packed-refs"
                || (rest.hasPrefix("refs/") && !rest.hasPrefix("refs/kelp/"))
        }
    }

    /// Whether any of `changes` can change a workspace's file list (`files.list`) or what it shows. Outside .git, that
    /// means a file or folder that was made, removed or moved (`reshapes`), because a save writes a file and leaves the
    /// list as it was. A change to the ignore rules counts too. Inside .git, only the index (`git rm --cached`,
    /// staging), HEAD (a checkout) and info/exclude count. Without this filter, git's own churn would list the files
    /// again several times a second, and once for every save.
    /// Limit: FSEvents adds up a path's flags for a few seconds. So a file written just after it was made, and every
    /// atomic save (a rename), still lists the files again.
    public static func touchesFileList(_ changes: [FileWatcher.Change]) -> Bool {
        changes.contains { change in
            let path = change.path
            guard let range = path.range(of: "/.git/") else {
                return !path.hasSuffix("/.git") && (change.reshapes || path.hasSuffix("/.gitignore"))
            }
            let rest = path[range.upperBound...]
            return rest == "index" || rest == "HEAD" || rest == "info/exclude"
        }
    }

    /// Returns the commits that no remote branch has. Topological order lists a commit before its ancestors, so one
    /// pass down from the tips of the remote branches marks everything they reach, and whatever is left is local only.
    /// With no remotes, nothing is marked.
    public static func unpushed(_ commits: [GraphCommit], remotes: Set<String>) -> Set<String> {
        guard !remotes.isEmpty else { return [] }
        var pushed = Set<String>(), out = Set<String>()
        for commit in commits {
            if pushed.contains(commit.hash) || commit.refs.contains(where: remotes.contains) {
                pushed.formUnion(commit.parents)
            } else {
                out.insert(commit.hash)
            }
        }
        return out
    }
}

public struct FileChange: Codable, Sendable, Equatable {
    public var path: String
    public var index: String   // The staged status column.
    public var worktree: String
    public init(path: String, index: String, worktree: String) {
        self.path = path
        self.index = index
        self.worktree = worktree
    }
    public var staged: Bool { index != "." && index != "?" }
    public var unstaged: Bool { worktree != "." }
    public var untracked: Bool { index == "?" }
    public var conflicted: Bool {
        index == "U" || worktree == "U" || (index == "A" && worktree == "A") || (index == "D" && worktree == "D")
    }

    /// The most files a status lists, which is VS Code's limit too. A folder that should be ignored (node_modules) can
    /// hold hundreds of thousands of files, and the list goes to the app on each change. A status this long may be
    /// missing some files.
    public static let limit = 10_000
}

/// The sections Source Control lists, in order: conflicts, then staged changes, then the rest.
/// A file with both staged and unstaged edits is in two sections. A conflicted file is only in the first.
public struct ChangeGroups: Equatable, Sendable {
    public var merge: [FileChange], staged: [FileChange], changes: [FileChange]
    public init(merge: [FileChange], staged: [FileChange], changes: [FileChange]) {
        self.merge = merge
        self.staged = staged
        self.changes = changes
    }
}

extension Array where Element == FileChange {
    public var grouped: ChangeGroups {
        ChangeGroups(
            merge: filter(\.conflicted),
            staged: filter { $0.staged && !$0.conflicted },
            changes: filter { ($0.unstaged || $0.untracked) && !$0.conflicted })
    }
}

extension FileChange {
    /// Returns the status letter VS Code shows. `inWorktree` picks which status column the letter comes from, and the
    /// unstaged list shows the worktree's column.
    public func letter(inWorktree: Bool, merging: Bool = false) -> String {
        if merging || conflicted { return "!" }
        if untracked { return "U" }
        switch inWorktree ? worktree : index {
        case "A": return "A"
        case "D": return "D"
        case "R": return "R"
        case "C": return "C"
        default: return "M"
        }
    }
}

public struct DiffLine: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case context, add, del }
    public var kind: Kind
    public var text: String
    public var oldLine: Int?
    public var newLine: Int?
    /// The file's last line has no newline after it (git's "\ No newline at end of file").
    public var noNewline: Bool?
    public init(kind: Kind, text: String, oldLine: Int? = nil, newLine: Int? = nil, noNewline: Bool? = nil) {
        self.kind = kind
        self.text = text
        self.oldLine = oldLine
        self.newLine = newLine
        self.noNewline = noNewline
    }
}

public struct Hunk: Codable, Sendable, Equatable {
    public var header: String
    public var oldStart: Int, newStart: Int
    public var lines: [DiffLine]
    public init(header: String, oldStart: Int, newStart: Int, lines: [DiffLine]) {
        self.header = header
        self.oldStart = oldStart
        self.newStart = newStart
        self.lines = lines
    }
}

extension Hunk {
    /// The hunk as shown, with its header and every line. An edit inside the hunk that keeps the line counts (a line
    /// rewritten in place) changes this fingerprint, while the "@@" header alone stays the same.
    public var fingerprint: String {
        ([header] + lines.map { "\($0.kind.rawValue)|\($0.text)" }).joined(separator: "\n")
    }
}

public struct FileDiff: Codable, Sendable, Equatable {
    public var path: String
    /// The raw `diff --git`, `---` and `+++` lines, which are needed to rebuild patches for hunk staging.
    public var header: String
    public var hunks: [Hunk]
    public var binary: Bool
    /// True when the file isn't UTF-8. Its text was then read byte for byte as Latin-1, and patches are written back
    /// the same way.
    public var latin1: Bool?
    /// True when the file's changes are more than one reply carries (`Git.diffBudget`), so only the header is sent and
    /// no hunks. When the file is asked for on its own, it may fit.
    public var tooLarge: Bool?
    public init(path: String, header: String, hunks: [Hunk], binary: Bool, latin1: Bool? = nil, tooLarge: Bool? = nil) {
        self.path = path
        self.header = header
        self.hunks = hunks
        self.binary = binary
        self.latin1 = latin1
        self.tooLarge = tooLarge
    }
    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .add }.count } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .del }.count } }

    /// Returns a patch with only the given hunk, in the file's own encoding, for `git apply --cached [-R]`.
    public func patch(hunk index: Int) -> Data {
        var patch = header + "\n" + hunks[index].header + "\n"
        for line in hunks[index].lines {
            patch += (line.kind == .add ? "+" : line.kind == .del ? "-" : " ") + line.text + "\n"
            if line.noNewline == true { patch += "\\ No newline at end of file\n" }
        }
        return latin1 == true
            ? Data(patch.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }) : Data(patch.utf8)
    }
}

/// The details of a commit: its message body (the graph shows the subject), its author's email, and its size compared
/// with its first parent.
public struct CommitDetails: Codable, Sendable, Equatable {
    public var body: String
    public var email: String
    public var files: Int, added: Int, removed: Int
    /// Each file's lines added and removed, by its path after the commit (a binary file counts none).
    public var lines: [FileLines]?
    public init(body: String, email: String, files: Int, added: Int, removed: Int, lines: [FileLines]? = nil) {
        self.body = body
        self.email = email
        self.files = files
        self.added = added
        self.removed = removed
        self.lines = lines
    }
}

/// How many lines a commit added to and removed from one file.
public struct FileLines: Codable, Sendable, Equatable {
    public var path: String, added: Int, removed: Int
    public init(path: String, added: Int, removed: Int) {
        self.path = path
        self.added = added
        self.removed = removed
    }
}

/// One row of the commit graph (VS Code's Source Control Graph). Lines are lane pairs:
/// `top` runs from the row's top edge (lane `[0]`) to its middle (lane `[1]`), `bottom` from the middle to the bottom edge.
public struct GraphCommit: Codable, Sendable, Equatable {
    public var hash: String
    public var parents: [String]
    public var author: String
    public var date: Double
    public var subject: String
    /// `git log %D` items: "HEAD -> main", "origin/main", "tag: v1.0".
    public var refs: [String]
    public var lane: Int
    public var top: [[Int]]
    public var bottom: [[Int]]
    public init(
        hash: String, parents: [String], author: String, date: Double, subject: String, refs: [String], lane: Int,
        top: [[Int]], bottom: [[Int]]
    ) {
        self.hash = hash
        self.parents = parents
        self.author = author
        self.date = date
        self.subject = subject
        self.refs = refs
        self.lane = lane
        self.top = top
        self.bottom = bottom
    }
}

public struct BranchInfo: Codable, Sendable, Equatable {
    public var current: String?   // nil when HEAD is detached
    public var head: String?   // short hash of HEAD (nil before the first commit)
    public var local: [String]
    public var remote: [String]
    public var upstream: String?
    /// The number of commits to push. These are the commits past the upstream, or, when there is no upstream, the
    /// commits on no remote branch (which the graph marks "not pushed yet").
    public var ahead: Int?
    public var behind: Int?
    public var merging: Bool
    public init(
        current: String?, head: String?, local: [String], remote: [String], upstream: String? = nil, ahead: Int? = nil,
        behind: Int? = nil, merging: Bool
    ) {
        self.current = current
        self.head = head
        self.local = local
        self.remote = remote
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.merging = merging
    }
    /// Returns true when a push or a publish went out since `old`, which starts CI. That is when the same branch now
    /// has fewer commits to push, or has just appeared on a remote.
    public func pushed(since old: BranchInfo) -> Bool {
        upstream != nil && current == old.current && (old.upstream == nil || (ahead ?? 0) < (old.ahead ?? 0))
    }
}

/// The newest commits a sync would move. `outgoing` is what a push sends, and `incoming` is what a pull brings (none
/// without an upstream).
public struct Unsynced: Codable, Sendable, Equatable {
    public struct Commit: Codable, Sendable, Equatable {
        public var hash: String, subject: String, author: String
        /// Seconds since 1970.
        public var date: Double
        public init(hash: String, subject: String, author: String, date: Double) {
            self.hash = hash
            self.subject = subject
            self.author = author
            self.date = date
        }
    }
    public var outgoing: [Commit], incoming: [Commit]
    /// When the last fetch was, in seconds since 1970. nil when there was none, and for a remote project, because it
    /// isn't read over ssh.
    public var fetched: Double?
    public init(outgoing: [Commit], incoming: [Commit], fetched: Double? = nil) {
        self.outgoing = outgoing
        self.incoming = incoming
        self.fetched = fetched
    }
}

/// Lines added and removed in the working tree (staged, unstaged and new files) compared with HEAD, split by the kind
/// of file.
public struct LineStats: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case code, tests, generated }
    public var added: [Kind: Int] = [:], removed: [Kind: Int] = [:]
    public var totalAdded: Int { added.values.reduce(0, +) }
    public var totalRemoved: Int { removed.values.reduce(0, +) }
    public init(added: [Kind: Int] = [:], removed: [Kind: Int] = [:]) {
        self.added = added
        self.removed = removed
    }

    /// Returns the kind of a file. Lock files, build output and codegen count as generated. Test folders and files
    /// named `*.test.*` or `*Tests.swift` count as tests.
    public static func kind(_ path: String) -> Kind {
        let lowered = path.lowercased(), name = (lowered as NSString).lastPathComponent
        let locks: Set<String> = [
            "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock", "cargo.lock", "podfile.lock",
            "package.resolved", "go.sum", "poetry.lock", "composer.lock", "gemfile.lock", "uv.lock", "flake.lock"
        ]
        if locks.contains(name) || lowered.hasPrefix("dist/") || lowered.hasPrefix("build/")
            || lowered.contains("/__generated__/")
            || lowered.contains("/generated/")
            || name.contains(".min.") || name.contains(".generated.") || name.hasSuffix(".pb.go")
            || name.hasSuffix(".g.dart") || name.hasSuffix(".snap")
        {
            return .generated
        }
        let dirs = lowered.split(separator: "/").dropLast()
        if dirs.contains(where: {
            ["test", "tests", "spec", "specs", "__tests__", "testing"].contains($0) || $0.hasSuffix("tests")
        })
            || name.contains(".test.") || name.contains(".spec.") || name.contains("_test.") || name.hasPrefix("test_")
            || name.hasSuffix("tests.swift") || name.hasSuffix("test.swift")
        {
            return .tests
        }
        return .code
    }
}

public struct SearchMatch: Codable, Sendable, Equatable {
    public var path: String
    public var line: Int
    public var text: String
    public init(path: String, line: Int, text: String) {
        self.path = path
        self.line = line
        self.text = text
    }
}

/// Project files. Quick Open's fuzzy match lives here, while listing and searching (with git and rg) live in GitKit.
public enum ProjectFiles {
    /// The most files `files.list` returns, so a list this long may be missing some. It is more than nearly any
    /// checkout has, and it stops a folder that should be ignored from making a list that Quick Open and the tree choke
    /// on.
    public static let listLimit = 200_000
    /// The most matches `files.search` returns, so a list this long may be missing some.
    public static let searchLimit = 2000

    /// A path prepared once for fuzzyScore, because Quick Open scores every file of the project on each keystroke.
    /// It holds the Unicode scalars of the composed form. So "é" is one letter however the name was stored, and "日"
    /// can't be matched from pieces of other characters, as it could with UTF-8 bytes.
    public struct FuzzyPath: Sendable {
        let scalars: [Unicode.Scalar], name: Int, length: Int   // lowercased, where the file name starts, length in characters
        public init(_ path: String) {
            scalars = fuzzyQuery(path)
            name = scalars.lastIndex(of: "/").map { $0 + 1 } ?? 0
            length = path.count
        }
    }
    /// Returns the query (or a path) in the form fuzzyScore compares.
    public static func fuzzyQuery(_ query: String) -> [Unicode.Scalar] {
        Array(query.precomposedStringWithCanonicalMapping.lowercased().unicodeScalars)
    }

    /// Returns the fuzzy subsequence score for Quick Open, where higher is better and nil means no match. Matches
    /// inside the file name score higher.
    public static func fuzzyScore(_ path: FuzzyPath, _ query: [Unicode.Scalar]) -> Int? {
        if query.isEmpty { return 0 }
        let full = subsequenceScore(path.scalars[...], query),
            inName = subsequenceScore(path.scalars[path.name...], query).map { $0 + 100 }
        guard let best = [full, inName].compactMap({ $0 }).max() else { return nil }
        return best - path.length / 4
    }

    private static let wordStarts = Set("/._- ".unicodeScalars)
    static func subsequenceScore(_ path: ArraySlice<Unicode.Scalar>, _ query: [Unicode.Scalar]) -> Int? {
        var ci = path.startIndex, score = 0, streak = 0, last = -2
        for ch in query {
            guard ci < path.endIndex, let found = path[ci...].firstIndex(of: ch) else { return nil }
            streak = (found == last + 1) ? streak + 1 : 0
            score += 10 + streak * 5
            if found == path.startIndex || wordStarts.contains(path[found - 1]) { score += 15 }   // word start
            last = found
            ci = found + 1
        }
        return score
    }
}
