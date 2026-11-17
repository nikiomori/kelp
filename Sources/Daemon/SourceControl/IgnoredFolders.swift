import Core
import Foundation
import GitKit
import os

/// Tracks the folders of a workspace that git ignores (dist/, build/, coverage/…). A change in them changes neither git
/// status nor the file list, and a build writes there all the time. Git is asked about each folder once, and about all
/// of them again after a .gitignore changes.
/// Limit: only folders count (a `*.o` written beside the sources still counts), and a tracked file in an ignored
/// folder isn't seen.
final class IgnoredFolders: Sendable {
    private let root: String
    private let prefixes: [String]   // the root as FSEvents may name it (/tmp is /private/tmp)
    private let known = OSAllocatedUnfairLock<[String: Bool]>(initialState: [:])

    private let remotes: Remotes

    init(root: String, remotes: Remotes) {
        self.root = root
        self.remotes = remotes
        prefixes = Array(Set([root, Paths.real(root) ?? root].map { $0.hasSuffix("/") ? $0 : $0 + "/" }))
    }

    /// Returns `changes` without those in a folder that git ignores.
    func drop(_ changes: [FileWatcher.Change]) -> [FileWatcher.Change] {
        let rel = changes.map(\.path).map { p in
            prefixes.first(where: p.hasPrefix).map { String(p.dropFirst($0.count)) }
        }
        if rel.contains(where: { $0.map(Self.rulesChange) ?? false }) { known.withLock { $0 = [:] } }
        let folders = rel.map { $0.map(Self.folders) ?? [] }
        var answers = known.withLock { $0 }
        let unknown = Set(folders.filter { !$0.contains { answers[$0] == true } }.joined()).filter {
            answers[$0] == nil
        }
        if !unknown.isEmpty {
            // A git that fails here counts every change, as before.
            let hits = (try? Git.ignored(Array(unknown), cwd: root, remotes: remotes)) ?? []
            answers = known.withLock { cached in
                for folder in unknown { cached[folder] = hits.contains(folder) }
                return cached
            }
        }
        return zip(changes, folders).filter { _, fs in !fs.contains { answers[$0] == true } }.map(\.0)
    }

    /// Returns the folders that `rel` is in, outermost first, so "a/b/c.txt" is in "a/" and "a/b/". Changes in git's
    /// own folder are left to `Git.touches…`.
    static func folders(_ rel: String) -> [String] {
        guard !rel.hasPrefix(".git/") else { return [] }
        let parts = rel.split(separator: "/").dropLast()
        return parts.indices.map { parts[...$0].joined(separator: "/") + "/" }
    }

    static func rulesChange(_ rel: String) -> Bool {
        rel == ".gitignore" || rel.hasSuffix("/.gitignore") || rel == ".git/info/exclude"
    }
}
