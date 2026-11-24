import Core
import Foundation

extension Main {
    /// `artifact links <name>`: where a design's buttons and links go, board to board, and the dead ends.
    static func links(_ cwd: String, _ c: RPCClient) async throws {
        let root = try await projectRoot(cwd, c)
        guard let name = args.first, let artifact = Artifacts.list(root: root).first(where: { $0.slug == name }),
            artifact.record.file == Artifacts.Kind.design.file
        else { fail("artifact links <name of a design> (names: kelp artifact list)") }
        let folder = URL(fileURLWithPath: Artifacts.target(artifact.slug, artifact.record, root: root))
            .deletingLastPathComponent()
        let read = { (file: String) in
            FileManager.default.contents(atPath: folder.appendingPathComponent(file).path).map {
                String(decoding: $0, as: UTF8.self)
            }
        }
        guard let canvas = read(Artifacts.Kind.design.file).flatMap(ArtifactCanvas.read) else {
            fail("can't read \(name)'s canvas.json")
        }
        let lines = BoardLinks.lines(BoardLinks.all(canvas, read: read), boards: canvas.boards.map(\.file))
        print(lines.isEmpty ? "No buttons or links on its boards." : lines.joined(separator: "\n"))
    }

    /// `artifact new … --from <file>`: the file copied beside the new page, and the line that says so ("" without one).
    static func keep(_ source: String?, beside page: String) throws -> String {
        guard let source else { return "" }
        let from = URL(fileURLWithPath: (source as NSString).expandingTildeInPath)
        let to = URL(fileURLWithPath: page).deletingLastPathComponent().appendingPathComponent(from.lastPathComponent)
        try FileManager.default.copyItem(at: from, to: to)
        return "\nMade from \(to.path), kept beside it: read it whole, then make the page from it."
    }
}
