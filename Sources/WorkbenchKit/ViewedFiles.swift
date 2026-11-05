import Core

/// The files of a workspace's diff marked as read, each with a print of its diff when marked: a file an agent changed
/// since doesn't match its print any more, so it's unread again by itself. Kept in the daemon's UI state as
/// "path<TAB>print" strings under `key(worktree)`.
public enum ViewedFiles {
    public static func key(_ worktree: String) -> String { "viewed/" + worktree }

    /// A short print of the file's changes as shown, the same on every run (FNV-1a over its hunks).
    public static func print(_ d: FileDiff) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in d.hunks.map(\.fingerprint).joined(separator: "\n").utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 36)
    }

    public static func read(_ entries: [String]) -> [String: String] {
        Dictionary(entries.compactMap { e in
            let p = e.split(separator: "\t", maxSplits: 1)
            return p.count == 2 ? (String(p[0]), String(p[1])) : nil
        }, uniquingKeysWith: { _, b in b })
    }

    /// `marks` with `d` marked or not, keeping only the files `diffs` still holds (what's gone needs no mark).
    public static func marking(_ d: FileDiff, _ on: Bool, in marks: [String: String], diffs: [FileDiff]) -> [String] {
        var m = marks.filter { k, _ in diffs.contains { $0.path == k } }
        m[d.path] = on ? print(d) : nil
        return m.map { "\($0.key)\t\($0.value)" }.sorted()
    }

    public static func viewed(_ d: FileDiff, in marks: [String: String]) -> Bool { marks[d.path] == print(d) }
}
