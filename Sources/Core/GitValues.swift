import Foundation

// git's output as values: what the daemon sends and the app shows. Running git is GitKit's (the daemon's).

/// Thin wrapper over the system git: reading its output here, running it in GitKit.
public enum Git {
    /// Whether file events can change what `git status` says: anything outside `.git/`, and inside it only what moves the
    /// index, HEAD or a branch (lock and object files churn during every git command, a status of ours included).
    public static func touchesStatus(_ paths: [String]) -> Bool {
        paths.contains { p in
            guard let r = p.range(of: "/.git/") else { return true }
            let rest = p[r.upperBound...]
            return rest == "index" || rest == "HEAD" || rest == "MERGE_HEAD" || rest == "packed-refs" || rest.hasPrefix("refs/")
        }
    }

    /// Whether a change at one of `paths` can change a workspace's file list (`files.list`) or what it shows: anything
    /// outside .git; in it, only the index (`git rm --cached`, staging) and HEAD (a checkout). git's own churn otherwise
    /// would list the files again several times a second.
    public static func touchesFileList(_ paths: [String]) -> Bool {
        paths.contains { p in
            guard let r = p.range(of: "/.git/") else { return !p.hasSuffix("/.git") }
            let rest = p[r.upperBound...]
            return rest == "index" || rest == "HEAD"
        }
    }

    /// Commits no remote branch has. Topological order lists a commit before its ancestors, so one pass down from the
    /// remote branches' tips marks everything they reach; what's left is local only. No remotes: nothing to mark.
    public static func unpushed(_ commits: [GraphCommit], remotes: Set<String>) -> Set<String> {
        guard !remotes.isEmpty else { return [] }
        var pushed = Set<String>(), out = Set<String>()
        for c in commits {
            if pushed.contains(c.hash) || c.refs.contains(where: remotes.contains) { pushed.formUnion(c.parents) } else { out.insert(c.hash) }
        }
        return out
    }
}

public struct FileChange: Codable, Sendable, Equatable {
    public var path: String
    public var index: String   // staged status column
    public var worktree: String
    public init(path: String, index: String, worktree: String) { self.path = path; self.index = index; self.worktree = worktree }
    public var staged: Bool { index != "." && index != "?" }
    public var unstaged: Bool { worktree != "." }
    public var untracked: Bool { index == "?" }
    public var conflicted: Bool { index == "U" || worktree == "U" || (index == "A" && worktree == "A") || (index == "D" && worktree == "D") }

    /// A status lists at most this many (VS Code's limit too): a folder that should be ignored (node_modules) can hold
    /// hundreds of thousands, and the list goes to the app on each change. A status this long may be missing some.
    public static let limit = 10_000
}

/// What Source Control lists, in the order it lists it: conflicts, then what's staged, then the rest.
/// A file with both staged and unstaged edits is in two sections; a conflicted one only in the first.
public struct ChangeGroups: Equatable, Sendable {
    public var merge: [FileChange], staged: [FileChange], changes: [FileChange]
    public init(merge: [FileChange], staged: [FileChange], changes: [FileChange]) { self.merge = merge; self.staged = staged; self.changes = changes }
}

extension Array where Element == FileChange {
    public var grouped: ChangeGroups {
        ChangeGroups(merge: filter(\.conflicted),
                     staged: filter { $0.staged && !$0.conflicted },
                     changes: filter { ($0.unstaged || $0.untracked) && !$0.conflicted })
    }
}

extension FileChange {
    /// VS Code's status letter: `inWorktree` picks which column speaks (the unstaged list shows the worktree's).
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
    public enum Kind: String, Codable, Sendable { case context, add, del }
    public var kind: Kind
    public var text: String
    public var oldLine: Int?
    public var newLine: Int?
    /// The file's last line, with no newline after it (git's "\ No newline at end of file").
    public var noNewline: Bool?
    public init(kind: Kind, text: String, oldLine: Int? = nil, newLine: Int? = nil, noNewline: Bool? = nil) {
        self.kind = kind; self.text = text; self.oldLine = oldLine; self.newLine = newLine; self.noNewline = noNewline
    }
}

public struct Hunk: Codable, Sendable, Equatable {
    public var header: String
    public var oldStart: Int, newStart: Int
    public var lines: [DiffLine]
    public init(header: String, oldStart: Int, newStart: Int, lines: [DiffLine]) {
        self.header = header; self.oldStart = oldStart; self.newStart = newStart; self.lines = lines
    }
}

extension Hunk {
    /// The hunk as shown, header and every line: an edit inside it that keeps the counts (a line rewritten in place) changes
    /// this, where the "@@" header alone stays the same.
    public var fingerprint: String {
        ([header] + lines.map { "\($0.kind.rawValue)|\($0.text)" }).joined(separator: "\n")
    }
}

public struct FileDiff: Codable, Sendable, Equatable {
    public var path: String
    /// Raw `diff --git` / `---` / `+++` lines, needed to rebuild patches for hunk staging.
    public var header: String
    public var hunks: [Hunk]
    public var binary: Bool
    /// The file isn't UTF-8: its text was read byte for byte (Latin-1), and patches go back the same way.
    public var latin1: Bool?
    /// Its changes are past what one reply carries (`Git.diffBudget`): no hunks, only the header. Asked for alone, it may fit.
    public var tooLarge: Bool?
    public init(path: String, header: String, hunks: [Hunk], binary: Bool, latin1: Bool? = nil, tooLarge: Bool? = nil) {
        self.path = path; self.header = header; self.hunks = hunks; self.binary = binary; self.latin1 = latin1; self.tooLarge = tooLarge
    }
    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .add }.count } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .del }.count } }

    /// Patch containing only the given hunk, for `git apply --cached [-R]`, in the file's own bytes.
    public func patch(hunk i: Int) -> Data {
        var s = header + "\n" + hunks[i].header + "\n"
        for l in hunks[i].lines {
            s += (l.kind == .add ? "+" : l.kind == .del ? "-" : " ") + l.text + "\n"
            if l.noNewline == true { s += "\\ No newline at end of file\n" }
        }
        return latin1 == true ? Data(s.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }) : Data(s.utf8)
    }
}

/// A commit's message body (the subject is the graph's), its author's email, and its size against the first parent.
public struct CommitDetails: Codable, Sendable, Equatable {
    public var body: String
    public var email: String
    public var files: Int, added: Int, removed: Int
    public init(body: String, email: String, files: Int, added: Int, removed: Int) {
        self.body = body; self.email = email; self.files = files; self.added = added; self.removed = removed
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
    public init(hash: String, parents: [String], author: String, date: Double, subject: String, refs: [String], lane: Int, top: [[Int]], bottom: [[Int]]) {
        self.hash = hash; self.parents = parents; self.author = author; self.date = date; self.subject = subject
        self.refs = refs; self.lane = lane; self.top = top; self.bottom = bottom
    }
}

public struct BranchInfo: Codable, Sendable, Equatable {
    public var current: String?        // nil when HEAD is detached
    public var head: String?           // short hash of HEAD (nil before the first commit)
    public var local: [String]
    public var remote: [String]
    public var upstream: String?
    /// Commits to push: past the upstream, or with none, on no remote branch (what the graph marks "not pushed yet").
    public var ahead: Int?
    public var behind: Int?
    public var merging: Bool
    public init(current: String?, head: String?, local: [String], remote: [String], upstream: String? = nil, ahead: Int? = nil,
                behind: Int? = nil, merging: Bool) {
        self.current = current; self.head = head; self.local = local; self.remote = remote
        self.upstream = upstream; self.ahead = ahead; self.behind = behind; self.merging = merging
    }
    /// The same branch with fewer commits to push, or newly on a remote: a push (or a publish) went out, which starts CI.
    public func pushed(since old: BranchInfo) -> Bool {
        upstream != nil && current == old.current && (old.upstream == nil || (ahead ?? 0) < (old.ahead ?? 0))
    }
}

/// The newest commits a sync would move: `outgoing` is what a push sends, `incoming` what a pull brings (none without an upstream).
public struct Unsynced: Codable, Sendable, Equatable {
    public struct Commit: Codable, Sendable, Equatable {
        public var hash: String, subject: String, author: String
        /// Seconds since 1970.
        public var date: Double
        public init(hash: String, subject: String, author: String, date: Double) {
            self.hash = hash; self.subject = subject; self.author = author; self.date = date
        }
    }
    public var outgoing: [Commit], incoming: [Commit]
    public init(outgoing: [Commit], incoming: [Commit]) { self.outgoing = outgoing; self.incoming = incoming }
}

/// Lines added / removed in the working tree (staged, unstaged and new files) against HEAD, split by what kind of file.
public struct LineStats: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case code, tests, generated }
    public var added: [Kind: Int] = [:], removed: [Kind: Int] = [:]
    public var totalAdded: Int { added.values.reduce(0, +) }
    public var totalRemoved: Int { removed.values.reduce(0, +) }
    public init(added: [Kind: Int] = [:], removed: [Kind: Int] = [:]) { self.added = added; self.removed = removed }

    /// Lock files, build output and codegen count as generated; test folders and `*.test.*` / `*Tests.swift` as tests.
    public static func kind(_ path: String) -> Kind {
        let p = path.lowercased(), name = (p as NSString).lastPathComponent
        let locks: Set<String> = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock", "cargo.lock", "podfile.lock",
                                  "package.resolved", "go.sum", "poetry.lock", "composer.lock", "gemfile.lock", "uv.lock", "flake.lock"]
        if locks.contains(name) || p.hasPrefix("dist/") || p.hasPrefix("build/") || p.contains("/__generated__/") || p.contains("/generated/")
            || name.contains(".min.") || name.contains(".generated.") || name.hasSuffix(".pb.go") || name.hasSuffix(".g.dart") || name.hasSuffix(".snap") {
            return .generated
        }
        let dirs = p.split(separator: "/").dropLast()
        if dirs.contains(where: { ["test", "tests", "spec", "specs", "__tests__", "testing"].contains($0) || $0.hasSuffix("tests") })
            || name.contains(".test.") || name.contains(".spec.") || name.contains("_test.") || name.hasPrefix("test_")
            || name.hasSuffix("tests.swift") || name.hasSuffix("test.swift") {
            return .tests
        }
        return .code
    }
}

public struct SearchMatch: Codable, Sendable, Equatable {
    public var path: String; public var line: Int; public var text: String
    public init(path: String, line: Int, text: String) { self.path = path; self.line = line; self.text = text }
}

/// Project files: Quick Open's fuzzy match here, listing and search (git, rg) in GitKit.
public enum ProjectFiles {
    /// `files.list` gives at most this many (a list this long may be missing some): more than nearly any checkout has,
    /// and a folder that should be ignored can't make a list Quick Open and the tree choke on.
    public static let listLimit = 200_000
    /// `files.search` gives at most this many matches (a list this long may be missing some).
    public static let searchLimit = 2000

    /// A path made ready for fuzzyScore once: Quick Open scores every file of the project on each keystroke.
    /// Unicode scalars of the composed form, so "é" is one letter however the name was stored and "日" can't be matched
    /// from pieces of other characters (as UTF-8 bytes could).
    public struct FuzzyPath: Sendable {
        let scalars: [Unicode.Scalar], name: Int, length: Int   // lowercased, where the file name starts, length in characters
        public init(_ path: String) {
            scalars = fuzzyQuery(path)
            name = scalars.lastIndex(of: "/").map { $0 + 1 } ?? 0
            length = path.count
        }
    }
    /// The query (or a path) as fuzzyScore compares it.
    public static func fuzzyQuery(_ q: String) -> [Unicode.Scalar] { Array(q.precomposedStringWithCanonicalMapping.lowercased().unicodeScalars) }

    /// Fuzzy subsequence score for quick open (higher is better, nil = no match). Matches inside the file name win.
    public static func fuzzyScore(_ c: FuzzyPath, _ q: [Unicode.Scalar]) -> Int? {
        if q.isEmpty { return 0 }
        let full = subsequenceScore(c.scalars[...], q), inName = subsequenceScore(c.scalars[c.name...], q).map { $0 + 100 }
        guard let best = [full, inName].compactMap({ $0 }).max() else { return nil }
        return best - c.length / 4
    }

    private static let wordStarts = Set("/._- ".unicodeScalars)
    static func subsequenceScore(_ c: ArraySlice<Unicode.Scalar>, _ q: [Unicode.Scalar]) -> Int? {
        var ci = c.startIndex, score = 0, streak = 0, last = -2
        for ch in q {
            guard ci < c.endIndex, let i = c[ci...].firstIndex(of: ch) else { return nil }
            streak = (i == last + 1) ? streak + 1 : 0
            score += 10 + streak * 5
            if i == c.startIndex || wordStarts.contains(c[i - 1]) { score += 15 }   // word start
            last = i; ci = i + 1
        }
        return score
    }
}
