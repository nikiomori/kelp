import Core
import Foundation

extension Git {
    /// Parse `git status --porcelain=v2 -z`: entries end in NUL, paths are as they are (no quoting), and a rename's
    /// entry is followed by its old path. Renames report the new path. The first `limit` entries.
    public static func parseStatus(_ s: String, limit: Int = .max) -> [FileChange] {
        var out: [FileChange] = [], oldPath = false
        for l in s.split(separator: "\0") {
            if oldPath {
                oldPath = false
                continue
            }
            if out.count >= limit { break }
            oldPath = l.hasPrefix("2")
            let f = l.split(
                separator: " ", maxSplits: l.hasPrefix("2") ? 9 : (l.hasPrefix("u") ? 10 : 8),
                omittingEmptySubsequences: false)
            switch l.first {
            case "1" where f.count >= 9:
                let xy = Array(f[1]).map(String.init)
                out.append(FileChange(path: String(f[8]), index: xy[0], worktree: xy[1]))
            case "2" where f.count >= 10:
                let xy = Array(f[1]).map(String.init)
                out.append(FileChange(path: String(f[9]), index: xy[0], worktree: xy[1]))
            case "u" where f.count >= 11:
                out.append(FileChange(path: String(f[10]), index: "U", worktree: "U"))
            case "?":
                out.append(FileChange(path: String(l.dropFirst(2)), index: "?", worktree: "?"))
            default: break
            }
        }
        return out
    }

    /// `only`: one file's status (a diff of one file mustn't walk every untracked folder in the repository). `limit`: the
    /// first that many entries (`FileChange.limit` for what's shown; git's output past them is read and dropped);
    /// without one, all of them or an error.
    public static func status(_ path: String, only file: String? = nil, limit: Int = .max, remotes: Remotes = .none)
        throws -> [FileChange]
    {
        let a = ["status", "--porcelain=v2", "-z", "-uall"] + (file.map { ["--"] + literal([$0]) } ?? [])
        let r = try runPart(a, cwd: path, limit: Subprocess.outputLimit, remotes: remotes)
        let changes = parseStatus(
            String(decoding: r.truncated ? wholeEntries(r.data, 0) : r.data, as: UTF8.self), limit: limit)
        guard !r.truncated || changes.count >= limit else { throw tooMuch(a) }
        return changes
    }
}
