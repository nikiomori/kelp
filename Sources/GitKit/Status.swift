import Core
import Foundation

extension Git {
    /// Parse `git status --porcelain=v2 -z`: entries end in NUL, paths are as they are (no quoting), and a rename's
    /// entry is followed by its old path. Renames report the new path. The first `limit` entries.
    public static func parseStatus(_ output: String, limit: Int = .max) -> [FileChange] {
        var out: [FileChange] = [], oldPath = false
        for entry in output.split(separator: "\0") {
            if oldPath {
                oldPath = false
                continue
            }
            if out.count >= limit { break }
            oldPath = entry.hasPrefix("2")
            let fields = entry.split(
                separator: " ", maxSplits: entry.hasPrefix("2") ? 9 : (entry.hasPrefix("u") ? 10 : 8),
                omittingEmptySubsequences: false)
            switch entry.first {
            case "1" where fields.count >= 9:
                let xy = Array(fields[1]).map(String.init)
                out.append(FileChange(path: String(fields[8]), index: xy[0], worktree: xy[1]))
            case "2" where fields.count >= 10:
                let xy = Array(fields[1]).map(String.init)
                out.append(FileChange(path: String(fields[9]), index: xy[0], worktree: xy[1]))
            case "u" where fields.count >= 11:
                out.append(FileChange(path: String(fields[10]), index: "U", worktree: "U"))
            case "?":
                out.append(FileChange(path: String(entry.dropFirst(2)), index: "?", worktree: "?"))
            default: break
            }
        }
        return out
    }

    /// Returns the repository's status. With `only`, it returns one file's status, because a diff of one file mustn't
    /// walk every untracked folder in the repository. With `limit`, it returns the first that many entries
    /// (`FileChange.limit` for what's shown), and git's output past them is read and dropped. Without a limit, it
    /// returns all of them or an error.
    public static func status(_ path: String, only file: String? = nil, limit: Int = .max, remotes: Remotes)
        throws -> [FileChange]
    {
        let args = ["status", "--porcelain=v2", "-z", "-uall"] + (file.map { ["--"] + literal([$0]) } ?? [])
        let output = try runPart(args, cwd: path, limit: Subprocess.outputLimit, remotes: remotes)
        let changes = parseStatus(
            wholeEntries(output, 0), limit: limit
        )
        guard !output.truncated || changes.count >= limit else { throw GitError.tooMuch }
        return changes
    }
}
