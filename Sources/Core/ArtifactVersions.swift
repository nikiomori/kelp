import Foundation

/// A page as one turn of its agent left it: `versions/<n>.md` beside it, named by the prompt that started the turn.
public struct ArtifactVersion: Codable, Equatable, Sendable {
    public var n: Int
    /// Seconds since 1970.
    public var at: Double
    public var label: String
    public init(n: Int, at: Double, label: String) { self.n = n; self.at = at; self.label = label }
}

extension Artifacts {
    /// Kelp keeps this many; older ones go.
    public static let keptVersions = 20

    /// A turn of chat `session` ended: each page it made whose file changed since its last version gets a new one, named
    /// `label` (the turn's prompt, on one line). Returns how many were kept.
    @discardableResult
    public static func keepVersions(root: String, session: String, label: String, now: Date = Date()) throws -> Int {
        var kept = 0
        for (slug, r) in list(root: root) where r.session == session && r.file != nil {
            let target = target(slug, r, root: root)
            guard let live = FileManager.default.contents(atPath: target) else { continue }
            var versions = r.versions ?? []
            if let last = versions.last, versionText(target: target, last.n).map { Data($0.utf8) } == live { continue }
            let n = (versions.last?.n ?? 0) + 1, folder = URL(fileURLWithPath: target).deletingLastPathComponent()
            let dir = folder.appendingPathComponent("versions")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try live.write(to: dir.appendingPathComponent("\(n).md"))
            versions.append(ArtifactVersion(n: n, at: now.timeIntervalSince1970, label: oneLine(label, n: n)))
            for old in versions.dropLast(keptVersions) {
                try FileManager.default.removeItem(at: dir.appendingPathComponent("\(old.n).md"))
            }
            var record = r
            record.versions = Array(versions.suffix(keptVersions))
            try save(record, in: folder)
            kept += 1
        }
        return kept
    }

    /// The file of version `n` of the page at `target`.
    public static func versionPath(target: String, _ n: Int) -> String {
        URL(fileURLWithPath: target).deletingLastPathComponent().appendingPathComponent("versions/\(n).md").path
    }

    static func versionText(target: String, _ n: Int) -> String? {
        FileManager.default.contents(atPath: versionPath(target: target, n)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The prompt's first line, at most 80 characters; "Turn n" for none.
    private static func oneLine(_ s: String, n: Int) -> String {
        let line = s.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return "Turn \(n)" }
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }
}
