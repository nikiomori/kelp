import Foundation

/// A page as one of its agent's turns left it, kept as `versions/<n>.md` (or `.html`) beside the page and labelled with
/// the prompt that started the turn.
public struct ArtifactVersion: Codable, Equatable, Sendable {
    public var n: Int
    /// Seconds since 1970.
    public var at: Double
    public var label: String
    /// Whether the user's hand edits made it: its label then names what they changed, not a prompt.
    public var byUser: Bool?
    /// The version the user brought back to make it (Restore), when it is one.
    public var restored: Int?
    public init(n: Int, at: Double, label: String, byUser: Bool? = nil, restored: Int? = nil) {
        self.n = n
        self.at = at
        self.label = label
        self.byUser = byUser
        self.restored = restored
    }
}

extension Artifacts {
    /// Where the app leaves its check of a video it exported for `kelp artifact export`, which waits for it.
    public static func exportCheck(for video: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kelp-export-checks")
            .appendingPathComponent(video.replacingOccurrences(of: "/", with: "_") + ".json")
    }

    /// How many versions Kelp keeps. Older ones are removed, but for those the user saved.
    public static let keptVersions = 20

    /// The versions the user saved by a name of their own, beside the page: `{"3": "Approved"}`.
    public static let savedFile = "saved.json"

    /// The saved versions' names by number, from `json` (the file's text; nil: none). Throws when it doesn't read.
    public static func saved(_ json: String?) throws -> [Int: String] {
        guard let data = json?.data(using: .utf8) else { return [:] }
        let names = try JSONDecoder().decode([String: String].self, from: data)
        return Dictionary(uniqueKeysWithValues: names.compactMap { k, v in Int(k).map { ($0, v) } })
    }

    public static func savedJSON(_ names: [Int: String]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let keyed = Dictionary(uniqueKeysWithValues: names.map { (String($0.key), $0.value) })
        return String(decoding: try encoder.encode(keyed), as: UTF8.self) + "\n"
    }

    /// The versions kept: the last `keptVersions`, and any the user saved.
    public static func kept(_ versions: [ArtifactVersion], saved: Set<Int>) -> [ArtifactVersion] {
        let last = Set(versions.suffix(keptVersions).map(\.n))
        return versions.filter { last.contains($0.n) || saved.contains($0.n) }
    }

    /// Returns the file of version `number` of the page at `target`.
    public static func versionPath(target: String, _ number: Int) -> String {
        let url = URL(fileURLWithPath: target)
        return url.deletingLastPathComponent().appendingPathComponent("versions/\(number).\(url.pathExtension)").path
    }

    /// Returns the line numbers (from 1) of `new` that aren't in `old`, plus the lines where lines of `old` were taken
    /// out. This is what a turn changed, for the page to mark.
    public static func changedLines(from old: String, to new: String) -> [Int] {
        let before = old.split(separator: "\n", omittingEmptySubsequences: false)
        let after = new.split(separator: "\n", omittingEmptySubsequences: false)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in after.difference(from: before) {
            switch change {
            case .insert(let offset, _, _): inserted.insert(offset)
            case .remove(let offset, _, _): removed.insert(offset)
            }
        }
        // Walk both texts side by side. A line taken out of `old` is marked at the line `new` has reached then.
        var out = Set<Int>(), i = 0, j = 0
        while i < before.count || j < after.count {
            if removed.contains(i) {
                out.insert(min(j, after.count - 1) + 1)
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
