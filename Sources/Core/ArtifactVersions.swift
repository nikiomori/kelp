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

    /// A turn of chat `session` ended: each page it made whose file changed since its last version gets a new one, named
    /// `label` (the turn's prompt, on one line). Returns how many were kept.
    @discardableResult
    public static func keepVersions(root: String, session: String, label: String, now: Date = Date()) throws -> Int {
        var kept = 0, failed: (any Error)?
        for (slug, r) in list(root: root) where r.session == session && r.file != nil {
            do { kept += try keepVersion(slug, r, root: root, label: label, now: now) ? 1 : 0 } catch {
                failed = failed ?? error
            }   // the others still
        }
        if let failed { throw failed }
        return kept
    }

    private static func keepVersion(_ slug: String, _ r: ArtifactRecord, root: String, label: String, now: Date) throws
        -> Bool
    {
        let target = target(slug, r, root: root)
        guard let live = small(target) else { return false }
        var versions = r.versions ?? []
        if let last = versions.last, versionText(target: target, last.n).map({ Data($0.utf8) }) == live { return false }
        let n = (versions.last?.n ?? 0) + 1, folder = URL(fileURLWithPath: target).deletingLastPathComponent()
        let dir = folder.appendingPathComponent("versions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try live.write(to: URL(fileURLWithPath: versionPath(target: target, n)))
        versions.append(ArtifactVersion(n: n, at: now.timeIntervalSince1970, label: oneLine(label, n: n)))
        for old in versions.dropLast(keptVersions) {   // one gone already (by hand) is no reason to stop keeping
            let p = versionPath(target: target, old.n)
            if FileManager.default.fileExists(atPath: p) { try FileManager.default.removeItem(atPath: p) }
        }
        var record = r
        record.versions = Array(versions.suffix(keptVersions))
        try save(record, in: folder)
        return true
    }

    /// The file of version `n` of the page at `target`.
    public static func versionPath(target: String, _ n: Int) -> String {
        let url = URL(fileURLWithPath: target)
        return url.deletingLastPathComponent().appendingPathComponent("versions/\(n).\(url.pathExtension)").path
    }

    static func versionText(target: String, _ n: Int) -> String? {
        small(versionPath(target: target, n)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The prompt's first line, at most 80 characters; "Turn n" for none.
    private static func oneLine(_ s: String, n: Int) -> String {
        let line =
            s.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return "Turn \(n)" }
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }
}
