import Foundation

/// A page as one turn of its agent left it: `versions/<n>.md` (or `.html`) beside it, named by the prompt that started the turn.
public struct ArtifactVersion: Codable, Equatable, Sendable {
    public var n: Int
    /// Seconds since 1970.
    public var at: Double
    public var label: String
    public init(n: Int, at: Double, label: String) {
        self.n = n
        self.at = at
        self.label = label
    }
}

extension Artifacts {
    /// Kelp keeps this many; older ones go.
    public static let keptVersions = 20

    /// The file of version `number` of the page at `target`.
    public static func versionPath(target: String, _ number: Int) -> String {
        let url = URL(fileURLWithPath: target)
        return url.deletingLastPathComponent().appendingPathComponent("versions/\(number).\(url.pathExtension)").path
    }

    /// The lines of `new` (from 1) that aren't in `old`, and the line where lines of `old` were taken out: what a
    /// turn changed, for the page to mark.
    public static func changedLines(from old: String, to new: String) -> [Int] {
        let a = old.split(separator: "\n", omittingEmptySubsequences: false)
        let b = new.split(separator: "\n", omittingEmptySubsequences: false)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case .insert(let offset, _, _): inserted.insert(offset)
            case .remove(let offset, _, _): removed.insert(offset)
            }
        }
        // Both walked side by side: a line taken out of `old` is marked where `new` is at that point.
        var out = Set<Int>(), i = 0, j = 0
        while i < a.count || j < b.count {
            if removed.contains(i) {
                out.insert(min(j, b.count - 1) + 1)
                i += 1
            } else if inserted.contains(j) {
                out.insert(j + 1)
                j += 1
            } else {
                i += 1
                j += 1
            }
        }
        return out.sorted()
    }
}
