import Core
import Foundation
import GitKit
import os

/// The folders of a workspace git ignores (dist/, build/, coverage/…): what changes in them changes neither git status nor
/// the file list, and a build writes there all the time. Each folder is asked once, all again after a .gitignore changes.
/// Limit: folders only (a `*.o` written beside the sources still counts), and a tracked file in an ignored folder isn't seen.
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

    /// `paths` less those in a folder git ignores.
    func drop(_ paths: [String]) -> [String] {
        let rel = paths.map { p in prefixes.first(where: p.hasPrefix).map { String(p.dropFirst($0.count)) } }
        if rel.contains(where: { $0.map(Self.rulesChange) ?? false }) { known.withLock { $0 = [:] } }
        let folders = rel.map { $0.map(Self.folders) ?? [] }
        var k = known.withLock { $0 }
        let unknown = Set(folders.filter { !$0.contains { k[$0] == true } }.joined()).filter { k[$0] == nil }
        if !unknown.isEmpty {
            // A git that fails here counts every change, as before.
            let hits = (try? Git.ignored(Array(unknown), cwd: root, remotes: remotes)) ?? []
            k = known.withLock { k in
                for f in unknown { k[f] = hits.contains(f) }
                return k
            }
        }
        return zip(paths, folders).filter { _, fs in !fs.contains { k[$0] == true } }.map(\.0)
    }

    /// The folders `rel` is in, outermost first: "a/b/c.txt" is in "a/" and "a/b/". git's own folder is left to `Git.touches…`.
    static func folders(_ rel: String) -> [String] {
        guard !rel.hasPrefix(".git/") else { return [] }
        let parts = rel.split(separator: "/").dropLast()
        return parts.indices.map { parts[...$0].joined(separator: "/") + "/" }
    }

    static func rulesChange(_ rel: String) -> Bool {
        rel == ".gitignore" || rel.hasSuffix("/.gitignore") || rel == ".git/info/exclude"
    }
}
