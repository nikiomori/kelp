import AppKit
import Core
import KelpKit

/// A design's boards and their variations (`CanvasVariants`): Variations ×3 asks the agent for three directions of a
/// board as boards beside it; Keep puts the one kept in the original's place (its file's text) and takes the others
/// off the canvas, their files staying, and keeps that as the user's version; Three More Like This asks for more in
/// its direction. Duplicate and Remove change the canvas by hand.
extension MarkdownTab {
    func variantsMessage(_ kind: String, _ body: [String: Any]) -> Bool {
        guard let board = body["board"] as? String else { return false }
        let page = Artifacts.projectPath(url.path)
        switch kind {
        case "boardMenu":
            let menu = NSMenu()
            menu.add(String(localized: "Variations of This Board")) { [weak self] in
                self?.send(Self.variations(of: board, page: page, like: nil))
            }
            menu.addItem(.separator())
            menu.add(String(localized: "Copy as Picture")) { [weak self] in self?.copyBoard(board) }
            menu.add(String(localized: "Duplicate Board")) { [weak self] in self?.duplicateBoard(board) }
            menu.add(String(localized: "Remove Board")) { [weak self] in self?.removeBoard(board) }
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        case "moreLike":
            send(Self.variations(of: body["of"] as? String ?? board, page: page, like: board))
        case "keepVariant":
            keepVariant(board, of: body["of"] as? String ?? board)
        default: return false
        }
        return true
    }

    /// The request for three variations of `board` (in the direction of `like`, when there is one).
    static func variations(of board: String, page: String, like: String?) -> String {
        let base = (board as NSString).deletingPathExtension
        let way =
            like.map { "three more in the direction of \($0) (keep its idea, vary the details)" }
            ?? "three directions: same content, a different layout each"
        return "Variations on \(page): make \(way) of \(board) as new boards (\(base)-b.html, \(base)-c.html…), "
            + "listed in canvas.json right after it with \"variant\": \"\(board)\". Leave \(board) as it is."
    }

    private func keepVariant(_ kept: String, of original: String) {
        let folder = url.deletingLastPathComponent()
        Task {
            if kept != original {
                guard let text = await app.call(FilesRead(path: folder.appendingPathComponent(kept).path)),
                    let old = await app.call(FilesRead(path: folder.appendingPathComponent(original).path))
                else { return }
                guard
                    await app.call(
                        FilesWrite(
                            path: folder.appendingPathComponent(original).path, text: text.text, base: old.stamp))
                        != nil
                else { return }
            }
            guard await changeBoards({ $0.filter { ($0["variant"] as? String) != original } }) else { return }
            await app.quiet(ArtifactKeepVersion(path: url.path, label: "kept \(kept)"))
        }
    }

    private func duplicateBoard(_ board: String) {
        let folder = url.deletingLastPathComponent()
        Task {
            guard let file = await app.call(FilesRead(path: folder.appendingPathComponent(board).path)) else { return }
            let base = (board as NSString).deletingPathExtension
            let taken = Set(ArtifactCanvas.read(editor.text)?.boards.map(\.file) ?? [])
            let copy =
                (1...).lazy.map { "\(base)-copy\($0 == 1 ? "" : String($0)).html" }.first { !taken.contains($0) }
                ?? base + "-copy.html"
            guard
                await app.call(FilesWrite(path: folder.appendingPathComponent(copy).path, text: file.text, base: nil))
                    != nil
            else { return }
            _ = await changeBoards({ boards in
                var out = boards
                guard let i = boards.firstIndex(where: { ($0["file"] as? String) == board }) else {
                    return boards
                }
                var entry = boards[i]
                entry["file"] = copy
                entry["title"] = ((entry["title"] as? String) ?? board) + " " + String(localized: "copy")
                entry["variant"] = nil
                out.insert(entry, at: i + 1)
                return out
            })
        }
    }

    private func removeBoard(_ board: String) {
        Task { _ = await changeBoards({ $0.filter { ($0["file"] as? String) != board } }) }
    }

    /// Changes canvas.json's board list and saves it; false, with a banner, when it doesn't read.
    private func changeBoards(_ change: ([[String: Any]]) -> [[String: Any]]) async -> Bool {
        let json: String
        do { json = try ArtifactCanvas.editBoards(editor.text, change) } catch {
            Banner.show(String(localized: "canvas.json doesn't read: fix it first."), style: .error)
            return false
        }
        editor.apply(text: json, selection: NSRange(location: 0, length: 0))
        return await saveFile?() ?? false
    }
}
