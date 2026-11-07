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
        for (slug, record) in list(root: root) where record.session == session && record.file != nil {
            do { kept += try keepVersion(slug, record, root: root, label: label, now: now) ? 1 : 0 } catch {
                failed = failed ?? error
            }   // the others still
        }
        if let failed { throw failed }
        return kept
    }

    private static func keepVersion(_ slug: String, _ record: ArtifactRecord, root: String, label: String, now: Date)
        throws
        -> Bool
    {
        let target = target(slug, record, root: root)
        guard let live = small(target) else { return false }
        var versions = record.versions ?? []
        if let last = versions.last, versionText(target: target, last.n).map({ Data($0.utf8) }) == live { return false }
        let number = (versions.last?.n ?? 0) + 1, folder = URL(fileURLWithPath: target).deletingLastPathComponent()
        let dir = folder.appendingPathComponent("versions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try live.write(to: URL(fileURLWithPath: versionPath(target: target, number)))
        versions.append(
            ArtifactVersion(n: number, at: now.timeIntervalSince1970, label: oneLine(label, number: number)))
        for old in versions.dropLast(keptVersions) {   // one gone already (by hand) is no reason to stop keeping
            let path = versionPath(target: target, old.n)
            if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
        }
        var updated = record
        updated.versions = Array(versions.suffix(keptVersions))
        try save(updated, in: folder)
        return true
    }

    /// The file of version `number` of the page at `target`.
    public static func versionPath(target: String, _ number: Int) -> String {
        let url = URL(fileURLWithPath: target)
        return url.deletingLastPathComponent().appendingPathComponent("versions/\(number).\(url.pathExtension)").path
    }

    static func versionText(target: String, _ number: Int) -> String? {
        small(versionPath(target: target, number)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The prompt's first line, at most 80 characters; "Turn n" for none.
    private static func oneLine(_ prompt: String, number: Int) -> String {
        let line =
            prompt.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return "Turn \(number)" }
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }
}
