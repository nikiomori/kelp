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
}
