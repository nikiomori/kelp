import Core

/// The files of a workspace's diff marked as read, each with a print of its diff when marked: a file an agent changed
/// since doesn't match its print any more, so it's unread again by itself. Kept in the daemon's UI state as
/// "path<TAB>print" strings under `key(worktree)`.
enum ViewedFiles {
    static func key(_ worktree: String) -> String { "viewed/" + worktree }

    /// A short print of the file's changes as shown, the same on every run (FNV-1a over its hunks).
    static func print(_ d: FileDiff) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for b in d.hunks.map(\.fingerprint).joined(separator: "\n").utf8 { hash = (hash ^ UInt64(b)) &* 0x100000001b3 }
        return String(hash, radix: 36)
    }

    static func read(_ entries: [String]) -> [String: String] {
        Dictionary(
            entries.compactMap { entry in
                let parts = entry.split(separator: "\t", maxSplits: 1)
                return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
            }, uniquingKeysWith: { _, b in b })
    }

    /// Marks kept of files the diff on screen doesn't hold: another source (Staged, a commit) shows them.
    static let kept = 300

    /// `marks` with `d` marked or not. A file `diffs` doesn't hold keeps its mark (its print tells whether it's still
    /// read), until there are more than `kept`: then only the files `diffs` holds keep theirs.
    static func marking(_ d: FileDiff, _ on: Bool, in marks: [String: String], diffs: [FileDiff]) -> [String] {
        let here = Set(diffs.map(\.path))
        var updated = marks.count < kept ? marks : marks.filter { here.contains($0.key) }
        updated[d.path] = on ? print(d) : nil
        return updated.map { "\($0.key)\t\($0.value)" }.sorted()
    }

    /// `printed`: the file's print worked out already (off the main thread, with its rows); a file not marked needs none.
    static func viewed(_ d: FileDiff, in marks: [String: String], printed: String? = nil) -> Bool {
        guard let mark = marks[d.path] else { return false }
        return mark == (printed ?? print(d))
    }
}
