import Core
import Foundation

/// The daemon's side of a page's marks (`ArtifactMarks`): the counts the artifacts list shows, the version a send is
/// checked against, and what the end of a turn hands back to the user.
extension Artifacts {
    /// How many of the marks in `folder` are with an agent or wait for the user. nil when none are.
    static func markCounts(in folder: URL) -> ArtifactMarkCounts? {
        let path = folder.appendingPathComponent(ArtifactMarks.file).path
        guard fileStat(path) != nil else { return nil }
        let counts = ArtifactMarks.read(small(path)).counts
        let sent = counts[.sent] ?? 0, check = counts[.check] ?? 0
        return sent + check == 0 ? nil : ArtifactMarkCounts(sent: sent, check: check)
    }

    /// Whether the page in `folder` has marks with chat `session`, waiting for its turn to end.
    static func hasMarks(sentTo session: String, in folder: URL) -> Bool {
        ArtifactMarks.read(small(folder.appendingPathComponent(ArtifactMarks.file).path)).marks.contains {
            $0.state == .sent && ($0.rounds.last?.to == nil || $0.rounds.last?.to == session)
        }
    }

    /// The page whose file is `path`: its folder's name, its record and its project's folder. nil when `path` isn't a
    /// page in a project's `.kelp/artifacts`.
    static func page(at path: String) -> (slug: String, record: ArtifactRecord, root: String)? {
        guard let marker = path.range(of: "/\(folder)/") else { return nil }
        let pageFolder = URL(fileURLWithPath: path).deletingLastPathComponent()
        guard let record = record(in: pageFolder) else { return nil }
        return (pageFolder.lastPathComponent, record, String(path[..<marker.lowerBound]))
    }

    /// Keeps a version of the page at `path` as it is now, when it changed since its last version, and returns the
    /// last version's number. `label` names what the user changed by hand; with none, the version is labelled as the
    /// page the marks were sent with.
    static func versionForMarks(page path: String, label: String) throws -> Int? {
        guard let (slug, record, root) = page(at: path) else { return nil }
        _ = try keepVersion(
            slug, record, root: root, label: label.isEmpty ? "Marks sent" : label, byUser: !label.isEmpty, now: Date())
        return self.record(in: URL(fileURLWithPath: path).deletingLastPathComponent())?.versions?.last?.n
    }

    /// The text of the thing `mark` is on in version `n` of the page at `target` (nil for the page as it is now): its
    /// board's text on a canvas, the page's text on a doc. nil when that version or board isn't there.
    static func markedText(_ mark: ArtifactMark, target: String, record: ArtifactRecord, version n: Int?) -> String? {
        let canvas = record.file == Kind.design.file
        guard let n else {
            let file = canvas ? (target as NSString).deletingLastPathComponent + "/" + mark.board : target
            return small(file).map { String(decoding: $0, as: UTF8.self) }
        }
        guard let text = versionText(target: target, n) else { return nil }
        return canvas ? CanvasSnapshot.read(text)?.boards[mark.board] : text
    }

    /// Called when a turn of chat `session` ends, after its versions are kept. Each page whose marks went to that chat,
    /// and which the turn's prompt was about, hands its marks back to the user with what the turn did to each one.
    static func settleMarks(root: String, session: String, prompt: String) throws {
        for (slug, _) in list(root: root) {
            let folder = dir(root: root).appendingPathComponent(slug)
            guard hasMarks(sentTo: session, in: folder), let record = record(in: folder), record.file != nil else {
                continue
            }
            let target = target(slug, record, root: root)
            let after = record.versions?.last?.n
            try ArtifactMarks.update(in: folder) { marks in
                marks.turnEnded(session: session, prompt: prompt, page: projectPath(target), after: after) {
                    mark, round in
                    ArtifactMarks.outcome(
                        of: mark,
                        before: round.before.flatMap { markedText(mark, target: target, record: record, version: $0) },
                        after: markedText(mark, target: target, record: record, version: after))
                }
            }
        }
    }
}

extension ArtifactMarksChange: Handled {
    // Agents may not call it (`agents` is `.none`): marks are the user's. A reply has its own method.
    var fence: Fence { Fence(writesInFolder: (path as NSString).deletingLastPathComponent) }

    func handle(_: NoService) throws -> ArtifactMarks {
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        guard Artifacts.page(at: path) != nil else {
            throw RPCError.invalidParams("not a page in .kelp/artifacts: \(path)")
        }
        var change = change
        if change.kind == .send {
            let edits = ArtifactMarks.read(Artifacts.small(folder.appendingPathComponent(ArtifactMarks.file).path))
                .edits
            let label = Array(Set(edits.map(\.id))).sorted().joined(separator: ", ")
            change.before = try Artifacts.versionForMarks(page: path, label: label)
        }
        let written = try ArtifactMarks.update(in: folder) { marks in
            if let pictures, !pictures.isEmpty {
                let dir = folder.appendingPathComponent(ArtifactMarks.pictures)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for (key, png) in pictures {
                    guard let id = Int(key), let i = marks.marks.firstIndex(where: { $0.id == id }) else { continue }
                    let name = "\(id)-\(marks.marks[i].rounds.count + 1).png"   // each sending keeps its own
                    try png.write(to: dir.appendingPathComponent(name), options: .atomic)
                    marks.marks[i].picture = ArtifactMarks.pictures + "/" + name
                }
            }
            return marks.apply(change) || !(pictures ?? [:]).isEmpty
        }
        return written ?? ArtifactMarks.read(Artifacts.small(folder.appendingPathComponent(ArtifactMarks.file).path))
    }
}

extension ArtifactKeepVersion: Handled {
    var fence: Fence { Fence(writesInFolder: (path as NSString).deletingLastPathComponent) }

    func handle(_: NoService) throws -> Bool {
        guard let (slug, record, root) = Artifacts.page(at: path) else { return false }
        return try Artifacts.keepVersion(slug, record, root: root, label: label, byUser: true, now: Date())
    }
}

extension ArtifactReply: Handled {
    static let agents = AgentAccess.acts
    var fence: Fence { Fence(writesInFolder: (path as NSString).deletingLastPathComponent) }

    func handle(_: NoService) throws -> Bool {
        guard Artifacts.page(at: path) != nil else {
            throw RPCError.invalidParams("not a page in .kelp/artifacts: \(path)")
        }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { throw RPCError.invalidParams("say something about the mark") }
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        guard try ArtifactMarks.update(in: folder, { $0.apply(.reply(id: id, text: String(line.prefix(2000)))) }) != nil
        else {
            throw RPCError.invalidParams("no mark #\(id) with you or waiting for the user: see kelp artifact marks")
        }
        return true
    }
}
