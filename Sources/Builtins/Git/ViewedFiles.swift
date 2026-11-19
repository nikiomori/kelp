import Core

/// The files of a workspace's diff marked as read, each with a print of its diff when it was marked. When an agent
/// changes the file since, it no longer matches its print, so it is unread again by itself. The marks are kept in the
/// daemon's UI state as "path<TAB>print" strings under `key(worktree)`.
enum ViewedFiles {
    static func key(_ worktree: String) -> String { "viewed/" + worktree }

    /// A short print of the file's changes as shown, the same on every run (FNV-1a over its hunks).
    static func print(_ fileDiff: FileDiff) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in fileDiff.hunks.map(\.fingerprint).joined(separator: "\n").utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(hash, radix: 36)
    }

    static func read(_ entries: [String]) -> [String: String] {
        Dictionary(
            entries.compactMap { entry in
                let parts = entry.split(separator: "\t", maxSplits: 1)
                return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
            }, uniquingKeysWith: { _, b in b })
    }

    /// How many marks are kept before the marks of files the diff on screen doesn't hold are dropped. Another source
    /// (Staged, a commit) may show those files.
    static let kept = 300

    /// Returns `marks` with `fileDiff` marked or not. A file `diffs` doesn't hold keeps its mark (its print tells
    /// whether it's still read) until there are more than `kept` marks; then only the files `diffs` holds keep theirs.
    static func marking(_ fileDiff: FileDiff, _ on: Bool, in marks: [String: String], diffs: [FileDiff]) -> [String] {
        let here = Set(diffs.map(\.path))
        var updated = marks.count < kept ? marks : marks.filter { here.contains($0.key) }
        updated[fileDiff.path] = on ? print(fileDiff) : nil
        return updated.map { "\($0.key)\t\($0.value)" }.sorted()
    }

    /// `printed` is the file's print when it was worked out already (off the main thread, with its rows). A file that
    /// isn't marked needs none.
    static func viewed(_ fileDiff: FileDiff, in marks: [String: String], printed: String? = nil) -> Bool {
        guard let mark = marks[fileDiff.path] else { return false }
        return mark == (printed ?? print(fileDiff))
    }
}
